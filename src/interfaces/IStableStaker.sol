// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStableStaker
 * @notice Minimal surface of {StableStaker} that the {StableStakerMigrator} depends on.
 * @dev Kept intentionally small so the migrator is decoupled from the full staker
 *      implementation. Both functions are permissioned (`onlyMigrator`) on the staker.
 */
interface IStableStaker {
    /**
     * @notice Permissioned, batched exit. For each user: settles and mints their pending
     *         phUSD, zeroes their position and removes them from the staker set. The sum of
     *         all withdrawn principal is transferred to the caller (the migrator).
     * @param token  The staked token whose positions are being migrated out.
     * @param users  The users to migrate.
     * @return amounts Per-user amount actually re-credited, parallel to `users` (0 for empty positions).
     *         At or above par these equal each user's requested principal. Below par the strategy
     *         delivers a haircut, so each non-zero entry is scaled to its REALIZED, pro-rata share of
     *         the redeemed payout (`requested * payout / totalRequested`, floored), guaranteeing the
     *         sum never exceeds the funds transferred to the migrator. Floor-division dust accrues to
     *         the protocol (left in the migrator).
     */
    function migrateOut(address token, address[] calldata users) external returns (uint256[] memory amounts);

    /**
     * @notice Permissioned deposit crediting `user`. Pulls `amount` of `token` from the caller
     *         (the migrator) and credits it to `user`'s position.
     * @param token  The staked token.
     * @param user   The user to credit.
     * @param amount The principal to deposit on the user's behalf.
     */
    function depositFor(address token, address user, uint256 amount) external;
}
