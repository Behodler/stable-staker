// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAntimatter
 * @notice Minimal view of the Antimatter emissions token that StableStakerV2 needs.
 * @dev StableStakerV2 touches Antimatter at four call sites: `mint` (claim, the terminal-migration
 *      exit, and both halves of {StableStakerV2-autoAnnihilate}), `annihilate` and `toStableAmount`.
 *      Declaring the surface locally keeps `src/` free of the antimatter repo's transitive phUSD,
 *      phUSD-minter and pauser imports; the concrete `Antimatter` is deployed only in tests, against
 *      the `lib/antimatter` submodule.
 *
 *      Minting is gated by Antimatter's owner-managed approved-minter whitelist
 *      (`setApprovedMinter(address,bool)`); a non-approved caller reverts with the custom error
 *      `NotApprovedMinter(address)`.
 */
interface IAntimatter {
    /// @notice Mint `amount` of Antimatter to `to`. Caller must be the owner or an approved minter.
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burn `amount` of the CALLER's antimatter against `toStableAmount(stable, amount)` of
     *         `stable` pulled from the CALLER, minting the combined phUSD to `recipient`.
     * @dev Two consequences drive {StableStakerV2-autoAnnihilate}: the antimatter must be minted to
     *      the staker itself (there is no allowance path — `annihilate` burns `msg.sender`'s own
     *      balance), and the staker must approve Antimatter for the stable half before calling.
     *      `recipient` is only ever credited, so passing the user delivers the phUSD directly.
     *
     *      This is the only `whenNotPaused` function on Antimatter, guarded by Antimatter's OWN
     *      Phoenix pauser, which StableStaker does not control. See the two-pause note in CLAUDE.md.
     * @param stable A stablecoin registered with the phUSD stable minter.
     * @param recipient The address that receives the phUSD. Never debited.
     * @param amount 18-decimal antimatter to burn. Must be representable in `stable`'s decimals.
     * @param minPhUSDOut The least phUSD the caller will accept across BOTH halves. Zero waives it.
     */
    function annihilate(address stable, address recipient, uint256 amount, uint256 minPhUSDOut) external;

    /**
     * @notice The quantity of `stable` that pairs with `amount` 18-decimal antimatter.
     * @dev Reverts `StablecoinNotRegistered(stable)` unless `stable` is registered with the phUSD
     *      stable minter, `AmountNotRepresentable(amount, decimals)` when `amount` is finer than the
     *      stablecoin can express, and `DecimalsMismatch`/`DecimalsUnavailable` on a misregistration.
     *      StableStakerV2 uses it only as a pre-flight probe ({StableStakerV2-autoAnnihilateAvailable});
     *      the scaling itself is done locally against the token's own `decimals()`.
     */
    function toStableAmount(address stable, uint256 amount) external view returns (uint256);
}
