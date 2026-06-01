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
contract StableStaker is Ownable, Pausable, ReentrancyGuard, IPausable {
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

    /// @notice Address authorized to perform permissioned migration (migrateOut / depositFor).
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
    mapping(address => mapping(address => UserInfo)) public userInfo;

    /// @notice token => enumerable set of addresses currently holding a non-zero position.
    mapping(address => EnumerableSet.AddressSet) private _stakers;

    /// @notice Set of every registered pool token.
    EnumerableSet.AddressSet private _registeredTokens;

    /// @notice token => yield strategy that custodies its principal. address(0) ⇒ held idle in-contract.
    /// @dev Principal-moving paths route through this adapter when set. Reward accounting is unaffected:
    ///      yield accrued inside the strategy is protocol-owned and never credited to stakers.
    mapping(address => IYieldStrategy) public yieldStrategy;

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
    event DepositedFor(address indexed token, address indexed user, uint256 amount);
    event BufferWithdrawn(address indexed token, address indexed user, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

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
     *      it). When clearing or replacing, the old strategy's allowance is reset to 0. Replacing an
     *      in-use strategy does NOT migrate funds out of the old one (see CLAUDE.md / story Concerns):
     *      drain the old strategy or replace only while `totalStaked == 0`.
     *
     *      Wiring prerequisite: the strategy owner must authorize this contract as a client
     *      (`strategy.setClient(address(this), true)`) before deposits will succeed.
     */
    function setYieldStrategy(address token, IYieldStrategy strategy) external onlyOwner poolExists(token) {
        IYieldStrategy old = yieldStrategy[token];
        if (address(old) != address(0)) {
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
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        UserInfo storage user = userInfo[token][msg.sender];
        _settle(msg.sender, user, pool);

        uint256 received = _pullToken(token, msg.sender, amount);
        _routeDeposit(token, received);
        user.amount += received;
        pool.totalStaked += received;
        user.rewardDebt = (user.amount * pool.accPhusdPerShare) / ACC_PRECISION;
        _stakers[token].add(msg.sender);
        emit Staked(token, msg.sender, received);
    }

    /// @notice Withdraw `amount` of staked `token`. Any pending reward is minted to the caller.
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused poolExists(token) {
        require(amount > 0, "StableStaker: amount=0");
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

    // ============================== MIGRATION ==============================

    /**
     * @notice Permissioned batched exit (see {IStableStaker-migrateOut}). Settles and mints each
     *         user's pending reward, zeroes their position, and transfers the aggregate principal
     *         to the migrator. Callable while paused so a migration can proceed during an incident.
     */
    function migrateOut(address token, address[] calldata users)
        external
        nonReentrant
        onlyMigrator
        poolExists(token)
        returns (uint256[] memory amounts)
    {
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        amounts = new uint256[](users.length);
        uint256 totalPrincipal;
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            UserInfo storage info = userInfo[token][u];
            uint256 amt = info.amount;
            if (amt == 0) {
                continue;
            }
            uint256 pending = (amt * pool.accPhusdPerShare) / ACC_PRECISION - info.rewardDebt;
            info.amount = 0;
            info.rewardDebt = 0;
            pool.totalStaked -= amt;
            _stakers[token].remove(u);
            amounts[i] = amt;
            totalPrincipal += amt;
            if (pending > 0) {
                phUSD.mint(u, pending);
            }
            emit MigratedOut(token, u, amt, pending);
        }
        if (totalPrincipal > 0) {
            // Redeem the aggregate principal in a single strategy call (the farm is one client).
            // No underwater guard: a below-par migration delivers the redeemed (haircut) amount.
            uint256 payout = _routeExit(token, totalPrincipal, false);
            IERC20(token).safeTransfer(msg.sender, payout);

            // M-01 fix: when below par, the migrator only holds `payout` (< totalPrincipal). Re-credit
            // users on the REALIZED basis so Σ amounts[i] <= payout and the migrator's redeposits can
            // never exceed the funds it received. Division dust (payout - Σ scaled) stays in the migrator
            // (protocol-owned). At/above par payout == totalPrincipal, so scaling is an identity and is skipped.
            if (payout < totalPrincipal) {
                for (uint256 i = 0; i < users.length; i++) {
                    if (amounts[i] > 0) {
                        amounts[i] = (amounts[i] * payout) / totalPrincipal;
                    }
                }
            }
        }
    }

    /**
     * @notice Permissioned deposit crediting `user` (see {IStableStaker-depositFor}). Pulls
     *         `amount` of `token` from the migrator. Callable while paused so a freshly deployed
     *         (and possibly paused) target can be seeded.
     */
    function depositFor(address token, address user, uint256 amount)
        external
        nonReentrant
        onlyMigrator
        poolExists(token)
    {
        require(amount > 0, "StableStaker: amount=0");
        PoolInfo storage pool = poolInfo[token];
        _updatePool(token);
        UserInfo storage info = userInfo[token][user];
        _settle(user, info, pool);

        uint256 received = _pullToken(token, msg.sender, amount);
        _routeDeposit(token, received);
        info.amount += received;
        pool.totalStaked += received;
        info.rewardDebt = (info.amount * pool.accPhusdPerShare) / ACC_PRECISION;
        _stakers[token].add(user);
        emit DepositedFor(token, user, received);
    }

    // ============================== VIEWS ==============================

    /// @notice Projected pending phUSD reward for `account` in `token`'s pool.
    function pendingReward(address token, address account) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[token];
        uint256 acc = pool.accPhusdPerShare;
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
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

    /// @dev If a strategy is set for `token`, deposit `amount` into it under this contract's account.
    ///      No-op (idle hold) when unset. Reward/principal accounting always uses `amount` regardless.
    function _routeDeposit(address token, uint256 amount) internal {
        IYieldStrategy strategy = yieldStrategy[token];
        if (address(strategy) != address(0)) {
            strategy.deposit(token, amount, address(this));
        }
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
