// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "../src/CrossVersionMigrator.sol";
import "../src/interfaces/IStableStakerMigratable.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice A staker-shaped address that does NOT expose `STAKER_VERSION`, standing in for the live
///         V1 deployment whose bytecode predates the getter (a static call to it reverts).
contract VersionlessStaker {
    function initiateMigration(address) external {}
}

/// @notice A staker-shaped address reporting an arbitrary future version, so the probe is shown to
///         read the real value rather than a hard-coded 2.
contract FutureVersionStaker {
    uint256 public constant STAKER_VERSION = 7;
}

/// @notice A destination exposing ONLY the golden-rule triad — no `migrator()`, no
///         `getStakedTokens()`, no `STAKER_VERSION`. Stands in for a future staker shape this
///         migrator does not recognise, against which both pre-flight probes must fail open.
contract ProbelessStaker {
    function initiateMigration(address) external {}

    function batchMigrate(address, address[] calldata users) external pure returns (uint256[] memory) {
        return new uint256[](users.length);
    }

    function depositFor(address, address, uint256) external {}
}

/// @notice `CrossVersionMigrator` — the version-agnostic cross-staker migrator. Mirrors the
///         two-staker harness of `Migration.t.sol`, and additionally pins the behaviours that
///         distinguish this contract from the retired cross-staker migrator it replaced: the
///         advisory version probe, the zero-credit skip, and the explicit absence of underwater
///         compensation.
contract CrossVersionMigratorTest is Test {
    FlaxToken internal phUSD;
    StableStakerV2 internal oldStaker;
    StableStakerV2 internal newStaker;
    CrossVersionMigrator internal migrator;
    MockERC20 internal usdc;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint256 internal constant PER_DAY = 86_400 ether; // 1e18 / second

    event MigratedAcrossVersions(
        address indexed token, uint256 userCount, uint256 totalPrincipal, uint256 fromVersion, uint256 toVersion
    );

    function setUp() public {
        phUSD = new FlaxToken();
        oldStaker = new StableStakerV2(phUSD, owner);
        newStaker = new StableStakerV2(phUSD, owner);

        // both instances may mint phUSD
        phUSD.setMinter(address(oldStaker), true);
        phUSD.setMinter(address(newStaker), true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oldStaker.addToken(address(usdc));
        newStaker.addToken(address(usdc));
        oldStaker.phUSDPerDay(address(usdc), PER_DAY);
        newStaker.phUSDPerDay(address(usdc), PER_DAY);

        migrator = new CrossVersionMigrator(
            IStableStakerMigratable(address(oldStaker)), IStableStakerMigratable(address(newStaker)), owner
        );
        oldStaker.setMigrator(address(migrator));
        newStaker.setMigrator(address(migrator));

        // Fund users but do NOT stake yet — strategy-routing tests must wire setYieldStrategy on the
        // empty pool BEFORE the first stake (empty-pool gate, story 010).
        usdc.mint(alice, 100e6);
        usdc.mint(bob, 300e6);
        vm.prank(alice);
        usdc.approve(address(oldStaker), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(oldStaker), type(uint256).max);
    }

    function _stakeAliceAndBob() internal {
        vm.prank(alice);
        oldStaker.stake(address(usdc), 100e6);
        vm.prank(bob);
        oldStaker.stake(address(usdc), 300e6);
    }

    function _fundAndStake(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(oldStaker), type(uint256).max);
        oldStaker.stake(address(usdc), amt);
        vm.stopPrank();
    }

    function _users() internal view returns (address[] memory users) {
        users = new address[](2);
        users[0] = alice;
        users[1] = bob;
    }

    /// @dev Wire the OLD staker's USDC principal through a MockYieldStrategy, then stake alice and
    ///      bob. Wiring happens FIRST (empty-pool gate).
    function _routeOldThroughStrategy() internal returns (MockYieldStrategy strategy) {
        strategy = new MockYieldStrategy();
        strategy.setClient(address(oldStaker), true);
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
        _stakeAliceAndBob();
    }

    // ============================== CONSTRUCTION ==============================

    function test_constructor_pinsBothEndsImmutably() public view {
        assertEq(address(migrator.oldStaker()), address(oldStaker));
        assertEq(address(migrator.newStaker()), address(newStaker));
        assertEq(migrator.owner(), owner);
    }

    function test_constructor_rejectsZeroStakers() public {
        vm.expectRevert(bytes("Migrator: zero old staker"));
        new CrossVersionMigrator(
            IStableStakerMigratable(address(0)), IStableStakerMigratable(address(newStaker)), owner
        );

        vm.expectRevert(bytes("Migrator: zero new staker"));
        new CrossVersionMigrator(
            IStableStakerMigratable(address(oldStaker)), IStableStakerMigratable(address(0)), owner
        );
    }

    function test_constructor_rejectsAliasedStakers() public {
        vm.expectRevert(bytes("Migrator: aliased stakers"));
        new CrossVersionMigrator(
            IStableStakerMigratable(address(oldStaker)), IStableStakerMigratable(address(oldStaker)), owner
        );
    }

    // ============================== DESTINATION PRE-FLIGHT ==============================
    //
    // `initiateMigration` is a one-way door on the SOURCE: it realizes the strategy position,
    // decouples the strategy and latches poolState to Migrating. Every test below therefore asserts
    // not only the revert string but that the source pool is still `Active` afterwards — i.e. that
    // the irreversible call never happened.

    function test_initiateMigration_revertsWhenDestinationTokenNotRegistered() public {
        _stakeAliceAndBob();

        // A destination that was never `addToken`ed, but IS wired — so registration is what bites.
        StableStakerV2 unregisteredDest = new StableStakerV2(phUSD, owner);
        CrossVersionMigrator preflight = new CrossVersionMigrator(
            IStableStakerMigratable(address(oldStaker)), IStableStakerMigratable(address(unregisteredDest)), owner
        );
        oldStaker.setMigrator(address(preflight));
        unregisteredDest.setMigrator(address(preflight));

        vm.expectRevert(bytes("Migrator: destination token not registered"));
        preflight.initiateMigration(address(usdc));

        // the one-way door did not open
        assertTrue(oldStaker.poolState(address(usdc)) == StableStakerV2.PoolState.Active);
        (,,, uint256 oldTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(oldTotal, 400e6);
    }

    function test_initiateMigration_revertsWhenDestinationNotWired() public {
        _stakeAliceAndBob();

        // `newStaker` has USDC registered but still points at the setUp migrator, not this one.
        CrossVersionMigrator unwired = new CrossVersionMigrator(
            IStableStakerMigratable(address(oldStaker)), IStableStakerMigratable(address(newStaker)), owner
        );
        oldStaker.setMigrator(address(unwired));
        assertEq(newStaker.migrator(), address(migrator));

        vm.expectRevert(bytes("Migrator: destination not wired"));
        unwired.initiateMigration(address(usdc));

        assertTrue(oldStaker.poolState(address(usdc)) == StableStakerV2.PoolState.Active);
        (,,, uint256 oldTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(oldTotal, 400e6);
    }

    /// @notice A destination exposing neither `migrator()` nor `getStakedTokens()` is UNVERIFIABLE,
    ///         not wrong. Both probes fail open and the migration proceeds, so the migrator stays
    ///         valid for staker shapes that do not exist yet (section (A)). In particular a failed
    ///         `migrator()` probe must not masquerade as a definitive `address(0)` answer — that
    ///         would compare unequal to the migrator and hard-revert here.
    function test_initiateMigration_probeFailureIsAdvisoryAndPassesThrough() public {
        _stakeAliceAndBob();

        ProbelessStaker probeless = new ProbelessStaker();
        CrossVersionMigrator advisory = new CrossVersionMigrator(
            IStableStakerMigratable(address(oldStaker)), IStableStakerMigratable(address(probeless)), owner
        );
        oldStaker.setMigrator(address(advisory));

        // sanity: the destination really does answer neither probe
        (bool okMigrator,) = address(probeless).staticcall(abi.encodeWithSignature("migrator()"));
        (bool okTokens,) = address(probeless).staticcall(abi.encodeWithSignature("getStakedTokens()"));
        assertFalse(okMigrator);
        assertFalse(okTokens);

        advisory.initiateMigration(address(usdc));

        assertTrue(oldStaker.poolState(address(usdc)) == StableStakerV2.PoolState.Migrating);
    }

    /// @notice The setUp harness already satisfies both preconditions, so the guards are invisible on
    ///         the happy path.
    function test_initiateMigration_passesPreflightOnCorrectlyWiredPair() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        assertTrue(oldStaker.poolState(address(usdc)) == StableStakerV2.PoolState.Migrating);
    }

    // ============================== HAPPY PATH ==============================

    function test_happyPath_migrationPreservesEveryUsersPrincipal() public {
        _stakeAliceAndBob();
        vm.warp(block.timestamp + 1 days);

        uint256 pendingAlice = oldStaker.pendingReward(address(usdc), alice);
        uint256 pendingBob = oldStaker.pendingReward(address(usdc), bob);
        assertGt(pendingAlice, 0);
        assertGt(pendingBob, 0);

        migrator.initiateMigration(address(usdc));
        migrator.migrate(address(usdc), _users());

        // old staker fully drained
        (uint256 aOld,) = oldStaker.userInfo(address(usdc), alice);
        (uint256 bOld,) = oldStaker.userInfo(address(usdc), bob);
        assertEq(aOld, 0);
        assertEq(bOld, 0);
        (,,, uint256 oldTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(oldTotal, 0);
        assertEq(oldStaker.stakerCount(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(oldStaker)), 0);

        // new staker credited with exactly the same principal
        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6);
        assertEq(bNew, 300e6);
        (,,, uint256 newTotal) = newStaker.poolInfo(address(usdc));
        assertEq(newTotal, 400e6);
        assertEq(usdc.balanceOf(address(newStaker)), 400e6);

        // earned phUSD was minted to the users on the way out (story 022: pending + any
        // `unclaimedReward` backlog; neither user booked one here)
        assertEq(phUSD.balanceOf(alice), pendingAlice);
        assertEq(phUSD.balanceOf(bob), pendingBob);
        assertEq(oldStaker.unclaimedReward(address(usdc), alice), 0);
        assertEq(oldStaker.unclaimedReward(address(usdc), bob), 0);

        // nothing stranded in the migrator
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    function test_migrate_emitsBothVersionsInEvent() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));

        vm.expectEmit(true, false, false, true, address(migrator));
        emit MigratedAcrossVersions(address(usdc), 2, 400e6, oldStaker.STAKER_VERSION(), newStaker.STAKER_VERSION());
        migrator.migrate(address(usdc), _users());
    }

    function test_migrate_emptyBatchEmitsZeroesAndReturns() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));

        address[] memory none = new address[](0);
        vm.expectEmit(true, false, false, true, address(migrator));
        emit MigratedAcrossVersions(address(usdc), 0, 0, 2, 2);
        migrator.migrate(address(usdc), none);

        // nothing moved
        (,,, uint256 newTotal) = newStaker.poolInfo(address(usdc));
        assertEq(newTotal, 0);
    }

    // ============================== VERSION PROBE ==============================

    function test_versionOf_readsSTAKER_VERSIONWhenPresent() public view {
        assertEq(migrator.versionOf(address(oldStaker)), oldStaker.STAKER_VERSION());
        assertEq(migrator.versionOf(address(newStaker)), newStaker.STAKER_VERSION());
    }

    function test_versionOf_readsAnArbitraryFutureVersion() public {
        FutureVersionStaker future = new FutureVersionStaker();
        assertEq(migrator.versionOf(address(future)), 7);
    }

    function test_versionOf_revertingProbeIsReportedAsVersionOne() public {
        // Mirrors the live V1 deployment: a contract with no STAKER_VERSION getter at all.
        VersionlessStaker v1 = new VersionlessStaker();
        assertEq(migrator.versionOf(address(v1)), 1);
    }

    function test_versionOf_nonContractIsReportedAsVersionOne() public view {
        // An EOA returns empty data rather than reverting; that is version 1 too.
        assertEq(migrator.versionOf(alice), 1);
    }

    // ============================== ZERO-CREDIT DUST USER ==============================

    /// @notice A dust user whose underwater snapshot credit floors to zero must be SKIPPED, not
    ///         passed to `depositFor` (which reverts on a zero amount and would take the whole batch
    ///         down with it). Open item L-01 / ss12l1.
    function test_zeroCreditDustUser_doesNotRevertTheBatch() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        _fundAndStake(carol, 1); // 1 wei of USDC
        strategy.setValueFactorBps(9_000); // 10% loss ⇒ carol's credit floors to 0

        migrator.initiateMigration(address(usdc));
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq((1 * R) / P, 0, "carol's snapshot credit must floor to zero for this test to bite");

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;

        // Only alice and bob are credited; the batch does not revert.
        migrator.migrate(address(usdc), users);

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        (uint256 cNew,) = newStaker.userInfo(address(usdc), carol);
        assertEq(aNew, (100e6 * R) / P);
        assertEq(bNew, (300e6 * R) / P);
        assertEq(cNew, 0);

        // carol is still fully exited from the old staker
        (uint256 cOld,) = oldStaker.userInfo(address(usdc), carol);
        assertEq(cOld, 0);
        assertEq(oldStaker.stakerCount(address(usdc)), 0);
    }

    // ============================== UNDERWATER ==============================

    /// @notice Below par every user takes the SAME uniform haircut and the migration still completes.
    ///         This contract does NOT top the haircut up — `InPlaceMigrator` owns that flow.
    function test_underwater_creditsUniformHaircutAndDoesNotRevert() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000); // 10% loss

        migrator.initiateMigration(address(usdc));
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(R, 360e6);
        assertEq(P, 400e6);

        migrator.migrate(address(usdc), _users());

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, (100e6 * R) / P); // 90e6
        assertEq(bNew, (300e6 * R) / P); // 270e6

        // strictly below principal: no top-up happened here, by design
        assertLt(aNew, 100e6);
        assertLt(bNew, 300e6);

        // sum of credits never exceeds what the migrator received, and nothing is stranded
        assertLe(aNew + bNew, R);
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // ============================== ACCESS CONTROL ==============================

    function test_initiateMigration_nonOwnerReverts() public {
        _stakeAliceAndBob();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        migrator.initiateMigration(address(usdc));
    }

    function test_migrate_nonOwnerReverts() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        migrator.migrate(address(usdc), _users());
    }
}
