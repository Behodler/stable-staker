// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/versions/v1/StableStakerV1.sol";
import "../src/interfaces/IStableStakerMigratable.sol";
import "flax-token/FlaxToken.sol";

/// @notice Proof that `src/versions/v1/StableStakerV1.sol` — the frozen source of the live mainnet
///         instance 0xbce8ABC09BaEDCabE93419bF875f6186e182079A — is **deployable**, not merely
///         parseable.
///
/// @dev Why this file exists (story 019). Story 016 froze V1 as an interface only. An interface
///      cannot be fork-tested and cannot be deployed, so it could not support a runbook, a recovery
///      rehearsal, or an audit that needs to reason about what the deployed bytecode actually does.
///      The frozen full-source copy can. This test is the guard that keeps that property true: a
///      library pin drift that broke the frozen copy's compilation would fail here first.
///
///      The constructor arguments below are the REAL mainnet deploy arguments, read out of
///      `phase-2-staging/broadcast/ResumeStableStakerMigration.s.sol/1/run-latest.json`
///      (2026-06-10). They are addresses with no code on a bare local chain, which is fine: the
///      constructor only stores them and rejects a zero phUSD.
///
///      This file must NOT grow behavioural assertions about V1's bugs. `ss14m1` and `ss14l8` are
///      deliberately preserved in the frozen copy and are the subject of separate stories; asserting
///      them here would turn a deployability smoke test into a bug-freezing test.
contract StableStakerV1FrozenTest is Test {
    // ============================== MAINNET DEPLOY FACTS ==============================

    /// @dev The live V1 instance. Deployed 2026-06-10 from stable-staker commit `c3ec65b`.
    address internal constant MAINNET_V1 = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;

    /// @dev Constructor arg 0: the mainnet phUSD token.
    address internal constant MAINNET_PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;

    /// @dev Constructor arg 1: the owner the deploy handed V1 to.
    address internal constant MAINNET_OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Pools registered by the deploy, with their per-day phUSD budgets.
    address internal constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // Golden-rule selectors, hard-coded exactly as `test/GoldenRule.t.sol` pins them.
    bytes4 internal constant INITIATE_MIGRATION_SELECTOR = 0x71726c92;
    bytes4 internal constant BATCH_MIGRATE_SELECTOR = 0x0ad9aeb9;
    bytes4 internal constant DEPOSIT_FOR_SELECTOR = 0xb3db428b;

    // ============================== DEPLOYABILITY ==============================

    /// @notice The frozen V1 source deploys with the exact constructor arguments mainnet used, and
    ///         lands runtime bytecode.
    function test_frozenV1DeploysWithMainnetConstructorArgs() public {
        StableStakerV1 v1 = new StableStakerV1(IFlax(MAINNET_PHUSD), MAINNET_OWNER);

        assertTrue(address(v1) != address(0), "frozen V1 must deploy");
        assertGt(address(v1).code.length, 0, "frozen V1 must land runtime bytecode");
        assertEq(address(v1.phUSD()), MAINNET_PHUSD, "phUSD immutable must be the constructor arg");
        assertEq(v1.owner(), MAINNET_OWNER, "owner must be the constructor arg");
        assertEq(v1.ACC_PRECISION(), 1e18, "ACC_PRECISION is pinned");
        assertEq(v1.SECONDS_PER_DAY(), 86400, "SECONDS_PER_DAY is pinned");
    }

    /// @notice The deploy script's own configuration sequence replays against the frozen copy: three
    ///         pools at 5 / 7 / 10 phUSD per day, plus the migrator and pauser wiring.
    function test_frozenV1ReplaysTheMainnetConfigurationSequence() public {
        StableStakerV1 v1 = new StableStakerV1(IFlax(MAINNET_PHUSD), address(this));

        v1.addToken(DOLA);
        v1.phUSDPerDay(DOLA, 5e18);
        v1.addToken(USDC);
        v1.phUSDPerDay(USDC, 7e18);
        v1.addToken(USDe);
        v1.phUSDPerDay(USDe, 10e18);

        address[] memory tokens = v1.getStakedTokens();
        assertEq(tokens.length, 3, "the mainnet deploy registered three pools");

        (uint256 dolaRate,,,) = v1.poolInfo(DOLA);
        (uint256 usdcRate,,,) = v1.poolInfo(USDC);
        (uint256 usdeRate,,,) = v1.poolInfo(USDe);
        assertEq(dolaRate, uint256(5e18) / 86400, "DOLA rate");
        assertEq(usdcRate, uint256(7e18) / 86400, "USDC rate");
        assertEq(usdeRate, uint256(10e18) / 86400, "USDe rate");

        v1.setMigrator(address(0x316A));
        assertEq(v1.migrator(), address(0x316A), "setMigrator must land");
        v1.setPauser(address(0xAB5E4));
        assertEq(v1.pauser(), address(0xAB5E4), "setPauser must land");
    }

    // ============================== THE GOLDEN RULE ON V1 ==============================

    /// @notice The frozen V1 exposes the migration triad at exactly the frozen selectors. These are
    ///         the selectors the live instance answers to; if this fails, the frozen copy is no
    ///         longer an honest description of what is on chain.
    function test_frozenV1ExposesTheGoldenRuleSelectors() public pure {
        assertEq(StableStakerV1.initiateMigration.selector, INITIATE_MIGRATION_SELECTOR, "V1 initiateMigration drift");
        assertEq(StableStakerV1.batchMigrate.selector, BATCH_MIGRATE_SELECTOR, "V1 batchMigrate drift");
        assertEq(StableStakerV1.depositFor.selector, DEPOSIT_FOR_SELECTOR, "V1 depositFor drift");
    }

    /// @notice A deployed frozen V1 dispatches all three selectors: each raw call reaches a real
    ///         function body (it reverts on a business-logic guard, not on "function does not
    ///         exist", which returns empty returndata).
    function test_frozenV1DispatchesTheTriadAtRuntime() public {
        StableStakerV1 v1 = new StableStakerV1(IFlax(MAINNET_PHUSD), address(this));
        v1.addToken(USDC);
        v1.setMigrator(address(this));

        // depositFor: reaches the amount==0 guard inside the body.
        _expectBodyRevert(
            address(v1),
            abi.encodeWithSelector(DEPOSIT_FOR_SELECTOR, USDC, address(0xA11CE), uint256(0)),
            "StableStaker: amount=0"
        );

        // batchMigrate: rejected on the Active pool, from inside the body.
        address[] memory users = new address[](0);
        _expectBodyRevert(
            address(v1), abi.encodeWithSelector(BATCH_MIGRATE_SELECTOR, USDC, users), "StableStaker: pool not migrating"
        );

        // initiateMigration: succeeds on the empty Active pool and really moves it to Migrating.
        (bool okInit,) = address(v1).call(abi.encodeWithSelector(INITIATE_MIGRATION_SELECTOR, USDC));
        assertTrue(okInit, "initiateMigration selector must resolve on a deployed frozen V1");
        assertEq(uint256(v1.poolState(USDC)), 1, "initiateMigration must move the pool to Migrating");

        // ...and a second call reaches the same body's Active guard.
        _expectBodyRevert(
            address(v1), abi.encodeWithSelector(INITIATE_MIGRATION_SELECTOR, USDC), "StableStaker: pool not active"
        );

        // batchMigrate now resolves and returns an empty credit array on the Migrating pool.
        (bool okBatch, bytes memory retBatch) =
            address(v1).call(abi.encodeWithSelector(BATCH_MIGRATE_SELECTOR, USDC, users));
        assertTrue(okBatch, "batchMigrate selector must resolve on a Migrating pool");
        uint256[] memory credits = abi.decode(retBatch, (uint256[]));
        assertEq(credits.length, 0, "batchMigrate over no users returns no credits");
    }

    /// @notice A deployed frozen V1 is castable to the perpetual migration interface — the property
    ///         that keeps the live instance drainable by any future `CrossVersionMigrator`.
    function test_frozenV1IsUsableThroughThePerpetualInterface() public {
        StableStakerV1 v1 = new StableStakerV1(IFlax(MAINNET_PHUSD), address(this));
        IStableStakerMigratable migratable = IStableStakerMigratable(address(v1));
        assertEq(address(migratable), address(v1), "frozen V1 must be usable wherever the triad is required");
    }

    // ============================== VERSION IDENTITY ==============================

    /// @notice The frozen V1 has NO `STAKER_VERSION` getter, and must never gain one.
    /// @dev `CrossVersionMigrator` probes the version with a `STAKER_VERSION()` staticcall and reads
    ///      a REVERT as "this is version 1". Adding the getter to the frozen copy would both lie
    ///      about the deployed bytecode and break that probe.
    function test_frozenV1HasNoStakerVersionGetter() public {
        StableStakerV1 v1 = new StableStakerV1(IFlax(MAINNET_PHUSD), address(this));
        (bool ok, bytes memory ret) = address(v1).staticcall(abi.encodeWithSignature("STAKER_VERSION()"));
        assertFalse(ok, "frozen V1 must NOT expose STAKER_VERSION - its absence is how V1 is detected");
        assertEq(ret.length, 0, "a missing function returns empty returndata");
    }

    /// @notice The mainnet address this frozen copy claims to describe is recorded here so a reader
    ///         never has to leave the file to find it.
    function test_mainnetAddressIsRecorded() public pure {
        assertEq(MAINNET_V1, 0xbce8ABC09BaEDCabE93419bF875f6186e182079A, "live V1 address");
    }

    // ============================== HELPERS ==============================

    function _expectBodyRevert(address target, bytes memory payload, string memory reason) internal {
        (bool ok, bytes memory ret) = target.call(payload);
        assertFalse(ok, "call was expected to revert on a business-logic guard");
        assertGt(ret.length, 0, "empty returndata means the selector did not resolve to a function body");
        assertEq(_revertReason(ret), reason, "unexpected revert reason");
    }

    function _revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "";
        assembly {
            ret := add(ret, 0x04)
        }
        return abi.decode(ret, (string));
    }
}
