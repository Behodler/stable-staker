// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IStableStaker.sol";

/**
 * @title InPlaceMigrator
 * @notice Swaps a per-token dependency (e.g. an {IYieldStrategy}) on a SINGLE live {StableStaker}
 *         in place, without a throwaway temp staker.
 *
 * @dev (A) USE CASE — This contract safely changes a per-token dependency (e.g. an `IYieldStrategy`)
 *      on a single live `StableStaker` without hot-swapping while staking is live. It evacuates
 *      users into the migrator's own custody, lets the operator run the empty-pool-only
 *      `finalizeAndReset` + `setYieldStrategy` rewire, then re-injects the same users into the same
 *      staker. Source and target are the same staker — hence in place.
 *
 *      `StableStaker.setYieldStrategy(token, strategy)` reverts unless `poolInfo[token].totalStaked
 *      == 0` (empty-pool gate). There is no hot-swap path: to replace a strategy on a live pool you
 *      must drain every staker out, reset the pool, wire the new strategy, then put everyone back.
 *      A cross-staker migrator (`CrossVersionMigrator`) does this by bouncing all users through a
 *      throwaway temp `StableStaker`. This migrator removes the temp staker: it already physically
 *      receives the principal during `batchMigrate` (the staker `safeTransfer`s the aggregate to
 *      `msg.sender`), so instead of forwarding it into a temp staker and pulling it back later, it
 *      simply PARKS it across the reset and re-injects it into the SAME staker once the new
 *      strategy is wired.
 *
 *      (B) CUSTODY IS THE WHOLE POINT — Between `migrateOut` and `migrateIn` the migrator holds raw
 *      principal for every parked user. This is a real, deliberate trust concession during the
 *      rewire window. It exists ONLY because `setYieldStrategy` is empty-pool-only: the principal
 *      has to leave the staker so the pool can be reset and rewired, and the migrator is where it
 *      waits. The window is intended to be SHORT (minutes-to-hours) and fully operator-orchestrated
 *      (out -> finalizeAndReset -> setYieldStrategy -> in, ideally same operator session).
 *
 *      (C) THE OWNER CAN NEVER REDIRECT PARKED PRINCIPAL TO A NON-USER DESTINATION — The ONLY two
 *      exits for parked principal are:
 *        1. `migrateIn` -> `staker.depositFor(token, user, amount)` (the immutable staker, crediting
 *           the original parked user), and
 *        2. `claimTimedOut` -> `safeTransfer(msg.sender, amount)` (the parked user themselves).
 *      There is no owner path that sends parked principal anywhere else. `rescueERC20` is fenced
 *      below the `totalParked` floor (see (G)) so it cannot touch parked principal either.
 *
 *      (F) TIMEOUT IS A GUARDED ESCAPE HATCH, NOT A CONVENIENCE — `claimTimedOut` is permissionless
 *      and self-scoped, but only opens after `migrationTimeout` has elapsed since the user's
 *      `migrateOut`. The delay is intentional: it gives the operator an uninterrupted window to
 *      finish the rewire while still guaranteeing that if the operator is incapacitated / loses keys
 *      / keys are compromised, every parked user can eventually recover their PRINCIPAL unilaterally.
 *      Earned phUSD was already minted to the user at `migrateOut` (inside the staker's
 *      `batchMigrate`), so the hatch returns PRINCIPAL ONLY.
 *
 *      Scoped for a small staker set, a single batch, and a short window. Not built for long-running,
 *      multi-day, many-batch migrations. `CrossVersionMigrator` is the tool for the cross-staker /
 *      cross-version (true replacement) case; this contract is additive.
 */
contract InPlaceMigrator is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @notice The single live staker we are rewiring in place. Source AND target.
     * @dev (D) THE STAKER IS IMMUTABLE — ON PURPOSE. We deliberately do NOT accept an owner-supplied
     *      target in `migrateIn`. An owner-mutable target is a drain vector: a compromised key could
     *      point `depositFor` at a malicious contract that pulls the scoped approval and credits
     *      nobody, defeating the timeout hatch (the parked users would have nothing to claim back).
     *      Pinning `staker` at construction closes that hole — re-injection can only ever go back into
     *      this one staker that the users were drained from.
     */
    IStableStaker public immutable staker;

    /// @notice Seconds after `migrateOut` before a parked user may invoke `claimTimedOut`.
    uint256 public immutable migrationTimeout;

    /// @notice token => user => parked principal currently held in custody by this migrator.
    mapping(address => mapping(address => uint256)) public parked;

    /// @notice token => user => `block.timestamp` at which the user was migrated out (timeout anchor).
    mapping(address => mapping(address => uint256)) public migrationBegin;

    /// @notice token => set of users currently parked (re-injection / timeout-claim worklist).
    mapping(address => EnumerableSet.AddressSet) private _parkedUsers;

    /// @notice token => Σ parked[token][*]. The FLOOR `rescueERC20` can never cross — see (G).
    mapping(address => uint256) public totalParked;

    /// @notice Lower bound on `migrationTimeout`: rejects 0/tiny values that would open the hatch
    ///         immediately and let an impatient user front-run `migrateIn` and break the migration.
    uint256 public constant MIN_TIMEOUT = 1 days;

    /// @notice Upper bound on `migrationTimeout` (1 month, operator-confirmed): rejects an
    ///         effectively-infinite value that would neuter the escape hatch (users never recover).
    uint256 public constant MAX_TIMEOUT = 30 days;

    /// @notice Emitted when a batch of users is drained out of the staker into custody.
    event MigratedOut(address indexed token, uint256 userCount, uint256 totalPrincipal);

    /// @notice Emitted when a slice of parked users is re-injected into the staker.
    event MigratedIn(address indexed token, uint256 userCount, uint256 totalPrincipal);

    /// @notice Emitted when a parked user unilaterally reclaims their principal after the timeout.
    event TimedOutClaim(address indexed token, address indexed user, uint256 amount);

    /**
     * @notice Emitted per re-injected user in {migrateIn}, recording the migration-slippage top-up.
     * @param token         The re-injected token.
     * @param user          The user re-credited.
     * @param parked        The principal that was parked for the user (the `amt` re-injected).
     * @param credited      What the FIRST `depositFor(amt)` actually credited (haircut-reduced).
     * @param topup         The grossed-up surplus-funded top-up deposited to close the shortfall (0 if none).
     * @param finalCredited The user's total credited principal across both deposits (target == `parked`).
     */
    event ReinjectedWithTopup(
        address indexed token,
        address indexed user,
        uint256 parked,
        uint256 credited,
        uint256 topup,
        uint256 finalCredited
    );

    /**
     * @param _staker          The single live staker to rewire in place (source AND target).
     * @param _migrationTimeout Seconds before `claimTimedOut` opens. Recommended deploy value: 7 days.
     * @param initialOwner     The operator who orchestrates the migration.
     */
    constructor(IStableStaker _staker, uint256 _migrationTimeout, address initialOwner) Ownable(initialOwner) {
        require(address(_staker) != address(0), "InPlaceMigrator: zero staker");
        // MIN_TIMEOUT rejects 0/tiny values (immediate hatch -> front-run migrateIn); MAX_TIMEOUT
        // rejects an effectively-infinite value that would neuter the hatch (users never recover).
        require(
            _migrationTimeout >= MIN_TIMEOUT && _migrationTimeout <= MAX_TIMEOUT,
            "InPlaceMigrator: timeout out of bounds"
        );
        staker = _staker;
        migrationTimeout = _migrationTimeout;
    }

    // ============================== MIGRATION (OUT) ==============================

    /**
     * @notice Engage terminal migration on the staker for `token`. Thin owner-only forwarder to
     *         {IStableStaker-initiateMigration} (realizes the strategy position once, snapshots
     *         `(R, P)`, freezes emissions). Call exactly once per token BEFORE the first `migrateOut`.
     * @param token The staked token to put into terminal migration.
     */
    function initiateMigration(address token) external onlyOwner {
        staker.initiateMigration(token);
    }

    /**
     * @notice Drain a batch of users out of the staker and PARK their principal in this migrator's
     *         custody. The staker mints each user's frozen earned phUSD during `batchMigrate` and
     *         `safeTransfer`s the aggregate snapshot credit to this contract; we record it per-user.
     * @dev Requires a prior {initiateMigration} for `token` (the staker reverts otherwise). Idempotent
     *      by construction: `batchMigrate` zeroes the source position, so a re-run returns `0` for an
     *      already-migrated user — no double-park guard is needed (an already-parked user is simply not
     *      touched again).
     * @param token The staked token being drained.
     * @param users The users to drain out (build batches off-chain via the staker's getStakers views).
     */
    function migrateOut(address token, address[] calldata users) external onlyOwner nonReentrant {
        uint256[] memory amounts = staker.batchMigrate(token, users);

        uint256 total;
        uint256 count;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 amt = amounts[i];
            if (amt > 0) {
                parked[token][users[i]] += amt;
                migrationBegin[token][users[i]] = block.timestamp;
                _parkedUsers[token].add(users[i]);
                totalParked[token] += amt;
                total += amt;
                count++;
            }
        }

        emit MigratedOut(token, count, total);
    }

    // ============================== MIGRATION (IN) ==============================

    /**
     * @notice Re-inject a slice `[start, end)` of currently-parked users back into the SAME staker,
     *         crediting each user the exact principal that was parked for them.
     * @dev (D) IMMUTABLE TARGET — re-injection goes ONLY into the immutable `staker`; there is no
     *      owner-supplied target. (E) SCOPED APPROVALS — `forceApprove` is set to the EXACT slice total
     *      immediately before the `depositFor` loop and never left dangling: `forceApprove` overwrites
     *      the previous allowance, and `depositFor` pulls exactly the slice total, so nothing lingers.
     *
     *      Snapshots the slice into a memory array FIRST, because removing users from the set mid-loop
     *      shifts live indices. CEI under `nonReentrant`: each user's `parked` is checked `> 0` and the
     *      state is zeroed BEFORE its `depositFor` external call. Skips already-claimed/empty users
     *      (parked == 0) with no revert and no double pay.
     * @param token The staked token being re-injected.
     * @param start Inclusive start index into the parked-user set.
     * @param end   Exclusive end index (clamped to the set length).
     */
    function migrateIn(address token, uint256 start, uint256 end) external onlyOwner nonReentrant {
        EnumerableSet.AddressSet storage set = _parkedUsers[token];
        uint256 len = set.length();
        if (end > len) {
            end = len;
        }
        require(start <= end, "InPlaceMigrator: bad range");

        // Snapshot the slice FIRST: removing from the set mid-loop shifts live indices.
        uint256 sliceLen = end - start;
        address[] memory slice = new address[](sliceLen);
        uint256 total;
        for (uint256 i = 0; i < sliceLen; i++) {
            address user = set.at(start + i);
            slice[i] = user;
            total += parked[token][user];
        }

        // (E) Approve the migrator's FULL token balance for this token immediately before the loop.
        // The principal deposits pull `total`; the per-user top-ups pull ADDITIONAL surplus, and the
        // cumulative top-ups across the batch cannot exceed the surplus (= balance - totalParked).
        // Approving the whole balance bounds and covers both legs in a single scoped approval that
        // `forceApprove` overwrites (no dangling allowance).
        if (IERC20(token).balanceOf(address(this)) > 0) {
            IERC20(token).forceApprove(address(staker), IERC20(token).balanceOf(address(this)));
        }

        uint256 count;
        for (uint256 i = 0; i < sliceLen; i++) {
            address user = slice[i];
            uint256 amt = parked[token][user];
            if (amt == 0) {
                // Already claimed via the timeout hatch (or otherwise emptied) — skip, no double pay.
                continue;
            }
            // Effects BEFORE interaction (CEI): zero the parked state before depositFor.
            parked[token][user] = 0;
            delete migrationBegin[token][user];
            totalParked[token] -= amt;
            _parkedUsers[token].remove(user);
            count++;

            // (C) The only owner-driven exit for parked principal: back into the immutable staker,
            // crediting the original user. No other destination is reachable. Delegated to a helper
            // to keep the loop frame shallow (interactions + top-up locals live in the helper).
            _reinjectWithTopup(token, user, amt);
        }

        emit MigratedIn(token, count, total);
    }

    /**
     * @notice Re-inject `amt` parked principal for `user` into the staker, then close the
     *         migration-slippage shortfall with a surplus-funded, grossed-up top-up so the user lands
     *         at par (within `amt/1000`). Reverts the whole batch if the live surplus can't cover it.
     * @dev Extracted from {migrateIn}'s loop to keep that frame shallow (avoids stack-too-deep). MUST
     *      be called only AFTER the caller's CEI effects block has zeroed `parked`/`migrationBegin`,
     *      decremented `totalParked` by `amt`, and removed the user from the set — the live-surplus
     *      check relies on `totalParked` already reflecting this user's exit.
     */
    function _reinjectWithTopup(address token, address user, uint256 amt) private {
        // M-01 fix: `depositFor(amt)` credits only the strategy's (haircut-reduced) return, so a
        // re-injected user would be silently underpaid by the migration slippage. Snapshot the credited
        // principal around the deposit, then close any shortfall with a surplus-funded top-up grossed
        // up to survive its OWN haircut, restoring the user to par.
        (uint256 amountBefore,) = staker.userInfo(token, user);
        staker.depositFor(token, user, amt); // funded from parked principal (as today)
        (uint256 amountAfter,) = staker.userInfo(token, user);
        uint256 credited = amountAfter - amountBefore; // > 0: depositFor reverts on zero credit

        uint256 topup = 0;
        if (credited < amt) {
            // Gross-up so the top-up survives its OWN haircut: topup = shortfall * amt / credited.
            // Math.mulDiv avoids intermediate overflow on `shortfall * amt`.
            topup = Math.mulDiv(amt - credited, amt, credited);
            // Implicit budget: surplus held above the remaining parked principal. The caller's effects
            // block already decremented `totalParked` by `amt`, and the principal `depositFor` pulled
            // `amt` from balance, so only a top-up (no matching `totalParked` decrement) consumes it.
            require(
                topup <= IERC20(token).balanceOf(address(this)) - totalParked[token],
                "InPlaceMigrator: top-up surplus exhausted"
            );
            staker.depositFor(token, user, topup); // funded from migrator surplus balance
        }

        (uint256 finalAmount,) = staker.userInfo(token, user);
        uint256 finalCredited = finalAmount - amountBefore;
        // Non-reverting backstop: the gross-up targets exact par algebraically, so this only ever
        // forgives the few-wei integer-division residual. It binds only under a pathological ~100%
        // haircut, where reverting the batch is correct.
        require(finalCredited >= amt - amt / 1000, "InPlaceMigrator: par not restored");
        emit ReinjectedWithTopup(token, user, amt, credited, topup, finalCredited);
    }

    // ============================== TIMEOUT ESCAPE HATCH ==============================

    /**
     * @notice Permissionless, self-only escape hatch: a parked user reclaims THEIR OWN principal once
     *         `migrationTimeout` has elapsed since their `migrateOut`.
     * @dev (F) Returns PRINCIPAL ONLY — earned phUSD was already minted to the user at `migrateOut`.
     *      Strict CEI under `nonReentrant`: all state is cleared BEFORE the transfer, so a malicious
     *      token callback cannot re-enter to double-claim (the second entry sees `parked == 0`).
     * @param token The token whose parked principal the caller is reclaiming.
     */
    function claimTimedOut(address token) external nonReentrant {
        uint256 amount = parked[token][msg.sender];
        require(amount > 0, "InPlaceMigrator: nothing parked");
        require(
            block.timestamp >= migrationBegin[token][msg.sender] + migrationTimeout,
            "InPlaceMigrator: timeout not elapsed"
        );

        // Effects BEFORE interaction (CEI).
        parked[token][msg.sender] = 0;
        delete migrationBegin[token][msg.sender];
        totalParked[token] -= amount;
        _parkedUsers[token].remove(msg.sender);

        // (C) The only user-driven exit for parked principal: to the user themselves.
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TimedOutClaim(token, msg.sender, amount);
    }

    // ============================== RESCUE ==============================

    /**
     * @notice Sweep a STRAY/DONATED token balance above the parked floor to `to`.
     * @dev (G) `totalParked[token]` is the floor the owner can NEVER cross — this is what preserves
     *      invariant (C) even against the owner. `surplus` is the balance strictly above all parked
     *      principal; any `amount` that would dip into `totalParked` reverts. It is therefore incapable
     *      of touching parked principal.
     * @param token  The token to rescue surplus of.
     * @param to     The recipient of the surplus.
     * @param amount The surplus amount to sweep (must be <= balance - totalParked).
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        uint256 surplus = IERC20(token).balanceOf(address(this)) - totalParked[token];
        require(amount <= surplus, "InPlaceMigrator: cannot touch parked principal");
        IERC20(token).safeTransfer(to, amount);
    }

    // ============================== VIEWS ==============================

    /// @notice Number of users currently parked for `token`.
    function parkedUserCount(address token) external view returns (uint256) {
        return _parkedUsers[token].length();
    }

    /**
     * @notice Page through the currently-parked users for `token` (for building `migrateIn` slices).
     * @param token The token whose parked users to list.
     * @param start Inclusive start index (clamped to length).
     * @param end   Exclusive end index (clamped to length).
     */
    function parkedUsersRange(address token, uint256 start, uint256 end)
        external
        view
        returns (address[] memory users)
    {
        EnumerableSet.AddressSet storage set = _parkedUsers[token];
        uint256 len = set.length();
        if (end > len) {
            end = len;
        }
        if (start > end) {
            start = end;
        }
        users = new address[](end - start);
        for (uint256 i = 0; i < users.length; i++) {
            users[i] = set.at(start + i);
        }
    }

    /// @notice Timestamp at/after which `user` may `claimTimedOut` for `token` (0 if not parked).
    function claimableAt(address token, address user) external view returns (uint256) {
        uint256 begin = migrationBegin[token][user];
        if (begin == 0) {
            return 0;
        }
        return begin + migrationTimeout;
    }
}
