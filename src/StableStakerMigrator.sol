// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IStableStaker.sol";

/**
 * @title StableStakerMigrator
 * @notice Orchestrates a zero-user-action migration between two {StableStaker} instances.
 *
 * @dev The owner calls {migrate} with a batch of users. The migrator pulls those users'
 *      principal out of the old staker (which also mints each user's earned phUSD to them) and
 *      re-deposits it into the new staker crediting the same users. No staker needs to act.
 *
 *      The migrator must be set as `migrator` on BOTH stakers (via `setMigrator`), and the new
 *      staker must already have the token registered (`addToken`). It uses the per-user `amounts`
 *      returned by {IStableStaker-batchMigrate}, which guarantees the approval/redeposit totals
 *      exactly match the principal that was pulled in.
 *
 *      Terminal-migration flow: the owner calls {initiateMigration} ONCE per token (engaging the
 *      old staker's terminal snapshot), then {migrate} for each batch of users.
 */
contract StableStakerMigrator is Ownable {
    using SafeERC20 for IERC20;

    /// @notice The staker users are migrating out of.
    IStableStaker public immutable oldStaker;

    /// @notice The staker users are migrating into.
    IStableStaker public immutable newStaker;

    event Migrated(address indexed token, uint256 userCount, uint256 totalPrincipal);

    constructor(IStableStaker _oldStaker, IStableStaker _newStaker, address initialOwner) Ownable(initialOwner) {
        require(address(_oldStaker) != address(0), "Migrator: zero old staker");
        require(address(_newStaker) != address(0), "Migrator: zero new staker");
        oldStaker = _oldStaker;
        newStaker = _newStaker;
    }

    /**
     * @notice Engage terminal migration on the old staker for `token`. Thin owner-only forwarder to
     *         {IStableStaker-initiateMigration}: realizes the strategy position once and snapshots
     *         (R, P) so every subsequent {migrate} batch pays a fixed, order-independent credit.
     * @dev Must be called exactly once per token BEFORE the first {migrate} batch. Reverts (on the
     *      staker) if the token is already migrating, so it is naturally idempotent-guarded.
     * @param token The staked token to put into terminal migration on the old staker.
     */
    function initiateMigration(address token) external onlyOwner {
        oldStaker.initiateMigration(token);
    }

    /**
     * @notice Migrate a batch of users for `token` from the old staker to the new staker.
     * @dev Requires a prior {initiateMigration} for `token` (the old staker reverts otherwise).
     * @param token The staked token to migrate.
     * @param users The users to migrate (build batches off-chain via getStakers/getStakersRange).
     */
    function migrate(address token, address[] calldata users) external onlyOwner {
        uint256[] memory amounts = oldStaker.batchMigrate(token, users);

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        if (total == 0) {
            emit Migrated(token, 0, 0);
            return;
        }

        IERC20(token).forceApprove(address(newStaker), total);

        uint256 migratedCount;
        for (uint256 i = 0; i < users.length; i++) {
            if (amounts[i] > 0) {
                newStaker.depositFor(token, users[i], amounts[i]);
                migratedCount++;
            }
        }

        emit Migrated(token, migratedCount, total);
    }
}
