// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "flax-token/IFlax.sol";
import "pauser/interfaces/IPausable.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import "./interfaces/IStableStaker.sol";

/**
 * @title StableStaker
 * @notice A MasterChef-style yield farm that supports any number of staked (stable) tokens and
 *         rewards stakers in phUSD. Unlike a classic MasterChef, rewards are not paid from a
 *         pre-funded balance: the contract is an authorized minter of phUSD and mints rewards
 *         directly to users on claim / withdraw / migration.
 *
 * @dev Reward accounting is the canonical per-pool MasterChef model, one pool per token:
 *
 *        accPhusdPerShare += elapsed * phusdPerSecond * ACC_PRECISION / totalStaked
 *        pending(user)     = user.amount * accPhusdPerShare / ACC_PRECISION - user.rewardDebt
 *
 *      Emission-cap invariant (the core safety property): the only writer of `accPhusdPerShare`
 *      is {_updatePool}, which folds in exactly `elapsed * phusdPerSecond` of value per update.
 *      The sum of every staker's pending increase therefore equals that amount minus
 *      integer-division dust, *independent of how stake is split or churned*. Consequences:
 *        - flash staking (stake + exit in one block) yields elapsed == 0 -> 0 reward;
 *        - windows where `totalStaked == 0` accrue nothing (lastRewardTime is fast-forwarded);
 *        - dust always rounds DOWN, so realized emission <= phusdPerSecond * elapsed.
 *      Hence no sequence of user actions can mint more than `phUSDPerDay` for a token over any
 *      window. {phUSDPerDay} settles the pool at the old rate before changing it, so a rate
 *      change is never applied retroactively.
 *
 *      Pausing follows the Behodler3 pattern (OZ {Pausable} + {IPausable}): a dedicated `pauser`
 *      address pauses; owner OR pauser unpauses. The {emergencyWithdraw} escape hatch and the
 *      migration hooks intentionally remain callable while paused.
 */
contract StableStaker is Ownable, Pausable, ReentrancyGuard, IPausable, IStableStaker {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Fixed-point scaling factor for `accPhusdPerShare`. Dust rounds down.
    uint256 public constant ACC_PRECISION = 1e18;

    /// @notice Seconds in a day, used to convert a per-day budget into a per-second rate.
    uint256 public constant SECONDS_PER_DAY = 86400;

    /// @notice The phUSD reward token. This contract must be an authorized minter on it.
    IFlax public immutable phUSD;

    /// @notice Address authorized to pause the contract (Behodler3 pattern). Satisfies IPausable.
    address public override pauser;

    /// @notice Address authorized to perform permissioned migration (initiateMigration / batchMigrate / depositFor).
    address public migrator;

    /// @notice Per-token reward pool accounting.
    struct PoolInfo {
        uint256 phusdPerSecond; // current emission rate (phUSD wei per second)
        uint256 accPhusdPerShare; // accumulated phUSD per staked unit, scaled by ACC_PRECISION
        uint256 lastRewardTime; // last time the pool accrued
        uint256 totalStaked; // total principal staked in this pool
    }

    /// @notice Per-user position within a pool.
    struct UserInfo {
        uint256 amount; // staked principal
        uint256 rewardDebt; // accounting baseline: amount * accPhusdPerShare / ACC_PRECISION at last settle
    }

    /// @notice token => pool accounting.
    mapping(address => PoolInfo) public poolInfo;

    /// @notice token => user => position.
    mapping(address => mapping(address => UserInfo)) public override userInfo;

    /// @notice token => enumerable set of addresses currently holding a non-zero position.
    mapping(address => EnumerableSet.AddressSet) private _stakers;

    /// @notice Set of every registered pool token.
    EnumerableSet.AddressSet private _registeredTokens;

    /// @notice token => yield strategy that custodies its principal. address(0) ⇒ held idle in-contract.
    /// @dev Principal-moving paths route through this adapter when set. Reward accounting is unaffected:
    ///      yield accrued inside the strategy is protocol-owned and never credited to stakers.
    mapping(address => IYieldStrategy) public yieldStrategy;

    /// @notice Per-token pool lifecycle state. The pool is a small, explicit state machine; every
    ///         operational gate reads {poolState} (NOT a boolean inside {MigrationInfo}, which was
    ///         removed in favour of this enum). Two legal states and ONLY two transitions:
    ///           - Active   -> Migrating: {initiateMigration} (onlyMigrator), one-way per engagement.
    ///           - Migrating -> Active:   {finalizeAndReset} (onlyOwner), allowed ONLY once the pool
    ///                                     is fully drained (`stakerCount == 0 && totalStaked == 0`).
    /// @dev The zero value MUST be `Active` so all currently-registered, never-migrated tokens keep
    ///      behaving exactly as before (matches the legacy `active == false` default). `poolState` is
    ///      the sole source of truth for migration gating.
    enum PoolState {
        Active,
        Migrating
    }

    /// @notice token => pool lifecycle state. Default 0 == Active.
    mapping(address => PoolState) public poolState;

    /// @notice Per-token terminal-migration snapshot (see the TERMINAL MIGRATION section).
    /// @dev `realized` (R) and `principalSnapshot` (P) are captured once in {initiateMigration} and are
    ///      immutable for the life of the migration — every user's credit divides by this fixed `P`,
    ///      never a re-summed batch total, which is what makes payouts order- and method-independent.
    ///      Whether a token IS migrating is tracked by {poolState}, not by a flag in this struct.
    ///      {finalizeAndReset} zeroes both fields when returning a fully-drained pool to Active.
    struct MigrationInfo {
        uint256 realized; // R: token realized into this contract by the full strategy exit
        uint256 principalSnapshot; // P: poolInfo[token].totalStaked captured at initiateMigration
    }

    /// @notice token => terminal-migration snapshot. Meaningful only while `poolState[token] == Migrating`.
    mapping(address => MigrationInfo) public migrationInfo;

    // ============================== EVENTS ==============================

    event TokenAdded(address indexed token);
    event RewardRateSet(address indexed token, uint256 phusdPerDay, uint256 phusdPerSecond);
    event MigratorSet(address indexed migrator);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event YieldStrategySet(address indexed token, address indexed oldStrategy, address indexed newStrategy);
    event Staked(address indexed token, address indexed user, uint256 amount);
    event Withdrawn(address indexed token, address indexed user, uint256 amount);
    event Claimed(address indexed token, address indexed user, uint256 reward);
    event EmergencyWithdrawn(address indexed token, address indexed user, uint256 amount);
    event MigratedOut(address indexed token, address indexed user, uint256 amount, uint256 reward);
    event MigrationInitiated(address indexed token, uint256 realized, uint256 principalSnapshot);
    event UserMigrated(address indexed token, address indexed user, uint256 credit);
    event DepositedFor(address indexed token, address indexed user, uint256 amount);
    event BufferWithdrawn(address indexed token, address indexed user, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event PoolReset(address indexed token);

    // ============================== MODIFIERS ==============================

    modifier onlyPauser() {
        require(msg.sender == pauser, "StableStaker: only pauser");
        _;
    }

    modifier onlyMigrator() {
        require(msg.sender == migrator, "StableStaker: only migrator");
        _;
    }

    modifier poolExists(address token) {
        require(_registeredTokens.contains(token), "StableStaker: unknown token");
        _;
    }

    // ============================== CONSTRUCTOR ==============================

    /**
     * @param _phUSD       The phUSD token this farm mints as rewards.
     * @param initialOwner The owner (can register tokens, set rates, migrator and pauser).
     */
    constructor(IFlax _phUSD, address initialOwner) Ownable(initialOwner) {
        require(address(_phUSD) != address(0), "StableStaker: zero phUSD");
        phUSD = _phUSD;
    }

    // ============================== OWNER CONFIG ==============================

    /// @notice Register a new stable token as a reward pool.
    function addToken(address token) external onlyOwner {
        require(token != address(0), "StableStaker: zero token");
        require(_registeredTokens.add(token), "StableStaker: token exists");
        poolInfo[token].lastRewardTime = block.timestamp;
        emit TokenAdded(token);
    }

    /**
     * @notice Set the daily phUSD emission budget for a token. Internally converted to a
     *         per-second rate (`amountPerDay / SECONDS_PER_DAY`, rounded down). The pool is
     *         settled at the existing rate first so the change never applies retroactively.
     */
    function phUSDPerDay(address token, uint256 amountPerDay) external onlyOwner poolExists(token) {
        _updatePool(token);
        uint256 perSecond = amountPerDay / SECONDS_PER_DAY;
        poolInfo[token].phusdPerSecond = perSecond;
        emit RewardRateSet(token, amountPerDay, perSecond);
    }

    /// @notice Set the address authorized to perform permissioned migration.
    function setMigrator(address _migrator) external onlyOwner {
        migrator = _migrator;
        emit MigratorSet(_migrator);
    }

    /// @notice Set (or clear, with address(0)) the pauser address.
    function setPauser(address _pauser) external onlyOwner {
        address old = pauser;
        pauser = _pauser;
        emit PauserUpdated(old, _pauser);
    }

    /**
     * @notice Set (or clear, with address(0)) the yield strategy that custodies `token`'s principal.
     * @dev On set to a non-zero strategy: approves it for unlimited `token` and sweeps any idle balance
     *      already held by the contract into the new strategy (so subsequent withdrawals resolve against
     *      it). When clearing or replacing, the old strategy is best-effort drained (its full client
     *      position is withdrawn into this contract via the same realization path as
     *      {initiateMigration}, underwater guard OFF) and its allowance is reset to 0; the recovered
     *      idle balance is then re-custodied into the new strategy by the idle sweep. The whole
     *      position therefore moves YS1->YS2 in this single call, with no per-user migration.
     *      Above-par yield is left behind in the decoupled old strategy as protocol-owned value
     *      (StableStaker credits users principal only). Blocked during a terminal migration.
     *
     *      Wiring prerequisite: the strategy owner must authorize this contract as a client
     *      (`strategy.setClient(address(this), true)`) before deposits will succeed.
     */
    function setYieldStrategy(address token, IYieldStrategy strategy) external onlyOwner poolExists(token) {
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        // Strategy (un)wiring is an EMPTY-POOL-only operation. Once a pool holds staked principal,
        // moving that principal in place desyncs `totalStaked` from `strategy.principalOf` whenever
        // the deposit/exit haircuts (market/AMM strategies). That is the shared root cause of
        // ss6m1/M-01 (first-adoption sweep), M-06 (underwater swap) and M-07 (AMM-execution swap):
        // no guard compares `totalStaked` against strategy principal, so the desync is silent.
        // Principal may only move through the realize-once-and-socialize terminal-migration path:
        //   initiateMigration -> batchMigrate/userMigrate -> finalizeAndReset (pool now empty) -> setYieldStrategy
        require(poolInfo[token].totalStaked == 0, "StableStaker: pool not empty");

        IYieldStrategy old = yieldStrategy[token];
        if (address(old) != address(0)) {
            // M-06: refuse to swap an underwater strategy in place. Swapping while below par
            // silently lifts the underwater-withdraw block and FCFS-concentrates the realized
            // loss on the last withdrawer. An impaired strategy must instead be wound down via
            // initiateMigration -> batchMigrate -> finalizeAndReset, which socializes the loss
            // proportionally via the (R,P) snapshot. At/above par swaps are unaffected. An empty
            // old strategy (principalOf == 0) is not underwater, so first-adoption/idle swaps pass.
            require(!_isUnderwater(token, old), "StableStaker: old strategy underwater");

            // Drain the full client position out of the old strategy into this contract so the new
            // strategy (or idle hold) can re-custody it. Best-effort: caps at recoverable principal,
            // underwater guard OFF — same realization path as initiateMigration. Above-par yield is
            // left behind in the old strategy as protocol-owned value (StableStaker owes users
            // principal only). `_routeExit` reads yieldStrategy[token], which is still `old` here.
            // Skip when there is no principal to realize: the strategy's withdraw reverts on a
            // zero amount, so a drain at totalStaked == 0 must be a no-op (first-adoption / idle).
            uint256 staked = poolInfo[token].totalStaked;
            if (staked > 0) {
                _routeExit(token, staked, false);
            }

            // Revoke the old strategy's spending allowance.
            IERC20(token).forceApprove(address(old), 0);
        }

        yieldStrategy[token] = strategy;

        if (address(strategy) != address(0)) {
            // Approve the new strategy to pull this token for deposits.
            IERC20(token).forceApprove(address(strategy), type(uint256).max);

            // Sweep any idle balance already sitting in the contract into the new strategy so that
            // accounting is consistent immediately (at first adoption this equals staked principal).
            uint256 idleBalance = IERC20(token).balanceOf(address(this));
            if (idleBalance > 0) {
                strategy.deposit(token, idleBalance, address(this));
            }
        }

        emit YieldStrategySet(token, address(old), address(strategy));
    }

    // ============================== PAUSING (IPausable) ==============================

    /// @inheritdoc IPausable
    function pause() external override onlyPauser {
        _pause();
    }

    /// @inheritdoc IPausable
    function unpause() external override {
        require(msg.sender == owner() || msg.sender == pauser, "StableStaker: only owner or pauser");
        _unpause();
    }

    // ============================== STAKING ==============================

    /// @notice Stake `amount` of `token`. Any pending reward is minted to the caller first.
    function stake(address token, uint256 amount) external nonReentrant whenNotPaused poolExists(token) {
        require(amount > 0, "StableStaker: amount=0");
        // Frozen once terminal migration is engaged: new stake would pollute the immutable `P`
        // snapshot. See TERMINAL MIGRATION.
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        UserInfo storage user = userInfo[token][msg.sender];
        _settle(msg.sender, user, pool);

        uint256 received = _pullToken(token, msg.sender, amount);
        uint256 credited = _routeDeposit(token, received);
        require(credited > 0, "StableStaker: nothing credited");
        user.amount += credited;
        pool.totalStaked += credited;
        user.rewardDebt = (user.amount * pool.accPhusdPerShare) / ACC_PRECISION;
        _stakers[token].add(msg.sender);
        emit Staked(token, msg.sender, credited);
    }

    /// @notice Withdraw `amount` of staked `token`. Any pending reward is minted to the caller.
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused poolExists(token) {
        require(amount > 0, "StableStaker: amount=0");
        // Frozen once terminal migration is engaged: exits go through {userMigrate}, which honours the
        // fixed (R, P) snapshot. A live withdraw would change `P`. See TERMINAL MIGRATION.
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        PoolInfo storage pool = poolInfo[token];
        UserInfo storage user = userInfo[token][msg.sender];
        require(user.amount >= amount, "StableStaker: insufficient stake");
        _updatePool(token);

        uint256 pending = (user.amount * pool.accPhusdPerShare) / ACC_PRECISION - user.rewardDebt;
        user.amount -= amount;
        pool.totalStaked -= amount;
        user.rewardDebt = (user.amount * pool.accPhusdPerShare) / ACC_PRECISION;
        if (user.amount == 0) {
            _stakers[token].remove(msg.sender);
        }

        if (pending > 0) {
            phUSD.mint(msg.sender, pending);
        }
        // Non-migrating withdrawals are blocked while the strategy is below par (avoids realising
        // a loss on a user who did not opt into migration). Forward the measured-received amount.
        uint256 payout = _routeExit(token, amount, true);
        IERC20(token).safeTransfer(msg.sender, payout);
        emit Withdrawn(token, msg.sender, amount);
    }

    /// @notice Mint the caller's pending phUSD reward for `token` without touching principal.
    function claim(address token) external nonReentrant whenNotPaused poolExists(token) {
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        UserInfo storage user = userInfo[token][msg.sender];
        uint256 pending = (user.amount * pool.accPhusdPerShare) / ACC_PRECISION - user.rewardDebt;
        require(pending > 0, "StableStaker: nothing to claim");
        user.rewardDebt = (user.amount * pool.accPhusdPerShare) / ACC_PRECISION;
        phUSD.mint(msg.sender, pending);
        emit Claimed(token, msg.sender, pending);
    }

    /**
     * @notice Escape hatch: withdraw the caller's full principal for `token`, forfeiting any
     *         pending reward. Works while paused and never touches reward accounting, so a
     *         broken mint path can never trap principal.
     */
    function emergencyWithdraw(address token) external nonReentrant {
        // Frozen once terminal migration is engaged: the escape hatch becomes {userMigrate}, which
        // pays the fixed snapshot credit. A live exit here would change `P`. See TERMINAL MIGRATION.
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        UserInfo storage user = userInfo[token][msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "StableStaker: nothing staked");
        user.amount = 0;
        user.rewardDebt = 0;
        poolInfo[token].totalStaked -= amount;
        _stakers[token].remove(msg.sender);
        // No underwater guard: the escape hatch must always work, accepting a haircut if below par.
        uint256 payout = _routeExit(token, amount, false);
        IERC20(token).safeTransfer(msg.sender, payout);
        emit EmergencyWithdrawn(token, msg.sender, amount);
    }

    // ============================== TERMINAL MIGRATION ==============================

    /**
     * @dev Terminal, per-token migration mode — a dormant incident / protocol-upgrade escape hatch.
     *      It may never fire, or fire once years from now operated by someone who has never seen the
     *      original design notes; the on-chain source must therefore explain the *why*, not just the
     *      *what*. (The design plan in scratchpad is NOT shipped and is not the explanation of record.)
     *
     *      Motivation. The legacy per-batch `migrateOut` re-credited an underwater migration pro-rata,
     *      but recomputed the haircut ratio per batch. Through an AMM-backed strategy each batch's
     *      aggregate exit moved the pool price, so two users with identical principal received
     *      materially different payouts based solely on batch placement (finding ss2m1 / M-01). This
     *      design collapses realization to a single event and distributes a single, fixed snapshot.
     *
     *      Lifecycle. {initiateMigration} runs once per engagement: it settles & freezes emissions,
     *      snapshots P = totalStaked, realizes the whole strategy position into idle balance as R,
     *      decouples the strategy, and sets `poolState = Migrating`. Thereafter every exit — operator
     *      {batchMigrate} or permissionless {userMigrate} — pays a credit that is a pure function of
     *      the snapshot:
     *
     *          credit_i = p_i * min(R, P) / P            (p_i = user's snapshot principal)
     *
     *      Because R and P are immutable for the migration's life and the denominator is the fixed P
     *      (never a re-summed batch total), the payout is independent of exit order, batch composition,
     *      and batch-vs-self. Equal principal ⇒ equal payout. That is the formal statement of the fix.
     *
     *      Terminal per engagement; revival only from empty. While Migrating the token's pool can never
     *      resume healthy operation: there is no in-place resume, so the snapshot ratio can never go
     *      stale against a re-grown position and there are no resume races. The ONLY way back to Active
     *      is {finalizeAndReset}, which is gated on a FULLY-DRAINED pool (`stakerCount == 0 &&
     *      totalStaked == 0`): once every position has exited at the fixed snapshot, the empty pool
     *      carries no stale state, so it can be cleared and re-opened under a fresh strategy. This
     *      preserves the no-stale-snapshot guarantee (you can only revive from empty) while removing the
     *      "pool slot frozen forever / redeploy required" limitation.
     *
     *      Conservation. With S = min(R, P): Σ floor(p_i·S/P) ≤ (S/P)·Σ p_i = S ≤ R. The idle pile (R)
     *      always covers every credit in any interleaving of batch/self exits — the last claimer is
     *      never starved. Floor-division dust stays protocol-owned (owner-rescuable via {rescueERC20}).
     */

    /**
     * @notice Engage terminal migration for `token`: realize the entire strategy position once and
     *         snapshot (R, P) so all subsequent exits pay a fixed, order-independent pro-rata credit.
     * @dev Permission: `onlyMigrator` (the migration orchestrator owns the whole flow; the migrator
     *      exposes a thin owner-only forwarder). Reverts unless the pool is `Active`, so this runs once
     *      per engagement. After it succeeds `token` is `Migrating` — the only way back to `Active` is
     *      {finalizeAndReset}, gated on a fully-drained pool.
     *
     *      Emissions are settled to this block and then frozen ({_updatePool} no-ops while Migrating), so
     *      every user's pending phUSD is fixed at the snapshot and is minted in full on their exit.
     * @param token The staked token to put into terminal migration. Must be a registered pool and not
     *              already migrating.
     */
    function initiateMigration(address token) external override nonReentrant onlyMigrator poolExists(token) {
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");

        // Settle rewards to this block; subsequent _updatePool calls are frozen once Migrating is set,
        // so pending phUSD is now fixed at the snapshot for every migrating user.
        _updatePool(token);

        // P: the immutable principal denominator. Held in lockstep with strategy.principalOf, so passing
        // it to _routeExit requests exactly the strategy-side client principal.
        uint256 P = poolInfo[token].totalStaked;
        IYieldStrategy strategy = yieldStrategy[token];

        // Realize the full position via the client-callable, synchronous strategy.withdraw (through
        // _routeExit with the underwater guard OFF). `totalWithdrawal` is deliberately NOT used despite
        // appearing in IYieldStrategy: it is onlyOwner (this contract is only a client), two-phase with
        // a 24h delay (no atomic realization), and redeems to the strategy *owner*, not this client —
        // so the funds would never land here. withdraw caps the request to available principal, draining
        // the client fully. When no strategy is set, _routeExit returns P (principal already idle ⇒ R = P).
        uint256 R = _routeExit(token, P, false);

        // Post-check the exit fully drained the client (a tranche/queue vault that can only exit
        // partially would understate R and strand value — terminal mode gives no retry). Skipped when
        // no strategy is set.
        require(
            address(strategy) == address(0) || strategy.principalOf(token, address(this)) == 0,
            "StableStaker: incomplete exit"
        );

        // Decouple the strategy: revoke its allowance and clear the wiring. The contract is now an
        // honest idle-hold for `token`; the migration paths pay from this idle pile only.
        if (address(strategy) != address(0)) {
            IERC20(token).forceApprove(address(strategy), 0);
            yieldStrategy[token] = IYieldStrategy(address(0));
        }

        // Engage the terminal-migration state. `poolState` is the sole gate source; the snapshot below
        // is meaningful only while Migrating and is zeroed by {finalizeAndReset} on revival.
        poolState[token] = PoolState.Migrating;

        // Surplus is NOT swept. withdraw caps payout at par, so R ≤ P structurally; any above-par yield
        // stays inside the now-decoupled strategy as protocol-owned value and never reaches users (the
        // "stakers get principal + phUSD only" invariant holds). min(R, P) below is therefore == R in
        // practice but defends against a stray above-par R (e.g. a donation) by capping credits at par.
        migrationInfo[token] = MigrationInfo({realized: R, principalSnapshot: P});
        emit MigrationInitiated(token, R, P);
    }

    /**
     * @notice Permissioned batched exit during terminal migration (see {IStableStaker-batchMigrate}).
     *         Replaces the legacy `migrateOut`. For each non-zero user: mints their frozen pending
     *         phUSD, zeroes their position, and accumulates the snapshot credit `p_i·min(R,P)/P`. The
     *         aggregate is transferred to the migrator from the idle pile; the migrator redeposits each
     *         per-user credit into the new staker.
     * @dev Permission: `onlyMigrator`. Requires a prior {initiateMigration} (`active`). No `_routeExit`,
     *      no per-batch re-sum, no requested-vs-received delta — credits come solely from the immutable
     *      (R, P) snapshot, so they are identical regardless of batch composition or ordering, and a
     *      user who already self-migrated (position zeroed) is skipped automatically. Callable while
     *      paused so a migration can proceed during an incident.
     * @param token The token under terminal migration.
     * @param users The users to migrate out (build batches off-chain via getStakers/getStakersRange).
     * @return amounts Per-user snapshot credit `p_i·min(R,P)/P`, parallel to `users` (0 for empty /
     *         already-migrated positions). Σ amounts ≤ R, so the migrator's redeposits can never exceed
     *         the funds it received.
     */
    function batchMigrate(address token, address[] calldata users)
        external
        override
        nonReentrant
        onlyMigrator
        poolExists(token)
        returns (uint256[] memory amounts)
    {
        require(poolState[token] == PoolState.Migrating, "StableStaker: pool not migrating");

        amounts = new uint256[](users.length);
        uint256 total;
        for (uint256 i = 0; i < users.length; i++) {
            // Empty or already self-migrated positions return 0 and are skipped (no separate flag).
            uint256 credit = _exitPosition(token, users[i]);
            amounts[i] = credit;
            total += credit;
        }
        if (total > 0) {
            // Pay from the idle pile realized at initiateMigration. No strategy round-trip.
            IERC20(token).safeTransfer(msg.sender, total);
        }
    }

    /**
     * @dev Shared terminal-migration exit for one user: mints their frozen pending phUSD, computes the
     *      snapshot credit `p_i·min(R,P)/P`, zeroes their position and removes them from the staker set.
     *      Returns the credit (0 for an empty position). Used by both {batchMigrate} and {userMigrate},
     *      so a self-migrated user and a batch-migrated user with equal principal get identical credit.
     *      Does NOT transfer the credit — the caller forwards it (CEI).
     */
    function _exitPosition(address token, address account) internal returns (uint256 credit) {
        UserInfo storage info = userInfo[token][account];
        uint256 amt = info.amount;
        if (amt == 0) {
            return 0;
        }
        MigrationInfo storage mig = migrationInfo[token];
        uint256 P = mig.principalSnapshot;
        uint256 S = mig.realized < P ? mig.realized : P; // min(R, P): caps credits at par
        credit = (amt * S) / P;

        // Pending was frozen at the snapshot (_updatePool is a no-op while active).
        PoolInfo storage pool = poolInfo[token];
        uint256 pending = (amt * pool.accPhusdPerShare) / ACC_PRECISION - info.rewardDebt;

        info.amount = 0;
        info.rewardDebt = 0;
        pool.totalStaked -= amt;
        _stakers[token].remove(account);

        if (pending > 0) {
            phUSD.mint(account, pending);
        }
        emit MigratedOut(token, account, credit, pending);
    }

    /**
     * @notice Permissionless terminal-migration exit: the caller redeems their own position for the
     *         fixed snapshot credit `p_i·min(R,P)/P` and exits the system entirely (tokens to their
     *         own wallet — they are NOT re-deposited into the new staker).
     * @dev The escape hatch for the terminal state, replacing {emergencyWithdraw} (which is blocked
     *      while migrating). Requires `active` and a non-zero position. Strict CEI: the position is
     *      zeroed before the transfer. Pays the SAME credit a batch exit would, so it is order- and
     *      method-independent; a later {batchMigrate} skips this user automatically.
     * @param token The token under terminal migration.
     */
    function userMigrate(address token) external nonReentrant {
        require(poolState[token] == PoolState.Migrating, "StableStaker: pool not migrating");
        require(userInfo[token][msg.sender].amount > 0, "StableStaker: nothing staked");

        // Effects (mint pending, zero position, remove from set) happen inside _exitPosition; the
        // transfer below is the only interaction, so CEI holds.
        uint256 credit = _exitPosition(token, msg.sender);
        IERC20(token).safeTransfer(msg.sender, credit);
        emit UserMigrated(token, msg.sender, credit);
    }

    /**
     * @notice Return a fully-ejected pool from terminal migration (Migrating) back to a clean,
     *         re-stakeable Active state, so the SAME token can be revived under a fresh strategy
     *         without redeploying.
     * @dev Permission: `onlyOwner`. Deliberately has NO `whenNotPaused` so the operator can reset
     *      while paused (the recommended revival runbook wraps the reconfiguration in pause/unpause).
     *
     *      This ONLY applies to the fully-ejected terminal-migration path: it requires
     *      `poolState == Migrating` AND an empty, zero-principal pool (`stakerCount == 0 &&
     *      totalStaked == 0`), meaning every position has already exited via {batchMigrate} /
     *      {userMigrate} at the immutable `(R, P)` snapshot. The empty-pool requirement is the core
     *      safety property: no stale `userInfo` position can survive into the revived pool to
     *      cannibalize a future staker's real principal.
     *
     *      An IMPAIRED / underwater strategy reaches this path ONLY via {initiateMigration} (which
     *      socializes the loss proportionally via the `(R, P)` snapshot) — NEVER via an in-place
     *      {setYieldStrategy} swap, which story 008's underwater guard forbids. There is intentionally
     *      no seamless underwater-flee; survivors are paid `min(R,P)/P` and must re-stake.
     *
     *      O(1): asserts `stakerCount == 0` rather than iterating the staker set (the bounded ejection
     *      work is done by the migrator's paged {batchMigrate} loop). Clears the `(R, P)` snapshot and
     *      fast-forwards `lastRewardTime` to now so the frozen migration gap is never retro-accrued
     *      (belt-and-suspenders given `_updatePool`'s `totalStaked == 0` fast-forward). After reset
     *      `yieldStrategy[token]` is still `address(0)` (cleared during {initiateMigration}); the owner
     *      then calls {setYieldStrategy} to wire a fresh strategy before users stake again.
     * @param token The token whose fully-drained migrating pool should be reset to Active.
     */
    function finalizeAndReset(address token) external onlyOwner poolExists(token) {
        require(poolState[token] == PoolState.Migrating, "StableStaker: pool not migrating");
        require(_stakers[token].length() == 0, "StableStaker: stakers remain");
        require(poolInfo[token].totalStaked == 0, "StableStaker: principal remains");

        // Clear the snapshot and fast-forward accrual so the frozen migration window is never
        // retroactively emitted into the revived pool.
        migrationInfo[token] = MigrationInfo({realized: 0, principalSnapshot: 0});
        poolInfo[token].lastRewardTime = block.timestamp;
        poolState[token] = PoolState.Active;
        emit PoolReset(token);
    }

    // ============================== MIGRATION (DEPOSIT) ==============================

    /**
     * @notice Permissioned deposit crediting `user` (see {IStableStaker-depositFor}). Pulls
     *         `amount` of `token` from the migrator. Callable while paused so a freshly deployed
     *         (and possibly paused) target can be seeded.
     * @dev On a token under terminal migration this is the OLD staker and is blocked (would change the
     *      `P` snapshot). The migrator's redeposit target is the NEW (healthy) staker, where this
     *      guard does not trip.
     */
    function depositFor(address token, address user, uint256 amount)
        external
        override
        nonReentrant
        onlyMigrator
        poolExists(token)
    {
        require(amount > 0, "StableStaker: amount=0");
        // Frozen on the migrating (old) staker: a deposit would change `P`. See TERMINAL MIGRATION.
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        UserInfo storage info = userInfo[token][user];
        _settle(user, info, pool);

        uint256 received = _pullToken(token, msg.sender, amount);
        uint256 credited = _routeDeposit(token, received);
        require(credited > 0, "StableStaker: nothing credited");
        info.amount += credited;
        pool.totalStaked += credited;
        info.rewardDebt = (info.amount * pool.accPhusdPerShare) / ACC_PRECISION;
        _stakers[token].add(user);
        emit DepositedFor(token, user, credited);
    }

    // ============================== VIEWS ==============================

    /// @notice Projected pending phUSD reward for `account` in `token`'s pool.
    /// @dev While terminal migration is active, emissions are frozen at the snapshot, so this returns
    ///      the fixed pending (no forward projection) — matching what the migration exit mints.
    function pendingReward(address token, address account) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[token];
        uint256 acc = pool.accPhusdPerShare;
        if (poolState[token] == PoolState.Active && block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
            uint256 elapsed = block.timestamp - pool.lastRewardTime;
            uint256 reward = elapsed * pool.phusdPerSecond;
            acc += (reward * ACC_PRECISION) / pool.totalStaked;
        }
        UserInfo storage user = userInfo[token][account];
        return (user.amount * acc) / ACC_PRECISION - user.rewardDebt;
    }

    /// @notice All stakers with a non-zero position in `token`.
    function getStakers(address token) external view returns (address[] memory) {
        return _stakers[token].values();
    }

    /**
     * @notice A half-open slice `[start, end)` of `token`'s staker set, for paging. `end` is
     *         clamped to the set length, so passing a large `end` returns through the last entry.
     */
    function getStakersRange(address token, uint256 start, uint256 end) external view returns (address[] memory) {
        EnumerableSet.AddressSet storage set = _stakers[token];
        uint256 len = set.length();
        if (end > len) {
            end = len;
        }
        require(start <= end, "StableStaker: bad range");
        address[] memory out = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = set.at(i);
        }
        return out;
    }

    /// @notice Number of stakers with a non-zero position in `token`.
    function stakerCount(address token) external view returns (uint256) {
        return _stakers[token].length();
    }

    /// @notice Every registered pool token.
    function getStakedTokens() external view returns (address[] memory) {
        return _registeredTokens.values();
    }

    /**
     * @notice True when non-migrating withdrawals are currently disabled for `token` because its
     *         yield strategy is below par (`totalBalanceOf < principalOf`). False when no strategy
     *         is set. Cheap off-chain check before prompting a user to withdraw.
     */
    function withdrawDisabled(address token) external view returns (bool) {
        IYieldStrategy strategy = yieldStrategy[token];
        if (address(strategy) == address(0)) {
            return false;
        }
        return _isUnderwater(token, strategy);
    }

    // ============================== INTERNAL ==============================

    /// @dev Accrue rewards for `token` up to the current block. Empty pools accrue nothing.
    function _updatePool(address token) internal {
        // Emissions are frozen once terminal migration is engaged: each user's pending phUSD stays
        // fixed at the {initiateMigration} snapshot, so it is minted in full on their migration exit.
        // See TERMINAL MIGRATION.
        if (poolState[token] != PoolState.Active) {
            return;
        }
        PoolInfo storage pool = poolInfo[token];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (pool.totalStaked == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - pool.lastRewardTime;
        uint256 reward = elapsed * pool.phusdPerSecond;
        if (reward > 0) {
            pool.accPhusdPerShare += (reward * ACC_PRECISION) / pool.totalStaked;
        }
        pool.lastRewardTime = block.timestamp;
    }

    /// @dev Mint any outstanding pending reward for an existing position. Assumes pool is current.
    function _settle(address account, UserInfo storage user, PoolInfo storage pool) internal {
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accPhusdPerShare) / ACC_PRECISION - user.rewardDebt;
            if (pending > 0) {
                phUSD.mint(account, pending);
            }
        }
    }

    /// @dev Pull `amount` of `token` from `from`, returning the actual amount received.
    function _pullToken(address token, address from, uint256 amount) internal returns (uint256) {
        IERC20 t = IERC20(token);
        uint256 balanceBefore = t.balanceOf(address(this));
        t.safeTransferFrom(from, address(this), amount);
        return t.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev The strategy is below par for the farm's position when its total balance (principal +
    ///      yield) is worth less than the principal it custodies for this contract.
    function _isUnderwater(address token, IYieldStrategy strategy) internal view returns (bool) {
        return strategy.totalBalanceOf(token, address(this)) < strategy.principalOf(token, address(this));
    }

    /// @dev If a strategy is set for `token`, deposit `amount` into it under this contract's
    ///      account and return the principal the strategy actually booked (the market strategy
    ///      haircuts this below `amount`; direct strategies return `amount`). When no strategy is
    ///      set the tokens sit idle in this contract, so the full `amount` is credited.
    function _routeDeposit(address token, uint256 amount) internal returns (uint256 credited) {
        IYieldStrategy strategy = yieldStrategy[token];
        if (address(strategy) == address(0)) {
            return amount; // idle hold: full credit
        }
        return strategy.deposit(token, amount, address(this));
    }

    /**
     * @dev If a strategy is set for `token`, redeem `amount` of principal from it to this contract
     *      and return the ACTUAL amount received (balance delta) for forwarding to the user/migrator.
     *      Internal principal accounting is decremented by the requested `amount` by the caller, not
     *      the received amount; sub-amount differences remain protocol-owned yield/loss. When no
     *      strategy is set, returns `amount` unchanged (the tokens already sit in the contract).
     * @param guardUnderwater When true (the non-migrating `withdraw` path), reverts if the strategy
     *      is below par. The escape hatch and migration pass false so they always succeed.
     */
    function _routeExit(address token, uint256 amount, bool guardUnderwater) internal returns (uint256 payout) {
        IYieldStrategy strategy = yieldStrategy[token];
        if (address(strategy) == address(0)) {
            return amount;
        }
        IERC20 t = IERC20(token);
        if (guardUnderwater && _isUnderwater(token, strategy)) {
            // Underwater: try to satisfy the entire withdraw from the on-contract buffer.
            // Caller forwards the returned amount via safeTransfer, so we just signal
            // "use the buffer" by returning `amount` without touching the strategy.
            if (t.balanceOf(address(this)) >= amount) {
                emit BufferWithdrawn(token, msg.sender, amount);
                strategy.relinquishPrincipal(token, amount);
                return amount;
            }
            revert("StableStaker: strategy underwater");
        }
        uint256 balanceBefore = t.balanceOf(address(this));
        strategy.withdraw(token, amount, address(this));
        return t.balanceOf(address(this)) - balanceBefore;
    }

    // ============================== OWNER RESCUE ==============================

    /**
     * @notice Owner-only rescue of arbitrary ERC20s that have accumulated in the contract
     *         (wrong-token transfers, dust, faucet mistakes, idle buffer). Guarded so the owner
     *         cannot withdraw user principal: when a token has no strategy set, user principal
     *         is held idle in this contract and is reserved (= `poolInfo[token].totalStaked`);
     *         when a strategy is set, principal lives inside the strategy and the contract
     *         balance is purely buffer + dust, so the full balance is rescuable.
     * @dev Works while paused — owner rescue is most useful exactly when normal flow is halted.
     *      No `nonReentrant`: there is no state to corrupt after the trailing `safeTransfer`.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "StableStaker: zero recipient");
        uint256 reserved = address(yieldStrategy[token]) == address(0) ? poolInfo[token].totalStaked : 0;
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal >= reserved + amount, "StableStaker: would touch user principal");
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }
}
