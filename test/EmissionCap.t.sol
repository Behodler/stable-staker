// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The safety spec: no sequence of user actions can mint more than phUSDPerDay for a token.
contract EmissionCapTest is Test {
    FlaxToken internal phUSD;
    StableStakerV2 internal staker;
    MockERC20 internal usdc;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant PER_DAY = 86_400 ether; // 1e18 / second

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStakerV2(phUSD, owner);
        phUSD.setMinter(address(staker), true);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        staker.addToken(address(usdc));
        staker.phUSDPerDay(address(usdc), PER_DAY);
        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(address(staker), type(uint256).max);
    }

    function _stake(address who, uint256 amt) internal {
        vm.prank(who);
        staker.stake(address(usdc), amt);
    }

    function _claim(address who) internal {
        vm.prank(who);
        staker.claim(address(usdc));
    }

    // The headline property: one staker over a full day mints AT MOST the daily budget. With an
    // arbitrary stake size, per-share division loses a little dust (always rounding DOWN), so the
    // realized emission is perDay minus a few wei -- never more.
    function test_singleStaker_fullDay_mintsAtMostPerDay() public {
        _stake(alice, 123_456e6);
        vm.warp(block.timestamp + 1 days);
        _claim(alice);
        assertLe(phUSD.balanceOf(alice), PER_DAY); // hard cap
        assertApproxEqAbs(phUSD.balanceOf(alice), PER_DAY, 1e9); // ~all of it (dust only)
    }

    // With a stake size that divides the emission evenly, a sole staker mints EXACTLY perDay.
    function test_singleStaker_cleanDivisor_exact() public {
        _stake(alice, 100e6);
        vm.warp(block.timestamp + 1 days);
        _claim(alice);
        assertEq(phUSD.balanceOf(alice), PER_DAY);
    }

    // Two stakers over a full day: their combined minted amount never exceeds the budget.
    function test_twoStakers_sumNeverExceedsPerDay() public {
        _stake(alice, 100e6);
        _stake(bob, 300e6);
        vm.warp(block.timestamp + 1 days);
        _claim(alice);
        _claim(bob);
        uint256 total = phUSD.balanceOf(alice) + phUSD.balanceOf(bob);
        assertLe(total, PER_DAY); // hard cap
        assertApproxEqAbs(total, PER_DAY, 1e6); // and essentially all of it (only rounding dust lost)
    }

    // Flash staking (stake + exit in the same block) earns nothing.
    function test_flashStake_mintsZero() public {
        _stake(alice, 1_000e6);
        // no time passes
        assertEq(staker.pendingReward(address(usdc), alice), 0);
        vm.prank(alice);
        staker.withdraw(address(usdc), 1_000e6);
        assertEq(phUSD.balanceOf(alice), 0);
    }

    // Time elapsed while the pool is empty mints nothing; only post-stake time accrues.
    function test_emptyPoolWindow_mintsNothing() public {
        vm.warp(block.timestamp + 1 days); // a full day with no stakers
        _stake(alice, 100e6);
        vm.warp(block.timestamp + 100);
        // Only the 100s after staking count, not the idle day.
        assertEq(staker.pendingReward(address(usdc), alice), 100 ether);
    }

    // Changing the rate is never retroactive: the old rate is settled first.
    function test_rateChange_notRetroactive() public {
        _stake(alice, 100e6);
        vm.warp(block.timestamp + 100); // 100s at 1e18/s
        staker.phUSDPerDay(address(usdc), PER_DAY * 5); // -> 5e18/s, settles old rate first
        vm.warp(block.timestamp + 100); // 100s at 5e18/s
        // 100*1e18 + 100*5e18 = 600e18
        assertEq(staker.pendingReward(address(usdc), alice), 600 ether);
    }

    // Cap holds across heavy churn: cumulative minted over N days <= N * perDay.
    function test_emissionCap_holdsUnderChurn() public {
        uint256 startMinted = phUSD.totalSupply();
        uint256 startTime = block.timestamp;

        _stake(alice, 50e6);
        for (uint256 d = 0; d < 7; d++) {
            vm.warp(block.timestamp + 6 hours);
            _stake(bob, 10e6); // churn: bob keeps adding
            vm.warp(block.timestamp + 6 hours);
            _claim(alice);
            _claim(bob);
            vm.prank(bob);
            staker.withdraw(address(usdc), 10e6); // and pulling out
        }

        // One final window that is settled but NOT claimed, so a real backlog is outstanding when the
        // cap is measured. Story 022: `stake` books alice's pending instead of minting it.
        vm.warp(block.timestamp + 6 hours);
        _stake(alice, 1e6);

        uint256 elapsed = block.timestamp - startTime;
        uint256 minted = phUSD.totalSupply() - startMinted;
        uint256 cap = elapsed * (PER_DAY / 1 days); // perSecond * elapsed
        assertLe(minted, cap);

        // Story 022 companion: minted alone now UNDERSTATES what was accrued, because withdraw books
        // to `unclaimedReward` instead of minting. The statement that carries the invariant is
        // sum(unclaimed) + minted <= cap — the cap holds a fortiori once payout is deferred.
        uint256 unclaimed = staker.unclaimedReward(address(usdc), alice) + staker.unclaimedReward(address(usdc), bob);
        assertGt(unclaimed, 0, "the churn really did book a backlog");
        assertLe(unclaimed + minted, cap, "accrued (minted + booked) never exceeds the emission cap");

        // And draining the whole backlog to phUSD still respects the cap. Bob exited fully inside the
        // loop and claimed each round, so alice holds all of it.
        assertEq(staker.unclaimedReward(address(usdc), bob), 0);
        _claim(alice);
        assertEq(staker.unclaimedReward(address(usdc), alice), 0);
        assertLe(phUSD.totalSupply() - startMinted, cap);
    }
}
