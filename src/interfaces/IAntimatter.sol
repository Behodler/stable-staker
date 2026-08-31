// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAntimatter
 * @notice Minimal view of the Antimatter emissions token that StableStakerV2 needs.
 * @dev StableStakerV2 touches Antimatter at exactly two call sites, both `mint`. Declaring the
 *      surface locally keeps `src/` free of the antimatter repo's transitive phUSD, phUSD-minter
 *      and pauser imports; the concrete `Antimatter` is deployed only in tests, against the
 *      `lib/antimatter` submodule.
 *
 *      Minting is gated by Antimatter's owner-managed approved-minter whitelist
 *      (`setApprovedMinter(address,bool)`); a non-approved caller reverts with the custom error
 *      `NotApprovedMinter(address)`.
 */
interface IAntimatter {
    /// @notice Mint `amount` of Antimatter to `to`. Caller must be the owner or an approved minter.
    function mint(address to, uint256 amount) external;
}
