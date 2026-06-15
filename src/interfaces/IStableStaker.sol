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
     * @notice Engage terminal migration for `token`: realize the entire strategy position once and
     *         snapshot (R, P) so all subsequent exits pay a fixed, order-independent pro-rata credit.
     *         Must be called exactly once before any {batchMigrate}. Terminal — there is no resume path.
     * @dev Permissioned (`onlyMigrator` on the staker). Reverts if `token` is already migrating.
     * @param token The staked token to put into terminal migration.
     */
    function initiateMigration(address token) external;

    /**
     * @notice Permissioned, batched terminal-migration exit (replaces the legacy `migrateOut`).
     *         For each user: mints their frozen pending phUSD, zeroes their position and removes them
     *         from the staker set. The aggregate snapshot credit is transferred to the caller (the
     *         migrator). Requires a prior {initiateMigration}.
     * @param token  The staked token whose positions are being migrated out.
     * @param users  The users to migrate.
     * @return amounts Per-user snapshot-consistent realized credit `p_i·min(R,P)/P`, parallel to `users`
     *         (0 for empty / already self-migrated positions). At or above par these equal each user's
     *         principal; below par every user takes the SAME uniform haircut, independent of batch
     *         composition or ordering. Σ amounts ≤ R, so the migrator's redeposits can never exceed the
     *         funds it received. Floor-division dust accrues to the protocol (left in the old staker).
     */
    function batchMigrate(address token, address[] calldata users) external returns (uint256[] memory amounts);

    /**
     * @notice Permissioned deposit crediting `user`. Pulls `amount` of `token` from the caller
     *         (the migrator) and credits it to `user`'s position.
     * @param token  The staked token.
     * @param user   The user to credit.
     * @param amount The principal to deposit on the user's behalf.
     */
    function depositFor(address token, address user, uint256 amount) external;

    /**
     * @notice Read-only auto-getter for the staker's public `userInfo` mapping. Returns `user`'s
     *         currently-credited position for `token`. Used by the migrator to snapshot the credited
     *         principal before/after a {depositFor} so it can compute and fund a re-injection top-up.
     * @dev Interface-only declaration matching the StableStaker public mapping's auto-getter; this is
     *      NOT a change to StableStaker.sol.
     * @param token The staked token.
     * @param user  The user whose position to read.
     * @return amount     The user's credited principal.
     * @return rewardDebt The user's reward-debt bookkeeping value.
     */
    function userInfo(address token, address user) external view returns (uint256 amount, uint256 rewardDebt);
}
