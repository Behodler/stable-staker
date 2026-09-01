// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPhusdStableMinter
 * @notice Minimal view of the phUSD stable minter that StableStakerV2 needs.
 * @dev StableStakerV2 touches the minter at exactly one call site, {calculateMintAmount}, reached
 *      through the two-hop read `antimatter.phUSDMinter()` -> `calculateMintAmount(token, amount)`.
 *      It is the only way to learn what the stablecoin half of an annihilation is worth in phUSD, and
 *      {StableStakerV2-autoAnnihilate} needs that figure to size the frictionless payout it now
 *      guarantees the caller.
 *
 *      Declaring the surface locally, exactly as {IAntimatter} and {IPhUSD} do, is not merely a style
 *      choice here: the concrete `PhusdStableMinter` carries two RELATIVE imports into a third level
 *      of submodule nesting (`../lib/vault/src/interfaces/IYieldStrategy.sol` and
 *      `../lib/pauser/src/interfaces/IPausable.sol`), which need not even be populated in a
 *      stable-staker checkout. Importing it into `src/` would make the production contract
 *      uncompilable without recursively initialising three levels of submodule.
 *
 *      The cost of a hand-written interface is that nothing links it to the real `PhusdStableMinter`
 *      at compile time. It is mitigated the way {IAntimatter}'s is: `test/AutoAnnihilate.t.sol`
 *      deploys the concrete minter out of `lib/antimatter` and drives the whole path through it, so
 *      ABI drift surfaces there.
 */
interface IPhusdStableMinter {
    /**
     * @notice The phUSD that would be minted for `inputAmount` of `stablecoin`.
     * @dev `(inputAmount * exchangeRate * 10 ** (18 - decimals)) / 1e18` — one truncation, at the
     *      final division, which floors in the protocol's favour. `public view`, reads its config
     *      into memory, makes no external call and no SSTORE, so it is STATICCALL-safe.
     *
     *      **A returned value is NOT a promise that the mint will succeed.** The function is
     *      deliberately permissive and consults none of the conditions `mint` enforces:
     *
     *      | Condition | {calculateMintAmount} | `mint` |
     *      |---|---|---|
     *      | Stablecoin unregistered | returns 0 | reverts `"Stablecoin not registered"` |
     *      | `enabled == false` | never read | reverts `"Stablecoin minting is paused"` |
     *      | The minter's OWN pause | never read | reverts `"Contract is paused"` |
     *      | Rolling 24h `maxMintPerDay` | never read | reverts `"Daily mint limit exceeded"` |
     *      | `decimals > 18` | reverts `Panic(0x11)` | reverts `Panic(0x11)` |
     *
     *      That is why {StableStakerV2-autoAnnihilate} uses this to compute its TARGET but derives
     *      what was actually delivered by MEASURING a phUSD balance delta — the same discipline
     *      `Antimatter.annihilate` itself applies to the minter.
     * @param stablecoin The stablecoin being deposited.
     * @param inputAmount The amount of `stablecoin`, in that token's own decimals.
     * @return The 18-decimal phUSD figure.
     */
    function calculateMintAmount(address stablecoin, uint256 inputAmount) external view returns (uint256);
}
