// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStaker.sol";
import "../src/StableStakerMigrator.sol";
import "../src/interfaces/IStableStaker.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";

/// @notice End-to-end migration: an operator moves users from v1 to v2 with zero user action,
///         principal and earned rewards preserved, and v2 keeps accruing afterwards.
contract MigrationTest is Test {
    FlaxToken internal phUSD;
    StableStaker internal oldStaker;
    StableStaker internal newStaker;
    StableStakerMigrator internal migrator;
    MockERC20 internal usdc;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant PER_DAY = 86_400 ether; // 1e18 / second

    function setUp() public {
        phUSD = new FlaxToken();
        oldStaker = new StableStaker(phUSD, owner);
        newStaker = new StableStaker(phUSD, owner);

        // both instances may mint phUSD
        phUSD.setMinter(address(oldStaker), true);
        phUSD.setMinter(address(newStaker), true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oldStaker.addToken(address(usdc));
        newStaker.addToken(address(usdc));
        oldStaker.phUSDPerDay(address(usdc), PER_DAY);
        newStaker.phUSDPerDay(address(usdc), PER_DAY);

        migrator = new StableStakerMigrator(IStableStaker(address(oldStaker)), IStableStaker(address(newStaker)), owner);
        oldStaker.setMigrator(address(migrator));
        newStaker.setMigrator(address(migrator));

        // users stake into v1
        _fundAndStake(alice, 100e6);
        _fundAndStake(bob, 300e6);
    }

    function _fundAndStake(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(oldStaker), type(uint256).max);
        oldStaker.stake(address(usdc), amt);
        vm.stopPrank();
    }

    function test_endToEnd_migration_preservesPositionsAndRewards() public {
        // accrue rewards in v1 for a day
        vm.warp(block.timestamp + 1 days);

        uint256 pendingAlice = oldStaker.pendingReward(address(usdc), alice);
        uint256 pendingBob = oldStaker.pendingReward(address(usdc), bob);
        assertGt(pendingAlice, 0);
        assertGt(pendingBob, 0);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        // single operator transaction; neither alice nor bob acts.
        migrator.migrate(address(usdc), users);

        // --- v1 fully drained ---
        (uint256 aOld,) = oldStaker.userInfo(address(usdc), alice);
        (uint256 bOld,) = oldStaker.userInfo(address(usdc), bob);
        assertEq(aOld, 0);
        assertEq(bOld, 0);
        (,,, uint256 oldTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(oldTotal, 0);
        assertEq(oldStaker.stakerCount(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(oldStaker)), 0);

        // --- earned rewards minted to the users during migrateOut (same block => exact) ---
        assertEq(phUSD.balanceOf(alice), pendingAlice);
        assertEq(phUSD.balanceOf(bob), pendingBob);

        // --- v2 credited with original principal ---
        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6);
        assertEq(bNew, 300e6);
        (,,, uint256 newTotal) = newStaker.poolInfo(address(usdc));
        assertEq(newTotal, 400e6);
        assertEq(newStaker.stakerCount(address(usdc)), 2);
        assertEq(usdc.balanceOf(address(newStaker)), 400e6);

        // no dust left stranded in the migrator
        assertEq(usdc.balanceOf(address(migrator)), 0);

        // --- v2 keeps accruing; alice (who never signed anything) can claim ---
        uint256 aliceBefore = phUSD.balanceOf(alice);
        vm.warp(block.timestamp + 100);
        assertApproxEqAbs(newStaker.pendingReward(address(usdc), alice), 25 ether, 1e6); // 1:3 share of 100e18
        vm.prank(alice);
        newStaker.claim(address(usdc));
        assertGt(phUSD.balanceOf(alice), aliceBefore);
    }

    function test_migrate_onlyOwner() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(alice);
        vm.expectRevert();
        migrator.migrate(address(usdc), users);
    }

    function test_migrateOut_onlyMigrator() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: only migrator"));
        oldStaker.migrateOut(address(usdc), users);
    }

    function test_depositFor_onlyMigrator() public {
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: only migrator"));
        newStaker.depositFor(address(usdc), alice, 1e6);
    }

    // Migration must work even while v1 is paused (incident response).
    function test_migration_worksWhilePaused() public {
        oldStaker.setPauser(owner);
        oldStaker.pause();
        vm.warp(block.timestamp + 1 days);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        migrator.migrate(address(usdc), users);

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        assertEq(aNew, 100e6);
    }

    // ============================== M-01: UNDERWATER MIGRATION ==============================

    /// @dev Route the OLD staker's USDC principal through a MockYieldStrategy so we can force it
    ///      below par via setValueFactorBps. Sweeps the already-staked idle balance into the
    ///      strategy. Returns the strategy so the test can set the value factor.
    function _routeOldThroughStrategy() internal returns (MockYieldStrategy strategy) {
        strategy = new MockYieldStrategy();
        strategy.setClient(address(oldStaker), true);
        // setYieldStrategy sweeps the existing idle USDC into the strategy.
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
    }

    function _users() internal view returns (address[] memory users) {
        users = new address[](2);
        users[0] = alice;
        users[1] = bob;
    }

    // M-01: a below-par migration must NOT revert (previously bricked with ERC20InsufficientBalance).
    function test_underwaterMigration_doesNotBrick() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000); // 10% loss

        // Pre-fix this reverts with ERC20InsufficientBalance(migrator, 260e6, 300e6). It must now succeed.
        migrator.migrate(address(usdc), _users());

        // Sanity: new staker has positions.
        assertEq(newStaker.stakerCount(address(usdc)), 2);
    }

    // M-01: each user is credited their realized, pro-rata share of the haircut payout.
    function test_underwaterMigration_proRataCreditOnNewStaker() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000); // 10% loss

        migrator.migrate(address(usdc), _users());

        // requested * 9000 / 10000
        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 90e6); // 100e6 * 9000 / 10000
        assertEq(bNew, 270e6); // 300e6 * 9000 / 10000

        (,,, uint256 newTotal) = newStaker.poolInfo(address(usdc));
        assertEq(newTotal, 360e6); // == payout, exact since both divisions are clean here
    }

    // M-01: conservation / solvency — Σ credited <= payout received, and the new staker actually
    // holds at least the credited principal.
    function test_underwaterMigration_conservationAndSolvency() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000); // 10% loss

        uint256 payout = (400e6 * 9_000) / 10_000; // 360e6 delivered to the migrator

        migrator.migrate(address(usdc), _users());

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        uint256 credited = aNew + bNew;

        // Σ credited never exceeds what the migrator received.
        assertLe(credited, payout);
        // New staker holds at least the credited principal (idle hold; no strategy on new staker).
        assertGe(usdc.balanceOf(address(newStaker)), credited);
    }

    // M-01: floor-division dust is bounded by users.length and equals exactly payout - Σ credited.
    function test_underwaterMigration_dustBound() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        // Use an "ugly" factor so the pro-rata divisions floor and leave residual dust.
        strategy.setValueFactorBps(8_333); // 16.67% loss; non-clean divisions

        uint256 payout = (400e6 * 8_333) / 10_000;

        address[] memory users = _users();
        migrator.migrate(address(usdc), users);

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        uint256 credited = aNew + bNew;

        uint256 residual = usdc.balanceOf(address(migrator));
        // Residual is exactly the un-credited portion of the payout...
        assertEq(residual, payout - credited);
        // ...and is strictly bounded by users.length base units (pro-rata floor dust).
        assertLt(residual, users.length);
    }

    // M-01: the old staker is fully drained below par (positions zeroed, set emptied, pool zeroed).
    function test_underwaterMigration_oldStakerFullyDrained() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000);

        migrator.migrate(address(usdc), _users());

        (uint256 aOld,) = oldStaker.userInfo(address(usdc), alice);
        (uint256 bOld,) = oldStaker.userInfo(address(usdc), bob);
        assertEq(aOld, 0);
        assertEq(bOld, 0);
        (,,, uint256 oldTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(oldTotal, 0);
        assertEq(oldStaker.stakerCount(address(usdc)), 0);
    }

    // M-01: rewards are still minted during an underwater migrateOut (independent of the haircut).
    function test_underwaterMigration_rewardsStillMinted() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000);

        // accrue a day of rewards before migrating
        vm.warp(block.timestamp + 1 days);
        uint256 pendingAlice = oldStaker.pendingReward(address(usdc), alice);
        uint256 pendingBob = oldStaker.pendingReward(address(usdc), bob);
        assertGt(pendingAlice, 0);
        assertGt(pendingBob, 0);

        migrator.migrate(address(usdc), _users());

        // same block as migrateOut => exact
        assertEq(phUSD.balanceOf(alice), pendingAlice);
        assertEq(phUSD.balanceOf(bob), pendingBob);
    }

    // M-01: boundary — at par (10000 bps) the rescale is skipped; full principal credited, no dust.
    // This re-runs the at-par scenario WITH a strategy wired to prove the guard skips correctly.
    function test_atParMigration_throughStrategy_stillExact() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(10_000); // par

        migrator.migrate(address(usdc), _users());

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6);
        assertEq(bNew, 300e6);
        (,,, uint256 newTotal) = newStaker.poolInfo(address(usdc));
        assertEq(newTotal, 400e6);
        assertEq(usdc.balanceOf(address(newStaker)), 400e6);
        // rescale skipped at par => no dust stranded
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // M-01 (optional): a dust-sized position whose pro-rata share floors to 0 is skipped by the
    // migrator (no depositFor(amount=0) revert) while the rest migrate successfully.
    function test_underwaterMigration_tinyPositionRoundsToZero_skipped() public {
        // carol stakes 1 base unit; with a deep haircut her pro-rata share floors to 0.
        address carol = address(0xCA401);
        _fundAndStake(carol, 1); // 1 base unit of USDC

        MockYieldStrategy strategy = _routeOldThroughStrategy(); // sweeps 400e6 + 1
        assertEq(strategy.principalOf(address(usdc), address(oldStaker)), 400_000_001);

        strategy.setValueFactorBps(5_000); // 50% loss

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;

        // Must not revert despite carol's share flooring to 0.
        migrator.migrate(address(usdc), users);

        // carol skipped on the new staker (depositFor never called with 0).
        (uint256 cNew,) = newStaker.userInfo(address(usdc), carol);
        assertEq(cNew, 0);
        // but her old position is still drained.
        (uint256 cOld,) = oldStaker.userInfo(address(usdc), carol);
        assertEq(cOld, 0);

        // alice & bob migrated with their pro-rata share.
        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertGt(aNew, 0);
        assertGt(bNew, 0);
    }
}
