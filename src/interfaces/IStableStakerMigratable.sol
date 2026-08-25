// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStableStakerMigratable
 * @notice The **golden rule** surface: the three permissioned functions that EVERY version of
 *         {StableStaker} — past, present and future — must expose so that a migrator can drain
 *         one version and credit another.
 * @dev Kept intentionally minimal so the migration orchestrators ({StableStakerMigrator},
 *      {InPlaceMigrator}) stay decoupled from the full staker implementation. All three are
 *      gated by `onlyMigrator` on the staker.
 *
 *      WHY THESE THREE, AND ONLY THESE THREE. `stable-staker` follows an *evergreen* model:
 *      `StableStaker.sol` is always the current implementation and each deploy is captured as a
 *      frozen snapshot under `src/versions/`. That model is only safe while every deployed
 *      version stays reachable by a migrator, and this triad is exactly what a version hop needs:
 *      {initiateMigration} freezes the source, {batchMigrate} drains it, {depositFor} credits the
 *      destination. Adjacent migration-path functions (`userMigrate`, `finalizeAndReset`) are
 *      deliberately EXCLUDED — they belong to a single version's own lifecycle, not to the
 *      cross-version hop. Every extra member here is a permanent obligation on all future
 *      versions, so widening this interface makes the rule harder to keep and should be resisted.
 *
 *      THE SIGNATURES ARE FROZEN. All three take `token` as their first parameter because a
 *      `StableStaker` is multi-pool: one contract, many staked tokens. A future redesign that
 *      dropped the `token` parameter (for example a one-pool-per-contract rewrite) would break
 *      the golden rule **by construction** — the new contract simply could not implement this
 *      interface, and would not be migratable from an existing deployment by the existing
 *      orchestrators. That is stated here so a later author confronts the decision deliberately
 *      rather than discovering it after the fact: changing these signatures is a decision to
 *      strand every prior version, and needs a replacement migration story before it is taken.
 *
 *      Sibling precedent: `nft-staking/src/INFTStakerMigratable.sol` is the same pattern for the
 *      ERC1155 staker, derived from this project's `IStableStaker`.
 */
interface IStableStakerMigratable {
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
}
