// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "../src/interfaces/IStableStakerMigratable.sol";
import "../src/versions/v1/IStableStakerV1.sol";
import "flax-token/FlaxToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice THE GOLDEN RULE, pinned at the ABI level: every version of {StableStaker} — past,
///         present and future — must expose `initiateMigration`, `batchMigrate` and
///         `depositFor`, with exactly these signatures.
///
/// @dev This file is the third layer of defence behind the `.claude/` PreToolUse hook and the
///      `.github/scripts/check-migration-surface.sh` CI gate. It differs from
///      `test/GoldenRuleInterface.t.sol` (story 014) in one decisive way: that file asserts the
///      interface and the implementation agree with *each other*, which stays true if BOTH are
///      changed together. This file asserts the selectors against **hard-coded byte constants**,
///      so a coordinated redesign — the realistic failure, e.g. a one-pool-per-contract rewrite
///      dropping the leading `address token` parameter — fails here even though everything still
///      compiles and agrees internally.
///
///      Those constants are not a magic number to be "fixed" when the test goes red. They are the
///      wire format the live mainnet instance at 0xbce8ABC09BaEDCabE93419bF875f6186e182079A
///      answers to. Changing a signature strands that user base; if this test fails, restore the
///      signature rather than updating the constant.
contract GoldenRuleTest is Test {
    // ============================== FROZEN SELECTORS ==============================
    // cast sig "initiateMigration(address)"                => 0x71726c92
    // cast sig "batchMigrate(address,address[])"           => 0x0ad9aeb9
    // cast sig "depositFor(address,address,uint256)"       => 0xb3db428b

    bytes4 internal constant INITIATE_MIGRATION_SELECTOR = 0x71726c92;
    bytes4 internal constant BATCH_MIGRATE_SELECTOR = 0x0ad9aeb9;
    bytes4 internal constant DEPOSIT_FOR_SELECTOR = 0xb3db428b;

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

    // ============================== SIGNATURES ARE FROZEN ==============================

    /// @notice The perpetual interface's three selectors equal the frozen byte constants. A
    ///         signature change — a renamed function, a dropped `token` parameter, a widened
    ///         argument type — moves the selector and fails here.
    function test_perpetualInterfaceSelectorsAreFrozen() public pure {
        assertEq(
            IStableStakerMigratable.initiateMigration.selector,
            INITIATE_MIGRATION_SELECTOR,
            "initiateMigration signature changed: initiateMigration(address) is frozen"
        );
        assertEq(
            IStableStakerMigratable.batchMigrate.selector,
            BATCH_MIGRATE_SELECTOR,
            "batchMigrate signature changed: batchMigrate(address,address[]) is frozen"
        );
        assertEq(
            IStableStakerMigratable.depositFor.selector,
            DEPOSIT_FOR_SELECTOR,
            "depositFor signature changed: depositFor(address,address,uint256) is frozen"
        );
    }

    /// @notice The selectors are also derivable from the literal signature strings, so the byte
    ///         constants above are self-documenting rather than opaque.
    function test_frozenSelectorsMatchTheirSignatureStrings() public pure {
        assertEq(bytes4(keccak256("initiateMigration(address)")), INITIATE_MIGRATION_SELECTOR);
        assertEq(bytes4(keccak256("batchMigrate(address,address[])")), BATCH_MIGRATE_SELECTOR);
        assertEq(bytes4(keccak256("depositFor(address,address,uint256)")), DEPOSIT_FOR_SELECTOR);
    }

    /// @notice The evergreen implementation dispatches those exact selectors.
    function test_implementationExposesFrozenSelectors() public pure {
        assertEq(StableStakerV2.initiateMigration.selector, INITIATE_MIGRATION_SELECTOR, "impl initiateMigration drift");
        assertEq(StableStakerV2.batchMigrate.selector, BATCH_MIGRATE_SELECTOR, "impl batchMigrate drift");
        assertEq(StableStakerV2.depositFor.selector, DEPOSIT_FOR_SELECTOR, "impl depositFor drift");
    }

    // ============================== EVERY VERSION SATISFIES THE RULE ==============================

    /// @notice The frozen V1 snapshot — the only accurate description of the deployed instance —
    ///         still inherits the perpetual interface, so V1 remains migratable by construction.
    ///         `IStableStakerV1 is IStableStakerMigratable` is what makes this cast compile; delete
    ///         that inheritance and this file stops building.
    function test_v1SnapshotIsCastableToMigratable() public {
        // Any address will do: the assertion is about the *type* relationship, which the compiler
        // checks, plus the selector identity the snapshot inherits.
        IStableStakerV1 v1 = IStableStakerV1(address(staker));
        IStableStakerMigratable migratable = IStableStakerMigratable(address(v1));
        assertEq(address(migratable), address(v1), "V1 snapshot must be castable to the perpetual interface");

        assertEq(v1.initiateMigration.selector, INITIATE_MIGRATION_SELECTOR, "V1 initiateMigration drift");
        assertEq(v1.batchMigrate.selector, BATCH_MIGRATE_SELECTOR, "V1 batchMigrate drift");
        assertEq(v1.depositFor.selector, DEPOSIT_FOR_SELECTOR, "V1 depositFor drift");

        // The snapshot's inherited triad is reachable on a live staker: dispatch lands in the
        // implementation's own body and trips its business-logic guard, not the fallback.
        vm.prank(migrator);
        vm.expectRevert("StableStaker: amount=0");
        v1.depositFor(address(usdc), alice, 0);
    }

    // ============================== SELECTORS RESOLVE ON A LIVE INSTANCE ==============================

    /// @notice Each frozen selector, invoked raw against a deployed `StableStaker`, reaches a real
    ///         function body. A missing function would fall through to the (absent) fallback and
    ///         revert with empty returndata; every call here reverts with the implementation's own
    ///         reason string, which is only reachable once dispatch has succeeded.
    function test_frozenSelectorsResolveOnDeployedInstance() public {
        _assertResolves(
            abi.encodeWithSelector(BATCH_MIGRATE_SELECTOR, address(usdc), new address[](0)),
            "StableStaker: pool not migrating"
        );
        _assertResolves(
            abi.encodeWithSelector(DEPOSIT_FOR_SELECTOR, address(usdc), alice, uint256(0)), "StableStaker: amount=0"
        );

        // initiateMigration is terminal, so it is exercised last: the first raw call succeeds and
        // the second is rejected by the implementation's own state guard — proof of dispatch.
        vm.prank(migrator);
        (bool ok,) = address(staker).call(abi.encodeWithSelector(INITIATE_MIGRATION_SELECTOR, address(usdc)));
        assertTrue(ok, "initiateMigration selector must resolve on a deployed StableStaker");

        _assertResolves(
            abi.encodeWithSelector(INITIATE_MIGRATION_SELECTOR, address(usdc)), "StableStaker: pool not active"
        );
    }

    /// @dev Raw-call `data` as the migrator and require it to revert with `expectedReason`. A
    ///      selector that does not exist reverts with EMPTY returndata, so a matching reason string
    ///      proves the call reached the intended function body.
    function _assertResolves(bytes memory data, string memory expectedReason) internal {
        vm.prank(migrator);
        (bool ok, bytes memory ret) = address(staker).call(data);
        assertFalse(ok, "expected the guarded call to revert");
        assertGt(ret.length, 0, "empty returndata: selector did not resolve to a function");

        // Strip the Error(string) selector and decode.
        bytes memory reasonBytes = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; i++) {
            reasonBytes[i - 4] = ret[i];
        }
        string memory reason = abi.decode(reasonBytes, (string));
        assertEq(reason, expectedReason, "dispatch did not reach the expected function body");
    }
}
