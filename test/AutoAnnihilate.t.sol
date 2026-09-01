// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {FlaxToken} from "@phUSD/FlaxToken.sol";
import {IFlax} from "@phUSD/IFlax.sol";
import {PhusdStableMinter} from "@phUSDMinter/PhusdStableMinter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import {MockMinterYieldStrategy} from "./mocks/MockMinterYieldStrategy.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {ERC4626YieldStrategy} from "reflax-yield-vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";

/// @notice Story 025: `claim` is owner-gated and off by default, and {StableStakerV2-autoAnnihilate}
///         becomes the reward path. It mints the caller's owed Antimatter to the staker itself,
///         annihilates it against a slice of the caller's OWN booked principal, and the phUSD lands
///         in the caller's wallet. The staked position shrinks by exactly the annihilated stable half.
/// @dev Runs against the REAL Antimatter / FlaxToken / PhusdStableMinter stack from `lib/antimatter`,
///      because the interesting failures (decimals representability, StablecoinNotRegistered, the
///      antimatter-side pause) all live in that stack and a mock would define them away.
contract AutoAnnihilateTest is Test {
    Antimatter internal antimatter;
    FlaxToken internal phUSD;
    PhusdStableMinter internal minter;
    MockMinterYieldStrategy internal minterYS;
    StableStakerV2 internal staker;

    MockERC20 internal usdc; // 6 decimals, registered with the minter
    MockERC20 internal dai; // 18 decimals, registered with the minter
    MockERC20 internal orphan; // 18 decimals, a staker pool token the minter does NOT know

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant PER_DAY = 86_400 ether; // -> 1e18 antimatter per second

    /// @dev A generous ceiling on "rounding-scale" for the 18-decimal DAI fixture, in phUSD wei.
    ///      The real shortfall a double round-down produces is a couple of wei; anything approaching
    ///      a haircut would blow past this by many orders of magnitude.
    uint256 internal constant ROUNDING_SCALE_CEILING = 1e6;

    /// @dev Mirrors {StableStakerV2.AutoAnnihilated} for vm.expectEmit. Story 028 added the two
    ///      phUSD figures: the total paid to the caller, and the part of it the protocol freshly
    ///      minted to cover the exit shortfall.
    event AutoAnnihilated(
        address indexed token,
        address indexed user,
        uint256 antimatterBurned,
        uint256 principalConsumed,
        uint256 excessMinted,
        uint256 phUSDPaid,
        uint256 phUSDMinted
    );

    function setUp() public {
        phUSD = new FlaxToken();
        minterYS = new MockMinterYieldStrategy();
        minter = new PhusdStableMinter(address(phUSD));
        antimatter = new Antimatter(owner);

        // phUSD authorises both the stable minter and antimatter to mint it.
        phUSD.setMinter(address(minter), true);
        phUSD.setMinter(address(antimatter), true);

        antimatter.setPhUSD(IFlax(address(phUSD)));
        antimatter.setPhUSDMinter(minter);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        orphan = new MockERC20("Orphan", "ORP", 18);

        minter.registerStablecoin(address(usdc), address(minterYS), 1e18, 6);
        minter.approveYS(address(usdc), address(minterYS));
        minter.registerStablecoin(address(dai), address(minterYS), 1e18, 18);
        minter.approveYS(address(dai), address(minterYS));

        staker = new StableStakerV2(IAntimatter(address(antimatter)), owner);
        antimatter.setApprovedMinter(address(staker), true);
        // Story 026: the staker may mint phUSD, solely to cover an under-delivering exit in
        // {StableStakerV2-autoAnnihilate}. Antimatter remains the reward token; nothing consumes
        // this grant until story 028.
        phUSD.setMinter(address(staker), true);

        staker.addToken(address(usdc));
        staker.addToken(address(dai));
        staker.addToken(address(orphan));
        staker.antimatterPerDay(address(usdc), PER_DAY);
        staker.antimatterPerDay(address(dai), PER_DAY);
        staker.antimatterPerDay(address(orphan), PER_DAY);

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000e6);
        dai.mint(who, 1_000_000 ether);
        orphan.mint(who, 1_000_000 ether);
        vm.startPrank(who);
        usdc.approve(address(staker), type(uint256).max);
        dai.approve(address(staker), type(uint256).max);
        orphan.approve(address(staker), type(uint256).max);
        vm.stopPrank();
    }

    function _stake(address who, address token, uint256 amount) internal {
        vm.prank(who);
        staker.stake(token, amount);
    }

    function _autoAnnihilate(address who, address token) internal {
        vm.prank(who);
        staker.autoAnnihilate(token);
    }

    /// @dev The same call, returning the two phUSD figures off the emitted event. `phUSDMinted` is
    ///      the protocol's inflation for this call and is not observable any other way — the staker
    ///      never holds a phUSD balance across the call, and the token's total supply also moves for
    ///      the two halves Antimatter mints.
    function _autoAnnihilateCapture(address who, address token)
        internal
        returns (uint256 phUSDPaid, uint256 phUSDMinted)
    {
        vm.recordLogs();
        vm.prank(who);
        staker.autoAnnihilate(token);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("AutoAnnihilated(address,address,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(staker) && logs[i].topics[0] == sig) {
                (,,, phUSDPaid, phUSDMinted) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                return (phUSDPaid, phUSDMinted);
            }
        }
        revert("no AutoAnnihilated event");
    }

    /// @dev What a FRICTIONLESS annihilation of `net` raw units of `token` pays: the antimatter half
    ///      plus the stable half priced by the minter. Computed, never assumed to be `2 * net` — that
    ///      identity holds only while the exchange rate is exactly 1e18.
    function _target(address token, uint256 net) internal view returns (uint256) {
        uint256 scale = 10 ** (18 - uint256(MockERC20(token).decimals()));
        return net * scale + minter.calculateMintAmount(token, net);
    }

    function _userAmount(address token, address who) internal view returns (uint256 amount) {
        (amount,) = staker.userInfo(token, who);
    }

    function _rewardDebt(address token, address who) internal view returns (uint256 debt) {
        (, debt) = staker.userInfo(token, who);
    }

    function _totalStaked(address token) internal view returns (uint256) {
        (,,, uint256 totalStaked) = staker.poolInfo(token);
        return totalStaked;
    }

    // ------------------------------------------------------------ happy paths

    function test_autoAnnihilate_18decStable_happyPath() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);

        // Sole staker at 1e18/sec for 50s.
        assertEq(staker.claimableReward(address(dai), alice), 50 ether, "precondition: owed");

        vm.expectEmit(true, true, false, true, address(staker));
        emit AutoAnnihilated(address(dai), alice, 50 ether, 50 ether, 0, 100 ether, 0);
        _autoAnnihilate(alice, address(dai));

        // 50 antimatter burned against 50 DAI of the caller's own principal.
        assertEq(_userAmount(address(dai), alice), 50 ether, "principal reduced by the stable half");
        assertEq(_totalStaked(address(dai)), 50 ether, "totalStaked in lockstep");
        assertEq(staker.unclaimedReward(address(dai), alice), 0, "backlog drained");
        assertEq(antimatter.balanceOf(alice), 0, "no raw antimatter reaches the user");
        assertEq(antimatter.balanceOf(address(staker)), 0, "no antimatter left on the staker");
        // Both halves land as phUSD: the antimatter half 1:1, the stable half via the minter.
        assertEq(phUSD.balanceOf(alice), 100 ether, "phUSD = antimatter half + stable half");
        assertEq(dai.balanceOf(address(minterYS)), 50 ether, "stable half custodied by the minter");
    }

    function test_autoAnnihilate_6decStable_floorsToRepresentable_andCarriesDust() public {
        // 1e12 + 1 antimatter per second, so `owed` is NOT a multiple of USDC's 1e12 scale.
        staker.antimatterPerDay(address(usdc), 86_400 * (1e12 + 1));
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 50);

        uint256 owed = staker.claimableReward(address(usdc), alice);
        assertEq(owed, 50 * (1e12 + 1), "precondition: non-representable owed");

        _autoAnnihilate(alice, address(usdc));

        uint256 annihilated = 50 * 1e12; // floored down to a multiple of 1e12
        assertEq(_userAmount(address(usdc), alice), 100e6 - 50, "principal reduced by 50 raw units");
        assertEq(_totalStaked(address(usdc)), 100e6 - 50, "totalStaked in lockstep");
        assertEq(staker.unclaimedReward(address(usdc), alice), 50, "sub-unit dust carried forward");
        assertEq(antimatter.balanceOf(alice), 0, "dust is not minted to the user");
        assertEq(phUSD.balanceOf(alice), 2 * annihilated, "both halves paid on the floored amount");
    }

    function test_autoAnnihilate_carriedDust_accruesToTheNextCall() public {
        staker.antimatterPerDay(address(usdc), 86_400 * (1e12 + 1));
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 50);
        _autoAnnihilate(alice, address(usdc));
        assertEq(staker.unclaimedReward(address(usdc), alice), 50, "precondition: dust booked");

        // The carried dust is part of the next call's `owed`, not a separate stranded balance.
        vm.warp(block.timestamp + 50);
        uint256 owed = staker.claimableReward(address(usdc), alice);
        assertGt(owed, 50 * (1e12 + 1), "dust is included in the next owed figure");
    }

    // ------------------------------------------------- reward outruns principal

    function test_autoAnnihilate_excessOverPrincipal_isMintedToTheUser() public {
        // 1 USDC of principal == 1e18 antimatter; 5 seconds accrues 5e18.
        _stake(alice, address(usdc), 1e6);
        vm.warp(block.timestamp + 5);
        assertEq(staker.claimableReward(address(usdc), alice), 5 ether, "precondition");

        vm.expectEmit(true, true, false, true, address(staker));
        emit AutoAnnihilated(address(usdc), alice, 1 ether, 1e6, 4 ether, 2 ether, 0);
        _autoAnnihilate(alice, address(usdc));

        assertEq(_userAmount(address(usdc), alice), 0, "whole position annihilated");
        assertEq(_totalStaked(address(usdc)), 0, "totalStaked in lockstep");
        assertEq(antimatter.balanceOf(alice), 4 ether, "excess minted straight to the user");
        assertEq(phUSD.balanceOf(alice), 2 ether, "annihilated half paid in phUSD");
        assertEq(staker.unclaimedReward(address(usdc), alice), 0, "nothing left booked");
    }

    function test_autoAnnihilate_zeroingPosition_removesStakerFromTheSet() public {
        _stake(alice, address(usdc), 1e6);
        _stake(bob, address(usdc), 1e6);
        vm.warp(block.timestamp + 100);

        _autoAnnihilate(alice, address(usdc));

        assertEq(_userAmount(address(usdc), alice), 0, "position emptied");
        assertEq(staker.stakerCount(address(usdc)), 1, "alice removed from the staker set");
        address[] memory stakers = staker.getStakers(address(usdc));
        assertEq(stakers[0], bob, "only bob remains");
    }

    function test_autoAnnihilate_partialPosition_keepsStakerInTheSet() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        _autoAnnihilate(alice, address(dai));
        assertEq(staker.stakerCount(address(dai)), 1, "still a staker");
    }

    // -------------------------------------------------------- rewardDebt rebase

    function test_autoAnnihilate_rebasesRewardDebt_soLaterSettlesDoNotUnderflow() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        _autoAnnihilate(alice, address(dai));

        // rewardDebt must be re-based against the NEW smaller amount, or every later settle
        // underflows and the position is permanently bricked.
        (uint256 amount, uint256 debt) = staker.userInfo(address(dai), alice);
        assertEq(amount, 50 ether, "precondition: halved principal");
        (, uint256 acc,,) = staker.poolInfo(address(dai));
        assertEq(debt, (amount * acc) / staker.ACC_PRECISION(), "rewardDebt re-based");
        assertEq(staker.pendingReward(address(dai), alice), 0, "no phantom pending");

        // A subsequent settle path must work rather than revert.
        vm.warp(block.timestamp + 10);
        assertEq(staker.pendingReward(address(dai), alice), 10 ether, "accrual resumes cleanly");
        _stake(alice, address(dai), 1 ether);
        assertEq(staker.unclaimedReward(address(dai), alice), 10 ether, "settled, not underflowed");
    }

    function test_autoAnnihilate_twiceInARow_isConsistent() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 10);
        _autoAnnihilate(alice, address(dai));
        assertEq(_userAmount(address(dai), alice), 90 ether, "first pass");
        vm.warp(block.timestamp + 10);
        _autoAnnihilate(alice, address(dai));
        // The second pass accrues against a 90-DAI position, so per-share division loses a few wei
        // (always DOWN, as the emission-cap invariant requires) and the consumed principal is a
        // hair under 10 ether. The exactness that matters is the lockstep, asserted below.
        assertApproxEqAbs(_userAmount(address(dai), alice), 80 ether, 1e4, "second pass");
        assertEq(_totalStaked(address(dai)), _userAmount(address(dai), alice), "totalStaked in lockstep");
    }

    // ------------------------------------------------------------------ guards

    function test_autoAnnihilate_revertsWhenNothingOwed() public {
        _stake(alice, address(dai), 100 ether);
        vm.expectRevert("StableStaker: nothing to annihilate");
        _autoAnnihilate(alice, address(dai));
    }

    function test_autoAnnihilate_revertsWhenPoolNotActive() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        staker.setMigrator(owner);
        staker.initiateMigration(address(dai));

        vm.expectRevert("StableStaker: pool not active");
        _autoAnnihilate(alice, address(dai));
    }

    function test_autoAnnihilate_revertsWhenPaused() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        staker.setPauser(owner);
        staker.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _autoAnnihilate(alice, address(dai));
    }

    function test_autoAnnihilate_revertsOnUnknownToken() public {
        vm.expectRevert("StableStaker: unknown token");
        _autoAnnihilate(alice, address(0xDEAD));
    }

    function test_autoAnnihilate_unregisteredStable_revertsWithAnExplicitMessage() public {
        _stake(alice, address(orphan), 100 ether);
        vm.warp(block.timestamp + 50);

        // NOT a bare `StablecoinNotRegistered(address)` bubbling up from Antimatter: the UI must be
        // able to tell "this pool token cannot be annihilated" from "you have nothing to annihilate".
        vm.expectRevert("StableStaker: token not annihilatable");
        _autoAnnihilate(alice, address(orphan));
    }

    function test_autoAnnihilateAvailable_distinguishesRegisteredStables() public view {
        assertTrue(staker.autoAnnihilateAvailable(address(usdc)), "usdc registered");
        assertTrue(staker.autoAnnihilateAvailable(address(dai)), "dai registered");
        assertFalse(staker.autoAnnihilateAvailable(address(orphan)), "orphan not registered");
    }

    /// @dev `minPhUSDOut` left the external ABI in story 028: the caller gains nothing from a floor
    ///      on a payout StableStaker itself guarantees. It is NOT dropped to zero — an exact floor,
    ///      sized against the amount actually being annihilated, is still handed to Antimatter, and it
    ///      is the only in-path guard against the exchange rate moving or a mint cap biting between
    ///      the quote and the burn. Asserted here by proving the payout meets the computed target
    ///      exactly, which is what the internal floor demands of Antimatter.
    function test_autoAnnihilate_internalMinPhUSDOut_isMetExactly() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        _autoAnnihilate(alice, address(dai));
        assertEq(phUSD.balanceOf(alice), _target(address(dai), 50 ether), "paid exactly the target");
    }

    function test_autoAnnihilate_revertsWhileAntimatterIsPaused() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        antimatter.setPauser(owner);
        antimatter.pause();

        // The two-pause deadlock: the operational answer is `setClaimEnabled(true)`, not a code path.
        vm.expectRevert();
        _autoAnnihilate(alice, address(dai));

        staker.setClaimEnabled(true);
        vm.prank(alice);
        staker.claim(address(dai));
        assertEq(antimatter.balanceOf(alice), 50 ether, "claim is the documented escape");
    }

    // ------------------------------------------------------- with a yield strategy

    function test_autoAnnihilate_sourcesStableFromTheYieldStrategy() public {
        MockYieldStrategy ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        staker.setYieldStrategy(address(dai), ys);

        _stake(alice, address(dai), 100 ether);
        assertEq(dai.balanceOf(address(staker)), 0, "principal lives in the strategy");
        vm.warp(block.timestamp + 50);

        _autoAnnihilate(alice, address(dai));

        assertEq(_userAmount(address(dai), alice), 50 ether, "principal reduced");
        assertEq(ys.principalOf(address(dai), address(staker)), 50 ether, "strategy principal follows");
        assertEq(dai.balanceOf(address(minterYS)), 50 ether, "the stable half reached the minter");
        assertEq(phUSD.balanceOf(alice), 100 ether, "user paid in phUSD");
    }

    function test_autoAnnihilate_underwaterStrategy_paysFromTheBuffer() public {
        MockYieldStrategy ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        staker.setYieldStrategy(address(dai), ys);

        _stake(alice, address(dai), 100 ether);
        // Buffer the staker so the underwater path can be satisfied without touching the strategy.
        dai.mint(address(staker), 100 ether);
        ys.setValueFactorBps(9_000); // below par
        vm.warp(block.timestamp + 50);

        _autoAnnihilate(alice, address(dai));

        assertEq(_userAmount(address(dai), alice), 50 ether, "principal reduced");
        // The buffer path writes the principal down on the strategy so principalOf tracks totalStaked.
        assertEq(ys.principalOf(address(dai), address(staker)), 50 ether, "relinquishPrincipal called");
        assertEq(dai.balanceOf(address(staker)), 50 ether, "half the buffer consumed");
        assertEq(phUSD.balanceOf(alice), 100 ether, "user paid in phUSD");
    }

    // ------------------------------------------------------------- no approval residue

    function test_autoAnnihilate_leavesNoStandingApproval() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        _autoAnnihilate(alice, address(dai));
        assertEq(dai.allowance(address(staker), address(antimatter)), 0, "approval reset to zero");
    }

    // ==================================================================================
    // Exit shortfall: measured, then COVERED by the protocol in freshly minted phUSD.
    //
    // Round 1 requested exactly the NET stable the annihilation needed and discarded
    // `_routeExit`'s return value, so a strategy that sells into an AMM on exit silently
    // covered its own shortfall out of the shared underwater-withdrawal buffer. What
    // replaces it is not a quote but a measurement: the request is debited, the real
    // balance delta is measured, and only what ARRIVED is ever approved and annihilated.
    // The buffer is therefore untouchable by construction rather than by a floor check.
    //
    // Story 028 then pays the caller what a FRICTIONLESS annihilation would have paid,
    // minting the difference as new phUSD. Two properties are asserted throughout:
    //   * the caller's payout equals the computed target and never exceeds it, and
    //   * the idle buffer is untouched, because the top-up is new supply and not a draw
    //     on any pooled asset. No other staker's position moves.
    // ==================================================================================

    /// @dev A strategy for DAI that sells on exit: principal is debited by the full request,
    ///      only `request * (10000 - bps) / 10000` is delivered.
    function _haircutStrategy(uint256 bps) internal returns (MockYieldStrategy ys) {
        ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        ys.setExitSlippageBps(bps);
        staker.setYieldStrategy(address(dai), ys);
    }

    function test_autoAnnihilate_fullCreditStrategy_isUnchangedAndLeavesTheBufferAlone() public {
        _haircutStrategy(0);
        _stake(alice, address(dai), 100 ether);
        dai.mint(address(staker), 25 ether); // idle buffer: shared, and none of this call's business
        vm.warp(block.timestamp + 50);

        // Byte-for-byte the round-1 figures: nothing is displaced when the exit delivers in full.
        vm.expectEmit(true, true, false, true, address(staker));
        emit AutoAnnihilated(address(dai), alice, 50 ether, 50 ether, 0, 100 ether, 0);
        _autoAnnihilate(alice, address(dai));

        assertEq(_userAmount(address(dai), alice), 50 ether, "principal reduced by the net");
        assertEq(_totalStaked(address(dai)), 50 ether, "totalStaked in lockstep");
        assertEq(phUSD.balanceOf(alice), 100 ether, "both halves paid");
        assertEq(antimatter.balanceOf(alice), 0, "nothing minted raw");
        assertEq(dai.balanceOf(address(staker)), 25 ether, "idle buffer untouched");
    }

    function test_autoAnnihilate_wholePositionAgainstAHaircut_doesNotUnderflow() public {
        _haircutStrategy(200);
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 100);
        assertEq(staker.claimableReward(address(dai), alice), 100 ether, "precondition: owed == principal");

        // Withdraw 100, receive 98, annihilate 98 -> 196 phUSD delivered. The frictionless payout is
        // 200, so the protocol mints the 4 phUSD difference and the caller is made whole.
        vm.expectEmit(true, true, false, true, address(staker));
        emit AutoAnnihilated(address(dai), alice, 98 ether, 100 ether, 0, 200 ether, 4 ether);
        _autoAnnihilate(alice, address(dai));

        assertEq(_userAmount(address(dai), alice), 0, "whole position consumed, no underflow");
        assertEq(_totalStaked(address(dai)), 0, "totalStaked in lockstep");
        assertEq(staker.stakerCount(address(dai)), 0, "staker removed from the set");
        assertEq(antimatter.balanceOf(alice), 0, "no raw antimatter: the displaced value arrives as phUSD");
        assertEq(phUSD.balanceOf(alice), _target(address(dai), 100 ether), "made whole at the frictionless target");
        assertEq(dai.balanceOf(address(staker)), 0, "idle buffer untouched");
    }

    function test_autoAnnihilate_acrossSlippageTolerances_conservesTheReward() public {
        uint256[3] memory tolerances = [uint256(0), 500, 2_000];
        for (uint256 i = 0; i < tolerances.length; i++) {
            uint256 snap = vm.snapshotState();
            _haircutStrategy(tolerances[i]);
            _stake(alice, address(dai), 100 ether);
            vm.warp(block.timestamp + 100); // owed == principal: the cap binds at every tolerance

            // What the exit will actually deliver for a 100-ether request, computed from the knob
            // rather than asked of the strategy: there is no quote to ask for any more.
            uint256 net = (100 ether * (10_000 - tolerances[i])) / 10_000;

            (uint256 paid, uint256 minted) = _autoAnnihilateCapture(alice, address(dai));

            assertEq(_userAmount(address(dai), alice), 0, "debited the request");
            assertEq(_totalStaked(address(dai)), 0, "totalStaked in lockstep");
            // The payout no longer depends on the tolerance at all: that is the whole point.
            assertEq(paid, _target(address(dai), 100 ether), "paid the frictionless target");
            assertEq(phUSD.balanceOf(alice), _target(address(dai), 100 ether), "and it reached the caller");
            // The protocol's inflation is exactly the value the haircut destroyed.
            assertEq(minted, _target(address(dai), 100 ether) - _target(address(dai), net), "minted the deficit");
            assertEq(antimatter.balanceOf(alice), 0, "nothing is displaced into raw antimatter any more");
            assertEq(dai.balanceOf(address(staker)), 0, "idle buffer untouched");
            vm.revertToState(snap);
        }
    }

    /// @dev THE invariant the deleted shortfall floor existed to protect, asserted directly. The
    ///      idle stable balance is the SHARED underwater-withdrawal buffer; `autoAnnihilate` must
    ///      never spend a unit of it, whatever the exit delivers. It now holds by construction —
    ///      only the measured `netUsed` is ever approved and annihilated — so it is asserted across
    ///      the full-credit, haircut and whole-position cases against a deliberately fat buffer.
    function test_autoAnnihilate_neverDrawsOnTheIdleBuffer() public {
        uint256[3] memory tolerances = [uint256(0), 200, 5_000];
        uint256[2] memory warps = [uint256(50), 100]; // partial position, then the whole position
        for (uint256 i = 0; i < tolerances.length; i++) {
            for (uint256 j = 0; j < warps.length; j++) {
                uint256 snap = vm.snapshotState();
                _haircutStrategy(tolerances[i]);
                _stake(alice, address(dai), 100 ether);
                dai.mint(address(staker), 500 ether); // a fat buffer the shortfall must not reach
                vm.warp(block.timestamp + warps[j]);

                _autoAnnihilate(alice, address(dai));

                assertEq(dai.balanceOf(address(staker)), 500 ether, "buffer untouched");
                vm.revertToState(snap);
            }
        }
    }

    function test_autoAnnihilateAvailable_staysTrueForAWorkingStrategy() public {
        // The only surviving condition is the stable-minter registration probe, so the strategy's
        // exit behaviour — however punishing — can no longer make the call unavailable.
        // Both swaps happen while the pool is empty, which is the only time setYieldStrategy allows one.
        _haircutStrategy(10_000); // delivers nothing at all: round 2 reported false here
        assertTrue(staker.autoAnnihilateAvailable(address(dai)), "delivery is measured, never pre-judged");

        _haircutStrategy(200);
        assertTrue(staker.autoAnnihilateAvailable(address(dai)), "empty pool");
        _stake(alice, address(dai), 100 ether);
        assertTrue(staker.autoAnnihilateAvailable(address(dai)), "funded pool with a survivable haircut");

        // ...while a pool token the minter does not know still reports false.
        assertFalse(staker.autoAnnihilateAvailable(address(orphan)), "unregistered token");
    }

    // --------------------------------------- the production ERC4626 strategy (rounding)

    /// @dev Stands up the REAL `ERC4626YieldStrategy` over a real OZ ERC4626 vault, then donates
    ///      `yieldAssets` so the share price stops being 1:1. That is the configuration in which
    ///      `_disposeShares` rounds down twice (`convertToShares` floors, `redeem` floors again)
    ///      and delivers `amount - 1` or less — the case `MockYieldStrategy` cannot express,
    ///      because it always delivers its net exactly.
    function _erc4626Strategy(uint256 stakeAmount, uint256 yieldAssets) internal returns (ERC4626YieldStrategy ys) {
        MockERC4626Vault vault = new MockERC4626Vault(IERC20(address(dai)));
        ys = new ERC4626YieldStrategy(owner, address(dai), address(vault));
        ys.setClient(address(staker), true);
        staker.setYieldStrategy(address(dai), ys);

        _stake(alice, address(dai), stakeAmount);

        // Donate straight to the vault: assets rise, shares do not, so the price goes non-integral.
        dai.mint(address(this), yieldAssets);
        dai.approve(address(vault), yieldAssets);
        vault.accrue(yieldAssets);
    }

    /// @dev The property that matters and must outlive round 2: a REAL ERC4626 at a non-integral
    ///      share price does not revert. Round 2 demanded delivery within a rounding allowance of a
    ///      quoted floor; there is no floor any more, so the double round-down is simply measured.
    function test_autoAnnihilate_realERC4626Strategy_roundingDoesNotRevert() public {
        // A share price of 100 / 97 — deliberately not a whole number of asset units per share.
        _erc4626Strategy(100 ether, 97 ether);
        vm.warp(block.timestamp + 50);

        uint256 owed = staker.claimableReward(address(dai), alice);
        assertEq(owed, 50 ether, "precondition: owed");

        (, uint256 minted) = _autoAnnihilateCapture(alice, address(dai));

        assertEq(_userAmount(address(dai), alice), 100 ether - owed, "written down the request");
        assertEq(_totalStaked(address(dai)), 100 ether - owed, "totalStaked in lockstep");
        // The PROTOCOL now absorbs the rounding, in freshly minted phUSD, and the caller is paid the
        // frictionless figure. It is a handful of wei, not a haircut — the point is that the call
        // SUCCEEDS, conserves, and inflates only at rounding scale.
        assertGt(minted, 0, "the double round-down really did displace something");
        assertLe(minted, ROUNDING_SCALE_CEILING, "and it is rounding-scale, not haircut-scale");
        assertEq(antimatter.balanceOf(alice), 0, "no raw antimatter reaches the caller");
        assertEq(phUSD.balanceOf(alice), _target(address(dai), owed), "paid the frictionless target");
        assertEq(dai.balanceOf(address(staker)), 0, "idle buffer untouched");
    }

    function test_autoAnnihilate_realERC4626Strategy_wholePosition_succeeds() public {
        _erc4626Strategy(100 ether, 97 ether);
        vm.warp(block.timestamp + 100); // owed == principal: the principal cap binds

        _autoAnnihilate(alice, address(dai));

        assertEq(_userAmount(address(dai), alice), 0, "whole position consumed, no underflow");
        assertEq(_totalStaked(address(dai)), 0, "totalStaked in lockstep");
        assertEq(staker.stakerCount(address(dai)), 0, "staker removed from the set");
        assertEq(dai.balanceOf(address(staker)), 0, "idle buffer untouched");
    }

    // ==================================================================================
    // Story 028: the protocol covers the shortfall in freshly minted phUSD.
    // ==================================================================================

    /// @dev THE worked example from the story, asserted figure for figure. John has 100 A accrued
    ///      and 100 U staked, the exit loses 3%:
    ///        request 100 U -> receive 97 U -> annihilate 97 A + 97 U -> 194 phUSD delivered
    ///        frictionless would have paid 200, so the staker mints the 6 phUSD deficit
    ///        John receives 200 phUSD, is debited 100 U of principal and 100 A of accrued reward.
    function test_autoAnnihilate_workedExample_threePercentHaircut_paysTheFrictionlessFigure() public {
        _haircutStrategy(300);
        _stake(alice, address(dai), 100 ether);
        dai.mint(address(staker), 500 ether); // a fat buffer the top-up must not reach
        vm.warp(block.timestamp + 100);
        assertEq(staker.claimableReward(address(dai), alice), 100 ether, "precondition: 100 A accrued");

        vm.expectEmit(true, true, false, true, address(staker));
        emit AutoAnnihilated(address(dai), alice, 97 ether, 100 ether, 0, 200 ether, 6 ether);
        (uint256 paid, uint256 minted) = _autoAnnihilateCapture(alice, address(dai));

        assertEq(paid, 200 ether, "John receives the frictionless 200 phUSD");
        assertEq(minted, 6 ether, "the staker minted exactly the deficit");
        assertEq(phUSD.balanceOf(alice), 200 ether, "and it reached his wallet");
        assertEq(_userAmount(address(dai), alice), 0, "staked balance falls by the requested 100 U");
        assertEq(_totalStaked(address(dai)), 0, "totalStaked in lockstep");
        assertEq(staker.claimableReward(address(dai), alice), 0, "accrued A falls by the full 100");
        assertEq(staker.unclaimedReward(address(dai), alice), 0, "nothing carried");
        assertEq(antimatter.balanceOf(alice), 0, "no raw antimatter");
        assertEq(antimatter.balanceOf(address(staker)), 0, "no antimatter stranded on the staker");
        assertEq(phUSD.balanceOf(address(staker)), 0, "no phUSD stranded on the staker");
        assertEq(dai.balanceOf(address(staker)), 500 ether, "idle buffer untouched: the top-up is new supply");
    }

    /// @dev The frictionless case must be byte-identical to the pre-028 result and must mint NOTHING.
    ///      A design that inflates on every call, rather than only on a real shortfall, would still
    ///      pass the worked example above.
    function test_autoAnnihilate_zeroSlippage_mintsNoPhUSD() public {
        _haircutStrategy(0);
        _stake(alice, address(dai), 100 ether);
        dai.mint(address(staker), 25 ether);
        vm.warp(block.timestamp + 50);

        uint256 supplyBefore = phUSD.totalSupply();
        (uint256 paid, uint256 minted) = _autoAnnihilateCapture(alice, address(dai));

        assertEq(minted, 0, "a full-credit exit inflates by nothing at all");
        assertEq(paid, 100 ether, "unchanged from the pre-028 payout");
        assertEq(phUSD.balanceOf(alice), 100 ether, "unchanged from the pre-028 payout");
        assertEq(phUSD.totalSupply() - supplyBefore, 100 ether, "only the two annihilation halves were minted");
        assertEq(dai.balanceOf(address(staker)), 25 ether, "idle buffer untouched");
    }

    /// @dev The `delivered >= target` branch. `netUsed` is clamped to `netWanted` and both halves are
    ///      priced through the same {IPhusdStableMinter-calculateMintAmount}, so at a fixed exchange
    ///      rate delivery can only ever MEET the target, never beat it — the branch is defensive
    ///      rather than reachable, and no fixture here can force it (`MockYieldStrategy.withdraw`
    ///      caps its payout at the request, and the real ERC4626 strategy rounds DOWN). What must
    ///      hold, and is asserted, is that a met target mints nothing and never underflows, including
    ///      on an ABOVE-PAR strategy where the surplus value stays behind as un-redeemed yield.
    function test_autoAnnihilate_deliveryMeetsTarget_mintsNothingAndDoesNotUnderflow() public {
        MockYieldStrategy ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        staker.setYieldStrategy(address(dai), ys);
        _stake(alice, address(dai), 100 ether);
        // Above par: the position is worth more than the principal booked against it.
        dai.mint(address(ys), 10 ether);
        ys.setValueFactorBps(11_000);
        vm.warp(block.timestamp + 50);

        uint256 supplyBefore = phUSD.totalSupply();
        (uint256 paid, uint256 minted) = _autoAnnihilateCapture(alice, address(dai));

        assertEq(minted, 0, "nothing minted when delivery meets the target");
        assertEq(paid, _target(address(dai), 50 ether), "paid exactly the target");
        assertEq(phUSD.totalSupply() - supplyBefore, paid, "no inflation beyond the two annihilation halves");
        assertEq(_userAmount(address(dai), alice), 50 ether, "debited the request, no underflow");
        assertEq(dai.balanceOf(address(staker)), 0, "nothing retained");
    }

    /// @dev The target is COMPUTED, never assumed to be 2x. The whole fixture registers both stables
    ///      at exactly 1e18, so a hardcoded doubling would pass every other test in this file and be
    ///      wrong the moment the rate moves. A third token at 0.99e18 makes the difference visible.
    function test_autoAnnihilate_nonUnityExchangeRate_targetIsComputedNotDoubled() public {
        MockERC20 eur = new MockERC20("Euro", "EUR", 18);
        minter.registerStablecoin(address(eur), address(minterYS), 0.99e18, 18);
        minter.approveYS(address(eur), address(minterYS));
        staker.addToken(address(eur));
        staker.antimatterPerDay(address(eur), PER_DAY);
        eur.mint(alice, 1_000 ether);
        vm.prank(alice);
        eur.approve(address(staker), type(uint256).max);

        MockYieldStrategy ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        ys.setExitSlippageBps(300);
        staker.setYieldStrategy(address(eur), ys);

        _stake(alice, address(eur), 100 ether);
        vm.warp(block.timestamp + 100);

        uint256 target = _target(address(eur), 100 ether);
        assertEq(target, 199 ether, "100 A + 99 phUSD for the stable half, NOT 200");
        assertTrue(target != 200 ether, "a hardcoded 2x would be wrong here");

        (uint256 paid, uint256 minted) = _autoAnnihilateCapture(alice, address(eur));

        assertEq(paid, target, "paid the computed target");
        assertEq(phUSD.balanceOf(alice), target, "and it reached the caller");
        assertEq(minted, target - _target(address(eur), 97 ether), "minted exactly the deficit at this rate");
        assertEq(_userAmount(address(eur), alice), 0, "debited the request");
    }

    /// @dev Rounding must always favour the protocol. Asserted as an upper bound on the payout across
    ///      the interesting shapes: a 6-decimal stable with sub-unit dust, a non-integral ERC4626
    ///      share price, and a deterministic haircut. The caller is never paid MORE than the target.
    function test_autoAnnihilate_neverPaysMoreThanTheTarget() public {
        // 6-decimal, with a non-representable `owed` so the floor-and-carry path runs.
        staker.antimatterPerDay(address(usdc), 86_400 * (1e12 + 1));
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 50);
        (uint256 paidUsdc,) = _autoAnnihilateCapture(alice, address(usdc));
        assertLe(paidUsdc, _target(address(usdc), 50), "6-decimal payout is capped at the target");
        assertEq(paidUsdc, _target(address(usdc), 50), "and meets it exactly");

        // A deterministic haircut on the 18-decimal stable.
        _haircutStrategy(700);
        _stake(bob, address(dai), 100 ether);
        vm.warp(block.timestamp + 100);
        (uint256 paidDai,) = _autoAnnihilateCapture(bob, address(dai));
        assertLe(paidDai, _target(address(dai), 100 ether), "haircut payout is capped at the target");
    }

    /// @dev The rolling 24h `maxMintPerDay` cap is invisible to `calculateMintAmount` — which is
    ///      exactly why the target it returns is a target and not a guarantee. When the cap bites, the
    ///      whole call reverts atomically inside `PhusdStableMinter.mint`, well before any phUSD is
    ///      paid or any top-up is minted. The caller keeps their principal and their accrual.
    function test_autoAnnihilate_dailyMintCap_revertsAtomically() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        // The stable half alone would mint 50 phUSD; cap the day at 1.
        minter.setMaxMintPerDay(address(dai), 1 ether);
        // The quote is unaffected: it never reads the cap.
        assertEq(minter.calculateMintAmount(address(dai), 50 ether), 50 ether, "the quote ignores the cap");

        vm.expectRevert("Daily mint limit exceeded");
        _autoAnnihilate(alice, address(dai));

        // Atomic: nothing moved.
        assertEq(_userAmount(address(dai), alice), 100 ether, "principal intact");
        assertEq(_totalStaked(address(dai)), 100 ether, "totalStaked intact");
        assertEq(staker.claimableReward(address(dai), alice), 50 ether, "accrual intact");
        assertEq(phUSD.balanceOf(alice), 0, "nothing paid");
    }

    /// @dev Fail closed when the top-up cannot be minted. The staker's phUSD grant is revoked, the
    ///      exit shortchanges, and the caller gets StableStaker's own message rather than a bare
    ///      `"phUSD: ..."` string surfacing from a foreign contract.
    function test_autoAnnihilate_phUSDGrantRevoked_failsClosedWithOurOwnMessage() public {
        _haircutStrategy(200);
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 100);

        phUSD.setMinter(address(staker), false);
        assertFalse(staker.phUSDMintAvailable(), "precondition: the probe agrees");

        vm.expectRevert("StableStaker: phUSD mint unavailable");
        _autoAnnihilate(alice, address(dai));

        assertEq(_userAmount(address(dai), alice), 100 ether, "principal intact");
        assertEq(phUSD.balanceOf(alice), 0, "nothing paid");
    }

    /// @dev The same fault arriving the way it actually will: phUSD's owner calls
    ///      `revokeAllMintPrivileges()`, which bumps a GLOBAL counter and de-authorises every minter
    ///      at once with no transaction ever touching this contract. Antimatter and the stable minter
    ///      are re-granted here; the staker deliberately is not, which is the state an operator who
    ///      forgets this contract leaves behind.
    function test_autoAnnihilate_revokeAllMintPrivileges_failsClosed() public {
        _haircutStrategy(200);
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 100);

        phUSD.revokeAllMintPrivileges();
        phUSD.setMinter(address(minter), true);
        phUSD.setMinter(address(antimatter), true);
        assertFalse(staker.phUSDMintAvailable(), "the staker's grant died with the version bump");

        vm.expectRevert("StableStaker: phUSD mint unavailable");
        _autoAnnihilate(alice, address(dai));
    }

    /// @dev ...and a frictionless exit is unaffected by a revoked grant, because it needs no top-up.
    ///      The fail-closed choice therefore costs nothing while the strategy delivers in full.
    function test_autoAnnihilate_phUSDGrantRevoked_fullCreditStillWorks() public {
        _haircutStrategy(0);
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        phUSD.setMinter(address(staker), false);

        _autoAnnihilate(alice, address(dai));
        assertEq(phUSD.balanceOf(alice), 100 ether, "no top-up needed, so no grant needed");
    }

    /// @dev The top-up is NEW supply, never a draw on the idle stable balance. Asserted across the
    ///      haircut grid against a deliberately fat buffer, with the payout pinned to the target so a
    ///      regression cannot pass by simply paying less.
    function test_autoAnnihilate_topUpNeverTouchesTheIdleBuffer() public {
        uint256[3] memory tolerances = [uint256(0), 300, 5_000];
        for (uint256 i = 0; i < tolerances.length; i++) {
            uint256 snap = vm.snapshotState();
            _haircutStrategy(tolerances[i]);
            _stake(alice, address(dai), 100 ether);
            dai.mint(address(staker), 500 ether);
            vm.warp(block.timestamp + 100);

            (uint256 paid,) = _autoAnnihilateCapture(alice, address(dai));

            assertEq(paid, _target(address(dai), 100 ether), "made whole at every tolerance");
            assertEq(dai.balanceOf(address(staker)), 500 ether, "buffer untouched");
            assertEq(phUSD.balanceOf(address(staker)), 0, "no phUSD retained");
            vm.revertToState(snap);
        }
    }

    /// @dev The 6-decimal stable against a haircut: the flooring to a multiple of `scale` still holds,
    ///      the sub-unit dust still carries into {unclaimedReward}, and the top-up is priced in the
    ///      token's own decimals rather than in 18.
    function test_autoAnnihilate_6decStable_haircut_floorsAndCarriesAndTopsUp() public {
        MockYieldStrategy ys = new MockYieldStrategy();
        ys.setClient(address(staker), true);
        ys.setExitSlippageBps(200);
        staker.setYieldStrategy(address(usdc), ys);

        staker.antimatterPerDay(address(usdc), 86_400 * (1e12 + 1));
        _stake(alice, address(usdc), 100e6);
        usdc.mint(address(staker), 10e6); // buffer
        vm.warp(block.timestamp + 50);
        assertEq(staker.claimableReward(address(usdc), alice), 50 * (1e12 + 1), "precondition");

        (uint256 paid, uint256 minted) = _autoAnnihilateCapture(alice, address(usdc));

        assertEq(_userAmount(address(usdc), alice), 100e6 - 50, "principal reduced by 50 raw units");
        assertEq(staker.unclaimedReward(address(usdc), alice), 50, "sub-unit dust still carried");
        assertEq(paid, _target(address(usdc), 50), "paid the frictionless target in 18-decimal phUSD");
        assertEq(phUSD.balanceOf(alice), _target(address(usdc), 50), "and it reached the caller");
        assertGt(minted, 0, "the 2% haircut really did need covering");
        assertEq(antimatter.balanceOf(alice), 0, "no raw antimatter");
        assertEq(usdc.balanceOf(address(staker)), 10e6, "idle buffer untouched");
    }

    /// @dev The two-hop read is live, not cached: `antimatter.phUSDMinter()` then
    ///      `calculateMintAmount`. Exposed so an operator can see what the staker will price against.
    function test_phUSDMinterContract_readsLiveOffAntimatter() public view {
        assertEq(staker.phUSDMinterContract(), address(minter), "resolved through antimatter");
    }
}
