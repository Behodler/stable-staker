// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStaker.sol";
import "flax-token/FlaxToken.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";

/// @notice Integration tests for routing staked principal through a per-token IYieldStrategy.
contract YieldStrategyIntegrationTest is Test {
    FlaxToken internal phUSD;
    StableStaker internal staker;
    MockERC20 internal usdc; // 6 decimals
    MockYieldStrategy internal strategy;

    address internal owner = address(this);
    address internal migrator = address(0x119C);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal faucet = address(0xFA0CE7);

    uint256 internal constant PER_DAY = 86_400 ether; // -> 1e18 phUSD per second

    event YieldStrategySet(address indexed token, address indexed oldStrategy, address indexed newStrategy);
    event BufferWithdrawn(address indexed token, address indexed user, uint256 amount);

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStaker(phUSD, owner);
        phUSD.setMinter(address(staker), true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staker.addToken(address(usdc));
        staker.phUSDPerDay(address(usdc), PER_DAY);
        staker.setMigrator(migrator);

        strategy = new MockYieldStrategy();
        // Mirror real wiring: the strategy owner authorizes the farm as a client.
        strategy.setClient(address(staker), true);

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(address(staker), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staker.stake(address(usdc), amount);
    }

    function _setStrategy() internal {
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
    }

    // ---------------------------------------------------------------- regression (no strategy)

    function test_noStrategy_stakeAndWithdraw_behaveAsToday() public {
        _stake(alice, 100e6);
        // Tokens sit idle in the contract.
        assertEq(usdc.balanceOf(address(staker)), 100e6);

        vm.warp(block.timestamp + 100);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);
        assertEq(usdc.balanceOf(alice), balBefore + 40e6);
        assertEq(phUSD.balanceOf(alice), 100 ether);
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 60e6);
    }

    function test_noStrategy_withdrawDisabled_false() public view {
        assertFalse(staker.withdrawDisabled(address(usdc)));
    }

    // ---------------------------------------------------------------- setYieldStrategy

    function test_setYieldStrategy_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
    }

    function test_setYieldStrategy_unknownToken_reverts() public {
        vm.expectRevert(bytes("StableStaker: unknown token"));
        staker.setYieldStrategy(address(0xdead), IYieldStrategy(address(strategy)));
    }

    function test_setYieldStrategy_emitsEventAndSetsMapping() public {
        vm.expectEmit(true, true, true, true);
        emit YieldStrategySet(address(usdc), address(0), address(strategy));
        _setStrategy();
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
    }

    function test_setYieldStrategy_setsApproval() public {
        _setStrategy();
        assertEq(usdc.allowance(address(staker), address(strategy)), type(uint256).max);
    }

    function test_setYieldStrategy_sweepsIdleBalance() public {
        // Stake before any strategy is set: tokens sit idle in the contract.
        _stake(alice, 100e6);
        assertEq(usdc.balanceOf(address(staker)), 100e6);

        _setStrategy();
        // Idle balance has been swept into the strategy.
        assertEq(usdc.balanceOf(address(staker)), 0);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
    }

    function test_setYieldStrategy_clearing_zeroesOldAllowance() public {
        _setStrategy();
        assertEq(usdc.allowance(address(staker), address(strategy)), type(uint256).max);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(0)));
        assertEq(usdc.allowance(address(staker), address(strategy)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(0));
    }

    function test_setYieldStrategy_replacing_zeroesOldAllowance() public {
        _setStrategy();
        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));
        assertEq(usdc.allowance(address(staker), address(strategy)), 0);
        assertEq(usdc.allowance(address(staker), address(strategy2)), type(uint256).max);
    }

    // ---------------------------------------------------------------- stake routes into strategy

    function test_stake_routesIntoStrategy() public {
        _setStrategy();
        _stake(alice, 100e6);
        // Contract holds ~no idle balance; principal lives in the strategy.
        assertEq(usdc.balanceOf(address(staker)), 0);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        // Internal principal accounting unchanged.
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 100e6);
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 100e6);
    }

    function test_depositFor_routesIntoStrategy() public {
        _setStrategy();
        usdc.mint(migrator, 100e6);
        vm.prank(migrator);
        usdc.approve(address(staker), type(uint256).max);
        vm.prank(migrator);
        staker.depositFor(address(usdc), alice, 100e6);

        assertEq(usdc.balanceOf(address(staker)), 0);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 100e6);
    }

    // ---------------------------------------------------------------- withdraw at/above par

    function test_withdraw_atPar_returnsPrincipalAndReward() public {
        _setStrategy();
        _stake(alice, 100e6);
        vm.warp(block.timestamp + 100);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);

        assertEq(usdc.balanceOf(alice), balBefore + 40e6);
        assertEq(phUSD.balanceOf(alice), 100 ether); // identical reward math
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 60e6);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 60e6);
    }

    function test_withdraw_abovePar_userGetsOnlyPrincipal_notYield() public {
        _setStrategy();
        _stake(alice, 100e6);
        // Simulate 20% yield growth in the strategy.
        strategy.setValueFactorBps(12_000);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 100e6);

        // Withdraw of principal at requested amount returns exactly principal (no yield leaks).
        assertEq(usdc.balanceOf(alice), balBefore + 100e6);
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 0);
    }

    // ---------------------------------------------------------------- underwater block

    function test_withdraw_underwater_reverts_andDisabledToggles() public {
        _setStrategy();
        _stake(alice, 100e6);

        // Push below par. Note: NO buffer is funded on the staker here; with story 002 in place,
        // the underwater revert still fires when the contract holds insufficient idle balance.
        strategy.setValueFactorBps(9_000);
        assertTrue(staker.withdrawDisabled(address(usdc)));

        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: strategy underwater"));
        staker.withdraw(address(usdc), 50e6);

        // Recover to par: withdraw works again.
        strategy.setValueFactorBps(10_000);
        assertFalse(staker.withdrawDisabled(address(usdc)));
        vm.prank(alice);
        staker.withdraw(address(usdc), 50e6);
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 50e6);
    }

    // ---------------------------------------------------------------- buffer path (story 002)

    /// @dev Faucet seeds the staker's idle balance — exact behaviour of the off-chain faucet contract.
    function _seedBuffer(uint256 amount) internal {
        usdc.mint(faucet, amount);
        vm.prank(faucet);
        usdc.transfer(address(staker), amount);
    }

    function test_withdraw_underwater_bufferCovers_succeedsAndEmits_andStrategyUntouched() public {
        _setStrategy();
        _stake(alice, 100e6);
        strategy.setValueFactorBps(9_000);
        assertTrue(staker.withdrawDisabled(address(usdc)));

        // Buffer >= amount → withdraw served from buffer; vault balance NOT touched but principal
        // accounting is written down via relinquishPrincipal so the invariant holds.
        _seedBuffer(60e6);
        uint256 strategyBalBefore = usdc.balanceOf(address(strategy));
        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit BufferWithdrawn(address(usdc), alice, 50e6);
        vm.prank(alice);
        staker.withdraw(address(usdc), 50e6);

        // Alice paid out of the buffer.
        assertEq(usdc.balanceOf(alice), aliceBalBefore + 50e6);
        // Buffer drained by exactly amount.
        assertEq(usdc.balanceOf(address(staker)), 60e6 - 50e6);
        // Vault token balance untouched (no vault withdraw call).
        assertEq(usdc.balanceOf(address(strategy)), strategyBalBefore);
        // Internal accounting still decremented.
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 50e6);
        // Invariant: strategy principal == staker totalStaked after buffer withdrawal.
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(strategy.principalOf(address(usdc), address(staker)), totalStaked);
    }

    function test_withdraw_underwater_bufferShort_revertsAndBufferUnchanged() public {
        _setStrategy();
        _stake(alice, 100e6);
        strategy.setValueFactorBps(9_000);

        _seedBuffer(40e6); // less than requested 50e6
        uint256 bufferBefore = usdc.balanceOf(address(staker));

        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: strategy underwater"));
        staker.withdraw(address(usdc), 50e6);

        // Partial buffer NOT drained.
        assertEq(usdc.balanceOf(address(staker)), bufferBefore);
        // Position unchanged.
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 100e6);
    }

    function test_withdraw_underwater_bufferEqualsAmount_succeedsAtBoundary() public {
        _setStrategy();
        _stake(alice, 100e6);
        strategy.setValueFactorBps(9_000);

        _seedBuffer(50e6); // exactly the withdraw amount

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 50e6);

        assertEq(usdc.balanceOf(alice), aliceBalBefore + 50e6);
        assertEq(usdc.balanceOf(address(staker)), 0);
    }

    function test_withdraw_underwater_sequentialDrainsBufferThenReverts() public {
        _setStrategy();
        _stake(alice, 200e6);
        strategy.setValueFactorBps(9_000);

        _seedBuffer(70e6);

        // First 30e6: succeeds from buffer.
        vm.prank(alice);
        staker.withdraw(address(usdc), 30e6);
        assertEq(usdc.balanceOf(address(staker)), 40e6);

        // Second 30e6: succeeds from buffer.
        vm.prank(alice);
        staker.withdraw(address(usdc), 30e6);
        assertEq(usdc.balanceOf(address(staker)), 10e6);

        // Third 30e6: exceeds remaining buffer of 10e6, reverts. Buffer not drained.
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: strategy underwater"));
        staker.withdraw(address(usdc), 30e6);
        assertEq(usdc.balanceOf(address(staker)), 10e6);

        // Internal accounting reflects the two successful withdrawals only.
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 200e6 - 60e6);
    }

    /// @dev Multiple sequential buffer withdrawals: after each one the invariant
    ///      `strategy.principalOf(token, staker) == poolInfo.totalStaked` must hold.
    ///      On vault recovery the relinquished principal must NOT re-inflate the staker's
    ///      redemption amount (vault shares are unchanged; only accounting was corrected).
    function test_bufferWithdraw_multipleSequential_principalInvariantHoldsAfterEach_noInflationOnRecovery() public {
        _setStrategy();
        _stake(alice, 200e6);
        strategy.setValueFactorBps(9_000); // push underwater

        // Fund a generous buffer: 3 × 40e6 = 120e6.
        _seedBuffer(120e6);

        // --- First buffer withdrawal ---
        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);
        {
            (,,, uint256 ts) = staker.poolInfo(address(usdc));
            assertEq(strategy.principalOf(address(usdc), address(staker)), ts, "invariant after 1st buffer withdraw");
            assertEq(ts, 160e6);
        }

        // --- Second buffer withdrawal ---
        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);
        {
            (,,, uint256 ts) = staker.poolInfo(address(usdc));
            assertEq(strategy.principalOf(address(usdc), address(staker)), ts, "invariant after 2nd buffer withdraw");
            assertEq(ts, 120e6);
        }

        // --- Third buffer withdrawal ---
        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);
        {
            (,,, uint256 ts) = staker.poolInfo(address(usdc));
            assertEq(strategy.principalOf(address(usdc), address(staker)), ts, "invariant after 3rd buffer withdraw");
            assertEq(ts, 80e6);
        }

        // --- Vault recovery: no principal inflation ---
        // The strategy's vault balance is 200e6 * 0.9 = 180e6 — we did NOT touch it during buffer
        // withdrawals, only principal accounting.  On recovery the staker's remaining principal is
        // 80e6 and the strategy holds 180e6.  A healthy withdraw of 80e6 must return exactly 80e6
        // (the user is NOT credited the dormant 120e6 worth of now-orphaned shares that were
        // relinquished — those are protocol-owned surplus, not user principal).
        strategy.setValueFactorBps(10_000); // recover to par
        assertFalse(staker.withdrawDisabled(address(usdc)));

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 80e6);

        // Alice receives exactly her remaining principal — not inflated by relinquished units.
        assertEq(usdc.balanceOf(alice), aliceBalBefore + 80e6);
        (,,, uint256 tsAfter) = staker.poolInfo(address(usdc));
        assertEq(tsAfter, 0);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);
    }

    function test_withdraw_healthy_withBufferPresent_routesThroughStrategy_bufferPreserved() public {
        _setStrategy();
        _stake(alice, 100e6);
        // Healthy strategy.
        _seedBuffer(70e6);

        uint256 strategyPrincipalBefore = strategy.principalOf(address(usdc), address(staker));
        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);

        // Alice paid in full.
        assertEq(usdc.balanceOf(alice), aliceBalBefore + 40e6);
        // Strategy principal reduced (withdraw routed through strategy).
        assertEq(strategy.principalOf(address(usdc), address(staker)), strategyPrincipalBefore - 40e6);
        // Buffer preserved — strategy paid through to alice without consuming buffer.
        assertEq(usdc.balanceOf(address(staker)), 70e6);
    }

    function test_buffer_isPerToken_tokenABufferDoesNotEnableTokenBWithdraw() public {
        // Add a second token with its own strategy.
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        staker.addToken(address(dai));
        MockYieldStrategy strategyDai = new MockYieldStrategy();
        strategyDai.setClient(address(staker), true);

        _setStrategy(); // USDC strategy
        staker.setYieldStrategy(address(dai), IYieldStrategy(address(strategyDai)));

        // Fund alice for both tokens & stake.
        dai.mint(alice, 1_000 ether);
        vm.prank(alice);
        dai.approve(address(staker), type(uint256).max);

        _stake(alice, 100e6); // USDC
        vm.prank(alice);
        staker.stake(address(dai), 100 ether);

        // Both underwater.
        strategy.setValueFactorBps(9_000);
        strategyDai.setValueFactorBps(9_000);

        // Buffer USDC only.
        _seedBuffer(100e6);

        // USDC withdraw succeeds (its own buffer).
        vm.prank(alice);
        staker.withdraw(address(usdc), 50e6);

        // DAI withdraw still reverts — its buffer is empty.
        vm.prank(alice);
        vm.expectRevert(bytes("StableStaker: strategy underwater"));
        staker.withdraw(address(dai), 50 ether);
    }

    function test_stake_whileUnderwater_stillWorks_regression() public {
        _setStrategy();
        _stake(alice, 100e6);
        // Push underwater.
        strategy.setValueFactorBps(9_000);

        // Staking through the dip MUST still work (DCA argument).
        _stake(bob, 50e6);

        (uint256 bobAmt,) = staker.userInfo(address(usdc), bob);
        assertEq(bobAmt, 50e6);
    }

    function test_deposit_doesNotConsumeBuffer() public {
        _setStrategy();
        _stake(alice, 100e6); // routes into strategy
        // Pre-fund buffer.
        _seedBuffer(75e6);
        assertEq(usdc.balanceOf(address(staker)), 75e6);

        // Bob stakes 30e6: should flow through to strategy, leaving buffer intact.
        _stake(bob, 30e6);

        // Buffer preserved.
        assertEq(usdc.balanceOf(address(staker)), 75e6);
        // Bob's 30e6 lives in the strategy.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 130e6);
    }

    // ---------------------------------------------------------------- emergencyWithdraw (no guard)

    function test_emergencyWithdraw_underwater_succeedsWithHaircut() public {
        _setStrategy();
        _stake(alice, 100e6);
        vm.warp(block.timestamp + 100);

        // Below par: emergency exit still works, delivering a haircut.
        strategy.setValueFactorBps(9_000);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.emergencyWithdraw(address(usdc));

        assertEq(usdc.balanceOf(alice), balBefore + 90e6); // 10% haircut
        assertEq(phUSD.balanceOf(alice), 0); // reward forfeited
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 0);
        assertEq(staker.stakerCount(address(usdc)), 0);
    }

    // ----------------------------------------------- terminal migration (initiate + batchMigrate)

    function test_batchMigrate_underwater_deliversSnapshotCredits() public {
        _setStrategy();
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        // Below par.
        strategy.setValueFactorBps(9_000);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        // Engage terminal migration: realizes the whole position once (400e6 * 0.9 = 360e6 = R),
        // then decouples the strategy (principalOf drained to 0).
        vm.prank(migrator);
        staker.initiateMigration(address(usdc));
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);

        uint256 migBefore = usdc.balanceOf(migrator);
        vm.prank(migrator);
        staker.batchMigrate(address(usdc), users);

        // Snapshot credits: 90e6 + 270e6 = 360e6 transferred to the migrator from the idle pile.
        assertEq(usdc.balanceOf(migrator) - migBefore, 360e6);
        (uint256 aliceAmt,) = staker.userInfo(address(usdc), alice);
        (uint256 bobAmt,) = staker.userInfo(address(usdc), bob);
        assertEq(aliceAmt, 0);
        assertEq(bobAmt, 0);
    }

    function test_batchMigrate_atPar_deliversFullPrincipal() public {
        _setStrategy();
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(migrator);
        staker.initiateMigration(address(usdc));
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);

        uint256 migBefore = usdc.balanceOf(migrator);
        vm.prank(migrator);
        staker.batchMigrate(address(usdc), users);

        assertEq(usdc.balanceOf(migrator) - migBefore, 400e6);
    }

    // ---------------------------------------------------------------- yield never reaches staker

    function test_yield_neverReachesStaker_partialWithdraws() public {
        _setStrategy();
        _stake(alice, 100e6);
        // Big above-par growth, and physically seed the strategy with the surplus tokens it now
        // notionally holds, so we can prove they are never paid to the staker.
        strategy.setValueFactorBps(15_000);
        usdc.mint(address(strategy), 50e6);

        uint256 strategyBalBefore = usdc.balanceOf(address(strategy));
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 60e6);
        vm.prank(alice);
        staker.withdraw(address(usdc), 40e6);

        // User receives exactly their 100e6 principal, never the 50% surplus.
        assertEq(usdc.balanceOf(alice), balBefore + 100e6);
        // The 50e6 surplus stays protocol-owned inside the strategy.
        assertEq(usdc.balanceOf(address(strategy)), strategyBalBefore - 100e6);
        assertEq(usdc.balanceOf(address(strategy)), 50e6);
    }

    // ------------------------------------------ M-02 guard: blocked during terminal migration

    function test_setYieldStrategy_revertsDuringActiveMigration() public {
        _setStrategy();
        _stake(alice, 100e6);

        // Engage terminal migration: holds the realized payout pile as idle balance, decoupled.
        vm.prank(migrator);
        staker.initiateMigration(address(usdc));
        assertEq(uint256(staker.poolState(address(usdc))), uint256(StableStaker.PoolState.Migrating));

        // setYieldStrategy must now be blocked — an unguarded sweep would brick userMigrate/batchMigrate.
        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));
    }

    // ------------------------------------------ swap: YS1 -> YS2 drains old, re-custodies, no migration

    function test_setYieldStrategy_swap_drainsOldAndReCustodiesIntoNew() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 400e6);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 400e6);

        // Swap to YS2 in a single owner call — no initiateMigration, no per-user migration.
        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // Old strategy fully drained; whole position re-custodied into the new strategy.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 400e6);
        // Mapping repointed; allowances flipped.
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy2));
        assertEq(usdc.allowance(address(staker), address(strategy)), 0);
        assertEq(usdc.allowance(address(staker), address(strategy2)), type(uint256).max);
        // No migration was engaged.
        assertEq(uint256(staker.poolState(address(usdc))), uint256(StableStaker.PoolState.Active));

        // A subsequent withdraw resolves against YS2.
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(address(usdc), 100e6);
        assertEq(usdc.balanceOf(alice), balBefore + 100e6);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 300e6);
    }

    // ------------------------------------------ M-06: swapping an underwater strategy reverts

    /// @dev M-06: an in-place swap of an underwater (below-par) strategy is FORBIDDEN. Swapping
    ///      while below par would silently lift the underwater-withdraw block and FCFS-concentrate
    ///      the realized loss on the last withdrawer. Impaired strategies must be wound down via the
    ///      fair, snapshot-based terminal-migration path instead. The guard reverts before any drain.
    function test_setYieldStrategy_swap_fromUnderwaterVault_reverts() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);

        // YS1 vault impaired: only pays 90% on exit (below par => underwater).
        strategy.setValueFactorBps(9_000);
        assertTrue(staker.withdrawDisabled(address(usdc)));

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);

        // The swap must revert — no state change, no token movement.
        vm.expectRevert(bytes("StableStaker: old strategy underwater"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // Nothing moved: old strategy still holds the full principal, mapping unchanged.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
    }

    // ------------------------------------------ M-06: at-par swap still succeeds

    function test_setYieldStrategy_swap_atPar_succeeds() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        // Exactly at par (factorBps == 10000).
        strategy.setValueFactorBps(10_000);
        assertFalse(staker.withdrawDisabled(address(usdc)));

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // Whole position drained out of YS1 and re-custodied at par into YS2 — accounting consistent.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 400e6);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy2));
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 400e6);
        assertFalse(staker.withdrawDisabled(address(usdc)));
    }

    // ------------------------------------------ M-06: above-par swap succeeds, yield left behind

    function test_setYieldStrategy_swap_abovePar_succeeds_yieldLeftBehind() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);

        // 20% yield growth in YS1 (factorBps > 10000): strategy holds 120e6 of value, 100e6 principal.
        strategy.setValueFactorBps(12_000);
        assertFalse(staker.withdrawDisabled(address(usdc)));

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // Principal (100e6) re-custodied at par into YS2; the drain caps the redeem at par so the
        // above-par yield is never pulled out and stays behind in the decoupled old strategy as
        // protocol-owned value (StableStaker credits users principal only).
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 100e6);
        // The old strategy's principal book is zeroed; any above-par surplus remains protocol-owned
        // and is not custodied for the farm anymore (the mock only ever held the 100e6 deposited).
        assertEq(strategy.totalBalanceOf(address(usdc), address(staker)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy2));
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 100e6);
        assertFalse(staker.withdrawDisabled(address(usdc)));
    }

    // ------------------------------------------ M-06: empty / first-adoption swaps succeed

    function test_setYieldStrategy_swap_emptyOldStrategy_succeeds() public {
        // Adopt YS1 but never stake into it: principalOf == 0, so it is NOT underwater (0 < 0 false),
        // even with the value factor pushed below par. The guard must permit the swap.
        _setStrategy(); // YS1
        strategy.setValueFactorBps(9_000);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy2));
        assertEq(usdc.allowance(address(staker), address(strategy)), 0);
        assertEq(usdc.allowance(address(staker), address(strategy2)), type(uint256).max);
    }

    function test_setYieldStrategy_firstAdoption_noOldStrategy_succeeds() public {
        // No old strategy at all (address(0)): the guarded block is skipped entirely.
        assertEq(address(staker.yieldStrategy(address(usdc))), address(0));
        _stake(alice, 100e6); // idle hold before adoption

        _setStrategy(); // first adoption

        // Idle balance swept into the freshly adopted strategy.
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        assertEq(usdc.balanceOf(address(staker)), 0);
    }
}
