// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IStableStakerMigratable.sol";

/**
 * @title IStableStaker
 * @notice Minimal surface of {StableStaker} that the migration orchestrators depend on: the
 *         three golden-rule functions inherited from {IStableStakerMigratable}
 *         (`initiateMigration`, `batchMigrate`, `depositFor`) plus the read-only `userInfo`
 *         auto-getter declared here.
 * @dev Kept intentionally small so the migrators are decoupled from the full staker
 *      implementation. Both {StableStakerMigrator} and {InPlaceMigrator} consume this
 *      interface; `userInfo` exists for the latter, which must snapshot a user's credited
 *      principal around a {depositFor} to compute a re-injection top-up.
 *
 *      The three permissioned functions (`onlyMigrator` on the staker) live in
 *      {IStableStakerMigratable}, the perpetual cross-version contract every `StableStaker`
 *      version must satisfy. `userInfo` is kept OUT of that triad on purpose: it is a
 *      convenience read for the in-place path, not part of the version hop. {StableStaker}
 *      declares `is IStableStaker`, so the whole member set is compiler-enforced.
 */
interface IStableStaker is IStableStakerMigratable {
    /**
     * @notice Read-only auto-getter for the staker's public `userInfo` mapping. Returns `user`'s
     *         currently-credited position for `token`. Used by the migrator to snapshot the credited
     *         principal before/after a {depositFor} so it can compute and fund a re-injection top-up.
     * @dev Matches the {StableStaker} public mapping's auto-getter, which carries `override` to
     *      satisfy this declaration.
     * @param token The staked token.
     * @param user  The user whose position to read.
     * @return amount     The user's credited principal.
     * @return rewardDebt The user's reward-debt bookkeeping value.
     */
    function userInfo(address token, address user) external view returns (uint256 amount, uint256 rewardDebt);
}
