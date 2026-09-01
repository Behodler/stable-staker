// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPhUSD
 * @notice Minimal view of the phUSD token (flax-token-v2 `FlaxToken`) that StableStakerV2 needs.
 * @dev StableStakerV2 touches phUSD at exactly three call sites, all of them reached through
 *      {StableStakerV2-phUSDToken} / {StableStakerV2-phUSDMintAvailable}: `mint` (the
 *      {StableStakerV2-autoAnnihilate} shortfall top-up), and `mintVersion` + `authorizedMinters`
 *      together, which form the two-condition probe that says whether that mint can succeed.
 *
 *      **This is not a reversal of the emissions pivot.** Antimatter remains the sole reward token
 *      for claims, withdrawals, deposits, APY accounting and migration. phUSD minting exists solely
 *      so that an under-delivering yield-strategy exit does not shortchange the annihilating user —
 *      the protocol absorbs the exit haircut as phUSD inflation instead.
 *
 *      Declaring the surface locally, exactly as {IAntimatter} does, keeps `src/` free of the
 *      antimatter repo's transitive imports: the phUSD remapping resolves through the NESTED submodule
 *      `lib/antimatter/lib/flax-token-v2`, so importing `IFlax` into `src/` would force every
 *      consumer of stable-staker-as-a-submodule to recursively init two levels merely to compile
 *      the production contract. The other reachable phUSD type, `flax-token/`, points inside the
 *      FROZEN `src/versions/v1/` tree, whose removal is the defined act of retiring V1; an
 *      evergreen-contract import would make that retirement impossible. `IFlax` is also `IERC20`
 *      with twelve functions, two events and a struct, where this contract needs three calls.
 *
 *      The cost of a hand-written interface is that nothing links it to the real `FlaxToken` at
 *      compile time. It is mitigated the way {IAntimatter}'s is: the tests deploy the concrete
 *      `FlaxToken` out of the antimatter submodule and drive it through this interface, so ABI drift surfaces there.
 */
interface IPhUSD {
    /**
     * @notice A minter's authorisation record.
     * @dev Layout must match `IFlax.MinterInfo` exactly — `{ bool canMint; uint256 mintVersion; }`.
     * @param canMint Whether the minter was ever granted rights.
     * @param mintVersion The global mint version in force when the grant was made.
     */
    struct MinterInfo {
        bool canMint;
        uint256 mintVersion;
    }

    /**
     * @notice Mint `amount` of phUSD to `recipient`.
     * @dev Reverts `"phUSD: caller is not authorized to mint"` when the caller was never granted
     *      minter rights, and `"phUSD: minter version is outdated"` when a grant that WAS made has
     *      since been invalidated by a global `revokeAllMintPrivileges()`. A consumer must treat
     *      both as live possibilities — see {authorizedMinters}.
     */
    function mint(address recipient, uint256 amount) external;

    /**
     * @notice The global mint version. Incremented by phUSD's owner calling
     *         `revokeAllMintPrivileges()`, which silently de-authorises EVERY minter at once.
     * @dev This is the reason a `canMint` check alone is not a sufficient probe: a staker granted
     *      rights months ago can lose them with no per-minter transaction ever being sent.
     */
    function mintVersion() external view returns (uint256);

    /**
     * @notice The authorisation record for `minter`.
     * @dev Authorised to mint iff `canMint` AND `mintVersion == `{mintVersion}`. Both conditions are
     *      checked inside `mint`, so a probe that checks only the first reports a false positive
     *      after a global revocation.
     */
    function authorizedMinters(address minter) external view returns (MinterInfo memory);
}
