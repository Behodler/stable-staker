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

/// @notice Terminal migration mode: an operator engages a one-time (R, P) snapshot on the old staker
///         and moves users to the new staker. Payouts are a fixed pro-rata of the snapshot, so they are
///         identical across batch composition, ordering, and batch-vs-self exit.
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

    function _users() internal view returns (address[] memory users) {
        users = new address[](2);
        users[0] = alice;
        users[1] = bob;
    }

    /// @dev Route the OLD staker's USDC principal through a MockYieldStrategy so we can force it
    ///      below / above par via setValueFactorBps. setYieldStrategy sweeps the already-staked idle
    ///      balance into the strategy. Returns the strategy so the test can set the value factor.
    function _routeOldThroughStrategy() internal returns (MockYieldStrategy strategy) {
        strategy = new MockYieldStrategy();
        strategy.setClient(address(oldStaker), true);
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
    }

    // ============================== END-TO-END (NO STRATEGY) ==============================

    function test_endToEnd_migration_preservesPositionsAndRewards() public {
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
        StableStaker oStaker = new StableStaker(phUSD, owner);
        StableStaker nStaker = new StableStaker(phUSD, owner);
        phUSD.setMinter(address(oStaker), true);
        phUSD.setMinter(address(nStaker), true);
        oStaker.addToken(address(usdc));
        nStaker.addToken(address(usdc));
        oStaker.phUSDPerDay(address(usdc), PER_DAY);
        nStaker.phUSDPerDay(address(usdc), PER_DAY);
        StableStakerMigrator m =
            new StableStakerMigrator(IStableStaker(address(oStaker)), IStableStaker(address(nStaker)), owner);
        oStaker.setMigrator(address(m));
        nStaker.setMigrator(address(m));

        // equal-principal stakes
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

        // underwater strategy
        MockYieldStrategy strat = new MockYieldStrategy();
        strat.setClient(address(oStaker), true);
        oStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strat)));
        strat.setValueFactorBps(factorBps);

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

    function _newCredit(StableStaker s, address who) internal view returns (uint256 amt) {
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
        (, uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
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
        (, uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
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
        (, uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));

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
        (, uint256 R,) = oldStaker.migrationInfo(address(usdc));

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
        vm.expectRevert(bytes("StableStaker: migrating"));
        oldStaker.stake(address(usdc), 1e6);
        vm.stopPrank();
    }

    function test_guard_withdrawBlockedWhileMigrating() public {
        migrator.initiateMigration(address(usdc));
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: migrating"));
        oldStaker.withdraw(address(usdc), 1e6);
    }

    function test_guard_emergencyWithdrawBlockedWhileMigrating() public {
        migrator.initiateMigration(address(usdc));
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: migrating"));
        oldStaker.emergencyWithdraw(address(usdc));
    }

    function test_guard_depositForBlockedOnMigratingStaker() public {
        migrator.initiateMigration(address(usdc));
        // depositFor must come from the migrator; it is blocked on the OLD (migrating) staker.
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: migrating"));
        oldStaker.depositFor(address(usdc), alice, 1e6);
    }

    function test_guard_userMigrateRevertsWhenNotMigrating() public {
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: not migrating"));
        oldStaker.userMigrate(address(usdc));
    }

    function test_guard_batchMigrateRevertsWithoutInitiate() public {
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: not migrating"));
        oldStaker.batchMigrate(address(usdc), _users());
    }

    function test_guard_initiateMigrationRevertsWhenAlreadyActive() public {
        migrator.initiateMigration(address(usdc));
        // terminal: cannot be re-initiated
        vm.prank(address(migrator));
        vm.expectRevert(bytes("StableStaker: already migrating"));
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
        // setUp leaves the old staker with no strategy: principal sits idle.
        migrator.initiateMigration(address(usdc));
        (bool active, uint256 R, uint256 P) = oldStaker.migrationInfo(address(usdc));
        assertTrue(active);
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

    // A strategy that cannot fully exit (leaves principalOf > 0) makes initiateMigration revert on the
    // post-check. UnderRealizingStrategy caps withdraw to only part of principal per call.
    function test_postCheck_incompleteExitReverts() public {
        UnderRealizingStrategy strat = new UnderRealizingStrategy();
        strat.setClient(address(oldStaker), true);
        oldStaker.setYieldStrategy(address(usdc), IYieldStrategy(address(strat)));

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
}

/// @notice Strategy whose withdraw only realizes part of the requested principal per call, leaving
///         principalOf > 0 so {StableStaker.initiateMigration}'s post-check trips. Models a
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
}
