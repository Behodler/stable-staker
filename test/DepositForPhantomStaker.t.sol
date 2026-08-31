// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";

/// @notice Regression test for [M-01] ss10m1 — `depositFor` phantom staker fix.
///
/// Before the fix, `depositFor` unconditionally inserted the recipient into `_stakers`
/// even when the strategy haircut returned a zero-credit (`credited == 0`). This "phantom"
/// staker could never be removed during terminal migration because `_exitPosition` early-
/// returns on `amt == 0` before the `_stakers.remove` call, leaving `stakerCount == 1`
/// after all real stakers exited, causing `finalizeAndReset` to revert forever.
///
/// After the fix, `depositFor` mirrors `stake` by adding:
///   require(credited > 0, "StableStaker: nothing credited");
/// before any state mutation, preventing the phantom from ever being created.
contract DepositForPhantomStakerTest is Test {
    Antimatter internal antimatter;
    StableStakerV2 internal staker;
    MockERC20 internal dai;
    MockYieldStrategy internal strategy;

    address internal owner = address(this);
    address internal migrator = address(0x4191A704);
    address internal realUser = address(0xA11CE);
    address internal phantom = address(0xDEAD);

    uint256 internal constant SLIP_BPS = 100; // 1% deposit haircut
    uint256 internal constant REAL_STAKE = 100 ether;

    function setUp() public {
        antimatter = new Antimatter(owner);
        staker = new StableStakerV2(IAntimatter(address(antimatter)), owner);
        antimatter.setApprovedMinter(address(staker), true);

        dai = new MockERC20("Dai", "DAI", 18);
        staker.addToken(address(dai));

        // 1% haircutting market strategy — must wire on empty pool (story 010 gate).
        strategy = new MockYieldStrategy();
        strategy.setClient(address(staker), true);
        strategy.setDepositSlippageBps(SLIP_BPS);
        staker.setYieldStrategy(address(dai), IYieldStrategy(address(strategy)));

        staker.setMigrator(migrator);

        dai.mint(migrator, 1_000_000 ether);
        vm.prank(migrator);
        dai.approve(address(staker), type(uint256).max);

        dai.mint(realUser, 1_000_000 ether);
        vm.prank(realUser);
        dai.approve(address(staker), type(uint256).max);
    }

    /// @notice A dust `depositFor` (1 wei with 1% slippage => 0 credit) MUST revert with
    ///         "StableStaker: nothing credited". No phantom should be inserted.
    function test_depositFor_dustInput_reverts_nothingCredited() public {
        // Stake a real user so stakerCount starts at 1.
        vm.prank(realUser);
        staker.stake(address(dai), REAL_STAKE);
        assertEq(staker.stakerCount(address(dai)), 1, "only real user staked before dust deposit");

        // 1 wei * (10000 - 100) / 10000 = 0 credit.
        vm.prank(migrator);
        vm.expectRevert(bytes("StableStaker: nothing credited"));
        staker.depositFor(address(dai), phantom, 1);

        // stakerCount must remain unchanged — no phantom inserted.
        assertEq(staker.stakerCount(address(dai)), 1, "phantom must not be inserted on zero-credit depositFor");

        // Phantom's userInfo.amount must remain zero.
        (uint256 phantomAmt,) = staker.userInfo(address(dai), phantom);
        assertEq(phantomAmt, 0, "phantom userInfo.amount must be zero");
    }

    /// @notice Full migration lifecycle succeeds when no phantom is present: initiateMigration,
    ///         batchMigrate, and finalizeAndReset all complete without reverting.
    function test_depositFor_noPhantom_finalizeAndReset_succeeds() public {
        // Stake a real user.
        vm.prank(realUser);
        staker.stake(address(dai), REAL_STAKE);
        assertEq(staker.stakerCount(address(dai)), 1);

        // Attempt a dust depositFor — it must revert, leaving stakerCount at 1.
        vm.prank(migrator);
        vm.expectRevert(bytes("StableStaker: nothing credited"));
        staker.depositFor(address(dai), phantom, 1);
        assertEq(staker.stakerCount(address(dai)), 1, "stakerCount unchanged after failed dust depositFor");

        // Begin terminal migration.
        vm.prank(migrator);
        staker.initiateMigration(address(dai));

        // Migrate the sole real user.
        address[] memory batch = new address[](1);
        batch[0] = realUser;
        vm.prank(migrator);
        staker.batchMigrate(address(dai), batch);

        // All stakers must now be cleared.
        assertEq(staker.stakerCount(address(dai)), 0, "all stakers cleared after batchMigrate");

        // finalizeAndReset must NOT revert — pool can be revived.
        staker.finalizeAndReset(address(dai));
    }

    /// @notice A non-dust depositFor (large enough input so credit > 0) still succeeds after
    ///         the guard is added — the guard only blocks the zero-credit case.
    function test_depositFor_sufficientInput_creditsAndInsertsStaker() public {
        // Stake a real user.
        vm.prank(realUser);
        staker.stake(address(dai), REAL_STAKE);
        assertEq(staker.stakerCount(address(dai)), 1);

        // 1 ether * (10000 - 100) / 10000 = 0.99 ether => credited > 0.
        vm.prank(migrator);
        staker.depositFor(address(dai), phantom, 1 ether);

        // phantom inserted and credited correctly.
        assertEq(staker.stakerCount(address(dai)), 2, "phantom properly inserted for non-dust deposit");
        (uint256 phantomAmt,) = staker.userInfo(address(dai), phantom);
        uint256 expectedCredit = (1 ether * (10_000 - SLIP_BPS)) / 10_000;
        assertEq(phantomAmt, expectedCredit, "phantom credited with correct haircut amount");
    }
}
