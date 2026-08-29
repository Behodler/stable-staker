// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableStakerV2.sol";
import "flax-token/FlaxToken.sol";

/// @notice Version identity for the evergreen `StableStakerV2`.
///
/// The evergreen contract is forked on DEPLOY, not on change: each deploy is frozen into
/// `src/versions/v<N>/` as full source plus interface, and `STAKER_VERSION` is then bumped
/// (story 019 — before it, snapshots were interface-only and a fork was forbidden outright).
/// `STAKER_VERSION` stays at 2 across the V1/V2 file split: the constant, not the filename, is the
/// identity. These tests pin the current value and, more importantly, pin the *probe contract*:
/// version detection is a `staticcall` whose revert means "version 1", because the deployed V1
/// instance (0xbce8ABC09BaEDCabE93419bF875f6186e182079A) predates the constant and does not expose
/// it. That is also why the frozen `src/versions/v1/StableStakerV1.sol` must never gain the getter.
contract StakerVersionTest is Test {
    FlaxToken internal phUSD;
    StableStakerV2 internal staker;

    /// @dev The selector any cross-version probe will use against an unknown staker.
    bytes internal constant VERSION_CALLDATA = abi.encodeWithSignature("STAKER_VERSION()");

    function setUp() public {
        phUSD = new FlaxToken();
        staker = new StableStakerV2(phUSD, address(this));
    }

    /// @notice The source is version 2: V1 is what is deployed, and the constant's existence is
    ///         itself the divergence from deployed bytecode.
    function test_stakerVersionIsTwo() public view {
        assertEq(staker.STAKER_VERSION(), 2, "STAKER_VERSION must be 2");
    }

    /// @notice Readable through a plain external call, not just as an inlined constant.
    function test_stakerVersionReadableExternally() public view {
        assertEq(StableStakerV2(address(staker)).STAKER_VERSION(), 2, "external call must return 2");
    }

    /// @notice Readable through a raw staticcall — the shape a version probe actually uses.
    function test_stakerVersionReadableViaStaticcall() public view {
        (bool ok, bytes memory ret) = address(staker).staticcall(VERSION_CALLDATA);
        assertTrue(ok, "staticcall to STAKER_VERSION must succeed");
        assertEq(ret.length, 32, "return data must be a single word");
        assertEq(abi.decode(ret, (uint256)), 2, "staticcall must decode to 2");
    }

    /// @notice A contract without the getter reverts rather than returning 0. A probe MUST treat
    ///         that revert as "version 1" instead of propagating it. This is the V1 case.
    function test_versionProbeRevertsOnContractWithoutGetter() public {
        (bool ok,) = address(phUSD).staticcall(VERSION_CALLDATA);
        assertFalse(ok, "a staker without STAKER_VERSION must revert, not return a value");
        assertEq(_probeVersion(address(phUSD)), 1, "a reverting probe means version 1");
    }

    /// @notice The probe returns the real version when the getter is present.
    function test_versionProbeReturnsTwoForCurrentSource() public view {
        assertEq(_probeVersion(address(staker)), 2, "probe must read 2 off the current source");
    }

    /// @dev Reference implementation of the failure-tolerant version probe described in CLAUDE.md.
    function _probeVersion(address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = who.staticcall(VERSION_CALLDATA);
        if (!ok || ret.length != 32) return 1;
        return abi.decode(ret, (uint256));
    }
}
