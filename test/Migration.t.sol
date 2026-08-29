// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "../src/CrossVersionMigrator.sol";
import "../src/interfaces/IStableStaker.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Terminal migration mode: an operator engages a one-time (R, P) snapshot on the old staker
///         and moves users to the new staker. Payouts are a fixed pro-rata of the snapshot, so they are
///         identical across batch composition, ordering, and batch-vs-self exit.
contract MigrationTest is Test {
    FlaxToken internal phUSD;
    StableStakerV2 internal oldStaker;
    StableStakerV2 internal newStaker;
    CrossVersionMigrator internal migrator;
    MockERC20 internal usdc;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant PER_DAY = 86_400 ether; // 1e18 / second

    /// @dev Mirrors {StableStakerV2.PrincipalDivergence} for vm.expectEmit.
    event PrincipalDivergence(address indexed token, uint256 claimed, uint256 booked, uint256 relinquished);

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

        // Fund users but do NOT stake yet — tests that need pre-staked positions
        // call _stakeAliceAndBob() explicitly. This allows strategy-routing tests to
        // wire setYieldStrategy on the empty pool BEFORE the first stake (required by the
        // empty-pool gate introduced in story 010).
        usdc.mint(alice, 100e6);
        usdc.mint(bob, 300e6);
        vm.prank(alice);
        usdc.approve(address(oldStaker), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(oldStaker), type(uint256).max);
    }

    /// @dev Stake alice (100e6) and bob (300e6) into oldStaker. Call this AFTER any
    ///      setYieldStrategy wiring so the empty-pool gate is satisfied.
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

    /// @dev Wire the OLD staker's USDC principal through a MockYieldStrategy and then stake alice
    ///      and bob. Wiring happens FIRST (empty-pool gate: pool must be empty at wire time).
    ///      Returns the strategy so the test can set the value factor.
    function _routeOldThroughStrategy() internal returns (MockYieldStrategy strategy) {
        strategy = new MockYieldStrategy();
        strategy.setClient(address(oldStaker), true);
        // Wire on empty pool (story 010 gate: totalStaked must be 0 at this point).
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
        // Stake alice and bob AFTER wiring so principal flows through the strategy.
        _stakeAliceAndBob();
    }

    // ============================== END-TO-END (NO STRATEGY) ==============================

    function test_endToEnd_migration_preservesPositionsAndRewards() public {
        _stakeAliceAndBob();
        // accrue rewards in v1 for a day
        vm.warp(block.timestamp + 1 days);

        uint256 pendingAlice = oldStaker.pendingReward(address(usdc), alice);
        uint256 pendingBob = oldStaker.pendingReward(address(usdc), bob);
        assertGt(pendingAlice, 0);
        assertGt(pendingBob, 0);

        migrator.initiateMigration(address(usdc));
        migrator.migrate(address(usdc), _users());

        // --- v1 fully drained ---
        (uint256 aOld,) = oldStaker.userInfo(address(usdc), alice);
        (uint256 bOld,) = oldStaker.userInfo(address(usdc), bob);
        assertEq(aOld, 0);
        assertEq(bOld, 0);
        (,,, uint256 oldTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(oldTotal, 0);
        assertEq(oldStaker.stakerCount(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(oldStaker)), 0);

        // --- earned rewards minted to the users during batchMigrate (same block => exact) ---
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

    // ============================== PERMISSION GUARDS ==============================

    function test_migrate_onlyOwner() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(alice);
        vm.expectRevert();
        migrator.migrate(address(usdc), users);
    }

    function test_initiateMigration_onlyOwner_onMigrator() public {
        vm.prank(alice);
        vm.expectRevert();
        migrator.initiateMigration(address(usdc));
    }

    function test_batchMigrate_onlyMigrator() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: only migrator"));
        oldStaker.batchMigrate(address(usdc), users);
    }

    function test_initiateMigration_onlyMigrator_onStaker() public {
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: only migrator"));
        oldStaker.initiateMigration(address(usdc));
    }

    function test_depositFor_onlyMigrator() public {
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: only migrator"));
        newStaker.depositFor(address(usdc), alice, 1e6);
    }

    // Migration must work even while v1 is paused (incident response).
    function test_migration_worksWhilePaused() public {
        _stakeAliceAndBob();
        oldStaker.setPauser(owner);
        oldStaker.pause();
        vm.warp(block.timestamp + 1 days);

        migrator.initiateMigration(address(usdc));
        migrator.migrate(address(usdc), _users());

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        assertEq(aNew, 100e6);
    }

    // ============================== CORE: ORDER / METHOD INDEPENDENCE ==============================

    // The ss2m1 fix: two users with EQUAL principal under an underwater AMM strategy must receive
    // IDENTICAL payouts across every exit permutation. We give alice & bob equal principal in a
    // fresh deployment and compare the four permutations.
    function test_orderMethodIndependence_equalPrincipal_underwater() public {
        // Helper that builds a fresh equal-principal underwater system, runs `mode`, and returns
        // (alicePayout, bobPayout). mode: 0=oneBatch, 1=separateBatches, 2=aliceSelfThenBob,
        // 3=reversedOrderBatch.
        uint256 P_EACH = 200e6;
        uint16 FACTOR = 9_000; // 10% underwater

        (uint256 a0, uint256 b0) = _runPermutation(P_EACH, FACTOR, 0);
        (uint256 a1, uint256 b1) = _runPermutation(P_EACH, FACTOR, 1);
        (uint256 a2, uint256 b2) = _runPermutation(P_EACH, FACTOR, 2);
        (uint256 a3, uint256 b3) = _runPermutation(P_EACH, FACTOR, 3);

        // Equal principal => equal payout, in EVERY permutation.
        assertEq(a0, b0, "perm0 a!=b");
        assertEq(a1, b1, "perm1 a!=b");
        assertEq(a2, b2, "perm2 a!=b");
        assertEq(a3, b3, "perm3 a!=b");

        // And the payout is identical ACROSS permutations (method/order independence).
        assertEq(a0, a1);
        assertEq(a0, a2);
        assertEq(a0, a3);
        assertEq(b0, b1);
        assertEq(b0, b2);
        assertEq(b0, b3);

        // Sanity: the haircut actually applied (under par), so this is a non-trivial equality.
        assertEq(a0, (P_EACH * FACTOR) / 10_000); // 180e6
    }

    /// @dev Build a fresh old/new staker pair with alice & bob each staking `pEach`, route through an
    ///      underwater strategy (`factorBps`), engage migration, then exit via `mode`. Returns each
    ///      user's realized payout (new-staker credit for batch, wallet delta for self-migrate).
    function _runPermutation(uint256 pEach, uint16 factorBps, uint8 mode)
        internal
        returns (uint256 alicePayout, uint256 bobPayout)
    {
        // Fresh isolated deployment so permutations don't interfere.
        StableStakerV2 oStaker = new StableStakerV2(phUSD, owner);
        StableStakerV2 nStaker = new StableStakerV2(phUSD, owner);
        phUSD.setMinter(address(oStaker), true);
        phUSD.setMinter(address(nStaker), true);
        oStaker.addToken(address(usdc));
        nStaker.addToken(address(usdc));
        oStaker.phUSDPerDay(address(usdc), PER_DAY);
        nStaker.phUSDPerDay(address(usdc), PER_DAY);
        CrossVersionMigrator m = new CrossVersionMigrator(
            IStableStakerMigratable(address(oStaker)), IStableStakerMigratable(address(nStaker)), owner
        );
        oStaker.setMigrator(address(m));
        nStaker.setMigrator(address(m));

        // Wire the strategy on the EMPTY pool BEFORE staking (empty-pool gate, story 010).
        MockYieldStrategy strat = new MockYieldStrategy();
        strat.setClient(address(oStaker), true);
        oStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strat)));
        strat.setValueFactorBps(factorBps);

        // equal-principal stakes AFTER wiring
        usdc.mint(alice, pEach);
        usdc.mint(bob, pEach);
        vm.startPrank(alice);
        usdc.approve(address(oStaker), type(uint256).max);
        oStaker.stake(address(usdc), pEach);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(oStaker), type(uint256).max);
        oStaker.stake(address(usdc), pEach);
        vm.stopPrank();

        m.initiateMigration(address(usdc));

        if (mode == 0) {
            // both in one batch [alice, bob]
            address[] memory u = new address[](2);
            u[0] = alice;
            u[1] = bob;
            m.migrate(address(usdc), u);
            alicePayout = _newCredit(nStaker, alice);
            bobPayout = _newCredit(nStaker, bob);
        } else if (mode == 1) {
            // separate batches: [alice] then [bob]
            address[] memory ua = new address[](1);
            ua[0] = alice;
            m.migrate(address(usdc), ua);
            address[] memory ub = new address[](1);
            ub[0] = bob;
            m.migrate(address(usdc), ub);
            alicePayout = _newCredit(nStaker, alice);
            bobPayout = _newCredit(nStaker, bob);
        } else if (mode == 2) {
            // alice self-migrates (wallet), then bob via batch
            uint256 aBefore = usdc.balanceOf(alice);
            vm.prank(alice);
            oStaker.userMigrate(address(usdc));
            alicePayout = usdc.balanceOf(alice) - aBefore;
            address[] memory ub = new address[](1);
            ub[0] = bob;
            m.migrate(address(usdc), ub);
            bobPayout = _newCredit(nStaker, bob);
        } else {
            // reversed-order batch [bob, alice]
            address[] memory u = new address[](2);
            u[0] = bob;
            u[1] = alice;
            m.migrate(address(usdc), u);
            alicePayout = _newCredit(nStaker, alice);
            bobPayout = _newCredit(nStaker, bob);
        }
    }

    function _newCredit(StableStakerV2 s, address who) internal view returns (uint256 amt) {
        (amt,) = s.userInfo(address(usdc), who);
    }

    // ============================== HEALTHY = PAR ==============================

    // valueFactorBps >= 10000: every user credited exactly p_i; new staker holds Σ p_i; no user gets
    // yield; any above-par yield stays in the (now-decoupled) strategy, not credited.
    function test_healthy_atOrAbovePar_creditsParNoYield() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(11_000); // 10% above par (yield)

        migrator.initiateMigration(address(usdc));
        migrator.migrate(address(usdc), _users());

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6); // exactly principal, no yield
        assertEq(bNew, 300e6);

        (,,, uint256 newTotal) = newStaker.poolInfo(address(usdc));
        assertEq(newTotal, 400e6);
        assertEq(usdc.balanceOf(address(newStaker)), 400e6);

        // Above-par realized R was capped at par by withdraw, so R == P == 400e6: no surplus reached
        // anyone, and no above-par yield was credited.
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(R, 400e6);
        assertEq(P, 400e6);
        // no dust stranded in the migrator
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // ============================== UNDERWATER = UNIFORM HAIRCUT ==============================

    // valueFactorBps < 10000: all users (batch and self) credited floor(p_i * R / P); Σ credit <= R;
    // dust <= N wei.
    function test_underwater_uniformHaircut_batchAndSelf() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000); // 10% loss

        migrator.initiateMigration(address(usdc));
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(R, 360e6); // 400e6 * 0.9
        assertEq(P, 400e6);

        // alice self-migrates, bob via batch
        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oldStaker.userMigrate(address(usdc));
        uint256 aliceCredit = usdc.balanceOf(alice) - aBefore;

        address[] memory ub = new address[](1);
        ub[0] = bob;
        migrator.migrate(address(usdc), ub);
        (uint256 bobCredit,) = newStaker.userInfo(address(usdc), bob);

        assertEq(aliceCredit, (100e6 * R) / P); // 90e6
        assertEq(bobCredit, (300e6 * R) / P); // 270e6

        uint256 sumCredit = aliceCredit + bobCredit;
        assertLe(sumCredit, R);
        // dust bounded by number of distinct exits (<= 2 here)
        assertLe(R - sumCredit, 2);
    }

    function test_underwater_dustBound_uglyFactor() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(8_333); // non-clean divisions

        migrator.initiateMigration(address(usdc));
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));

        migrator.migrate(address(usdc), _users());

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        uint256 credited = aNew + bNew;

        assertEq(aNew, (100e6 * R) / P);
        assertEq(bNew, (300e6 * R) / P);
        assertLe(credited, R);
        // floor dust strictly bounded by number of credited users
        assertLt(R - credited, 2);
    }

    // ============================== CONSERVATION ==============================

    // Σ credit + idle-residual == R exactly; the residual stays in the terminal staker (owner-rescuable).
    function test_conservation_sumCreditPlusResidualEqualsR() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(8_333);

        migrator.initiateMigration(address(usdc));
        (uint256 R,) = oldStaker.migrationInfo(address(usdc));

        // realized R now sits idle in the old staker
        assertEq(usdc.balanceOf(address(oldStaker)), R);

        migrator.migrate(address(usdc), _users());

        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        uint256 credited = aNew + bNew;

        // The credited total was transferred out of the old staker; the residual stays behind.
        uint256 residual = usdc.balanceOf(address(oldStaker));
        assertEq(credited + residual, R);

        // After everyone migrated, totalStaked == 0, so the owner can rescue the residual dust.
        (,,, uint256 oldTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(oldTotal, 0);
        if (residual > 0) {
            oldStaker.rescueERC20(address(usdc), owner, residual);
            assertEq(usdc.balanceOf(address(oldStaker)), 0);
        }
    }

    // ============================== STATE GUARDS ==============================

    function test_guard_stakeBlockedWhileMigrating() public {
        migrator.initiateMigration(address(usdc));
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(oldStaker), type(uint256).max);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.stake(address(usdc), 1e6);
        vm.stopPrank();
    }

    function test_guard_withdrawBlockedWhileMigrating() public {
        migrator.initiateMigration(address(usdc));
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.withdraw(address(usdc), 1e6);
    }

    function test_guard_emergencyWithdrawBlockedWhileMigrating() public {
        migrator.initiateMigration(address(usdc));
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.emergencyWithdraw(address(usdc));
    }

    function test_guard_depositForBlockedOnMigratingStaker() public {
        migrator.initiateMigration(address(usdc));
        // depositFor must come from the migrator; it is blocked on the OLD (migrating) staker.
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.depositFor(address(usdc), alice, 1e6);
    }

    function test_guard_userMigrateRevertsWhenNotMigrating() public {
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: pool not migrating"));
        oldStaker.userMigrate(address(usdc));
    }

    function test_guard_batchMigrateRevertsWithoutInitiate() public {
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: pool not migrating"));
        oldStaker.batchMigrate(address(usdc), _users());
    }

    function test_guard_initiateMigrationRevertsWhenAlreadyActive() public {
        migrator.initiateMigration(address(usdc));
        // terminal: cannot be re-initiated (pool is no longer Active)
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.initiateMigration(address(usdc));
    }

    // ============================== REWARDS STILL MINTED ==============================

    // Each migrating user's frozen pending phUSD is minted regardless of the principal haircut, and
    // emissions are frozen at the snapshot (_updatePool no-op while active).
    function test_rewards_frozenAtSnapshotAndMinted() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000);

        vm.warp(block.timestamp + 1 days);
        uint256 pendingAlice = oldStaker.pendingReward(address(usdc), alice);
        uint256 pendingBob = oldStaker.pendingReward(address(usdc), bob);
        assertGt(pendingAlice, 0);

        migrator.initiateMigration(address(usdc));

        // Emissions are now frozen: warping forward does NOT grow pending.
        uint256 frozenAlice = oldStaker.pendingReward(address(usdc), alice);
        vm.warp(block.timestamp + 5 days);
        assertEq(oldStaker.pendingReward(address(usdc), alice), frozenAlice);

        migrator.migrate(address(usdc), _users());

        // Pending minted in full (frozen value), independent of the 10% principal haircut.
        assertEq(phUSD.balanceOf(alice), pendingAlice);
        assertEq(phUSD.balanceOf(bob), pendingBob);
    }

    // ============================== NO-STRATEGY POOL ==============================

    // initiateMigration on a pool with no strategy sets R = P (idle principal); credits par.
    function test_noStrategy_setsRequalP_creditsPar() public {
        _stakeAliceAndBob(); // no strategy: principal sits idle in the contract
        migrator.initiateMigration(address(usdc));
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(uint256(oldStaker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Migrating));
        assertEq(R, 400e6);
        assertEq(P, 400e6);

        migrator.migrate(address(usdc), _users());
        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6);
        assertEq(bNew, 300e6);
        assertEq(usdc.balanceOf(address(oldStaker)), 0); // fully forwarded
    }

    // ============================== POST-CHECK GUARD (incomplete exit) ==============================

    // The post-check survives the ss14m1 self-heal, and this test now proves what is left of it: a
    // strategy whose relinquishPrincipal does not actually write the principal down still trips the
    // revert. UnderRealizingStrategy realizes only half the requested principal per withdraw AND
    // stubs relinquishPrincipal as a no-op, so the reconciliation cannot clear the residual and
    // "StableStaker: incomplete exit" fires. The self-heal removed the brick for the KNOWN divergence
    // (setYieldStrategy's idle sweep, which a real relinquish clears); it did not remove the guard
    // against a strategy that cannot honestly exit. Do not make the stub functional.
    function test_postCheck_incompleteExitReverts() public {
        // Wire the under-realizing strategy on the EMPTY pool first, then stake.
        UnderRealizingStrategy strat = new UnderRealizingStrategy();
        strat.setClient(address(oldStaker), true);
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strat)));
        _stakeAliceAndBob(); // stake AFTER wiring (empty-pool gate)

        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: incomplete exit"));
        oldStaker.initiateMigration(address(usdc));
    }

    // ============================== TERMINAL / DECOUPLING ==============================

    // After initiateMigration the strategy wiring is cleared (decoupled) and allowance revoked.
    function test_initiate_decouplesStrategy() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        migrator.initiateMigration(address(usdc));
        assertEq(address(oldStaker.yieldStrategy(address(usdc))), address(0));
        assertEq(usdc.allowance(address(oldStaker), address(strategy)), 0);
    }

    // ============================== STATE MACHINE / LIFECYCLE (STORY 009) ==============================

    // Assert the legal operations for each state and that illegal ops revert with the new messages.
    function test_stateMachine_illegalOpsRevertPerState() public {
        _stakeAliceAndBob(); // need stakers present to test state-machine transitions
        // --- Active state: migration-only ops are rejected ---
        assertEq(uint256(oldStaker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Active));
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: pool not migrating"));
        oldStaker.batchMigrate(address(usdc), _users());
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: pool not migrating"));
        oldStaker.userMigrate(address(usdc));
        // finalizeAndReset is illegal while Active (pool not migrating)
        vm.expectRevert(bytes("StableStaker: pool not migrating"));
        oldStaker.finalizeAndReset(address(usdc));

        // --- Active -> Migrating ---
        migrator.initiateMigration(address(usdc));
        assertEq(uint256(oldStaker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Migrating));

        // While Migrating: stake / withdraw / setYieldStrategy / initiateMigration all revert.
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(oldStaker), type(uint256).max);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.stake(address(usdc), 1e6);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.withdraw(address(usdc), 1e6);
        vm.stopPrank();
        MockYieldStrategy fresh = new MockYieldStrategy();
        fresh.setClient(address(oldStaker), true);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(fresh)));
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: pool not active"));
        oldStaker.initiateMigration(address(usdc));

        // finalizeAndReset reverts while stakers / principal remain.
        vm.expectRevert(bytes("StableStaker: stakers remain"));
        oldStaker.finalizeAndReset(address(usdc));

        // Drain everyone out, then reset succeeds.
        vm.prank(address(migrator));
        oldStaker.batchMigrate(address(usdc), _users());
        assertEq(oldStaker.stakerCount(address(usdc)), 0);
        (,,, uint256 totalStaked) = oldStaker.poolInfo(address(usdc));
        assertEq(totalStaked, 0);

        oldStaker.finalizeAndReset(address(usdc));
        assertEq(uint256(oldStaker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Active));
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(R, 0);
        assertEq(P, 0);
    }

    // finalizeAndReset must reject a pool that still has principal even if the staker set is empty
    // (defense-in-depth: both invariants are checked independently).
    function test_finalizeAndReset_rejectsNonZeroPrincipal() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        // Migrate only alice out; bob's 300e6 principal remains -> totalStaked > 0, stakerCount > 0.
        address[] memory justAlice = new address[](1);
        justAlice[0] = alice;
        vm.prank(address(migrator));
        oldStaker.batchMigrate(address(usdc), justAlice);
        vm.expectRevert(bytes("StableStaker: stakers remain"));
        oldStaker.finalizeAndReset(address(usdc));
    }

    // End-to-end REVIVAL: stake -> push underwater -> initiateMigration -> eject everyone (batch + self)
    // verifying credits at min(R,P)/P -> finalizeAndReset -> setYieldStrategy(fresh) -> a NEW staker
    // stakes at par with correct fresh reward accounting, and no stale position can withdraw.
    function test_revival_endToEnd_underwaterEjectResetRestake() public {
        // Route old staker's principal through a strategy and push it 10% underwater.
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_000); // R = 0.9 * P

        // Accrue a day of rewards before migration so frozen pending is non-zero.
        vm.warp(block.timestamp + 1 days);
        uint256 pendingAlice = oldStaker.pendingReward(address(usdc), alice);

        migrator.initiateMigration(address(usdc));
        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(P, 400e6);
        assertEq(R, 360e6); // 90% of 400e6

        // Alice self-migrates; Bob is batch-migrated. Both paid p_i * min(R,P)/P = 0.9 * p_i.
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oldStaker.userMigrate(address(usdc));
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, 90e6); // 0.9 * 100e6
        assertEq(phUSD.balanceOf(alice), pendingAlice); // frozen pending minted

        address[] memory justBob = new address[](1);
        justBob[0] = bob;
        vm.prank(address(migrator));
        uint256[] memory amts = oldStaker.batchMigrate(address(usdc), justBob);
        assertEq(amts[0], 270e6); // 0.9 * 300e6 (migrator received the credit)

        // Pool is now fully drained.
        assertEq(oldStaker.stakerCount(address(usdc)), 0);
        (,,, uint256 drained) = oldStaker.poolInfo(address(usdc));
        assertEq(drained, 0);

        // Reset the SAME pool back to Active.
        vm.expectEmit(true, false, false, false);
        emit StableStakerV2.PoolReset(address(usdc));
        oldStaker.finalizeAndReset(address(usdc));
        assertEq(uint256(oldStaker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Active));

        // Wire a FRESH, at-par strategy (old wiring was cleared to address(0) at initiateMigration,
        // so 008's underwater guard is skipped here).
        MockYieldStrategy fresh = new MockYieldStrategy();
        fresh.setClient(address(oldStaker), true);
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(fresh)));

        // A brand-new staker (carol) can stake at par into the revived pool.
        address carol = address(0xCA401);
        usdc.mint(carol, 500e6);
        vm.startPrank(carol);
        usdc.approve(address(oldStaker), type(uint256).max);
        oldStaker.stake(address(usdc), 500e6);
        vm.stopPrank();
        (uint256 carolAmt,) = oldStaker.userInfo(address(usdc), carol);
        assertEq(carolAmt, 500e6);
        assertEq(fresh.principalOf(address(usdc), address(oldStaker)), 500e6);

        // Fresh reward accounting: rewards accrue from the reset, NOT retroactively over the frozen gap.
        // Carol is the only staker, so a day's emission accrues entirely to her.
        assertEq(oldStaker.pendingReward(address(usdc), carol), 0);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(oldStaker.pendingReward(address(usdc), carol), PER_DAY, 1e6);

        // No stale position survives: alice/bob were zeroed, so they cannot withdraw.
        (uint256 aStale,) = oldStaker.userInfo(address(usdc), alice);
        (uint256 bStale,) = oldStaker.userInfo(address(usdc), bob);
        assertEq(aStale, 0);
        assertEq(bStale, 0);
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: insufficient stake"));
        oldStaker.withdraw(address(usdc), 1);

        // Carol can withdraw her full principal at par from the revived pool.
        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        oldStaker.withdraw(address(usdc), 500e6);
        assertEq(usdc.balanceOf(carol) - carolBefore, 500e6);
    }

    // Paused revival: setYieldStrategy and finalizeAndReset succeed while paused (onlyOwner, no
    // whenNotPaused), but stake reverts until unpause.
    function test_revival_whilePaused() public {
        oldStaker.setPauser(owner);

        migrator.initiateMigration(address(usdc));
        oldStaker.pause();

        // Eject everyone (migration hooks are callable while paused).
        vm.prank(address(migrator));
        oldStaker.batchMigrate(address(usdc), _users());
        assertEq(oldStaker.stakerCount(address(usdc)), 0);

        // finalizeAndReset succeeds while paused.
        oldStaker.finalizeAndReset(address(usdc));
        assertEq(uint256(oldStaker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Active));

        // setYieldStrategy succeeds while paused.
        MockYieldStrategy fresh = new MockYieldStrategy();
        fresh.setClient(address(oldStaker), true);
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(fresh)));

        // stake is whenNotPaused -> reverts until unpause.
        address carol = address(0xCA402);
        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(oldStaker), type(uint256).max);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        oldStaker.stake(address(usdc), 100e6);
        vm.stopPrank();

        // After unpause, stake works.
        oldStaker.unpause();
        vm.prank(carol);
        oldStaker.stake(address(usdc), 100e6);
        (uint256 carolAmt,) = oldStaker.userInfo(address(usdc), carol);
        assertEq(carolAmt, 100e6);
    }

    // Idle-hold revival: after finalizeAndReset the pool is empty; wire a fresh strategy first,
    // then carol stakes through it at par. This confirms the revived-empty-pool wiring works and
    // that a subsequent stake routes through the strategy with no desync.
    // NOTE: The original scenario (stake idle THEN wire) is now forbidden by the empty-pool gate.
    //       Wiring after staking desyncs totalStaked from strategy.principalOf on AMM strategies.
    //       The correct order is always: wire on empty pool -> stake -> withdraw.
    function test_revival_idleHoldThenStrategySweep() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        vm.prank(address(migrator));
        oldStaker.batchMigrate(address(usdc), _users());
        oldStaker.finalizeAndReset(address(usdc));

        // Pool is Active and empty (yieldStrategy was cleared by initiateMigration).
        assertEq(address(oldStaker.yieldStrategy(address(usdc))), address(0));
        (,,, uint256 emptyTotal) = oldStaker.poolInfo(address(usdc));
        assertEq(emptyTotal, 0);

        // Wire the fresh strategy on the EMPTY revived pool (gate satisfied).
        MockYieldStrategy fresh = new MockYieldStrategy();
        fresh.setClient(address(oldStaker), true);
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(fresh)));
        assertEq(address(oldStaker.yieldStrategy(address(usdc))), address(fresh));

        // Carol stakes AFTER wiring: principal routes through the fresh strategy at par.
        address carol = address(0xCA403);
        usdc.mint(carol, 250e6);
        vm.startPrank(carol);
        usdc.approve(address(oldStaker), type(uint256).max);
        oldStaker.stake(address(usdc), 250e6);
        vm.stopPrank();

        (uint256 carolAmt,) = oldStaker.userInfo(address(usdc), carol);
        assertEq(carolAmt, 250e6);
        assertEq(fresh.principalOf(address(usdc), address(oldStaker)), 250e6);
        assertEq(usdc.balanceOf(address(oldStaker)), 0); // no idle; principal in strategy

        // Carol withdraws full principal at par from the strategy-backed pool — no desync.
        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        oldStaker.withdraw(address(usdc), 250e6);
        assertEq(usdc.balanceOf(carol) - carolBefore, 250e6);
        (,,, uint256 totalAfter) = oldStaker.poolInfo(address(usdc));
        assertEq(totalAfter, 0);
    }

    // ================= SELF-HEAL: SWEPT PRINCIPAL DIVERGENCE (audit-14 ss14m1 / ss14l8) =================

    /// @dev Reproduces ss14m1. {StableStakerV2.setYieldStrategy}'s idle sweep books protocol money
    ///      (buffer, dust, donations) against this contract, so `strategy.principalOf` ends up ABOVE
    ///      `poolInfo.totalStaked`. Before the self-heal, initiateMigration reverted with
    ///      "StableStaker: incomplete exit" and terminal migration was permanently bricked. It must
    ///      now relinquish the excess and succeed.
    function test_initiate_selfHealsSweptDivergence() public {
        // Donation / set-aside buffer sitting idle while the pool is still EMPTY.
        usdc.mint(address(oldStaker), 50e6);

        MockYieldStrategy strategy = new MockYieldStrategy();
        strategy.setClient(address(oldStaker), true);
        // The sweep books the 50e6 as staker principal; totalStaked stays 0.
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
        assertEq(strategy.principalOf(address(usdc), address(oldStaker)), 50e6);

        _stakeAliceAndBob(); // P = 400e6 but principalOf = 450e6 => 50e6 divergence

        (,,, uint256 P) = oldStaker.poolInfo(address(usdc));
        assertEq(P, 400e6);
        assertEq(strategy.principalOf(address(usdc), address(oldStaker)), 450e6);

        vm.expectEmit(true, false, false, true, address(oldStaker));
        emit PrincipalDivergence(address(usdc), 400e6, 50e6, 50e6);
        migrator.initiateMigration(address(usdc));

        // The strategy no longer books anything against the staker: the post-check passed.
        assertEq(strategy.principalOf(address(usdc), address(oldStaker)), 0);
        (uint256 R, uint256 snapshot) = oldStaker.migrationInfo(address(usdc));
        assertEq(snapshot, 400e6);
        assertEq(R, 400e6);
    }

    /// @dev PrincipalDivergence fires on a CLEAN migration too (booked == 0). Absence of the log must
    ///      mean "the migration did not happen", never "it happened and reconciled nothing".
    function test_initiate_principalDivergence_emittedOnCleanMigration() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy(); // principalOf == totalStaked

        vm.expectEmit(true, false, false, true, address(oldStaker));
        emit PrincipalDivergence(address(usdc), 400e6, 0, 0);
        migrator.initiateMigration(address(usdc));

        assertEq(strategy.principalOf(address(usdc), address(oldStaker)), 0);
    }

    /// @dev With NO strategy wired there is nothing to read or relinquish; the short-circuit must hold
    ///      (calling into address(0) would revert) and the event still fires with booked == 0.
    function test_initiate_principalDivergence_emittedWithNoStrategy() public {
        _stakeAliceAndBob();
        assertEq(address(oldStaker.yieldStrategy(address(usdc))), address(0));

        vm.expectEmit(true, false, false, true, address(oldStaker));
        emit PrincipalDivergence(address(usdc), 400e6, 0, 0);
        migrator.initiateMigration(address(usdc));

        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(R, 400e6);
        assertEq(P, 400e6);
    }

    /// @dev ss14l8: R is measured from this contract's own balance, so idle set-aside buffer counts
    ///      toward the migration payout. A 5% underwater strategy delivers only 380e6 of the 400e6
    ///      principal; the 20e6 buffer parked on the staker closes the gap and nobody is haircut.
    ///      Measured from the strategy payout alone (the old behaviour) R would be 380e6, giving
    ///      alice 95e6 and bob 285e6.
    function test_initiate_realizedCountsSetAsideBuffer_belowPar() public {
        MockYieldStrategy strategy = _routeOldThroughStrategy();
        strategy.setValueFactorBps(9_500);

        // Buffer parked AFTER wiring, so it is idle on the staker rather than swept into the strategy.
        usdc.mint(address(oldStaker), 20e6);

        migrator.initiateMigration(address(usdc));

        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(P, 400e6);
        assertEq(R, 400e6); // 380e6 realized + 20e6 buffer == par

        migrator.migrate(address(usdc), _users());
        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6); // not 95e6
        assertEq(bNew, 300e6); // not 285e6
    }

    /// @dev R is capped at P: an above-par balance pays principal exactly and never more, and the
    ///      surplus stays protocol-owned on the staker.
    function test_initiate_realizedCappedAtPar() public {
        _routeOldThroughStrategy();
        // Above-par donation parked on the staker after wiring: balance at exit time is 475e6.
        usdc.mint(address(oldStaker), 75e6);

        migrator.initiateMigration(address(usdc));

        (uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertEq(P, 400e6);
        assertEq(R, 400e6);

        migrator.migrate(address(usdc), _users());
        (uint256 aNew,) = newStaker.userInfo(address(usdc), alice);
        (uint256 bNew,) = newStaker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6);
        assertEq(bNew, 300e6);
        assertEq(usdc.balanceOf(address(oldStaker)), 75e6); // surplus retained by the protocol
    }
}

/// @notice Strategy whose withdraw only realizes part of the requested principal per call, leaving
///         principalOf > 0 so {StableStakerV2.initiateMigration}'s post-check trips. Models a
///         tranche/queue vault that cannot exit atomically.
contract UnderRealizingStrategy is IYieldStrategy {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => uint256)) public principal;
    mapping(address => bool) public clients;

    function setClient(address client, bool a) external override {
        clients[client] = a;
    }

    function deposit(address token, uint256 amount, address recipient)
        external
        override
        returns (uint256 creditedPrincipal)
    {
        require(clients[msg.sender], "unauth");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        principal[token][recipient] += amount;
        return amount;
    }

    // Only ever realizes HALF the requested principal, leaving a residual ⇒ principalOf > 0.
    function withdraw(address token, uint256 amount, address recipient) external override {
        require(clients[msg.sender], "unauth");
        uint256 avail = principal[token][recipient];
        if (amount > avail) amount = avail;
        uint256 realize = amount / 2;
        principal[token][recipient] -= realize;
        if (realize > 0) IERC20(token).safeTransfer(recipient, realize);
    }

    function principalOf(address token, address account) external view override returns (uint256) {
        return principal[token][account];
    }

    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        return principal[token][account];
    }

    function balanceOf(address token, address account) external view override returns (uint256) {
        return principal[token][account];
    }

    function relinquishPrincipal(address, uint256) external override {}
    function relinquishPrincipalAsOwner(address, uint256) external override {}
    function emergencyWithdraw(uint256) external override {}
    function totalWithdrawal(address, address) external override {}

    function skimSurplus(address, address) external pure override returns (uint256) {
        return 0;
    }

    function getAuthorizedClients() external pure override returns (address[] memory) {
        return new address[](0);
    }
    function setSetAsideBuffer(address, uint256) external override {}

    function setAsideBufferSize(address) external pure override returns (uint256) {
        return 0;
    }

    function setSetAsideBufferRecipient(address) external override {}

    function setAsideBufferRecipient() external pure override returns (address) {
        return address(0);
    }
}
