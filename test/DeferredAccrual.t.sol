// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "../src/interfaces/IStableStakerMigratable.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Deferred reward accrual (story 022): `stake` and `withdraw` no longer mint antimatter. They
///         book the settled amount to {StableStakerV2-unclaimedReward}, which {claim} and the terminal
///         migration exit pay out. The headline property is robustness: with the staker's minter role
///         revoked, every principal path still works and only {claim} reverts.
contract DeferredAccrualTest is Test {
    Antimatter internal antimatter;
    StableStakerV2 internal staker;
    MockERC20 internal usdc; // 6 decimals
    MockERC20 internal dai; // 18 decimals

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant PER_DAY = 86_400 ether; // -> 1e18 antimatter per second

    /// @dev Mirrors {StableStakerV2.MigratedOut} for vm.expectEmit.
    event MigratedOut(address indexed token, address indexed user, uint256 amount, uint256 reward);

    /// @dev Mirrors {StableStakerV2.ClaimEnabledSet} for vm.expectEmit.
    event ClaimEnabledSet(bool enabled);

    function setUp() public {
        antimatter = new Antimatter(owner);
        staker = new StableStakerV2(IAntimatter(address(antimatter)), owner);
        antimatter.setApprovedMinter(address(staker), true);
        // Story 025 gates `claim` behind an owner flag, off by default. Opened here so the story-022
        // deferred-accrual tests below keep exercising the claim path; the CLAIM GATE section closes it
        // again explicitly where the gate itself is under test.
        staker.setClaimEnabled(true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);

        staker.addToken(address(usdc));
        staker.addToken(address(dai));
        staker.antimatterPerDay(address(usdc), PER_DAY);
        staker.antimatterPerDay(address(dai), PER_DAY);

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000e6);
        dai.mint(who, 1_000_000 ether);
        vm.startPrank(who);
        usdc.approve(address(staker), type(uint256).max);
        dai.approve(address(staker), type(uint256).max);
        vm.stopPrank();
    }

    function _stake(address who, address token, uint256 amount) internal {
        vm.prank(who);
        staker.stake(token, amount);
    }

    function _withdraw(address who, address token, uint256 amount) internal {
        vm.prank(who);
        staker.withdraw(token, amount);
    }

    // ------------------------------------------------------ booking, not minting

    function test_stake_onExistingPosition_booksInsteadOfMinting() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);

        _stake(alice, address(usdc), 50e6);

        assertEq(antimatter.balanceOf(alice), 0, "stake must not mint");
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether, "stake books the pending");
        assertEq(staker.pendingReward(address(usdc), alice), 0, "rewardDebt reset as before");
    }

    function test_withdraw_partial_booksInsteadOfMinting() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);

        uint256 balBefore = usdc.balanceOf(alice);
        _withdraw(alice, address(usdc), 40e6);

        assertEq(usdc.balanceOf(alice), balBefore + 40e6, "principal payout unchanged");
        assertEq(antimatter.balanceOf(alice), 0, "withdraw must not mint");
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);
        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 60e6);
    }

    function test_withdraw_full_booksInsteadOfMinting() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);

        uint256 balBefore = usdc.balanceOf(alice);
        _withdraw(alice, address(usdc), 100e6);

        assertEq(usdc.balanceOf(alice), balBefore + 100e6);
        assertEq(antimatter.balanceOf(alice), 0);
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);
        assertEq(staker.stakerCount(address(usdc)), 0);
    }

    // ------------------------------------------------------------------- claim

    function test_claim_paysBacklogPlusPending_thenReverts() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _withdraw(alice, address(usdc), 40e6); // books 100 ether
        vm.warp(block.timestamp + 100); // accrues a further 100 ether live

        vm.prank(alice);
        staker.claim(address(usdc));

        // 1 wei tolerance: `accAntimatterPerShare` truncates when totalStaked changes mid-window. That
        // dust is retained by the protocol, exactly as before this change.
        assertApproxEqAbs(antimatter.balanceOf(alice), 200 ether, 1, "claim mints backlog + pending");
        assertEq(staker.unclaimedReward(address(usdc), alice), 0, "backlog drained");

        vm.prank(alice);
        vm.expectRevert("StableStaker: nothing to claim");
        staker.claim(address(usdc));
    }

    function test_claim_worksForFullyWithdrawnUser() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _withdraw(alice, address(usdc), 100e6);

        (uint256 amount,) = staker.userInfo(address(usdc), alice);
        assertEq(amount, 0, "position fully exited");
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);

        vm.prank(alice);
        staker.claim(address(usdc));
        assertEq(antimatter.balanceOf(alice), 100 ether);
        assertEq(staker.unclaimedReward(address(usdc), alice), 0);
    }

    // --------------------------------------------------------- emergencyWithdraw

    function test_emergencyWithdraw_forfeitsUnclaimed() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _stake(alice, address(usdc), 1e6); // books 100 ether
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        staker.emergencyWithdraw(address(usdc));

        assertEq(staker.unclaimedReward(address(usdc), alice), 0, "escape hatch forfeits the backlog");
        assertEq(antimatter.balanceOf(alice), 0);
        assertEq(staker.claimableReward(address(usdc), alice), 0);

        vm.prank(alice);
        vm.expectRevert("StableStaker: nothing to claim");
        staker.claim(address(usdc));
    }

    // -------------------------------------------------------- path independence

    /// @dev A sole staker earns the pool's whole emission for the window regardless of how many
    ///      stake/withdraw settlements chop it up. Two identical windows, different action paths.
    function test_pathIndependence_sameTotalMinted() public {
        uint256 t0 = block.timestamp;

        // Path A on USDC: settle twice along the way.
        _stake(alice, address(usdc), 100e6);
        // Path B on DAI: never settle until the final claim.
        _stake(bob, address(dai), 100 ether);

        vm.warp(t0 + 100);
        _withdraw(alice, address(usdc), 40e6);
        vm.warp(t0 + 200);

        vm.prank(alice);
        staker.claim(address(usdc));
        vm.prank(bob);
        staker.claim(address(dai));

        // 1 wei apart at most: the only difference is `accAntimatterPerShare` truncation at the extra
        // settlement point, which pre-dates this story and rounds in the protocol's favour.
        assertApproxEqAbs(antimatter.balanceOf(alice), 200 ether, 1);
        assertEq(antimatter.balanceOf(bob), 200 ether);
        assertApproxEqAbs(antimatter.balanceOf(alice), antimatter.balanceOf(bob), 1, "payout is path-independent");
    }

    // ------------------------------------------------------ ROBUSTNESS (headline)

    /// @notice With the staker's minter role revoked, every principal path still works. Only
    ///         {claim} reverts. This is the whole point of the change.
    function test_minterRevoked_principalPathsUnaffected_onlyClaimReverts() public {
        _stake(alice, address(usdc), 100e6);
        _stake(bob, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);

        antimatter.setApprovedMinter(address(staker), false);

        // stake on an existing position: settles, does not mint.
        _stake(alice, address(usdc), 10e6);
        assertGt(staker.unclaimedReward(address(usdc), alice), 0);

        // withdraw: settles, does not mint.
        _withdraw(alice, address(usdc), 10e6);

        // emergencyWithdraw: pure storage, never minted anyway.
        vm.prank(bob);
        staker.emergencyWithdraw(address(usdc));

        // Only claim needs the minter role. Antimatter rejects the revoked staker with a custom
        // error, not a reason string.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Antimatter.NotApprovedMinter.selector, address(staker)));
        staker.claim(address(usdc));
    }

    // ---------------------------------------------------------- terminal migration

    function _engageMigration() internal {
        staker.setMigrator(address(this));
        staker.initiateMigration(address(usdc));
    }

    function test_batchMigrate_paysPendingPlusUnclaimed() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _stake(alice, address(usdc), 100e6); // books 100 ether BEFORE initiateMigration
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);
        vm.warp(block.timestamp + 100); // a further 100 ether of live pending

        uint256 pending = staker.pendingReward(address(usdc), alice);
        assertEq(pending, 100 ether);

        _engageMigration();

        address[] memory users = new address[](1);
        users[0] = alice;
        staker.batchMigrate(address(usdc), users);

        assertEq(antimatter.balanceOf(alice), 200 ether, "exit pays pending + unclaimed");
        assertEq(staker.unclaimedReward(address(usdc), alice), 0, "backlog drained by the exit");
    }

    function test_userMigrate_paysPendingPlusUnclaimed() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _stake(alice, address(usdc), 100e6); // books 100 ether
        vm.warp(block.timestamp + 100);

        _engageMigration();

        vm.prank(alice);
        staker.userMigrate(address(usdc));

        assertEq(antimatter.balanceOf(alice), 200 ether);
        assertEq(staker.unclaimedReward(address(usdc), alice), 0);
        assertEq(staker.claimableReward(address(usdc), alice), 0);
    }

    function test_migratedOut_carriesCombinedReward() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _stake(alice, address(usdc), 100e6); // books 100 ether
        vm.warp(block.timestamp + 100);

        _engageMigration();

        vm.expectEmit(true, true, false, true);
        emit MigratedOut(address(usdc), alice, 200e6, 200 ether);
        vm.prank(alice);
        staker.userMigrate(address(usdc));
    }

    // ------------------------------------------------------------ claimableReward

    function test_claimableReward_tracksUnclaimedPlusPending() public {
        assertEq(staker.claimableReward(address(usdc), alice), 0);

        _stake(alice, address(usdc), 100e6);
        _assertClaimableIsSum(alice);

        vm.warp(block.timestamp + 100);
        _assertClaimableIsSum(alice);
        assertEq(staker.claimableReward(address(usdc), alice), 100 ether);

        _withdraw(alice, address(usdc), 40e6);
        _assertClaimableIsSum(alice);
        assertEq(staker.claimableReward(address(usdc), alice), 100 ether);

        vm.warp(block.timestamp + 100);
        _assertClaimableIsSum(alice);
        // 1 wei of accumulator truncation dust after the mid-window totalStaked change.
        assertApproxEqAbs(staker.claimableReward(address(usdc), alice), 200 ether, 1);
    }

    function _assertClaimableIsSum(address who) internal view {
        assertEq(
            staker.claimableReward(address(usdc), who),
            staker.unclaimedReward(address(usdc), who) + staker.pendingReward(address(usdc), who),
            "claimableReward == unclaimedReward + pendingReward"
        );
    }

    function test_claimableReward_equalsWhatClaimMints() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _withdraw(alice, address(usdc), 40e6);
        vm.warp(block.timestamp + 100);

        uint256 expected = staker.claimableReward(address(usdc), alice);
        assertGt(expected, 0);

        uint256 balBefore = antimatter.balanceOf(alice);
        vm.prank(alice);
        staker.claim(address(usdc));

        assertEq(antimatter.balanceOf(alice) - balBefore, expected, "claim mints exactly claimableReward");
        assertEq(staker.claimableReward(address(usdc), alice), 0, "reads zero straight after");
    }

    /// @notice `pendingReward` keeps its exact V1 meaning: the live projection only, EXCLUDING the
    ///         settled-but-unminted backlog. This is load-bearing for cross-version reads.
    function test_pendingReward_excludesBacklog() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        _withdraw(alice, address(usdc), 100e6); // full exit: books 100 ether, position is empty

        assertEq(staker.pendingReward(address(usdc), alice), 0, "pendingReward is projection-only");
        assertEq(staker.unclaimedReward(address(usdc), alice), 100 ether);
        assertEq(staker.claimableReward(address(usdc), alice), 100 ether, "claimable carries the backlog");
    }
    // ============================== CLAIM GATE (story 025) ==============================

    /// @notice `claimEnabled` is a UX gate, not an access control: it is off on a freshly deployed
    ///         staker so users are steered to {StableStakerV2-autoAnnihilate} and learn what
    ///         antimatter is for. One owner transaction reverses it, with no redeploy.
    function test_claimEnabled_defaultsToFalseOnAFreshStaker() public {
        StableStakerV2 fresh = new StableStakerV2(IAntimatter(address(antimatter)), owner);
        assertFalse(fresh.claimEnabled(), "off by default");
    }

    function test_claim_revertsWhileClaimDisabled() public {
        staker.setClaimEnabled(false);
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        vm.expectRevert("StableStaker: claim disabled");
        staker.claim(address(usdc));

        // The reward is not lost, merely unminted: it stays readable and claimable later.
        assertEq(staker.claimableReward(address(usdc), alice), 100 ether, "reward still owed");
    }

    function test_claim_succeedsOnceEnabled() public {
        staker.setClaimEnabled(false);
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);

        staker.setClaimEnabled(true);
        vm.prank(alice);
        staker.claim(address(usdc));
        assertEq(antimatter.balanceOf(alice), 100 ether, "claim pays the full owed figure");
    }

    function test_setClaimEnabled_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staker.setClaimEnabled(false);
    }

    function test_setClaimEnabled_emitsClaimEnabledSet() public {
        staker.setClaimEnabled(false);
        vm.expectEmit(false, false, false, true, address(staker));
        emit ClaimEnabledSet(true);
        staker.setClaimEnabled(true);
    }

    /// @notice The migration carve-out: the antimatter mint inside the terminal-migration exit is
    ///         deliberately NOT gated by `claimEnabled`. Gating it would let a disabled claim brick
    ///         migration, which is the one path that must never be brickable.
    function test_terminalMigrationExit_stillMints_whileClaimDisabled() public {
        _stake(alice, address(usdc), 100e6);
        vm.warp(block.timestamp + 100);
        staker.setClaimEnabled(false);

        staker.setMigrator(owner);
        staker.initiateMigration(address(usdc));
        vm.prank(alice);
        staker.userMigrate(address(usdc));

        assertEq(antimatter.balanceOf(alice), 100 ether, "migration exit pays reward regardless");
    }
}
