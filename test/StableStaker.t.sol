// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStaker.sol";
import "flax-token/FlaxToken.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";

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

    // ---------------------------------------------------------------- rescueERC20 (story 002)

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    function test_rescueERC20_onlyOwner() public {
        // Mint some token directly into the staker to make the call meaningful.
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(staker), 1 ether);

        vm.prank(alice);
        // OZ Ownable v5 emits OwnableUnauthorizedAccount(address) — just assert it reverts.
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        staker.rescueERC20(address(stray), alice, 1 ether);
    }

    function test_rescueERC20_unregisteredToken_rescuesFullBalance() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(staker), 5 ether);

        vm.expectEmit(true, true, true, true);
        emit ERC20Rescued(address(stray), owner, 5 ether);
        staker.rescueERC20(address(stray), owner, 5 ether);

        assertEq(stray.balanceOf(owner), 5 ether);
        assertEq(stray.balanceOf(address(staker)), 0);
    }

    function test_rescueERC20_registeredNoStrategy_exactPrincipal_revertsOnAnyAmount() public {
        // Token registered, no strategy. Staker holds exactly totalStaked.
        _stake(alice, address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(staker)), 100e6);

        vm.expectRevert(bytes("StableStaker: would touch user principal"));
        staker.rescueERC20(address(usdc), owner, 1);
    }

    function test_rescueERC20_registeredNoStrategy_dust_rescuesExactlyDust() public {
        _stake(alice, address(usdc), 100e6);
        // Add dust on top of staked principal (e.g. donation).
        usdc.mint(address(staker), 7);
        assertEq(usdc.balanceOf(address(staker)), 100e6 + 7);

        // Can rescue exactly the dust.
        staker.rescueERC20(address(usdc), owner, 7);
        assertEq(usdc.balanceOf(address(staker)), 100e6);
        assertEq(usdc.balanceOf(owner), 7);

        // One wei more would touch principal.
        usdc.mint(address(staker), 3); // re-add 3 dust
        vm.expectRevert(bytes("StableStaker: would touch user principal"));
        staker.rescueERC20(address(usdc), owner, 4);
    }

    function test_rescueERC20_registeredWithStrategy_rescuesFullBuffer() public {
        // Wire up a strategy.
        MockYieldStrategy strategy = new MockYieldStrategy();
        strategy.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));

        // Stake while a strategy is set: principal lives in strategy.
        _stake(alice, address(usdc), 100e6);
        assertEq(usdc.balanceOf(address(staker)), 0);

        // Faucet (or random donor) seeds buffer of 80e6.
        usdc.mint(address(staker), 80e6);

        // Owner rescues the full buffer — allowed because principal sits in the strategy.
        staker.rescueERC20(address(usdc), owner, 80e6);
        assertEq(usdc.balanceOf(address(staker)), 0);
        assertEq(usdc.balanceOf(owner), 80e6);
    }

    function test_rescueERC20_zeroRecipient_reverts() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(staker), 1 ether);

        vm.expectRevert(bytes("StableStaker: zero recipient"));
        staker.rescueERC20(address(stray), address(0), 1 ether);
    }

    function test_rescueERC20_drainBufferThenWithdrawReverts_underwater() public {
        // Strategy + underwater + buffer present, then owner drains buffer.
        MockYieldStrategy strategy = new MockYieldStrategy();
        strategy.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));

        _stake(alice, address(usdc), 100e6);
        strategy.setValueFactorBps(9_000); // underwater
        usdc.mint(address(staker), 50e6); // seed buffer

        // Buffer would normally allow alice to withdraw 40e6.
        // But the owner rescues it first.
        staker.rescueERC20(address(usdc), owner, 50e6);
        assertEq(usdc.balanceOf(address(staker)), 0);

        // Subsequent user withdraw now reverts — no buffer, strategy still underwater.
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: strategy underwater"));
        staker.withdraw(address(usdc), 40e6);
    }

    function test_rescueERC20_worksWhilePaused() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(staker), 3 ether);

        vm.prank(pauser);
        staker.pause();

        // Must not revert: owner rescue is intentionally not gated by whenNotPaused.
        staker.rescueERC20(address(stray), owner, 3 ether);
        assertEq(stray.balanceOf(owner), 3 ether);
    }
}
