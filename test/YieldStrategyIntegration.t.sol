// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "flax-token/FlaxToken.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";

/// @notice Integration tests for routing staked principal through a per-token IYieldStrategy.
contract YieldStrategyIntegrationTest is Test {
    FlaxToken internal phUSD;
    StableStakerV2 internal staker;
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
    /// @dev Mirrors {StableStakerV2.ProtocolPrincipalSwept} for vm.expectEmit.
    event ProtocolPrincipalSwept(address indexed token, address indexed strategy, uint256 amount, uint256 credited);

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStakerV2(phUSD, owner);
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
        // Story 022: booked, not minted, on withdraw.
        assertEq(phUSD.balanceOf(alice), 0);
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);
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

    // test_setYieldStrategy_sweepsIdleBalance removed: stake-then-wire is now forbidden by the
    // empty-pool gate. The legitimate idle-then-sweep behaviour (stake idle on revived pool, then
    // wire strategy to sweep) is covered by Migration.t.sol::test_revival_idleHoldThenStrategySweep.

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
        // Story 022: identical reward math, booked to `unclaimedReward` instead of minted.
        assertEq(phUSD.balanceOf(alice), 0);
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);
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
        assertEq(staker.unclaimedReward(address(usdc), alice), 0); // story 022: backlog forfeited too
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
        assertEq(uint256(staker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Migrating));

        // setYieldStrategy must now be blocked — an unguarded sweep would brick userMigrate/batchMigrate.
        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        vm.expectRevert(bytes("StableStaker: pool not active"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));
    }

    // ------------------------------------------ swap: in-place swap is now forbidden on non-empty pool

    /// @dev Empty-pool gate: an in-place YS1->YS2 swap is FORBIDDEN once the pool holds principal.
    ///      The gate fires before any drain, so the full position stays intact in YS1.
    function test_setYieldStrategy_swap_drainsOldAndReCustodiesIntoNew() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 400e6);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 400e6);

        // Attempt swap to YS2 — must revert because pool is non-empty.
        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);
        vm.expectRevert(bytes("StableStaker: pool not empty"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // No state changed; positions and wiring intact.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 400e6);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
    }

    // ------------------------------------------ M-06: swapping an underwater strategy reverts (now "pool not empty")

    /// @dev M-06 (updated): an in-place swap on a non-empty pool is FORBIDDEN regardless of whether
    ///      the strategy is underwater or not. The empty-pool gate (statement 2) fires before the
    ///      underwater guard (now unreachable on non-empty pools), so the revert reason is
    ///      "pool not empty" rather than "old strategy underwater".
    function test_setYieldStrategy_swap_fromUnderwaterVault_reverts() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);

        // YS1 vault impaired: only pays 90% on exit (below par => underwater).
        strategy.setValueFactorBps(9_000);
        assertTrue(staker.withdrawDisabled(address(usdc)));

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);

        // The swap must revert — empty-pool gate fires first (before the underwater check).
        vm.expectRevert(bytes("StableStaker: pool not empty"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // Nothing moved: old strategy still holds the full principal, mapping unchanged.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
    }

    // ------------------------------------------ M-06: at-par swap now also forbidden on non-empty pool

    /// @dev Empty-pool gate: even an at-par in-place swap reverts if the pool is non-empty.
    ///      Being at par is no longer a sufficient condition for an in-place swap.
    function test_setYieldStrategy_swap_atPar_succeeds() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        // Exactly at par (factorBps == 10000).
        strategy.setValueFactorBps(10_000);
        assertFalse(staker.withdrawDisabled(address(usdc)));

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);

        // Must revert: pool is non-empty regardless of par status.
        vm.expectRevert(bytes("StableStaker: pool not empty"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // No state changed.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 400e6);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
    }

    // ------------------------------------------ M-06: above-par in-place swap also forbidden on non-empty pool

    /// @dev Empty-pool gate: even an above-par in-place swap reverts if the pool is non-empty.
    ///      Above-par is no longer a sufficient condition for an in-place swap.
    function test_setYieldStrategy_swap_abovePar_succeeds_yieldLeftBehind() public {
        _setStrategy(); // YS1
        _stake(alice, 100e6);

        // 20% yield growth in YS1 (factorBps > 10000): strategy holds 120e6 of value, 100e6 principal.
        strategy.setValueFactorBps(12_000);
        assertFalse(staker.withdrawDisabled(address(usdc)));

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);

        // Must revert: pool is non-empty regardless of above-par status.
        vm.expectRevert(bytes("StableStaker: pool not empty"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // No state changed; YS1 still holds the full position.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 100e6);
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
        // Wire must happen BEFORE any stake (empty-pool gate).
        assertEq(address(staker.yieldStrategy(address(usdc))), address(0));

        _setStrategy(); // first adoption on empty pool

        // Strategy wired correctly.
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
        assertEq(usdc.allowance(address(staker), address(strategy)), type(uint256).max);

        // Alice stakes AFTER wiring: principal routes through the strategy.
        _stake(alice, 100e6);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        assertEq(usdc.balanceOf(address(staker)), 0);
    }

    // ------------------------------------------ new TDD tests (story-010)

    /// @dev M-01 regression: first-adoption (no old strategy) on a non-empty pool MUST revert.
    ///      This is the ss6m1 / M-01 scenario: owner tries to wire a strategy after users have
    ///      already staked idle.  The empty-pool gate prevents the silent principal desync.
    function test_setYieldStrategy_revertsOnNonEmptyPool_firstAdoption() public {
        // Stake first (pool becomes non-empty, no strategy yet).
        _stake(alice, 100e6);
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 100e6);

        // First-adoption on non-empty pool must revert.
        vm.expectRevert(bytes("StableStaker: pool not empty"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));

        // No strategy was wired.
        assertEq(address(staker.yieldStrategy(address(usdc))), address(0));
        // Tokens remain idle in the contract (no sweep occurred).
        assertEq(usdc.balanceOf(address(staker)), 100e6);
    }

    /// @dev Empty-pool gate: even an at/above-par in-place strategy swap reverts on non-empty pool.
    ///      Both the old M-06 guard and the new M-01/M-07 guard collapse into this single check.
    function test_setYieldStrategy_revertsOnNonEmptyPool_inPlaceSwap() public {
        _setStrategy(); // YS1 on empty pool — succeeds
        _stake(alice, 100e6); // pool now non-empty

        MockYieldStrategy strategy2 = new MockYieldStrategy();
        strategy2.setClient(address(staker), true);

        // Attempt swap at par.
        strategy.setValueFactorBps(10_000);
        vm.expectRevert(bytes("StableStaker: pool not empty"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // Attempt swap above par (also reverts).
        strategy.setValueFactorBps(12_000);
        vm.expectRevert(bytes("StableStaker: pool not empty"));
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy2)));

        // Original wiring and positions untouched.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 100e6);
        assertEq(strategy2.principalOf(address(usdc), address(staker)), 0);
        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
    }

    /// @dev Full revival runbook end-to-end: after finalizeAndReset the pool is empty and
    ///      setYieldStrategy succeeds, wiring the fresh strategy on the revived pool.
    function test_setYieldStrategy_succeeds_afterFinalizeAndReset() public {
        _setStrategy(); // YS1 on empty pool
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        // Engage terminal migration, eject everyone, reset.
        vm.prank(migrator);
        staker.initiateMigration(address(usdc));

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        vm.prank(migrator);
        staker.batchMigrate(address(usdc), users);

        // Pool fully drained.
        (,,, uint256 drained) = staker.poolInfo(address(usdc));
        assertEq(drained, 0);
        assertEq(staker.stakerCount(address(usdc)), 0);

        staker.finalizeAndReset(address(usdc));
        assertEq(uint256(staker.poolState(address(usdc))), uint256(StableStakerV2.PoolState.Active));

        // Wire a fresh strategy on the revived empty pool — must succeed.
        MockYieldStrategy fresh = new MockYieldStrategy();
        fresh.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(fresh)));

        assertEq(address(staker.yieldStrategy(address(usdc))), address(fresh));
        assertEq(usdc.allowance(address(staker), address(fresh)), type(uint256).max);

        // A new stake routes through the fresh strategy correctly.
        _stake(alice, 50e6);
        assertEq(fresh.principalOf(address(usdc), address(staker)), 50e6);
    }

    /// @dev Donation dust does NOT brick the gate: totalStaked == 0 even if someone donated tokens.
    ///      A direct token transfer (donation) raises the idle balance but NOT totalStaked, so
    ///      the setYieldStrategy gate permits wiring.
    function test_setYieldStrategy_succeeds_withDonationDust_onEmptyPool() public {
        // Donate 1e6 dust to the staker (no user stake; totalStaked remains 0).
        usdc.mint(address(staker), 1e6);
        assertEq(usdc.balanceOf(address(staker)), 1e6);
        (,,, uint256 totalStaked) = staker.poolInfo(address(usdc));
        assertEq(totalStaked, 0); // gate checks totalStaked, not idle balance

        // Wire the strategy — must succeed because totalStaked == 0.
        _setStrategy();

        assertEq(address(staker.yieldStrategy(address(usdc))), address(strategy));
        // Idle dust (the donation) is swept into the strategy by the sweep-on-wire logic.
        assertEq(strategy.principalOf(address(usdc), address(staker)), 1e6);
        assertEq(usdc.balanceOf(address(staker)), 0);
    }

    /// @dev The sweep-on-wire reports itself. `amount` is the full idle balance pulled in; `credited`
    ///      is what the strategy actually booked, which a haircutting strategy reports as strictly
    ///      less. Capturing the previously-discarded deposit return (ledger entry dab5a656) is what
    ///      makes the two numbers separable off chain: an observer subtracts the swept history from a
    ///      later PrincipalDivergence.booked and is left with the UNEXPLAINED part.
    function test_setYieldStrategy_emitsProtocolPrincipalSwept_creditedBelowAmount() public {
        // Protocol money parked on the still-empty pool: buffer, dust, donations.
        usdc.mint(address(staker), 100e6);
        // 2% deposit slippage: the strategy pulls 100e6 but books only 98e6 as principal.
        strategy.setDepositSlippageBps(200);

        vm.expectEmit(true, true, false, true, address(staker));
        emit ProtocolPrincipalSwept(address(usdc), address(strategy), 100e6, 98e6);
        _setStrategy();

        // The sweep behaviour itself is unchanged: the full idle balance still moves.
        assertEq(usdc.balanceOf(address(staker)), 0);
        assertEq(usdc.balanceOf(address(strategy)), 100e6);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 98e6);
    }

    /// @dev With no slippage `credited == amount`, and the event still fires.
    function test_setYieldStrategy_emitsProtocolPrincipalSwept_fullCredit() public {
        usdc.mint(address(staker), 42e6);

        vm.expectEmit(true, true, false, true, address(staker));
        emit ProtocolPrincipalSwept(address(usdc), address(strategy), 42e6, 42e6);
        _setStrategy();

        assertEq(strategy.principalOf(address(usdc), address(staker)), 42e6);
    }
}
