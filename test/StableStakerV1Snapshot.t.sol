// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStaker.sol";
import "../src/versions/IStableStakerV1.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldStrategy} from "./mocks/MockYieldStrategy.sol";

/// @notice Fidelity proof for the frozen V1 snapshot, `src/versions/IStableStakerV1.sol`.
///
/// @dev The strongest guarantee here is again the COMPILER's: every call below is made through an
///      `IStableStakerV1` handle pointing at a real `StableStaker`, so if the snapshot ever declared
///      a member the implementation does not have — wrong name, wrong parameter types, wrong return
///      arity — this file would fail to compile or the call would hit the "function does not exist"
///      path. That makes the test a compile-and-call proof that the snapshot is a faithful *subset*
///      of `src/StableStaker.sol`.
///
///      What it deliberately does NOT prove: that the live mainnet instance at
///      0xbce8ABC09BaEDCabE93419bF875f6186e182079A matches. That needs a fork test, and deployment
///      reconciliation was explicitly retained by the human.
///
///      Direction of the guarantee matters. This proves snapshot ⊆ implementation. It does not
///      prove implementation ⊆ snapshot, and it must not: `StableStaker.sol` is the evergreen
///      current version and is expected to grow past V1. When it does, the answer is a NEW snapshot
///      under `src/versions/`, never an edit to this one.
contract StableStakerV1SnapshotTest is Test {
    FlaxToken internal phUSD;
    StableStaker internal staker;
    MockERC20 internal usdc;
    MockYieldStrategy internal strategy;

    /// @dev Every assertion in this file goes through this handle, never through `staker` directly.
    IStableStakerV1 internal v1;

    address internal owner = address(this);
    address internal migrator = address(0x316A);
    address internal pauserAddr = address(0xAB5E4);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStaker(phUSD, owner);
        phUSD.setMinter(address(staker), true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        strategy = new MockYieldStrategy();
        strategy.setClient(address(staker), true);

        v1 = IStableStakerV1(address(staker));

        v1.addToken(address(usdc));
        v1.phUSDPerDay(address(usdc), 7e18);
        v1.setMigrator(migrator);
        v1.setPauser(pauserAddr);

        usdc.mint(alice, 1_000e6);
        usdc.mint(bob, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(staker), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(staker), type(uint256).max);
    }

    // ============================== IDENTITY ==============================

    /// @notice A deployed `StableStaker` is castable to the frozen V1 snapshot, and the cast
    ///         resolves to the staker itself (no proxy or adapter hop).
    function test_stakerIsCastableToV1Snapshot() public view {
        assertEq(address(v1), address(staker), "V1 cast must resolve to the staker itself");
    }

    /// @notice V1 extends the perpetual golden-rule interface, so a V1 handle is also a
    ///         migratable handle. This is the property that keeps the deployed instance reachable
    ///         by any future migrator.
    function test_v1ExtendsGoldenRuleInterface() public view {
        IStableStakerMigratable migratable = IStableStakerMigratable(address(v1));
        assertEq(address(migratable), address(staker), "V1 must be usable wherever the triad is required");

        assertEq(
            IStableStakerMigratable.initiateMigration.selector,
            StableStaker.initiateMigration.selector,
            "initiateMigration selector drift"
        );
        assertEq(
            IStableStakerMigratable.batchMigrate.selector,
            StableStaker.batchMigrate.selector,
            "batchMigrate selector drift"
        );
        assertEq(
            IStableStakerMigratable.depositFor.selector, StableStaker.depositFor.selector, "depositFor selector drift"
        );
    }

    // ============================== OWNER CONFIG ==============================

    /// @notice Every owner-config member declared by the snapshot dispatches to the real body.
    ///         `addToken`, `phUSDPerDay`, `setMigrator` and `setPauser` were already exercised in
    ///         {setUp}; this asserts their effects and covers the remainder.
    function test_ownerConfigSurface() public {
        assertEq(v1.migrator(), migrator, "setMigrator must have landed");
        assertEq(v1.pauser(), pauserAddr, "setPauser must have landed");

        // addToken: a second pool registers and shows up in the registered-token set.
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        v1.addToken(address(dai));
        address[] memory tokens = v1.getStakedTokens();
        assertEq(tokens.length, 2, "addToken must register a second pool");

        // phUSDPerDay: the per-second rate is derived from the per-day figure.
        (uint256 phusdPerSecond,,,) = v1.poolInfo(address(usdc));
        assertEq(phusdPerSecond, 7e18 / v1.SECONDS_PER_DAY(), "phUSDPerDay must set the per-second rate");

        // setYieldStrategy: wire, then unwire, on an empty pool.
        v1.setYieldStrategy(address(usdc), IYieldStrategy(address(strategy)));
        assertEq(address(v1.yieldStrategy(address(usdc))), address(strategy), "strategy must be wired");
        v1.setYieldStrategy(address(usdc), IYieldStrategy(address(0)));
        assertEq(address(v1.yieldStrategy(address(usdc))), address(0), "strategy must be unwired");

        // rescueERC20: a stray, unregistered token sitting in the contract is recoverable.
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(staker), 5e18);
        v1.rescueERC20(address(stray), bob, 5e18);
        assertEq(stray.balanceOf(bob), 5e18, "rescueERC20 must move the stray balance");
    }

    // ============================== PAUSING ==============================

    /// @notice `pause` / `unpause` / `paused` / `pauser` all dispatch through the snapshot with the
    ///         deployed contract's own permissioning intact.
    function test_pausingSurface() public {
        assertFalse(v1.paused(), "fresh staker must be unpaused");

        vm.prank(pauserAddr);
        v1.pause();
        assertTrue(v1.paused(), "pause must set the flag");

        // Owner OR pauser may unpause; this is the owner path.
        v1.unpause();
        assertFalse(v1.paused(), "unpause must clear the flag");

        // The snapshot does not weaken the guard: a stranger still cannot pause.
        vm.prank(alice);
        vm.expectRevert("StableStaker: only pauser");
        v1.pause();
    }

    // ============================== USER SURFACE ==============================

    /// @notice `stake`, `claim`, `withdraw` and `emergencyWithdraw` all resolve on a live instance
    ///         and move real state.
    function test_userSurface() public {
        vm.prank(alice);
        v1.stake(address(usdc), 100e6);
        (uint256 staked,) = v1.userInfo(address(usdc), alice);
        assertEq(staked, 100e6, "stake must credit principal");

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        v1.claim(address(usdc));
        assertGt(phUSD.balanceOf(alice), 0, "claim must mint reward");

        vm.prank(alice);
        v1.withdraw(address(usdc), 40e6);
        (staked,) = v1.userInfo(address(usdc), alice);
        assertEq(staked, 60e6, "withdraw must reduce principal");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        v1.emergencyWithdraw(address(usdc));
        assertEq(usdc.balanceOf(alice) - balBefore, 60e6, "emergencyWithdraw must return the remainder");
        assertEq(v1.stakerCount(address(usdc)), 0, "pool must be empty after the escape hatch");
    }

    // ============================== VIEWS ==============================

    /// @notice Every read-only member declared by the snapshot resolves and returns live data.
    function test_viewSurface() public {
        vm.prank(alice);
        v1.stake(address(usdc), 100e6);
        vm.prank(bob);
        v1.stake(address(usdc), 300e6);

        vm.warp(block.timestamp + 1 days);

        assertGt(v1.pendingReward(address(usdc), alice), 0, "pendingReward must accrue");

        address[] memory stakers = v1.getStakers(address(usdc));
        assertEq(stakers.length, 2, "getStakers must list both stakers");

        address[] memory page = v1.getStakersRange(address(usdc), 0, 1);
        assertEq(page.length, 1, "getStakersRange must page");
        assertEq(page[0], stakers[0], "getStakersRange must agree with getStakers");

        assertEq(v1.stakerCount(address(usdc)), 2, "stakerCount must match");

        address[] memory tokens = v1.getStakedTokens();
        assertEq(tokens.length, 1, "getStakedTokens must list the one registered pool");
        assertEq(tokens[0], address(usdc), "getStakedTokens must name the pool token");

        // No strategy wired, so withdrawals are never strategy-blocked.
        assertFalse(v1.withdrawDisabled(address(usdc)), "withdrawDisabled must be false with no strategy");
    }

    // ============================== AUTO-GETTERS ==============================

    /// @notice The public auto-getters consumers already rely on are pinned at the exact arities the
    ///         deployed contract exposes. Any arity change here is a NEW version, not an edit.
    function test_autoGetterSurface() public {
        vm.prank(alice);
        v1.stake(address(usdc), 100e6);

        (uint256 phusdPerSecond, uint256 accPhusdPerShare, uint256 lastRewardTime, uint256 totalStaked) =
            v1.poolInfo(address(usdc));
        assertEq(phusdPerSecond, uint256(7e18) / 86400, "poolInfo.phusdPerSecond");
        assertEq(accPhusdPerShare, 0, "poolInfo.accPhusdPerShare starts at zero");
        assertEq(lastRewardTime, block.timestamp, "poolInfo.lastRewardTime");
        assertEq(totalStaked, 100e6, "poolInfo.totalStaked");

        assertEq(uint256(v1.poolState(address(usdc))), uint256(0), "poolState 0 == Active");

        (uint256 realized, uint256 principalSnapshot) = v1.migrationInfo(address(usdc));
        assertEq(realized, 0, "migrationInfo.realized is empty while Active");
        assertEq(principalSnapshot, 0, "migrationInfo.principalSnapshot is empty while Active");

        assertEq(address(v1.yieldStrategy(address(usdc))), address(0), "yieldStrategy defaults to idle");
        assertEq(address(v1.phUSD()), address(phUSD), "phUSD must be the reward token");
        assertEq(v1.ACC_PRECISION(), 1e18, "ACC_PRECISION is pinned at 1e18");
        assertEq(v1.SECONDS_PER_DAY(), 86400, "SECONDS_PER_DAY is pinned at 86400");
    }

    /// @notice **`userInfo` arity is load-bearing.** V1's `struct UserInfo` has exactly two fields,
    ///         so the auto-getter is a 2-tuple. `docs/deferred-reward-accrual-plan.md` §4 warns that
    ///         appending a field turns it into a 3-tuple and breaks ~25 destructuring sites plus
    ///         `InPlaceMigrator`. This snapshot pins the 2-tuple form permanently.
    /// @dev Two independent proofs. The destructuring below is the COMPILE-time one: adding a third
    ///      field to the snapshot's declaration would stop this file compiling. The raw-returndata
    ///      length check is the RUNTIME one: it observes that the deployed contract really encodes
    ///      exactly two words, which a compile-time cast alone cannot show.
    function test_userInfoDestructuresToExactlyTwoValues() public {
        vm.prank(alice);
        v1.stake(address(usdc), 100e6);

        (uint256 amount, uint256 rewardDebt) = v1.userInfo(address(usdc), alice);
        assertEq(amount, 100e6, "userInfo.amount");
        assertEq(rewardDebt, 0, "userInfo.rewardDebt at first stake");

        (bool ok, bytes memory raw) =
            address(staker).staticcall(abi.encodeWithSelector(IStableStakerV1.userInfo.selector, address(usdc), alice));
        assertTrue(ok, "userInfo must resolve on the deployed instance");
        assertEq(raw.length, 64, "userInfo must ABI-encode EXACTLY 2 words - a 3rd field is a NEW version");
    }

    // ============================== MIGRATION LIFECYCLE ==============================

    /// @notice The full terminal-migration lifecycle driven entirely through the snapshot handle:
    ///         `initiateMigration` -> `userMigrate` / `batchMigrate` -> `finalizeAndReset`, plus
    ///         `depositFor` crediting into the revived pool.
    function test_migrationLifecycleThroughSnapshot() public {
        vm.prank(alice);
        v1.stake(address(usdc), 100e6);
        vm.prank(bob);
        v1.stake(address(usdc), 300e6);

        vm.prank(migrator);
        v1.initiateMigration(address(usdc));
        assertEq(uint256(v1.poolState(address(usdc))), uint256(1), "poolState 1 == Migrating");

        (uint256 realized, uint256 principalSnapshot) = v1.migrationInfo(address(usdc));
        assertEq(realized, 400e6, "realized R must equal the idle principal");
        assertEq(principalSnapshot, 400e6, "principal snapshot P must equal totalStaked at engagement");

        // userMigrate: self-service exit at the frozen snapshot credit.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        v1.userMigrate(address(usdc));
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6, "userMigrate must pay the snapshot credit at par");

        // batchMigrate: permissioned drain of the remainder to the migrator.
        address[] memory users = new address[](1);
        users[0] = bob;
        vm.prank(migrator);
        uint256[] memory amounts = v1.batchMigrate(address(usdc), users);
        assertEq(amounts.length, 1, "batchMigrate must return one credit per user");
        assertEq(amounts[0], 300e6, "batchMigrate credit at par equals principal");
        assertEq(usdc.balanceOf(migrator), 300e6, "aggregate credit must land on the migrator");

        // finalizeAndReset: the drained pool returns to Active.
        assertEq(v1.stakerCount(address(usdc)), 0, "pool must be fully drained");
        v1.finalizeAndReset(address(usdc));
        assertEq(uint256(v1.poolState(address(usdc))), uint256(0), "finalizeAndReset must return the pool to Active");

        // depositFor: the migrator credits bob back into the revived pool.
        vm.startPrank(migrator);
        usdc.approve(address(staker), type(uint256).max);
        v1.depositFor(address(usdc), bob, 300e6);
        vm.stopPrank();
        (uint256 credited,) = v1.userInfo(address(usdc), bob);
        assertEq(credited, 300e6, "depositFor must credit the destination position");
    }

    // ============================== OWNABLE ==============================

    /// @notice The inherited OZ {Ownable} members consumers rely on are part of the frozen surface.
    function test_ownableSurface() public {
        assertEq(v1.owner(), owner, "owner must be the deployer-configured owner");

        v1.transferOwnership(alice);
        assertEq(v1.owner(), alice, "transferOwnership must move ownership");

        vm.prank(alice);
        v1.renounceOwnership();
        assertEq(v1.owner(), address(0), "renounceOwnership must clear ownership");
    }
}
