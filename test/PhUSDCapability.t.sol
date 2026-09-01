// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import {IPhUSD} from "../src/interfaces/IPhUSD.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {FlaxToken} from "@phUSD/FlaxToken.sol";
import {IFlax} from "@phUSD/IFlax.sol";

/// @notice Exposes the two internal-only halves of story 026's capability so they can be driven
///         before story 028 lands the consumer. Nothing here changes StableStakerV2's behaviour;
///         `exposedPhUSD` and `mintPhUSD` are literally the two lines story 028's shortfall branch
///         will contain, hoisted into a test contract so the capability is exercised end to end
///         rather than merely compiled.
contract PhUSDCapabilityHarness is StableStakerV2 {
    constructor(IAntimatter _antimatter, address initialOwner) StableStakerV2(_antimatter, initialOwner) {}

    function exposedPhUSD() external view returns (address) {
        return address(_phUSD());
    }

    function mintPhUSD(address recipient, uint256 amount) external {
        _phUSD().mint(recipient, amount);
    }
}

/// @notice Story 026: StableStakerV2 regains the CAPABILITY to mint phUSD — and nothing that
///         consumes it. Antimatter remains the sole reward token; this exists only so story 028's
///         {StableStakerV2-autoAnnihilate} rework can cover an exit shortfall out of protocol
///         inflation rather than shortchanging the annihilating user.
/// @dev Runs against the REAL FlaxToken and Antimatter from `lib/antimatter`, matching
///      AutoAnnihilate.t.sol's stated philosophy: the interesting failures — the two-condition mint
///      gate, the global `revokeAllMintPrivileges` sweep, a mutable `Antimatter.phUSD` — all live in
///      that stack, and a mock would define them away. A hand-written {IPhUSD} has no
///      compiler-enforced link to `FlaxToken`, so this suite IS the ABI-drift detector.
contract PhUSDCapabilityTest is Test {
    Antimatter internal antimatter;
    FlaxToken internal phUSD;
    PhUSDCapabilityHarness internal staker;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);

    function setUp() public {
        phUSD = new FlaxToken();
        antimatter = new Antimatter(owner);
        antimatter.setPhUSD(IFlax(address(phUSD)));

        staker = new PhUSDCapabilityHarness(IAntimatter(address(antimatter)), owner);
    }

    // ---------------------------------------------------------------- resolution

    function test_phUSDToken_readsAntimattersPhUSD() public view {
        assertEq(staker.phUSDToken(), address(phUSD), "phUSDToken should be Antimatter's phUSD");
        assertEq(address(antimatter.phUSD()), address(phUSD), "fixture wiring");
    }

    /// @dev The whole reason the read is live and the value is never cached or taken as a
    ///      constructor argument: `Antimatter.phUSD` is mutable.
    function test_phUSDToken_tracksRotationRatherThanGoingStale() public {
        FlaxToken rotated = new FlaxToken();
        antimatter.setPhUSD(IFlax(address(rotated)));

        assertEq(staker.phUSDToken(), address(rotated), "phUSDToken must follow a setPhUSD rotation");
        assertTrue(staker.phUSDToken() != address(phUSD), "a cached value would still point at the dead token");
    }

    function test_phUSDToken_isZeroWhenAntimatterHasNoPhUSD() public {
        Antimatter bare = new Antimatter(owner);
        PhUSDCapabilityHarness unwired = new PhUSDCapabilityHarness(IAntimatter(address(bare)), owner);

        assertEq(unwired.phUSDToken(), address(0), "observable view reports the absence rather than reverting");
    }

    /// @dev The mint path fails CLOSED where the observable view merely reports zero.
    function test_internalResolver_revertsWhenAntimatterHasNoPhUSD() public {
        Antimatter bare = new Antimatter(owner);
        PhUSDCapabilityHarness unwired = new PhUSDCapabilityHarness(IAntimatter(address(bare)), owner);

        vm.expectRevert("StableStaker: phUSD unset on antimatter");
        unwired.exposedPhUSD();

        vm.expectRevert("StableStaker: phUSD unset on antimatter");
        unwired.mintPhUSD(alice, 1 ether);
    }

    function test_internalResolver_returnsTheLiveToken() public view {
        assertEq(staker.exposedPhUSD(), address(phUSD), "resolver and observable view must agree");
    }

    // ---------------------------------------------------------------- the mint gate

    function test_cannotMintBeforeTheGrant() public {
        assertFalse(staker.phUSDMintAvailable(), "probe must report unavailable before the grant");

        vm.expectRevert("phUSD: caller is not authorized to mint");
        staker.mintPhUSD(alice, 1 ether);
    }

    function test_canMintOnceGranted() public {
        phUSD.setMinter(address(staker), true);
        assertTrue(staker.phUSDMintAvailable(), "probe must report available after the grant");

        staker.mintPhUSD(alice, 7 ether);

        assertEq(phUSD.balanceOf(alice), 7 ether, "the shortfall top-up lands in the user's wallet");
        assertEq(phUSD.totalSupply(), 7 ether, "and it is fresh inflation, not a transfer");
    }

    function test_cannotMintAfterAnExplicitRevocation() public {
        phUSD.setMinter(address(staker), true);
        phUSD.setMinter(address(staker), false);

        assertFalse(staker.phUSDMintAvailable(), "probe follows an explicit revocation");
        vm.expectRevert("phUSD: caller is not authorized to mint");
        staker.mintPhUSD(alice, 1 ether);
    }

    /// @dev The case a naive `canMint`-only probe misses. `revokeAllMintPrivileges` bumps a GLOBAL
    ///      counter and de-authorises every minter at once; the staker's own `canMint` flag is left
    ///      set, so the record still reads as authorised while `mint` reverts.
    function test_cannotMintAfterGlobalRevocation_andProbeKnowsIt() public {
        phUSD.setMinter(address(staker), true);
        assertTrue(staker.phUSDMintAvailable(), "granted");

        phUSD.revokeAllMintPrivileges();

        // The stale half of the record is still set — this is exactly the false positive.
        assertTrue(phUSD.authorizedMinters(address(staker)).canMint, "canMint alone still reads true");
        assertTrue(
            phUSD.authorizedMinters(address(staker)).mintVersion != phUSD.mintVersion(),
            "but the version recorded at the grant is now stale"
        );

        assertFalse(staker.phUSDMintAvailable(), "the two-condition probe must report unavailable");
        vm.expectRevert("phUSD: minter version is outdated");
        staker.mintPhUSD(alice, 1 ether);
    }

    /// @dev And a re-grant at the new version restores both the probe and the mint.
    function test_regrantAfterGlobalRevocationRestoresTheCapability() public {
        phUSD.setMinter(address(staker), true);
        phUSD.revokeAllMintPrivileges();
        assertFalse(staker.phUSDMintAvailable(), "swept away");

        phUSD.setMinter(address(staker), true);

        assertTrue(staker.phUSDMintAvailable(), "re-granted at the current version");
        staker.mintPhUSD(alice, 3 ether);
        assertEq(phUSD.balanceOf(alice), 3 ether);
    }

    // ---------------------------------------------------------------- probe robustness

    function test_probeReportsUnavailableWhenAntimatterHasNoPhUSD() public {
        Antimatter bare = new Antimatter(owner);
        PhUSDCapabilityHarness unwired = new PhUSDCapabilityHarness(IAntimatter(address(bare)), owner);

        assertFalse(unwired.phUSDMintAvailable(), "no token, no mint, and no revert out of a view");
    }

    /// @dev A rotation moves the grant along with the token: rights on the OLD phUSD say nothing
    ///      about the new one.
    function test_probeFollowsRotationRatherThanTheOldGrant() public {
        phUSD.setMinter(address(staker), true);
        assertTrue(staker.phUSDMintAvailable());

        FlaxToken rotated = new FlaxToken();
        antimatter.setPhUSD(IFlax(address(rotated)));

        assertFalse(staker.phUSDMintAvailable(), "the grant did not travel with the rotation");
        vm.expectRevert("phUSD: caller is not authorized to mint");
        staker.mintPhUSD(alice, 1 ether);

        rotated.setMinter(address(staker), true);
        assertTrue(staker.phUSDMintAvailable(), "granted on the new token");
        staker.mintPhUSD(alice, 1 ether);
        assertEq(rotated.balanceOf(alice), 1 ether);
        assertEq(phUSD.balanceOf(alice), 0, "and nothing was minted on the retired token");
    }

    // ---------------------------------------------------------------- the emissions pivot stands

    /// @dev Guards the story's central claim: this is a capability, not a reward-token change.
    ///      Antimatter is still what a staker earns, and the staker mints no phUSD on its own.
    function test_capabilityMintsNothingOnItsOwn() public {
        phUSD.setMinter(address(staker), true);
        assertEq(phUSD.totalSupply(), 0, "granting rights mints nothing");
        assertEq(staker.STAKER_VERSION(), 2, "no snapshot ritual: adding external functions is not a deploy");
    }
}
