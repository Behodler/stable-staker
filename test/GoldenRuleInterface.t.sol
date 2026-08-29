// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "../src/interfaces/IStableStaker.sol";
import "../src/interfaces/IStableStakerMigratable.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The golden rule: EVERY version of `StableStaker` must expose `initiateMigration`,
///         `batchMigrate` and `depositFor` so a migrator can always drain one version and credit
///         another. Story 014 turned that convention into a compile-time obligation by declaring
///         `contract StableStakerV2 is ... IStableStaker`.
///
/// @dev The strongest guarantee here is the COMPILER's, not this file's: once `StableStaker`
///      declares `is IStableStaker`, deleting any of the three functions fails the build outright,
///      so no runtime test can ever observe their absence. These assertions therefore guard the
///      layer the compiler cannot: that the *signatures* pinned in `IStableStakerMigratable` are
///      the ones actually dispatched on a deployed instance (selector identity), and that a live
///      staker address is castable to the perpetual interface. A future version that renamed a
///      parameter type — or dropped the leading `token` parameter for a one-pool redesign — would
///      change the selector and break migration silently at the call site; this catches that.
contract GoldenRuleInterfaceTest is Test {
    FlaxToken internal phUSD;
    StableStakerV2 internal staker;
    MockERC20 internal usdc;

    address internal owner = address(this);
    address internal migrator = address(0x316A);
    address internal alice = address(0xA11CE);

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStakerV2(phUSD, owner);
        phUSD.setMinter(address(staker), true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        staker.addToken(address(usdc));
        staker.setMigrator(migrator);
    }

    /// @notice A deployed `StableStaker` is castable to the perpetual migration interface, and the
    ///         cast address is the staker itself (no proxy/adapter hop).
    function test_stakerIsCastableToMigratableInterface() public view {
        IStableStakerMigratable migratable = IStableStakerMigratable(address(staker));
        assertEq(address(migratable), address(staker), "cast must resolve to the staker itself");

        // `IStableStaker` extends the triad, so the same instance satisfies the wider interface too.
        IStableStaker full = IStableStaker(address(staker));
        assertEq(address(full), address(staker), "IStableStaker cast must resolve to the staker");
    }

    /// @notice The selectors the interface pins are the selectors `StableStaker` actually exposes.
    ///         This is what freezes the signatures: all three lead with `address token`.
    function test_goldenSelectorsMatchImplementation() public view {
        // `userInfo` rides on `IStableStaker` only; the public mapping's auto-getter must match it.
        // Read off an instance, since a public state variable's auto-getter is not addressable as
        // `StableStaker.userInfo.selector` at the type level.
        assertEq(IStableStaker.userInfo.selector, staker.userInfo.selector, "userInfo selector drift");

        assertEq(
            IStableStakerMigratable.initiateMigration.selector,
            StableStakerV2.initiateMigration.selector,
            "initiateMigration selector drift"
        );
        assertEq(
            IStableStakerMigratable.batchMigrate.selector,
            StableStakerV2.batchMigrate.selector,
            "batchMigrate selector drift"
        );
        assertEq(
            IStableStakerMigratable.depositFor.selector, StableStakerV2.depositFor.selector, "depositFor selector drift"
        );
    }

    /// @notice Each golden selector actually resolves on a deployed instance: calling it does NOT
    ///         hit the fallback/"function does not exist" path. Every call is made as the configured
    ///         migrator and asserted to revert with the implementation's OWN business-logic revert
    ///         string — proof that dispatch reached the real function body.
    function test_goldenSelectorsResolveOnDeployedInstance() public {
        IStableStakerMigratable migratable = IStableStakerMigratable(address(staker));
        address[] memory users = new address[](1);
        users[0] = alice;

        // batchMigrate: reaches the body and trips the "must initiateMigration first" guard.
        vm.prank(migrator);
        vm.expectRevert("StableStaker: pool not migrating");
        migratable.batchMigrate(address(usdc), users);

        // depositFor: reaches the body and trips the amount==0 guard.
        vm.prank(migrator);
        vm.expectRevert("StableStaker: amount=0");
        migratable.depositFor(address(usdc), alice, 0);

        // initiateMigration: reaches the body and succeeds on an Active pool. Asserted last since
        // it is terminal and flips the pool out of Active.
        vm.prank(migrator);
        migratable.initiateMigration(address(usdc));

        // Proof the call landed: the pool is now Migrating, so a second call is rejected by the
        // implementation's own state guard.
        vm.prank(migrator);
        vm.expectRevert("StableStaker: pool not active");
        migratable.initiateMigration(address(usdc));
    }

    /// @notice The permissioning that makes the triad safe is preserved through the interface cast:
    ///         all three are `onlyMigrator`, so a non-migrator caller is rejected.
    function test_goldenFunctionsRemainMigratorGatedThroughInterface() public {
        IStableStakerMigratable migratable = IStableStakerMigratable(address(staker));
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.startPrank(alice);
        vm.expectRevert("StableStaker: only migrator");
        migratable.initiateMigration(address(usdc));

        vm.expectRevert("StableStaker: only migrator");
        migratable.batchMigrate(address(usdc), users);

        vm.expectRevert("StableStaker: only migrator");
        migratable.depositFor(address(usdc), alice, 1);
        vm.stopPrank();
    }

    /// @notice `userInfo` is reachable through the interface and returns the live position, which is
    ///         what `InPlaceMigrator` relies on to size its re-injection top-up.
    function test_userInfoReadableThroughInterface() public {
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(staker), type(uint256).max);
        staker.stake(address(usdc), 10e6);
        vm.stopPrank();

        (uint256 amount,) = IStableStaker(address(staker)).userInfo(address(usdc), alice);
        assertEq(amount, 10e6, "userInfo must report the staked principal through the interface");
    }
}
