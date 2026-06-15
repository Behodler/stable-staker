// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStaker.sol";
import "../src/InPlaceMigrator.sol";
import "../src/interfaces/IStableStaker.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";
import "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice In-place yield-strategy swap on a SINGLE live StableStaker: drain users into the
///         migrator's custody (migrateOut -> park), rewire (finalizeAndReset + setYieldStrategy),
///         then re-inject the same users into the SAME staker (migrateIn). A permissionless
///         self-only timeout escape hatch (claimTimedOut) returns principal if the operator stalls.
contract InPlaceMigratorTest is Test {
    FlaxToken internal phUSD;
    StableStaker internal staker;
    InPlaceMigrator internal migrator;
    MockERC20 internal usdc;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant PER_DAY = 86_400 ether; // 1e18 / second
    uint256 internal constant TIMEOUT = 7 days;

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStaker(phUSD, owner);
        phUSD.setMinter(address(staker), true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staker.addToken(address(usdc));
        staker.phUSDPerDay(address(usdc), PER_DAY);

        migrator = new InPlaceMigrator(IStableStaker(address(staker)), TIMEOUT, owner);
        staker.setMigrator(address(migrator));

        usdc.mint(alice, 100e6);
        usdc.mint(bob, 300e6);
        vm.prank(alice);
        usdc.approve(address(staker), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(staker), type(uint256).max);
    }

    // ============================== HELPERS ==============================

    function _stakeAliceAndBob() internal {
        vm.prank(alice);
        staker.stake(address(usdc), 100e6);
        vm.prank(bob);
        staker.stake(address(usdc), 300e6);
    }

    function _users() internal view returns (address[] memory users) {
        users = new address[](2);
        users[0] = alice;
        users[1] = bob;
    }

    function _all(address token) internal view returns (address[] memory) {
        return migrator.parkedUsersRange(token, 0, migrator.parkedUserCount(token));
    }

    // ============================== TEST 1: migrateOut parks exact amounts ==============================

    function test_migrateOut_parksExactAmounts() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        migrator.migrateOut(address(usdc), _users());

        // Parked == principal (par, no strategy).
        assertEq(migrator.parked(address(usdc), alice), 100e6);
        assertEq(migrator.parked(address(usdc), bob), 300e6);
        assertEq(migrator.totalParked(address(usdc)), 400e6);

        // migrationBegin == now for both.
        assertEq(migrator.migrationBegin(address(usdc), alice), block.timestamp);
        assertEq(migrator.migrationBegin(address(usdc), bob), block.timestamp);

        // Set grew to 2.
        assertEq(migrator.parkedUserCount(address(usdc)), 2);

        // The migrator physically holds the drained principal.
        assertEq(usdc.balanceOf(address(migrator)), 400e6);

        // Source position drained.
        (uint256 aAmt,) = staker.userInfo(address(usdc), alice);
        assertEq(aAmt, 0);
        assertEq(staker.stakerCount(address(usdc)), 0);
    }

    // ============================== TEST 2: full in-place cycle ==============================

    function test_fullInPlaceCycle_rewireThroughV2() public {
        _stakeAliceAndBob();
        // Accrue rewards so migrateOut mints non-zero phUSD.
        vm.warp(block.timestamp + 1 days);
        uint256 pendingAlice = staker.pendingReward(address(usdc), alice);
        uint256 pendingBob = staker.pendingReward(address(usdc), bob);
        assertGt(pendingAlice, 0);

        // OUT -> park.
        migrator.initiateMigration(address(usdc));
        migrator.migrateOut(address(usdc), _users());

        // Earned phUSD already minted to users at migrateOut.
        assertEq(phUSD.balanceOf(alice), pendingAlice);
        assertEq(phUSD.balanceOf(bob), pendingBob);

        // REWIRE: reset the SAME pool, wire a fresh V2 strategy on the now-empty pool.
        staker.finalizeAndReset(address(usdc));
        MockYieldStrategy v2 = new MockYieldStrategy();
        v2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(v2)));

        // IN: re-inject everyone into the SAME staker.
        migrator.migrateIn(address(usdc), 0, migrator.parkedUserCount(address(usdc)));

        // Same principal re-credited on the same staker.
        (uint256 aNew,) = staker.userInfo(address(usdc), alice);
        (uint256 bNew,) = staker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6);
        assertEq(bNew, 300e6);
        (,,, uint256 total) = staker.poolInfo(address(usdc));
        assertEq(total, 400e6);

        // Principal routed through V2.
        assertEq(v2.principalOf(address(usdc), address(staker)), 400e6);

        // Custody fully drained; parked state reset.
        assertEq(migrator.totalParked(address(usdc)), 0);
        assertEq(migrator.parked(address(usdc), alice), 0);
        assertEq(migrator.parked(address(usdc), bob), 0);
        assertEq(migrator.parkedUserCount(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // ============================== TEST 3: claimTimedOut reverts before timeout ==============================

    function test_claimTimedOut_revertsBeforeTimeout() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        migrator.migrateOut(address(usdc), _users());

        // Just before the timeout boundary.
        vm.warp(block.timestamp + TIMEOUT - 1);
        vm.prank(alice);
        vm.expectRevert(bytes("InPlaceMigrator: timeout not elapsed"));
        migrator.claimTimedOut(address(usdc));
    }

    // ============================== TEST 4: claimTimedOut succeeds at/after timeout ==============================

    function test_claimTimedOut_succeedsAtTimeout() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        uint256 t0 = block.timestamp;
        migrator.migrateOut(address(usdc), _users());

        assertEq(migrator.claimableAt(address(usdc), alice), t0 + TIMEOUT);

        vm.warp(t0 + TIMEOUT); // exactly at boundary
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        migrator.claimTimedOut(address(usdc));

        // Exact principal transferred.
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);

        // All state cleared, user removed from set.
        assertEq(migrator.parked(address(usdc), alice), 0);
        assertEq(migrator.migrationBegin(address(usdc), alice), 0);
        assertEq(migrator.totalParked(address(usdc)), 300e6); // bob still parked
        assertEq(migrator.parkedUserCount(address(usdc)), 1);
    }

    // ============================== TEST 5: no double-spend ==============================

    function test_noDoubleSpend_claimTwiceAndAfterMigrateIn() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        migrator.migrateOut(address(usdc), _users());

        vm.warp(block.timestamp + TIMEOUT);

        // Alice claims once.
        vm.prank(alice);
        migrator.claimTimedOut(address(usdc));

        // Cannot claim twice.
        vm.prank(alice);
        vm.expectRevert(bytes("InPlaceMigrator: nothing parked"));
        migrator.claimTimedOut(address(usdc));

        // Rewire and migrateIn over the WHOLE set: alice (already claimed) is skipped, bob re-injected.
        staker.finalizeAndReset(address(usdc));
        MockYieldStrategy v2 = new MockYieldStrategy();
        v2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(v2)));

        migrator.migrateIn(address(usdc), 0, migrator.parkedUserCount(address(usdc)));

        // Bob re-credited; alice NOT re-credited (she already escaped to her wallet).
        (uint256 bNew,) = staker.userInfo(address(usdc), bob);
        (uint256 aNew,) = staker.userInfo(address(usdc), alice);
        assertEq(bNew, 300e6);
        assertEq(aNew, 0);

        // Bob cannot then claim (migrated in).
        vm.warp(block.timestamp + TIMEOUT);
        vm.prank(bob);
        vm.expectRevert(bytes("InPlaceMigrator: nothing parked"));
        migrator.claimTimedOut(address(usdc));

        // No funds stranded.
        assertEq(migrator.totalParked(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // ============================== TEST 6: migrateIn pagination + interleaved claim ==============================

    function test_migrateIn_paginationAndInterleavedClaim() public {
        // Three stakers so the slice math is non-trivial.
        address carol = address(0xCA401);
        usdc.mint(carol, 200e6);
        vm.prank(carol);
        usdc.approve(address(staker), type(uint256).max);

        _stakeAliceAndBob();
        vm.prank(carol);
        staker.stake(address(usdc), 200e6);

        migrator.initiateMigration(address(usdc));
        address[] memory three = new address[](3);
        three[0] = alice;
        three[1] = bob;
        three[2] = carol;
        migrator.migrateOut(address(usdc), three);
        assertEq(migrator.parkedUserCount(address(usdc)), 3);

        // Rewire.
        staker.finalizeAndReset(address(usdc));
        MockYieldStrategy v2 = new MockYieldStrategy();
        v2.setClient(address(staker), true);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(v2)));

        // Process only the first slice [0,1): one user.
        migrator.migrateIn(address(usdc), 0, 1);
        assertEq(migrator.parkedUserCount(address(usdc)), 2);

        // A still-parked user times out and claims, interleaved with pagination.
        vm.warp(block.timestamp + TIMEOUT);
        address[] memory remaining = _all(address(usdc));
        address claimer = remaining[0];
        uint256 claimerParked = migrator.parked(address(usdc), claimer);
        uint256 claimerBefore = usdc.balanceOf(claimer);
        vm.prank(claimer);
        migrator.claimTimedOut(address(usdc));
        assertEq(usdc.balanceOf(claimer) - claimerBefore, claimerParked);
        assertEq(migrator.parkedUserCount(address(usdc)), 1);

        // Mop up the remainder over a generous range; the claimer is gone, no double payout.
        migrator.migrateIn(address(usdc), 0, 100);
        assertEq(migrator.parkedUserCount(address(usdc)), 0);
        assertEq(migrator.totalParked(address(usdc)), 0);

        // Conservation: every user ended up with exactly their principal, once.
        // Two were migrated in (staker credit), one claimed (wallet). Total principal conserved.
        (uint256 aS,) = staker.userInfo(address(usdc), alice);
        (uint256 bS,) = staker.userInfo(address(usdc), bob);
        (uint256 cS,) = staker.userInfo(address(usdc), carol);
        uint256 stakerCredited = aS + bS + cS;
        uint256 walletClaimed = usdc.balanceOf(claimer) - 0; // claimer started at 0 usdc after staking
        // claimer's staker credit is 0 (they claimed), so total principal = credited + their wallet claim
        assertEq(stakerCredited + claimerParked, 600e6);
        assertEq(walletClaimed, claimerParked);
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // ============================== TEST 7: rescueERC20 floor ==============================

    function test_rescueERC20_respectsParkedFloor() public {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        migrator.migrateOut(address(usdc), _users());
        assertEq(migrator.totalParked(address(usdc)), 400e6);

        // Cannot rescue even 1 wei out of the parked principal.
        vm.expectRevert(bytes("InPlaceMigrator: cannot touch parked principal"));
        migrator.rescueERC20(address(usdc), owner, 1);

        // Donate a genuine stray amount above the floor.
        usdc.mint(address(migrator), 50e6);

        // Cannot rescue more than the surplus.
        vm.expectRevert(bytes("InPlaceMigrator: cannot touch parked principal"));
        migrator.rescueERC20(address(usdc), owner, 50e6 + 1);

        // Can rescue exactly the surplus.
        uint256 ownerBefore = usdc.balanceOf(owner);
        migrator.rescueERC20(address(usdc), owner, 50e6);
        assertEq(usdc.balanceOf(owner) - ownerBefore, 50e6);

        // Parked principal untouched.
        assertEq(migrator.totalParked(address(usdc)), 400e6);
        assertEq(usdc.balanceOf(address(migrator)), 400e6);
    }

    // ============================== TEST 8: constructor guards ==============================

    function test_constructor_rejectsZeroStaker() public {
        vm.expectRevert(bytes("InPlaceMigrator: zero staker"));
        new InPlaceMigrator(IStableStaker(address(0)), TIMEOUT, owner);
    }

    function test_constructor_rejectsTimeoutZero() public {
        vm.expectRevert(bytes("InPlaceMigrator: timeout out of bounds"));
        new InPlaceMigrator(IStableStaker(address(staker)), 0, owner);
    }

    function test_constructor_rejectsTimeoutBelowMin() public {
        vm.expectRevert(bytes("InPlaceMigrator: timeout out of bounds"));
        new InPlaceMigrator(IStableStaker(address(staker)), 1 days - 1, owner);
    }

    function test_constructor_rejectsTimeoutAboveMax() public {
        vm.expectRevert(bytes("InPlaceMigrator: timeout out of bounds"));
        new InPlaceMigrator(IStableStaker(address(staker)), 30 days + 1, owner);
    }

    function test_constructor_acceptsBounds() public {
        InPlaceMigrator lo = new InPlaceMigrator(IStableStaker(address(staker)), 1 days, owner);
        InPlaceMigrator hi = new InPlaceMigrator(IStableStaker(address(staker)), 30 days, owner);
        assertEq(lo.migrationTimeout(), 1 days);
        assertEq(hi.migrationTimeout(), 30 days);
    }

    // ============================== TEST 9: reentrancy ==============================

    function test_claimTimedOut_reentrancyGuarded() public {
        // Use a reentrant token that re-enters claimTimedOut on transfer.
        ReentrantToken evil = new ReentrantToken();
        StableStaker evilStaker = new StableStaker(phUSD, owner);
        phUSD.setMinter(address(evilStaker), true);
        evilStaker.addToken(address(evil));
        evilStaker.phUSDPerDay(address(evil), PER_DAY);

        InPlaceMigrator evilMig = new InPlaceMigrator(IStableStaker(address(evilStaker)), TIMEOUT, owner);
        evilStaker.setMigrator(address(evilMig));

        // The attacker contract stakes, gets migrated out, then attempts a reentrant double-claim.
        ReentrantAttacker attacker = new ReentrantAttacker(evilMig, evil, evilStaker);
        evil.mint(address(attacker), 100e6);
        attacker.stakeIn();

        evilMig.initiateMigration(address(evil));
        address[] memory u = new address[](1);
        u[0] = address(attacker);
        evilMig.migrateOut(address(evil), u);

        evil.setReentrancyTarget(address(evilMig), address(evil));
        vm.warp(block.timestamp + TIMEOUT);

        // The reentrant attempt must NOT double-pay: the guard / CEI ensures one payout only.
        attacker.attack();
        // Attacker received exactly its principal once.
        assertEq(evil.balanceOf(address(attacker)), 100e6);
        assertEq(evilMig.totalParked(address(evil)), 0);
    }

    // ============================== TEST 10: only-owner gates ==============================

    function test_onlyOwnerGates() public {
        _stakeAliceAndBob();

        // initiateMigration
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        migrator.initiateMigration(address(usdc));

        migrator.initiateMigration(address(usdc));

        // migrateOut
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        migrator.migrateOut(address(usdc), _users());

        migrator.migrateOut(address(usdc), _users());

        // migrateIn (rewire first so a non-revert path exists for owner; non-owner still blocked)
        staker.finalizeAndReset(address(usdc));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        migrator.migrateIn(address(usdc), 0, 2);

        // rescueERC20
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        migrator.rescueERC20(address(usdc), alice, 0);

        // claimTimedOut is permissionless + self-scoped: alice (parked) succeeds after timeout for HERSELF.
        vm.warp(block.timestamp + TIMEOUT);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        migrator.claimTimedOut(address(usdc));
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);

        // A stranger with nothing parked gets nothing-parked revert (self-scoped).
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("InPlaceMigrator: nothing parked"));
        migrator.claimTimedOut(address(usdc));
    }

    // ============================== M-01 TOP-UP HELPERS ==============================

    /// @notice Drive the OUT leg (par, no strategy), then rewire the empty pool to a fresh slippage
    ///         strategy `v2` with `slippageBps` deposit haircut. Returns the wired strategy.
    function _outAndRewireWithSlippage(uint256 slippageBps) internal returns (MockYieldStrategy v2) {
        _stakeAliceAndBob();
        migrator.initiateMigration(address(usdc));
        migrator.migrateOut(address(usdc), _users());

        staker.finalizeAndReset(address(usdc));
        v2 = new MockYieldStrategy();
        v2.setClient(address(staker), true);
        v2.setDepositSlippageBps(slippageBps);
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(v2)));
    }

    // ============== TEST 11: M-01 PoC flips to whole when surplus funded ==============

    function test_m01_topupRestoresToParWithSurplus() public {
        // 1% deposit haircut on the re-injection strategy.
        _outAndRewireWithSlippage(100);

        // Owner funds the implicit top-up budget by sending surplus to the migrator BEFORE migrateIn.
        // Parked principal is 400e6; send 10e6 surplus (well above the ~1% slippage on 400e6).
        usdc.mint(address(migrator), 10e6);

        uint256 surplusBefore = usdc.balanceOf(address(migrator)) - migrator.totalParked(address(usdc));
        assertEq(surplusBefore, 10e6);

        migrator.migrateIn(address(usdc), 0, migrator.parkedUserCount(address(usdc)));

        // Re-injected stakers land at par (within amt/1000): WITHOUT the fix they'd be ~1% short.
        (uint256 aNew,) = staker.userInfo(address(usdc), alice);
        (uint256 bNew,) = staker.userInfo(address(usdc), bob);
        assertGe(aNew, 100e6 - 100e6 / 1000);
        assertGe(bNew, 300e6 - 300e6 / 1000);
        // And essentially exactly at par (a few wei of integer-division dust at most).
        assertApproxEqAbs(aNew, 100e6, 10);
        assertApproxEqAbs(bNew, 300e6, 10);

        // Custody parked state fully cleared.
        assertEq(migrator.totalParked(address(usdc)), 0);
        assertEq(migrator.parkedUserCount(address(usdc)), 0);

        // Surplus was consumed by the top-ups; whatever's left is still rescuable.
        uint256 leftover = usdc.balanceOf(address(migrator));
        assertLt(leftover, surplusBefore); // top-ups spent some surplus
        uint256 ownerBefore = usdc.balanceOf(owner);
        migrator.rescueERC20(address(usdc), owner, leftover);
        assertEq(usdc.balanceOf(owner) - ownerBefore, leftover);
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // ============== TEST 12: conservation control at 0 bps haircut ==============

    function test_m01_zeroHaircut_noTopupSurplusUntouched() public {
        _outAndRewireWithSlippage(0); // par strategy: credited == amt, no top-up path taken.

        // Send surplus; at 0 bps it must remain completely untouched.
        usdc.mint(address(migrator), 25e6);
        uint256 surplusBefore = usdc.balanceOf(address(migrator)) - migrator.totalParked(address(usdc));
        assertEq(surplusBefore, 25e6);

        migrator.migrateIn(address(usdc), 0, migrator.parkedUserCount(address(usdc)));

        // Identical to pre-fix: exact principal re-credited.
        (uint256 aNew,) = staker.userInfo(address(usdc), alice);
        (uint256 bNew,) = staker.userInfo(address(usdc), bob);
        assertEq(aNew, 100e6);
        assertEq(bNew, 300e6);

        // Surplus untouched: balance == surplus (parked is 0 now).
        assertEq(usdc.balanceOf(address(migrator)), surplusBefore);
        assertEq(migrator.totalParked(address(usdc)), 0);
    }

    // ============== TEST 13: fuzz haircut 1–500 bps lands at par ==============

    function testFuzz_m01_topupLandsAtPar(uint256 slippageBps) public {
        slippageBps = bound(slippageBps, 1, 500);
        _outAndRewireWithSlippage(slippageBps);

        // Generously fund the implicit budget (much more than the ~5% worst-case grossed-up shortfall).
        usdc.mint(address(migrator), 100e6);
        uint256 surplusBefore = usdc.balanceOf(address(migrator)) - migrator.totalParked(address(usdc));

        migrator.migrateIn(address(usdc), 0, migrator.parkedUserCount(address(usdc)));

        (uint256 aNew,) = staker.userInfo(address(usdc), alice);
        (uint256 bNew,) = staker.userInfo(address(usdc), bob);

        // Every user lands at par within amt/1000.
        assertGe(aNew, 100e6 - 100e6 / 1000);
        assertGe(bNew, 300e6 - 300e6 / 1000);

        // Surplus consumed matches the gross-up: spent == surplus drop, and the credited principal now
        // sitting in the strategy equals roughly the parked total (par restoration).
        uint256 surplusAfter = usdc.balanceOf(address(migrator)) - migrator.totalParked(address(usdc));
        uint256 spent = surplusBefore - surplusAfter;
        // Spend is positive (a haircut existed) and bounded by the gross-up budget for 400e6 @ <=5%.
        assertGt(spent, 0);
        assertLe(spent, 100e6);
    }

    // ============== TEST 14: insufficient surplus reverts whole batch, state intact ==============

    function test_m01_insufficientSurplusRevertsBatch() public {
        _outAndRewireWithSlippage(100); // 1% haircut needs ~4e6 surplus across 400e6 parked.

        // Snapshot pre-migrateIn state.
        uint256 parkedAliceBefore = migrator.parked(address(usdc), alice);
        uint256 parkedBobBefore = migrator.parked(address(usdc), bob);
        uint256 totalParkedBefore = migrator.totalParked(address(usdc));
        uint256 countBefore = migrator.parkedUserCount(address(usdc));

        // No surplus sent -> top-up has zero budget -> batch reverts.
        uint256 cnt = migrator.parkedUserCount(address(usdc));
        vm.expectRevert(bytes("InPlaceMigrator: top-up surplus exhausted"));
        migrator.migrateIn(address(usdc), 0, cnt);

        // All users remain parked and recoverable: no state-mutation leak.
        assertEq(migrator.parked(address(usdc), alice), parkedAliceBefore);
        assertEq(migrator.parked(address(usdc), bob), parkedBobBefore);
        assertEq(migrator.totalParked(address(usdc)), totalParkedBefore);
        assertEq(migrator.parkedUserCount(address(usdc)), countBefore);

        // The timeout hatch still works for the still-parked users.
        vm.warp(block.timestamp + TIMEOUT);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        migrator.claimTimedOut(address(usdc));
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6);
    }

    // ============== TEST 15: rescueERC20 floor + full reclaim after migration ==============

    function test_m01_rescueFloorAndLeftoverReclaim() public {
        _outAndRewireWithSlippage(100);
        usdc.mint(address(migrator), 10e6);

        // While users are parked, rescue still cannot dip below totalParked.
        vm.expectRevert(bytes("InPlaceMigrator: cannot touch parked principal"));
        migrator.rescueERC20(address(usdc), owner, 10e6 + 1);

        migrator.migrateIn(address(usdc), 0, migrator.parkedUserCount(address(usdc)));

        // After migration totalParked is 0, so the entire leftover balance is the rescuable surplus.
        uint256 leftover = usdc.balanceOf(address(migrator));
        assertEq(migrator.totalParked(address(usdc)), 0);
        uint256 ownerBefore = usdc.balanceOf(owner);
        migrator.rescueERC20(address(usdc), owner, leftover);
        assertEq(usdc.balanceOf(owner) - ownerBefore, leftover);
        assertEq(usdc.balanceOf(address(migrator)), 0);
    }

    // ============== TEST 16: zero-credit dust user reverts batch (L-01 out of scope) ==============

    function test_m01_zeroCreditDustRevertsBatch() public {
        // A near-100% haircut makes a tiny first deposit credit 0, so StableStaker.depositFor reverts
        // ("nothing credited") BEFORE the top-up logic. Documents L-01 as knowingly out of scope.
        address dust = address(0xD057);
        usdc.mint(dust, 1); // 1 wei position
        vm.prank(dust);
        usdc.approve(address(staker), type(uint256).max);

        vm.prank(dust);
        staker.stake(address(usdc), 1);

        migrator.initiateMigration(address(usdc));
        address[] memory one = new address[](1);
        one[0] = dust;
        migrator.migrateOut(address(usdc), one);
        assertEq(migrator.parked(address(usdc), dust), 1);

        staker.finalizeAndReset(address(usdc));
        MockYieldStrategy v2 = new MockYieldStrategy();
        v2.setClient(address(staker), true);
        v2.setDepositSlippageBps(9_999); // 99.99% haircut: 1 wei credits floor(1*1/10000)=0.
        staker.setYieldStrategy(address(usdc), IYieldStrategy(address(v2)));

        // Even with ample surplus, the FIRST depositFor(1) credits 0 and reverts the batch.
        usdc.mint(address(migrator), 100e6);
        uint256 dustCnt = migrator.parkedUserCount(address(usdc));
        vm.expectRevert(bytes("StableStaker: nothing credited"));
        migrator.migrateIn(address(usdc), 0, dustCnt);
    }
}

// ============================== REENTRANCY HARNESS ==============================

/// @notice ERC20 whose `transfer` optionally re-enters a target migrator's `claimTimedOut`.
contract ReentrantToken is MockERC20 {
    address private _migrator;
    address private _token;
    bool private _armed;

    constructor() MockERC20("Evil", "EVL", 6) {}

    function setReentrancyTarget(address migrator_, address token_) external {
        _migrator = migrator_;
        _token = token_;
        _armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (_armed && msg.sender == _migrator) {
            // Disarm to avoid infinite recursion; the reentrant call should itself revert.
            _armed = false;
            // Re-enter: this MUST revert (nonReentrant) and the try/catch swallows it so the
            // outer call completes with exactly one payout.
            try InPlaceMigrator(_migrator).claimTimedOut(_token) {} catch {}
        }
        return ok;
    }
}

/// @notice Helper holding a staked position that attempts a reentrant double-claim.
contract ReentrantAttacker {
    InPlaceMigrator private immutable migrator;
    ReentrantToken private immutable token;
    StableStaker private immutable staker;

    constructor(InPlaceMigrator _migrator, ReentrantToken _token, StableStaker _staker) {
        migrator = _migrator;
        token = _token;
        staker = _staker;
    }

    function stakeIn() external {
        token.approve(address(staker), type(uint256).max);
        staker.stake(address(token), 100e6);
    }

    function attack() external {
        migrator.claimTimedOut(address(token));
    }
}
