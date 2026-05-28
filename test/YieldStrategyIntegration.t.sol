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

        // Buffer >= amount → withdraw served from buffer, strategy NOT touched.
        _seedBuffer(60e6);
        uint256 strategyPrincipalBefore = strategy.principalOf(address(usdc), address(staker));
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
        // Strategy state untouched: no withdraw call hit it.
        assertEq(strategy.principalOf(address(usdc), address(staker)), strategyPrincipalBefore);
        assertEq(usdc.balanceOf(address(strategy)), strategyBalBefore);
        // Internal accounting still decremented.
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 50e6);
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

    // ---------------------------------------------------------------- migrateOut (no guard, aggregate)

    function test_migrateOut_underwater_deliversRedeemedAggregate() public {
        _setStrategy();
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        // Below par.
        strategy.setValueFactorBps(9_000);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        uint256 migBefore = usdc.balanceOf(migrator);
        vm.prank(migrator);
        staker.migrateOut(address(usdc), users);

        // Aggregate principal 400e6 redeemed at 90% = 360e6 delivered to migrator.
        assertEq(usdc.balanceOf(migrator) - migBefore, 360e6);
        (uint256 aliceAmt,) = staker.userInfo(address(usdc), alice);
        (uint256 bobAmt,) = staker.userInfo(address(usdc), bob);
        assertEq(aliceAmt, 0);
        assertEq(bobAmt, 0);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);
    }

    function test_migrateOut_atPar_deliversFullAggregate() public {
        _setStrategy();
        _stake(alice, 100e6);
        _stake(bob, 300e6);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        uint256 migBefore = usdc.balanceOf(migrator);
        vm.prank(migrator);
        staker.migrateOut(address(usdc), users);

        assertEq(usdc.balanceOf(migrator) - migBefore, 400e6);
        assertEq(strategy.principalOf(address(usdc), address(staker)), 0);
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
}
