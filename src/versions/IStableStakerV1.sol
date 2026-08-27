// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "flax-token/IFlax.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import "../interfaces/IStableStakerMigratable.sol";

/**
 * @title IStableStakerV1
 * @notice FROZEN SNAPSHOT of the complete external surface of the **deployed V1**
 *         {StableStaker} instance.
 *
 *         Deployed address : 0xbce8ABC09BaEDCabE93419bF875f6186e182079A (Ethereum mainnet)
 *         Source commit    : c3ec65b
 *         Deploy date      : 2026-06-10 (by `ResumeStableStakerMigration`, phase-2-staging story 055)
 *         Recorded in      : `reflax-mint/phase-2-staging/server/deployments/mainnet-addresses.ts`
 *
 * @dev ############################  NEVER EDIT THIS FILE  ############################
 *
 *      This is a historical record, not a design surface. It describes a contract that is
 *      already on chain and can never change. Editing it does not change the deployed
 *      contract — it only makes this file lie about the deployed contract, which is the one
 *      failure mode the `src/versions/` directory exists to prevent.
 *
 *      If `src/StableStaker.sol` grows, loses or reshapes a member, the correct response is a
 *      NEW snapshot (`IStableStakerV2.sol`, taken at the next deploy) — never an edit here.
 *      The evergreen model is exactly this: `StableStaker.sol` is always the current
 *      implementation, and every deploy is frozen under `src/versions/` so migrators, scripts
 *      and tests can always talk to whatever is actually live.
 *
 *      This file is retained in source PERPETUALLY — until the live V1 instance is genuinely
 *      empty and dead. Precedent for why: `phase-2-staging/foundry.toml` carries a compile-skip
 *      list because legacy scripts were hard-wired to V1 `yield-claim-nft` contracts that were
 *      deleted from the submodule. Deleting a live version's shape breaks downstream
 *      deployment scripts; keeping it costs nothing (interfaces are not deployed and so do not
 *      count against `forge build --sizes`).
 *
 *      ## `userInfo` arity is load-bearing
 *      V1's `struct UserInfo` has exactly two fields, so the public auto-getter is a 2-tuple.
 *      `docs/deferred-reward-accrual-plan.md` §4 warns that appending a field turns it into a
 *      3-tuple and breaks every destructuring call site. This snapshot pins the 2-tuple form
 *      permanently — that is its job, and it is precisely why a future version that changes
 *      `UserInfo` needs its own snapshot rather than an edit to this file.
 *
 *      ## `poolState` returns `uint8`, not the enum
 *      Declaring `enum PoolState` here would duplicate a type that already lives in
 *      `StableStaker.sol`. Returning the raw `uint8` keeps this snapshot self-contained and
 *      immune to a future enum change. Mapping: `0 = Active`, `1 = Migrating`.
 *
 *      ## Known external coupling
 *      {IYieldStrategy} is imported from the `reflax-yield-vault` submodule, which tracks
 *      `master`. If that interface ever changes shape, this frozen snapshot inherits the churn.
 *      A future hardening step could inline the signature instead of importing it. The same
 *      applies to {IFlax} from `flax-token`.
 *
 *      ## Fidelity
 *      `test/StableStakerV1Snapshot.t.sol` proves this snapshot is a faithful *subset* of the
 *      source at HEAD. It does not — and cannot, without a fork test — prove the live mainnet
 *      contract matches; deployment reconciliation is the human's job.
 */
interface IStableStakerV1 is IStableStakerMigratable {
    // ============================== EVENTS ==============================
    // Mirrors of the 16 events emitted by the deployed V1 contract.

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

    // ============================== OWNER CONFIG ==============================

    /// @notice Register a new pool for `token`.
    function addToken(address token) external;

    /// @notice Set `token`'s phUSD emission rate, expressed per day.
    function phUSDPerDay(address token, uint256 amountPerDay) external;

    /// @notice Set the address permitted to call the golden-rule migration triad.
    function setMigrator(address _migrator) external;

    /// @notice Set the address permitted to {pause}.
    function setPauser(address _pauser) external;

    /// @notice Wire (or unwire, with `address(0)`) the yield strategy custodying `token`'s principal.
    function setYieldStrategy(address token, IYieldStrategy strategy) external;

    /// @notice Return a fully-drained migrating pool to Active and clear its migration snapshot.
    function finalizeAndReset(address token) external;

    /// @notice Owner rescue of non-principal ERC20 balances.
    function rescueERC20(address token, address to, uint256 amount) external;

    // ============================== PAUSING (IPausable) ==============================
    // Declared here rather than by inheriting `IPausable` so this snapshot stays a
    // self-contained record that survives churn in the `pauser` submodule.

    /// @notice Pause the contract. Callable by `pauser()` only.
    function pause() external;

    /// @notice Unpause the contract. Callable by owner OR `pauser()`.
    function unpause() external;

    /// @notice Whether the contract is currently paused (OZ {Pausable}).
    function paused() external view returns (bool);

    /// @notice The address authorized to {pause}.
    function pauser() external view returns (address);

    // ============================== USER ==============================

    /// @notice Stake `amount` of `token`.
    function stake(address token, uint256 amount) external;

    /// @notice Withdraw `amount` of staked `token`, settling pending rewards.
    function withdraw(address token, uint256 amount) external;

    /// @notice Mint the caller's pending phUSD for `token`.
    function claim(address token) external;

    /// @notice Forfeit-rewards escape hatch; callable while paused.
    function emergencyWithdraw(address token) external;

    /// @notice Self-service exit during a terminal migration, paying the frozen pro-rata credit.
    function userMigrate(address token) external;

    // ============================== VIEWS ==============================

    /// @notice Unclaimed phUSD owed to `account` in `token`'s pool.
    function pendingReward(address token, address account) external view returns (uint256);

    /// @notice Every address currently holding a non-zero position in `token`'s pool.
    function getStakers(address token) external view returns (address[] memory);

    /// @notice Paginated form of {getStakers}, over `[start, end)`.
    function getStakersRange(address token, uint256 start, uint256 end) external view returns (address[] memory);

    /// @notice Number of addresses holding a non-zero position in `token`'s pool.
    function stakerCount(address token) external view returns (uint256);

    /// @notice Every registered pool token.
    function getStakedTokens() external view returns (address[] memory);

    /// @notice Whether ordinary withdrawals are currently blocked for `token`.
    function withdrawDisabled(address token) external view returns (bool);

    // ============================== PUBLIC AUTO-GETTERS ==============================
    // Consumers already rely on these; they are part of the frozen surface.

    /// @notice Auto-getter for the public `poolInfo` mapping (struct `PoolInfo`, 4 fields).
    function poolInfo(address token)
        external
        view
        returns (uint256 phusdPerSecond, uint256 accPhusdPerShare, uint256 lastRewardTime, uint256 totalStaked);

    /// @notice Auto-getter for the public `userInfo` mapping. EXACTLY TWO return values — see the
    ///         header note on `userInfo` arity.
    function userInfo(address token, address user) external view returns (uint256 amount, uint256 rewardDebt);

    /// @notice Auto-getter for the public `poolState` mapping. `0 = Active`, `1 = Migrating`.
    /// @dev Returns the raw `uint8` rather than the enum; see the header note.
    function poolState(address token) external view returns (uint8);

    /// @notice Auto-getter for the public `migrationInfo` mapping (struct `MigrationInfo`, 2 fields).
    function migrationInfo(address token) external view returns (uint256 realized, uint256 principalSnapshot);

    /// @notice Auto-getter for the public `yieldStrategy` mapping.
    function yieldStrategy(address token) external view returns (IYieldStrategy);

    /// @notice Auto-getter for the public `migrator` address.
    function migrator() external view returns (address);

    /// @notice Auto-getter for the immutable phUSD token.
    function phUSD() external view returns (IFlax);

    /// @notice Reward-accounting fixed-point scale (1e18).
    function ACC_PRECISION() external view returns (uint256);

    /// @notice Seconds per day (86400), used to convert `phUSDPerDay` into a per-second rate.
    function SECONDS_PER_DAY() external view returns (uint256);

    // ============================== OWNABLE ==============================

    /// @notice OZ {Ownable} owner.
    function owner() external view returns (address);

    /// @notice OZ {Ownable} ownership transfer.
    function transferOwnership(address newOwner) external;

    /// @notice OZ {Ownable} ownership renunciation.
    function renounceOwnership() external;
}
