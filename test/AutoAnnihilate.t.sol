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

    /// @dev Mirrors {StableStakerV2.AutoAnnihilated} for vm.expectEmit.
    event AutoAnnihilated(
        address indexed token,
        address indexed user,
        uint256 antimatterBurned,
        uint256 principalConsumed,
        uint256 excessMinted
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

    function _autoAnnihilate(address who, address token, uint256 minOut) internal {
        vm.prank(who);
        staker.autoAnnihilate(token, minOut);
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
        emit AutoAnnihilated(address(dai), alice, 50 ether, 50 ether, 0);
        _autoAnnihilate(alice, address(dai), 0);

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

        _autoAnnihilate(alice, address(usdc), 0);

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
        _autoAnnihilate(alice, address(usdc), 0);
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
        emit AutoAnnihilated(address(usdc), alice, 1 ether, 1e6, 4 ether);
        _autoAnnihilate(alice, address(usdc), 0);

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

        _autoAnnihilate(alice, address(usdc), 0);

        assertEq(_userAmount(address(usdc), alice), 0, "position emptied");
        assertEq(staker.stakerCount(address(usdc)), 1, "alice removed from the staker set");
        address[] memory stakers = staker.getStakers(address(usdc));
        assertEq(stakers[0], bob, "only bob remains");
    }

    function test_autoAnnihilate_partialPosition_keepsStakerInTheSet() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        _autoAnnihilate(alice, address(dai), 0);
        assertEq(staker.stakerCount(address(dai)), 1, "still a staker");
    }

    // -------------------------------------------------------- rewardDebt rebase

    function test_autoAnnihilate_rebasesRewardDebt_soLaterSettlesDoNotUnderflow() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        _autoAnnihilate(alice, address(dai), 0);

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
        _autoAnnihilate(alice, address(dai), 0);
        assertEq(_userAmount(address(dai), alice), 90 ether, "first pass");
        vm.warp(block.timestamp + 10);
        _autoAnnihilate(alice, address(dai), 0);
        assertEq(_userAmount(address(dai), alice), 80 ether, "second pass");
        assertEq(_totalStaked(address(dai)), 80 ether, "totalStaked in lockstep");
    }

    // ------------------------------------------------------------------ guards

    function test_autoAnnihilate_revertsWhenNothingOwed() public {
        _stake(alice, address(dai), 100 ether);
        vm.expectRevert("StableStaker: nothing to annihilate");
        _autoAnnihilate(alice, address(dai), 0);
    }

    function test_autoAnnihilate_revertsWhenPoolNotActive() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        staker.setMigrator(owner);
        staker.initiateMigration(address(dai));

        vm.expectRevert("StableStaker: pool not active");
        _autoAnnihilate(alice, address(dai), 0);
    }

    function test_autoAnnihilate_revertsWhenPaused() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        staker.setPauser(owner);
        staker.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _autoAnnihilate(alice, address(dai), 0);
    }

    function test_autoAnnihilate_revertsOnUnknownToken() public {
        vm.expectRevert("StableStaker: unknown token");
        _autoAnnihilate(alice, address(0xDEAD), 0);
    }

    function test_autoAnnihilate_unregisteredStable_revertsWithAnExplicitMessage() public {
        _stake(alice, address(orphan), 100 ether);
        vm.warp(block.timestamp + 50);

        // NOT a bare `StablecoinNotRegistered(address)` bubbling up from Antimatter: the UI must be
        // able to tell "this pool token cannot be annihilated" from "you have nothing to annihilate".
        vm.expectRevert("StableStaker: token not annihilatable");
        _autoAnnihilate(alice, address(orphan), 0);
    }

    function test_autoAnnihilateAvailable_distinguishesRegisteredStables() public view {
        assertTrue(staker.autoAnnihilateAvailable(address(usdc)), "usdc registered");
        assertTrue(staker.autoAnnihilateAvailable(address(dai)), "dai registered");
        assertFalse(staker.autoAnnihilateAvailable(address(orphan)), "orphan not registered");
    }

    function test_autoAnnihilate_enforcesMinPhUSDOut() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        // Both halves come to 100e18; asking for more must revert the whole call.
        vm.expectRevert();
        _autoAnnihilate(alice, address(dai), 100 ether + 1);
    }

    function test_autoAnnihilate_revertsWhileAntimatterIsPaused() public {
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 50);
        antimatter.setPauser(owner);
        antimatter.pause();

        // The two-pause deadlock: the operational answer is `setClaimEnabled(true)`, not a code path.
        vm.expectRevert();
        _autoAnnihilate(alice, address(dai), 0);

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

        _autoAnnihilate(alice, address(dai), 0);

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

        _autoAnnihilate(alice, address(dai), 0);

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
        _autoAnnihilate(alice, address(dai), 0);
        assertEq(dai.allowance(address(staker), address(antimatter)), 0, "approval reset to zero");
    }
}
