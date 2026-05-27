// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStaker.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Core unit tests for StableStaker: staking math, enumerable set, pausing, escape hatch.
contract StableStakerTest is Test {
    FlaxToken internal phUSD;
    StableStaker internal staker;
    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal dai; // 18 decimals

    address internal owner = address(this);
    address internal pauser = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA801);

    uint256 internal constant PER_DAY = 86_400 ether; // -> 1e18 phUSD per second

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStaker(phUSD, owner);
        phUSD.setMinter(address(staker), true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);

        staker.addToken(address(usdc));
        staker.addToken(address(dai));
        staker.phUSDPerDay(address(usdc), PER_DAY);
        staker.setPauser(pauser);

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000e6);
        dai.mint(who, 1_000_000 ether);
        vm.startPrank(who);
        usdc.approve(address(staker), type(uint256).max);
        dai.approve(address(staker), type(uint256).max);
        vm.stopPrank();
    }

    function _stake(address who, address token, uint256 amount) internal {
        vm.prank(who);
        staker.stake(token, amount);
    }

    // ---------------------------------------------------------------- staking

    function test_stake_updatesPositionAndSet() public {
        _stake(alice, address(usdc), 100e6);
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 100e6);
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 100e6);
        assertEq(staker.stakerCount(address(usdc)), 1);
        address[] memory s = staker.getStakers(address(usdc));
        assertEq(s.length, 1);
        assertEq(s[0], alice);
    }

    function test_singleStaker_accruesAtRate() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        // Sole staker receives the full emission of 100s * 1e18/s.
        assertEq(staker.pendingReward(address(usdc), alice), 100 ether);
    }

    function test_claim_mintsRewardAndResets() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        staker.claim(address(usdc));
        assertEq(phUSD.balanceOf(alice), 100 ether);
        assertEq(staker.pendingReward(address(usdc), alice), 0);
    }

    function test_withdraw_returnsPrincipalAndMintsReward() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);
        assertEq(usdc.balanceOf(alice), balBefore + 40e6);
        assertEq(phUSD.balanceOf(alice), 100 ether); // reward settled on withdraw
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 60e6);
        assertEq(staker.pendingReward(address(usdc), alice), 0);
    }

    function test_fullWithdraw_removesFromSet() public {
        _stake(alice, address(usdc), 100e6);
        vm.prank(alice);
        staker.withdraw(address(usdc), 100e6);
        assertEq(staker.stakerCount(address(usdc)), 0);
    }

    function test_twoStakers_proRata() public {
        _stake(alice, address(usdc), 100e6);
        _stake(bob, address(usdc), 300e6);
        vm.warp(block.timestamp + 100);
        // total emission 100e18 split 1:3
        assertApproxEqAbs(staker.pendingReward(address(usdc), alice), 25 ether, 1e6);
        assertApproxEqAbs(staker.pendingReward(address(usdc), bob), 75 ether, 1e6);
    }

    function test_multiToken_independent() public {
        staker.phUSDPerDay(address(dai), PER_DAY * 2); // 2e18/s
        _stake(alice, address(usdc), 100e6);
        _stake(alice, address(dai), 100 ether);
        vm.warp(block.timestamp + 100);
        assertEq(staker.pendingReward(address(usdc), alice), 100 ether);
        assertEq(staker.pendingReward(address(dai), alice), 200 ether);
    }

    // ---------------------------------------------------------------- enumeration

    function test_getStakersRange_pagesAndClamps() public {
        _stake(alice, address(usdc), 10e6);
        _stake(bob, address(usdc), 10e6);
        _stake(carol, address(usdc), 10e6);
        assertEq(staker.stakerCount(address(usdc)), 3);

        address[] memory first2 = staker.getStakersRange(address(usdc), 0, 2);
        assertEq(first2.length, 2);
        assertEq(first2[0], alice);
        assertEq(first2[1], bob);

        // end clamped to length
        address[] memory tail = staker.getStakersRange(address(usdc), 1, 999);
        assertEq(tail.length, 2);
        assertEq(tail[0], bob);
        assertEq(tail[1], carol);

        // empty slice
        address[] memory none = staker.getStakersRange(address(usdc), 3, 3);
        assertEq(none.length, 0);
    }

    function test_getStakersRange_revertsOnBadRange() public {
        _stake(alice, address(usdc), 10e6);
        vm.expectRevert(bytes("StableStaker: bad range"));
        staker.getStakersRange(address(usdc), 2, 1);
    }

    function test_getStakedTokens() public view {
        address[] memory tokens = staker.getStakedTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc));
        assertEq(tokens[1], address(dai));
    }

    // ---------------------------------------------------------------- access control

    function test_addToken_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staker.addToken(address(0x1234));
    }

    function test_phUSDPerDay_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staker.phUSDPerDay(address(usdc), PER_DAY);
    }

    function test_stake_unknownToken_reverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: unknown token"));
        staker.stake(address(0xdead), 1);
    }

    // ---------------------------------------------------------------- pausing

    function test_pause_blocksStakeWithdrawClaim() public {
        _stake(alice, address(usdc), 100e6);
        vm.prank(pauser);
        staker.pause();

        vm.prank(alice);
        vm.expectRevert();
        staker.stake(address(usdc), 1e6);

        vm.prank(alice);
        vm.expectRevert();
        staker.withdraw(address(usdc), 1e6);

        vm.prank(alice);
        vm.expectRevert();
        staker.claim(address(usdc));
    }

    function test_pause_onlyPauser() public {
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: only pauser"));
        staker.pause();
    }

    function test_unpause_byOwnerOrPauser() public {
        vm.prank(pauser);
        staker.pause();
        // owner can unpause
        staker.unpause();
        assertFalse(staker.paused());
        // pauser can also unpause
        vm.prank(pauser);
        staker.pause();
        vm.prank(pauser);
        staker.unpause();
        assertFalse(staker.paused());
    }

    // ---------------------------------------------------------------- emergency

    function test_emergencyWithdraw_returnsPrincipalForfeitsReward() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.emergencyWithdraw(address(usdc));
        assertEq(usdc.balanceOf(alice), balBefore + 100e6);
        assertEq(phUSD.balanceOf(alice), 0); // reward forfeited
        assertEq(staker.stakerCount(address(usdc)), 0);
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 0);
    }

    function test_emergencyWithdraw_worksWhilePaused() public {
        _stake(alice, address(usdc), 100e6);
        vm.prank(pauser);
        staker.pause();
        vm.prank(alice);
        staker.emergencyWithdraw(address(usdc)); // must not revert
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 0);
    }
}
