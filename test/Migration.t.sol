// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStaker.sol";
import "../src/StableStakerMigrator.sol";
import "../src/interfaces/IStableStaker.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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
}
