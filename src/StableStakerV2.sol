// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IAntimatter.sol";
import "./interfaces/IPhUSD.sol";
import "pauser/interfaces/IPausable.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import "./interfaces/IStableStaker.sol";

/**
 * @title StableStakerV2
 * @notice A MasterChef-style yield farm that supports any number of staked (stable) tokens and
 *         rewards stakers in Antimatter. Unlike a classic MasterChef, rewards are not paid from a
 *         pre-funded balance: the contract is an approved minter of Antimatter and mints rewards
 *         directly to users on claim / withdraw / migration.
 *
 * @dev Reward accounting is the canonical per-pool MasterChef model, one pool per token:
 *
 *        accAntimatterPerShare += elapsed * antimatterPerSecond * ACC_PRECISION / totalStaked
 *        pending(user)     = user.amount * accAntimatterPerShare / ACC_PRECISION - user.rewardDebt
 *
 *      Emission-cap invariant (the core safety property): the only writer of `accAntimatterPerShare`
 *      is {_updatePool}, which folds in exactly `elapsed * antimatterPerSecond` of value per update.
 *      The sum of every staker's pending increase therefore equals that amount minus
 *      integer-division dust, *independent of how stake is split or churned*. Consequences:
 *        - flash staking (stake + exit in one block) yields elapsed == 0 -> 0 reward;
 *        - windows where `totalStaked == 0` accrue nothing (lastRewardTime is fast-forwarded);
 *        - dust always rounds DOWN, so realized emission <= antimatterPerSecond * elapsed.
 *      Hence no sequence of user actions can mint more than `antimatterPerDay` for a token over any
 *      window. {antimatterPerDay} settles the pool at the old rate before changing it, so a rate
 *      change is never applied retroactively.
 *
 *      Pausing follows the Behodler3 pattern (OZ {Pausable} + {IPausable}): a dedicated `pauser`
 *      address pauses; owner OR pauser unpauses. The {emergencyWithdraw} escape hatch and the
 *      migration hooks intentionally remain callable while paused.
 */
contract StableStakerV2 is Ownable, Pausable, ReentrancyGuard, IPausable, IStableStaker {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Fixed-point scaling factor for `accAntimatterPerShare`. Dust rounds down.
    uint256 public constant ACC_PRECISION = 1e18;

    /// @notice Seconds in a day, used to convert a per-day budget into a per-second rate.
    uint256 public constant SECONDS_PER_DAY = 86400;

    /// @notice Monotonic identity of this contract's shape. Bumped by the snapshot ritual
    ///         whenever a deploy freezes the current surface into `src/versions/`.
    /// @dev The live V1 instance (0xbce8...079A) predates this constant and does NOT expose
    ///      it. Any version probe must therefore tolerate the call reverting — absence of
    ///      `STAKER_VERSION` means version 1.
    uint256 public constant STAKER_VERSION = 2;

    /// @notice Absolute rounding allowance, in raw `token` units, subtracted from {autoAnnihilate}'s
    ///         shortfall floor before the call is judged short.
    /// @dev NOT a slippage budget. `ERC4626YieldStrategy._disposeShares` redeems
    ///      `vault.convertToShares(amount)` and the vault's `redeem` then floors the assets back —
    ///      two independent round-downs, each in the protocol's favour, so an honest vault at a
    ///      non-integral share price delivers `amount - 1` (or a couple of units more on an
    ///      awkward price) for an exit it is guaranteeing in full via
    ///      `AYieldStrategy.previewExitFor`'s capped identity. Without an allowance the floor is an
    ///      exact equality that no real ERC4626 vault can meet once it has accrued any yield, and
    ///      since `claimEnabled` is false on deployment this is the ONLY reward path.
    uint256 public constant EXIT_ROUNDING_ALLOWANCE = 2;

    /// @notice Proportional rounding allowance in basis points, added to {EXIT_ROUNDING_ALLOWANCE}.
    /// @dev One basis point is rounding-scale, not haircut-scale: it exists only so a vault whose
    ///      share price is large relative to the request (where one share's worth of assets exceeds
    ///      a couple of raw units) still clears the floor. It is deliberately far too small to
    ///      accommodate a real exit haircut — a strategy that genuinely under-delivers, or a preview
    ///      that lies to widen the raw-mint path around the closed {claim} gate, still reverts.
    uint256 public constant EXIT_ROUNDING_ALLOWANCE_BPS = 1;

    /// @dev Denominator for {EXIT_ROUNDING_ALLOWANCE_BPS}.
    uint256 private constant MAX_BPS = 10_000;

    /// @notice The Antimatter reward token. This contract must be an approved minter on it.
    IAntimatter public immutable antimatter;

    /// @notice Address authorized to pause the contract (Behodler3 pattern). Satisfies IPausable.
    address public override pauser;

    /// @notice Address authorized to perform permissioned migration (initiateMigration / batchMigrate / depositFor).
    address public migrator;

    /// @notice Whether {claim} is open. FALSE ON DEPLOYMENT: while the flag is down, {autoAnnihilate}
    ///         is the reward path, so a staker's first encounter with antimatter is an annihilation
    ///         rather than a balance they do not understand.
    /// @dev A UX gate, NOT an access control. It is expected to be flipped true within weeks, it is
    ///      the documented operational answer to an antimatter-side pause, and {autoAnnihilate} mints
    ///      any reward that outruns the caller's principal directly to them anyway. Nothing in this
    ///      contract's safety argument may depend on antimatter being unobtainable while it is false.
    ///      The terminal-migration mint in {_exitPosition} is deliberately NOT gated by it.
    bool public claimEnabled;

    /// @notice Per-token reward pool accounting.
    struct PoolInfo {
        uint256 antimatterPerSecond; // current emission rate (Antimatter wei per second)
        uint256 accAntimatterPerShare; // accumulated Antimatter per staked unit, scaled by ACC_PRECISION
        uint256 lastRewardTime; // last time the pool accrued
        uint256 totalStaked; // total principal staked in this pool
    }

    /// @notice Per-user position within a pool.
    struct UserInfo {
        uint256 amount; // staked principal
        uint256 rewardDebt; // accounting baseline: amount * accAntimatterPerShare / ACC_PRECISION at last settle
    }

    /// @notice token => pool accounting.
    mapping(address => PoolInfo) public poolInfo;

    /// @notice token => user => position.
    mapping(address => mapping(address => UserInfo)) public override userInfo;

    /// @notice token => enumerable set of addresses currently holding a non-zero position.
    mapping(address => EnumerableSet.AddressSet) private _stakers;

    /// @notice token => user => settled-but-unminted Antimatter reward, claimable via {claim}.
    /// @dev Written only by {_settle}, {withdraw} and the terminal-migration exit; drained to zero by
    ///      {claim}, {emergencyWithdraw} (forfeit) and {_exitPosition} (paid out). A standalone mapping
    ///      rather than a third {UserInfo} field, so the public `userInfo` getter keeps its 2-tuple
    ///      arity and {IStableStaker} needs no change.
    mapping(address => mapping(address => uint256)) public unclaimedReward;

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
    event RewardRateSet(address indexed token, uint256 antimatterAmountPerDay, uint256 antimatterPerSecond);
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
    event ClaimEnabledSet(bool enabled);

    /// @notice Emitted by {autoAnnihilate}. `antimatterBurned` is the 18-decimal amount annihilated,
    ///         `principalConsumed` is the GROSS booked principal the caller gave up for it (in `token`
    ///         decimals) — which under a strategy that sells on exit is MORE than the stable half the
    ///         annihilation consumed, the difference being the exit haircut the caller absorbed — and
    ///         `excessMinted` is the reward that could not be annihilated (it outran the principal, or
    ///         the haircut displaced it) and was minted straight to the caller. Sub-unit dust appears
    ///         in none of the three: it stays booked in {unclaimedReward}.
    event AutoAnnihilated(
        address indexed token,
        address indexed user,
        uint256 antimatterBurned,
        uint256 principalConsumed,
        uint256 excessMinted
    );

    /// @notice Emitted once by EVERY initiateMigration, including a clean one. `claimed` is the pool's
    ///         totalStaked snapshot P; `booked` is strategy.principalOf after the full exit;
    ///         `relinquished` is what was written down. `booked == 0` is the clean case and is
    ///         reported explicitly - the absence of this log means the migration did not happen, not
    ///         that it happened cleanly. A non-zero `booked` means something moved principal without
    ///         the pool's accounting following it; see setYieldStrategy's idle sweep for the known cause.
    event PrincipalDivergence(address indexed token, uint256 claimed, uint256 booked, uint256 relinquished);

    /// @notice Emitted when setYieldStrategy sweeps idle (non-user) balance into a newly wired strategy.
    ///         The pool is empty at this point by the totalStaked == 0 gate, so `amount` is protocol
    ///         money by construction: set-aside buffer, dust, and donations. Pairs with
    ///         PrincipalDivergence - an observer subtracting the swept history from a later divergence
    ///         is left with the UNEXPLAINED part, which is the number worth alerting on.
    event ProtocolPrincipalSwept(address indexed token, address indexed strategy, uint256 amount, uint256 credited);

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
     * @param _antimatter  The Antimatter token this farm mints as rewards.
     * @param initialOwner The owner (can register tokens, set rates, migrator and pauser).
     */
    constructor(IAntimatter _antimatter, address initialOwner) Ownable(initialOwner) {
        require(address(_antimatter) != address(0), "StableStaker: zero antimatter");
        antimatter = _antimatter;
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
     * @notice Set the daily Antimatter emission budget for a token. Internally converted to a
     *         per-second rate (`amountPerDay / SECONDS_PER_DAY`, rounded down). The pool is
     *         settled at the existing rate first so the change never applies retroactively.
     */
    function antimatterPerDay(address token, uint256 amountPerDay) external onlyOwner poolExists(token) {
        _updatePool(token);
        uint256 perSecond = amountPerDay / SECONDS_PER_DAY;
        poolInfo[token].antimatterPerSecond = perSecond;
        emit RewardRateSet(token, amountPerDay, perSecond);
    }

    /// @notice Set the address authorized to perform permissioned migration.
    function setMigrator(address _migrator) external onlyOwner {
        migrator = _migrator;
        emit MigratorSet(_migrator);
    }

    /// @notice Open or close {claim}. Closed on deployment; see {claimEnabled}.
    /// @dev One transaction, no redeploy — which is the whole reason the teaching phase is a flag.
    function setClaimEnabled(bool enabled) external onlyOwner {
        claimEnabled = enabled;
        emit ClaimEnabledSet(enabled);
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
                uint256 credited = strategy.deposit(token, idleBalance, address(this));
                emit ProtocolPrincipalSwept(token, address(strategy), idleBalance, credited);
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

    /// @notice Stake `amount` of `token`. Any pending reward is booked to {unclaimedReward} first;
    ///         nothing is minted here. Claim it with {claim}.
    function stake(address token, uint256 amount) external nonReentrant whenNotPaused poolExists(token) {
        require(amount > 0, "StableStaker: amount=0");
        // Frozen once terminal migration is engaged: new stake would pollute the immutable `P`
        // snapshot. See TERMINAL MIGRATION.
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        UserInfo storage user = userInfo[token][msg.sender];
        _settle(token, msg.sender, user, pool);

        uint256 received = _pullToken(token, msg.sender, amount);
        uint256 credited = _routeDeposit(token, received);
        require(credited > 0, "StableStaker: nothing credited");
        user.amount += credited;
        pool.totalStaked += credited;
        user.rewardDebt = (user.amount * pool.accAntimatterPerShare) / ACC_PRECISION;
        _stakers[token].add(msg.sender);
        emit Staked(token, msg.sender, credited);
    }

    /// @notice Withdraw `amount` of staked `token`. Any pending reward is booked to {unclaimedReward}
    ///         rather than minted, so principal handling never depends on Antimatter being mintable.
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused poolExists(token) {
        require(amount > 0, "StableStaker: amount=0");
        // Frozen once terminal migration is engaged: exits go through {userMigrate}, which honours the
        // fixed (R, P) snapshot. A live withdraw would change `P`. See TERMINAL MIGRATION.
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        PoolInfo storage pool = poolInfo[token];
        UserInfo storage user = userInfo[token][msg.sender];
        require(user.amount >= amount, "StableStaker: insufficient stake");
        _updatePool(token);

        uint256 pending = (user.amount * pool.accAntimatterPerShare) / ACC_PRECISION - user.rewardDebt;
        user.amount -= amount;
        pool.totalStaked -= amount;
        user.rewardDebt = (user.amount * pool.accAntimatterPerShare) / ACC_PRECISION;
        if (user.amount == 0) {
            _stakers[token].remove(msg.sender);
        }

        if (pending > 0) {
            unclaimedReward[token][msg.sender] += pending;
        }
        // Non-migrating withdrawals are blocked while the strategy is below par (avoids realising
        // a loss on a user who did not opt into migration). Forward the measured-received amount.
        uint256 payout = _routeExit(token, amount, true);
        IERC20(token).safeTransfer(msg.sender, payout);
        emit Withdrawn(token, msg.sender, amount);
    }

    /// @notice Mint the caller's Antimatter reward for `token` without touching principal: the
    ///         settled-but-unminted {unclaimedReward} backlog plus anything freshly pending.
    ///         {claimableReward} reads the figure it pays.
    /// @dev CLOSED BY DEFAULT since story 025 — see {claimEnabled}. It is no longer the only
    ///      user-facing path that mints: {autoAnnihilate} mints too (to this contract, and to the
    ///      caller for any excess over their principal), and it is the path users are steered to while
    ///      this one is shut.
    ///
    ///      Succeeds for a caller with no position but a non-zero backlog (someone who fully withdrew
    ///      and has not claimed yet). Still `whenNotPaused`, so a pause withholds the backlog too.
    ///      Deliberately has no `PoolState.Active` gate: it moves no principal.
    function claim(address token) external nonReentrant whenNotPaused poolExists(token) {
        require(claimEnabled, "StableStaker: claim disabled");
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        UserInfo storage user = userInfo[token][msg.sender];
        uint256 pending = (user.amount * pool.accAntimatterPerShare) / ACC_PRECISION - user.rewardDebt;
        uint256 owed = unclaimedReward[token][msg.sender] + pending;
        require(owed > 0, "StableStaker: nothing to claim");
        unclaimedReward[token][msg.sender] = 0;
        user.rewardDebt = (user.amount * pool.accAntimatterPerShare) / ACC_PRECISION;
        antimatter.mint(msg.sender, owed);
        emit Claimed(token, msg.sender, owed);
    }

    /**
     * @notice Annihilate the caller's owed Antimatter for `token` against their OWN booked principal
     *         and receive phUSD. The staked position shrinks by exactly the stable half consumed.
     * @dev The reward path while {claimEnabled} is false, and the point of the teaching phase:
     *      annihilation becomes something the staker has done rather than something they have read
     *      about. Reward arithmetic is byte-identical to {claim} (settle, read
     *      `unclaimedReward + pending`, drain the mapping, re-base `rewardDebt`), so the emission-cap
     *      invariant in the contract header is untouched.
     *
     *      Sequence, and every step is load-bearing:
     *        1. `owed` is 18-decimal antimatter; principal is in `token` decimals. Principal is scaled
     *           up by `10 ** (18 - decimals)` to compare the two.
     *        2. The annihilated amount is capped at the caller's own principal and then FLOORED to a
     *           multiple of that scale, because {IAntimatter-toStableAmount} reverts rather than round.
     *        3. The sub-unit remainder is left in {unclaimedReward} — not minted, not transferred. It
     *           accrues to the next call, so it is neither stranded nor a dust-sized bypass of a
     *           disabled {claim}, and it rounds in the protocol's favour.
     *        4. Reward that OUTRUNS the caller's principal cannot be annihilated (there is no
     *           principal left to annihilate it against) and is minted straight to them, exactly as a
     *           claim would. A knowing, documented loophole around the gate — see CLAUDE.md. The
     *           alternative, reverting, strands a user whose rewards outgrew their stake.
     *        5. The stable half is sourced through {_routeExit}, never from the raw idle balance: with
     *           a strategy set the stable lives in the strategy, and the buffer path's
     *           `relinquishPrincipal` is what keeps `strategy.principalOf` in lockstep with
     *           `totalStaked`.
     *        6. Antimatter burns the CALLER's own balance, so the reward is minted to `address(this)`,
     *           the stable half is approved to Antimatter, and `recipient` is the user: the phUSD
     *           lands in their wallet with no second transfer. The approval is reset to zero after.
     *
     *      EXIT-HAIRCUT SIZING (round 2). A strategy that sells its position on exit — the market
     *      strategy always does — delivers LESS than it is asked for. Requesting the net the
     *      annihilation needs and burning that net anyway would silently pay the difference out of
     *      this contract's idle balance, which is the SHARED underwater-withdrawal buffer: one
     *      caller's routine exit loss socialised across every staker. So instead:
     *        a. {IYieldStrategy-previewExitFor} (vault-RM story 050) reports the GROSS that must be
     *           requested to net what the annihilation needs, and the floor that gross guarantees.
     *        b. The GROSS — not the net — is capped at the caller's own `user.amount`. Capping the net
     *           instead would underflow `user.amount` for exactly the caller annihilating their whole
     *           position, since the gross they must give up exceeds it.
     *        c. `user.amount` and `pool.totalStaked` are debited by the GROSS: the caller is written
     *           down everything the strategy gave up, exactly as {withdraw} does. This is the same
     *           outcome as withdrawing manually and annihilating in their own wallet.
     *        d. The Antimatter the haircut displaced — the reward the shrunken net can no longer be
     *           annihilated against — joins `excess` and is minted straight to the caller.
     *        e. The preview is ADVISORY ONLY. It reads live AMM state, is manipulable within a block,
     *           and is built on the FEE-FREE `convertToAssets` (vault-RM 049), so it can over-quote in
     *           two independent ways. The real balance delta across the exit is therefore MEASURED,
     *           and a delivery below the pro-rated guarantee reverts `"StableStaker: exit shortfall"`.
     *           A lying preview must fail the transaction, never raid the buffer.
     *        f. Anything the exit OVER-delivers (the AMM pays at or above its floor) is forwarded to
     *           the caller: they were debited the gross, so the surplus is theirs, and leaving it here
     *           would quietly grow the buffer at their expense.
     *
     *      Gated on `PoolState.Active` like {stake} / {withdraw} / {emergencyWithdraw}, because unlike
     *      {claim} this moves principal and would corrupt the terminal-migration `P` snapshot.
     *      `annihilate` is `whenNotPaused` against ANTIMATTER's pauser, which this contract does not
     *      control; the operational answer to that pause is {setClaimEnabled}(true).
     * @param token The pool token, which must ALSO be a registered stablecoin on the phUSD stable
     *              minter — see {autoAnnihilateAvailable}.
     * @param minPhUSDOut The least phUSD the caller accepts across both halves, forwarded verbatim to
     *              Antimatter. The stable minter's exchange rate is configurable and not guaranteed
     *              1:1, so this is real slippage protection; passing zero waives it.
     */
    function autoAnnihilate(address token, uint256 minPhUSDOut) external nonReentrant whenNotPaused poolExists(token) {
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");
        // Explicit and ahead of any state change, so the UI never has to interpret a foreign
        // contract's `StablecoinNotRegistered` custom error to tell "this token cannot be
        // annihilated" from "you have nothing to annihilate".
        require(autoAnnihilateAvailable(token), "StableStaker: token not annihilatable");

        // The 18-decimal antimatter scale for one raw unit of `token`.
        uint256 scale = _antimatterScale(token);
        uint256 netWanted; // the stable half the annihilation needs, in `token` decimals
        uint256 gross; // the principal the caller gives up to obtain it
        uint256 netFloor; // the least the exit may deliver before this call is a shortfall
        uint256 excessBase; // reward that outran the principal outright; minted to the caller

        // Scoped so the intermediate arithmetic leaves the stack before the interactions below.
        {
            PoolInfo storage pool = poolInfo[token];
            _updatePool(token);
            UserInfo storage user = userInfo[token][msg.sender];

            {
                // Byte-identical to {claim}: the settled backlog plus anything freshly pending.
                uint256 owed = unclaimedReward[token][msg.sender]
                    + ((user.amount * pool.accAntimatterPerShare) / ACC_PRECISION - user.rewardDebt);
                uint256 principalAsAntimatter = user.amount * scale;
                // Capped at the caller's own principal, then floored to something `token` can express:
                // toStableAmount reverts on a finer amount rather than rounding it away.
                uint256 capped = owed < principalAsAntimatter ? owed : principalAsAntimatter;
                netWanted = capped / scale;
                excessBase = owed - capped;
                require(netWanted > 0 || excessBase > 0, "StableStaker: nothing to annihilate");
                // The sub-unit remainder, carried in the mapping rather than paid out.
                unclaimedReward[token][msg.sender] = capped - netWanted * scale;
            }

            {
                // Size the exit against the strategy's haircut, then cap the GROSS — never the net —
                // at the caller's own principal, or the debit below underflows for the caller
                // annihilating their whole position. `netFloor` is pro-rated when our cap bites,
                // because the quote was issued for the uncapped request.
                (uint256 grossQuote, uint256 netQuote) = _previewExit(token, netWanted);
                require(netWanted == 0 || grossQuote > 0, "StableStaker: exit unavailable");
                gross = grossQuote > user.amount ? user.amount : grossQuote;
                netFloor = grossQuote == 0 ? 0 : (netQuote * gross) / grossQuote;
            }

            // Effects. All four parts of the bookkeeping, none of them optional: a stale `rewardDebt`
            // underflows every later settle and bricks the position, and a staker left in the set
            // makes finalizeAndReset's `stakerCount == 0` unsatisfiable.
            user.amount -= gross;
            pool.totalStaked -= gross;
            user.rewardDebt = (user.amount * pool.accAntimatterPerShare) / ACC_PRECISION;
            if (user.amount == 0) {
                _stakers[token].remove(msg.sender);
            }
        }

        // Interactions.
        uint256 netUsed;
        uint256 surplus;
        if (gross > 0) {
            // Underwater guard ON, matching {withdraw}: this is a voluntary principal exit, not an
            // escape hatch, so it must not realize a loss the user did not opt into.
            uint256 received = _routeExit(token, gross, true);
            // MANDATORY MEASUREMENT. The preview is advisory: manipulable within a block and built on
            // the fee-free ideal conversion. A delivery under the floor it promised fails the call
            // rather than quietly drawing the difference from the shared idle buffer.
            // The floor is slackened by a ROUNDING allowance, never a haircut allowance: the
            // guarantee is quoted from fee-free, ideal conversions, while the exit itself rounds
            // down at every step in the protocol's favour, so an honest strategy lands a hair under
            // its own promise. Anything materially short still fails here.
            uint256 allowance = EXIT_ROUNDING_ALLOWANCE + (netFloor * EXIT_ROUNDING_ALLOWANCE_BPS) / MAX_BPS;
            uint256 floorWithAllowance = netFloor > allowance ? netFloor - allowance : 0;
            require(received > 0 && received >= floorWithAllowance, "StableStaker: exit shortfall");
            netUsed = received < netWanted ? received : netWanted;
            surplus = received - netUsed;
        }
        uint256 annihilatable = netUsed * scale;
        // Everything the annihilation could not consume: the reward that outran the principal
        // (`owed - capped`) plus the reward the exit haircut displaced.
        uint256 excess = excessBase + (netWanted - netUsed) * scale;

        if (annihilatable > 0) {
            antimatter.mint(address(this), annihilatable);
            IERC20(token).forceApprove(address(antimatter), netUsed);
            antimatter.annihilate(token, msg.sender, annihilatable, minPhUSDOut);
            IERC20(token).forceApprove(address(antimatter), 0);
        }
        if (excess > 0) {
            antimatter.mint(msg.sender, excess);
        }
        if (surplus > 0) {
            // Over-delivery belongs to the caller, who was debited the gross that produced it.
            IERC20(token).safeTransfer(msg.sender, surplus);
        }

        emit AutoAnnihilated(token, msg.sender, annihilatable, gross, excess);
    }

    /**
     * @notice Escape hatch: withdraw the caller's full principal for `token`, forfeiting ALL reward —
     *         the live pending AND the settled-but-unminted {unclaimedReward} backlog. Works while
     *         paused and never mints, so a broken mint path can never trap principal.
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
        // Forfeit the backlog too: the hatch stays the single rule "no reward, principal out".
        unclaimedReward[token][msg.sender] = 0;
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
     *      every user's pending Antimatter is fixed at the snapshot and is minted in full on their exit.
     * @param token The staked token to put into terminal migration. Must be a registered pool and not
     *              already migrating.
     */
    function initiateMigration(address token) external override nonReentrant onlyMigrator poolExists(token) {
        require(poolState[token] == PoolState.Active, "StableStaker: pool not active");

        // Settle rewards to this block; subsequent _updatePool calls are frozen once Migrating is set,
        // so pending Antimatter is now fixed at the snapshot for every migrating user.
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
        // the client fully. When no strategy is set, _routeExit is a no-op (principal already idle).
        // The return value is deliberately NOT used: R is measured from this contract's own balance
        // below, so the set-aside buffer counts toward the migration payout.
        _routeExit(token, P, false);

        // Write down anything the strategy still books to us. setYieldStrategy's idle sweep can leave
        // principalOf > totalStaked — that excess is protocol money by construction (the sweep is gated
        // on an empty pool) and is relinquished here rather than bricking the migration, which is
        // audit-14 ss14m1. relinquishPrincipal is onlyAuthorizedClient, so this contract may call it on
        // its own behalf; it already does so on the underwater buffer path. The write-down touches
        // recorded principal only — no vault shares move — so the value stays in the strategy as
        // protocol-owned capital.
        uint256 booked = address(strategy) == address(0) ? 0 : strategy.principalOf(token, address(this));

        // Emitted on EVERY migration, a clean one included (booked == 0), so a missing log is itself a
        // signal rather than being indistinguishable from a migration that reconciled nothing.
        // Deliberately BEFORE the booked > 0 guard, never inside it.
        emit PrincipalDivergence(token, P, booked, booked);

        // The GUARD is on the call, not on the event: AYieldStrategy._relinquishInternal reverts on a
        // zero amount (twice — before and after capping), so an unguarded call would turn a clean
        // migration into a reverting one, which is precisely the failure this change removes.
        if (booked > 0) {
            strategy.relinquishPrincipal(token, booked);
        }

        // Post-check the exit fully drained the client. Now satisfiable by construction rather than
        // being the brick: it still catches a strategy whose relinquish does not actually write the
        // principal down (a tranche/queue vault that cannot exit atomically). Skipped when no strategy
        // is set.
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

        // R is the whole liquid position this contract can pay migration credits from, capped at par.
        // Measuring it from the balance (rather than from _routeExit's delta) counts the set-aside
        // buffer, dust and donations already sitting here, so a below-par exit is softened before any
        // user is haircut — audit-14 ss14l8. All liquid value up to par is paid to users; anything
        // above par stays protocol-owned in the now-decoupled strategy, so the "stakers get principal
        // + Antimatter only" invariant holds. Computed after the reconciliation block so the code reads in
        // the order the reasoning runs (relinquishPrincipal moves no tokens, so it cannot affect this
        // balance either way). min(R, P) at the credit site is now redundant but is kept as cheap
        // defence against a stray donation arriving between here and the last userMigrate.
        uint256 R = IERC20(token).balanceOf(address(this));
        if (R > P) {
            R = P;
        }

        migrationInfo[token] = MigrationInfo({realized: R, principalSnapshot: P});
        emit MigrationInitiated(token, R, P);
    }

    /**
     * @notice Permissioned batched exit during terminal migration (see {IStableStaker-batchMigrate}).
     *         Replaces the legacy `migrateOut`. For each non-zero user: mints their frozen pending
     *         Antimatter, zeroes their position, and accumulates the snapshot credit `p_i·min(R,P)/P`. The
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
     * @dev Shared terminal-migration exit for one user: mints their frozen pending Antimatter PLUS any
     *      {unclaimedReward} backlog (terminal exit settles everything owed), computes the
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
        uint256 pending = (amt * pool.accAntimatterPerShare) / ACC_PRECISION - info.rewardDebt;

        uint256 owed = unclaimedReward[token][account] + pending;

        info.amount = 0;
        info.rewardDebt = 0;
        unclaimedReward[token][account] = 0;
        pool.totalStaked -= amt;
        _stakers[token].remove(account);

        // DELIBERATELY UNGATED by {claimEnabled}. This is the terminal-migration exit, not a claim:
        // gating it would let a closed claim gate brick migration, and the golden rule is that
        // migration is never brickable. See {claimEnabled}.
        if (owed > 0) {
            antimatter.mint(account, owed);
        }
        emit MigratedOut(token, account, credit, owed);
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
        _settle(token, user, info, pool);

        uint256 received = _pullToken(token, msg.sender, amount);
        uint256 credited = _routeDeposit(token, received);
        require(credited > 0, "StableStaker: nothing credited");
        info.amount += credited;
        pool.totalStaked += credited;
        info.rewardDebt = (info.amount * pool.accAntimatterPerShare) / ACC_PRECISION;
        _stakers[token].add(user);
        emit DepositedFor(token, user, credited);
    }

    // ============================== VIEWS ==============================

    /// @notice Projected pending Antimatter reward for `account` in `token`'s pool — the LIVE PROJECTION
    ///         ONLY, measured against `rewardDebt`.
    /// @dev Deliberately EXCLUDES the settled-but-unminted {unclaimedReward} backlog, so its meaning is
    ///      byte-identical to the frozen V1 function of the same name (V1 is permanently deployed and
    ///      this project ships a cross-version migrator, so both are read side by side). For the figure
    ///      {claim} and the terminal-migration exit actually pay, read {claimableReward}. While terminal
    ///      migration is active, emissions are frozen at the snapshot, so this returns the fixed pending
    ///      with no forward projection.
    function pendingReward(address token, address account) external view returns (uint256) {
        return _pendingReward(token, account);
    }

    /// @notice Total Antimatter `account` could mint from `token`'s pool right now: the settled-but-unminted
    ///         {unclaimedReward} backlog plus the live projection returned by {pendingReward}.
    /// @dev This is the figure {claim} pays. {pendingReward} deliberately excludes the backlog so its
    ///      meaning stays identical to the frozen V1 function of the same name.
    function claimableReward(address token, address account) external view returns (uint256) {
        return unclaimedReward[token][account] + _pendingReward(token, account);
    }

    /// @dev Pure extraction of the former {pendingReward} body, shared with {claimableReward}. Returns
    ///      the identical value {pendingReward} always returned, for every input.
    function _pendingReward(address token, address account) internal view returns (uint256) {
        PoolInfo storage pool = poolInfo[token];
        uint256 acc = pool.accAntimatterPerShare;
        if (poolState[token] == PoolState.Active && block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
            uint256 elapsed = block.timestamp - pool.lastRewardTime;
            uint256 reward = elapsed * pool.antimatterPerSecond;
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

    /**
     * @notice True when {autoAnnihilate} can work for `token`: the pool token is ALSO a registered
     *         stablecoin on the phUSD stable minter (with decimals the minter and the token agree on)
     *         AND, if a yield strategy is set, that strategy can guarantee anything at all on exit.
     * @dev A live cross-contract configuration coupling StableStaker has never had before —
     *      registering a pool token with the stable minter is now part of the pool-registration
     *      runbook. Probed with a staticcall rather than a try/catch, because Antimatter's
     *      `toStableAmount` can fail through a return-data decode that a catch block would not
     *      intercept. `1e18` is representable in every decimals <= 18, so a failure here means the
     *      configuration, never the amount.
     *
     *      The strategy leg (round 2) keeps the view honest about the exit: a market strategy set to
     *      a 100% slippage tolerance answers `(0, 0)` to every {IYieldStrategy-previewExitFor}, i.e.
     *      it guarantees no output whatsoever, and {autoAnnihilate} would rather refuse than mint the
     *      whole reward raw through the `excess` path and hand the caller a bypass of a closed
     *      {claim}. The probe is skipped when the strategy custodies nothing for this pool: there is
     *      then no principal to annihilate against anyway, and the reward-outran-principal path still
     *      works, so reporting `false` would be the inconsistent answer.
     */
    function autoAnnihilateAvailable(address token) public view returns (bool) {
        (bool ok, bytes memory data) =
            address(antimatter).staticcall(abi.encodeCall(IAntimatter.toStableAmount, (token, 1e18)));
        if (!ok || data.length != 32) {
            return false;
        }
        IYieldStrategy strategy = yieldStrategy[token];
        if (address(strategy) == address(0) || strategy.principalOf(token, address(this)) == 0) {
            return true;
        }
        (bool previewOk, bytes memory previewData) =
            address(strategy).staticcall(abi.encodeCall(IYieldStrategy.previewExitFor, (token, address(this), 1)));
        if (!previewOk || previewData.length != 64) {
            return false;
        }
        (uint256 grossQuote,) = abi.decode(previewData, (uint256, uint256));
        return grossQuote > 0;
    }

    /**
     * @notice The phUSD token this staker may mint, read LIVE off Antimatter on every call.
     * @dev Deliberately NOT a constructor argument and NOT cached. `Antimatter.phUSD` is mutable —
     *      the owner may rotate it via `setPhUSD(IFlax)` — so a cached value would silently point at
     *      a dead token after a legitimate rotation. This mirrors {_antimatterScale}, which reads
     *      decimals live for the same reason: a live read that reverts fails closed, a stale cache
     *      misbehaves silently. Reading in the constructor would additionally require Antimatter to
     *      be fully wired before the staker is deployed, which the deployment runbook does not
     *      guarantee, and would break every test that constructs the staker against a bare stand-in.
     *
     *      Returns `address(0)` when Antimatter's phUSD is unset. Callers that intend to MINT must
     *      go through {_phUSD}, which fails closed instead.
     */
    function phUSDToken() public view returns (address) {
        return antimatter.phUSD();
    }

    /**
     * @notice True when this staker can actually mint phUSD right now.
     * @dev The gate on phUSD's `mint` has TWO conditions and the second is a live operational
     *      hazard: `canMint` must be set for this contract AND the `mintVersion` recorded at the
     *      grant must still equal phUSD's current global `mintVersion`. phUSD's owner can call
     *      `revokeAllMintPrivileges()`, which bumps that global counter and de-authorises EVERY
     *      minter at once with no per-minter transaction — so a `canMint`-only probe reports a false
     *      positive for a staker whose rights have already evaporated.
     *
     *      Staticcalled rather than called directly so that an unset, non-contract or ABI-divergent
     *      phUSD answers `false` instead of reverting the caller. Nothing in this contract consumes
     *      this yet; it exists so the shortfall path can degrade rather than assume, and so the
     *      capability is observable and testable before its consumer lands.
     */
    function phUSDMintAvailable() public view returns (bool) {
        address token = phUSDToken();
        if (token == address(0)) {
            return false;
        }
        (bool infoOk, bytes memory infoData) =
            token.staticcall(abi.encodeCall(IPhUSD.authorizedMinters, (address(this))));
        if (!infoOk || infoData.length != 64) {
            return false;
        }
        IPhUSD.MinterInfo memory info = abi.decode(infoData, (IPhUSD.MinterInfo));
        if (!info.canMint) {
            return false;
        }
        (bool versionOk, bytes memory versionData) = token.staticcall(abi.encodeCall(IPhUSD.mintVersion, ()));
        if (!versionOk || versionData.length != 32) {
            return false;
        }
        return info.mintVersion == abi.decode(versionData, (uint256));
    }

    // ============================== INTERNAL ==============================

    /// @dev Accrue rewards for `token` up to the current block. Empty pools accrue nothing.
    function _updatePool(address token) internal {
        // Emissions are frozen once terminal migration is engaged: each user's pending Antimatter stays
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
        uint256 reward = elapsed * pool.antimatterPerSecond;
        if (reward > 0) {
            pool.accAntimatterPerShare += (reward * ACC_PRECISION) / pool.totalStaked;
        }
        pool.lastRewardTime = block.timestamp;
    }

    /// @dev Book any outstanding pending reward for an existing position to {unclaimedReward}, where
    ///      {claim} will mint it. Never calls Antimatter, so a revoked minter role cannot brick the
    ///      principal paths that reach here. Assumes pool is current.
    function _settle(address token, address account, UserInfo storage user, PoolInfo storage pool) internal {
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accAntimatterPerShare) / ACC_PRECISION - user.rewardDebt;
            if (pending > 0) {
                unclaimedReward[token][account] += pending;
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

    /// @dev The 18-decimal-antimatter-per-stable-unit scale for `token`, i.e. `10 ** (18 - decimals)`.
    ///      Read LIVE from {IERC20Metadata} rather than cached at {addToken}: a cache would have to be
    ///      backfilled for the already-registered pools of the live V1 and V2 instances, and a token
    ///      whose decimals move under a cache mis-scales silently, whereas a live read that reverts
    ///      fails closed. Antimatter cross-checks the same figure against the stable minter's
    ///      registration and reverts `DecimalsMismatch` if the two disagree, so the live read has an
    ///      independent auditor on every call.
    function _antimatterScale(address token) internal view returns (uint256) {
        uint8 dec = IERC20Metadata(token).decimals();
        require(dec <= 18, "StableStaker: unsupported decimals");
        return 10 ** (18 - dec);
    }

    /// @dev Resolve the phUSD token as {IPhUSD}, failing closed when Antimatter's phUSD is unset.
    ///      This is the only path a MINT may take: {phUSDToken} is the observable view and answers
    ///      `address(0)` rather than reverting, which is the wrong answer for a caller about to
    ///      hand a mint to it. Read live, per the reasoning on {phUSDToken}.
    function _phUSD() internal view returns (IPhUSD) {
        address token = phUSDToken();
        require(token != address(0), "StableStaker: phUSD unset on antimatter");
        return IPhUSD(token);
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
    /**
     * @dev Size a strategy exit: the GROSS that must be requested to net `netWanted`, and the floor
     *      that gross is guaranteed to deliver. With no strategy set the principal is already idle in
     *      this contract, so gross == net == `netWanted` and nothing is haircut.
     *
     *      ⚠️ `netGuaranteed` is a FLOOR, not an expectation and not a settlement figure. It reads
     *      live vault and AMM state (manipulable within a block) and is built on the fee-free
     *      `convertToAssets` (vault-RM 049), so it can over-quote in two independent ways. Callers
     *      MUST measure the real balance delta across the exit — see {autoAnnihilate}.
     */
    function _previewExit(address token, uint256 netWanted)
        internal
        view
        returns (uint256 grossToRequest, uint256 netGuaranteed)
    {
        IYieldStrategy strategy = yieldStrategy[token];
        if (address(strategy) == address(0)) {
            return (netWanted, netWanted);
        }
        return strategy.previewExitFor(token, address(this), netWanted);
    }

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
