// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IStableStakerMigratable.sol";

/**
 * @title CrossVersionMigrator
 * @notice Moves a user base between ANY two versions of {StableStaker} — V1 to V2, V2 to V3 and
 *         onward — with zero user action, preserving principal and minting each user's earned reward token.
 *
 * @dev SUPERSEDES the original cross-staker migrator, which was removed in story 018 and remains
 *      recoverable from git history (see CLAUDE.md). This contract is a strict functional superset
 *      of it: the same owner-only {initiateMigration} forwarder, the same
 *      `batchMigrate` -> sum -> `forceApprove` -> per-user `depositFor` flow, the same zero-credit
 *      skip and the same both-ends-immutable constructor. It adds a narrower interface dependency,
 *      a runtime version probe, and a richer event.
 *
 *      (A) NARROWEST POSSIBLE DEPENDENCY — Both ends are typed `IStableStakerMigratable`, the
 *      perpetual "golden rule" triad ({initiateMigration}, `batchMigrate`, `depositFor`) that every
 *      version of the staker must expose. Nothing outside those three functions can change this
 *      contract's behaviour, so it stays valid across an arbitrary number of future staker
 *      redesigns. It never imports the concrete `StableStaker`.
 *
 *      (B) BOTH TARGETS ARE IMMUTABLE — ON PURPOSE. An owner-mutable target is a drain vector: a
 *      compromised owner key could point `depositFor` at a malicious contract that pulls the scoped
 *      approval and credits nobody. Pinning both stakers at construction closes that hole. Do not
 *      "improve" this into a setter — a new migration target means a NEW deploy plus re-wiring, by
 *      design. (Same rationale as `InPlaceMigrator` section (D).)
 *
 *      (C) TWO-SIDED WIRING IS REQUIRED BEFORE USE. This migrator must be set as `migrator` via
 *      `setMigrator` on BOTH stakers, the destination staker must already have the token registered
 *      (`addToken`), and the destination staker must be an authorized minter of the destination's reward token
 *      (phUSD on the frozen V1, Antimatter on V2 and onward). Because both
 *      targets are immutable there is no in-place retarget: a different pair of stakers is a new
 *      deployment of this contract, re-wired on both sides.
 *
 *      {initiateMigration} is a ONE-WAY DOOR on the source staker — it realizes the strategy
 *      position, decouples the strategy, freezes emissions and latches `poolState` to `Migrating`,
 *      and the only way back is `finalizeAndReset` on a fully drained pool. A wiring mistake
 *      discovered at the first {migrate} call is therefore discovered too late. Two of the three
 *      preconditions above are consequently asserted ON CHAIN, before the forward:
 *
 *        - destination token registration, probed via `getStakedTokens()`
 *          ("Migrator: destination token not registered");
 *        - destination wiring, probed via `migrator()` ("Migrator: destination not wired");
 *        - and, in the constructor, `_oldStaker != _newStaker` ("Migrator: aliased stakers"), since
 *          an aliased pair would freeze a staker and then attempt to `depositFor` back into the
 *          pool it just froze.
 *
 *      What remains a RUNBOOK OBLIGATION, unguarded and uncheckable from here:
 *
 *        - reward-token minter authorization on the destination. That permission lives on the reward
 *          token itself (`FlaxToken` for the frozen V1, `Antimatter` for V2 and onward), which this
 *          contract holds no reference to and deliberately does not import (section (A)).
 *        - source-side `setMigrator`. The live V1 is deployed and unpatchable, and nothing this
 *          contract can do protects against the SOURCE being mis-wired; that still fails only at
 *          call time.
 *
 *      ADVISORY ON PROBE FAILURE. Both pre-flight checks are staticcall probes on getters that are
 *      NOT part of `IStableStakerMigratable` and must not be added to it — widening the triad would
 *      make the frozen `IStableStakerV1` promise selectors the deployed V1 bytecode does not
 *      dispatch. A probe that SUCCEEDS and answers "no" is a hard revert; that is the case that
 *      actually occurs, since both V1 and V2 expose `migrator()` and `getStakedTokens()` publicly.
 *      A probe that FAILS (reverts, or returns short/undecodable data) means the destination is a
 *      staker shape this migrator does not recognise, NOT that the precondition is violated, and it
 *      passes through — the same advisory posture section (F) blesses for the version probe. So the
 *      guard is a safety net for the known shapes, never a total one, and it never costs this
 *      contract its version-agnosticism.
 *
 *      (D) ZERO-CREDIT USERS ARE SKIPPED, NOT PASSED THROUGH. `StableStaker.depositFor` reverts with
 *      "StableStaker: nothing credited" when the credit rounds to zero (story 011). A single dust
 *      user whose snapshot credit floors to 0 would therefore revert an entire batch. The
 *      `if (amounts[i] > 0)` guard below skips those users so the batch survives — the open item
 *      L-01 / `ss12l1` dust interaction recorded by story 013. A skipped user is still fully exited
 *      from the old staker by `batchMigrate` (their pending reward was minted to them there); what
 *      they forgo is a zero-value principal credit on the destination, and their floor-division dust
 *      accrues to the protocol in the old staker. The alternative — requiring batches to be
 *      pre-filtered off-chain — was rejected as a landmine.
 *
 *      (E) UNDERWATER HAIRCUTS ARE NOT COMPENSATED HERE. If the old staker's yield strategy is
 *      underwater, `batchMigrate` pays each user the uniform snapshot credit `p_i*min(R,P)/P`, which
 *      is LESS than their principal. This contract redeposits exactly what it received and no more;
 *      it does not top anyone up. Story 013's surplus-funded top-up lives in
 *      `InPlaceMigrator._reinjectWithTopup` and is specific to the park-and-reinject flow — its
 *      invariants (the live-surplus identity, the gross-up, the tolerance backstop) are delicate and
 *      must not be copied across without a dedicated story. A cross-version migration through an
 *      underwater strategy credits the haircut, and that asymmetry with `InPlaceMigrator` is a
 *      deliberate, human-visible product difference.
 *
 *      (F) THE VERSION PROBE IS ADVISORY ONLY. {versionOf} informs the {MigratedAcrossVersions}
 *      event so the on-chain record says which hop occurred. No behaviour branches on it: branching
 *      would couple this contract to version-specific semantics, which is exactly what the golden
 *      rule interface exists to avoid.
 *
 *      Terminal-migration flow: the owner calls {initiateMigration} ONCE per token (engaging the old
 *      staker's terminal snapshot), then {migrate} for each batch of users.
 */
contract CrossVersionMigrator is Ownable {
    using SafeERC20 for IERC20;

    /// @notice The staker users are migrating out of.
    IStableStakerMigratable public immutable oldStaker;

    /// @notice The staker users are migrating into.
    IStableStakerMigratable public immutable newStaker;

    /**
     * @notice Emitted once per {migrate} batch.
     * @param token The staked token that was migrated.
     * @param userCount Number of users actually credited on the new staker (zero-credit users are
     *        skipped and therefore not counted).
     * @param totalPrincipal Aggregate snapshot credit pulled out of the old staker for this batch.
     * @param fromVersion `STAKER_VERSION` of the old staker (1 when it predates the getter).
     * @param toVersion `STAKER_VERSION` of the new staker (1 when it predates the getter).
     */
    event MigratedAcrossVersions(
        address indexed token, uint256 userCount, uint256 totalPrincipal, uint256 fromVersion, uint256 toVersion
    );

    constructor(IStableStakerMigratable _oldStaker, IStableStakerMigratable _newStaker, address initialOwner)
        Ownable(initialOwner)
    {
        require(address(_oldStaker) != address(0), "Migrator: zero old staker");
        require(address(_newStaker) != address(0), "Migrator: zero new staker");
        require(address(_oldStaker) != address(_newStaker), "Migrator: aliased stakers");
        oldStaker = _oldStaker;
        newStaker = _newStaker;
    }

    /**
     * @notice Engage terminal migration on the old staker for `token`. Thin owner-only forwarder to
     *         {IStableStakerMigratable-initiateMigration}: realizes the strategy position once and
     *         snapshots (R, P) so every subsequent {migrate} batch pays a fixed, order-independent
     *         credit.
     * @dev Must be called exactly once per token BEFORE the first {migrate} batch. Reverts (on the
     *      staker) if the token is already migrating, so it is naturally idempotent-guarded.
     *
     *      PRE-FLIGHT. Because the forwarded call is irreversible on the source, the two
     *      destination-side preconditions that CAN be read on chain are asserted first — see section
     *      (C). Both are advisory when the destination does not expose the probed getter; neither
     *      covers the reward-token-minter precondition or the source side's own `setMigrator`.
     * @param token The staked token to put into terminal migration on the old staker.
     */
    function initiateMigration(address token) external onlyOwner {
        require(_isRegisteredOn(address(newStaker), token), "Migrator: destination token not registered");
        (address destMigrator, bool probed) = _migratorOf(address(newStaker));
        require(!probed || destMigrator == address(this), "Migrator: destination not wired");
        oldStaker.initiateMigration(token);
    }

    /**
     * @notice Migrate a batch of users for `token` from the old staker to the new staker.
     * @dev Requires a prior {initiateMigration} for `token` (the old staker reverts otherwise).
     *      Users whose snapshot credit is zero are skipped — see section (D) of the contract docs.
     * @param token The staked token to migrate.
     * @param users The users to migrate (build batches off-chain via getStakers/getStakersRange).
     */
    function migrate(address token, address[] calldata users) external onlyOwner {
        uint256[] memory amounts = oldStaker.batchMigrate(token, users);

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        if (total == 0) {
            emit MigratedAcrossVersions(token, 0, 0, versionOf(address(oldStaker)), versionOf(address(newStaker)));
            return;
        }

        IERC20(token).forceApprove(address(newStaker), total);

        uint256 migratedCount;
        for (uint256 i = 0; i < users.length; i++) {
            if (amounts[i] > 0) {
                newStaker.depositFor(token, users[i], amounts[i]);
                migratedCount++;
            }
        }

        emit MigratedAcrossVersions(
            token, migratedCount, total, versionOf(address(oldStaker)), versionOf(address(newStaker))
        );
    }

    /**
     * @notice Best-effort runtime version of `staker`.
     * @dev The live V1 deployment predates `STAKER_VERSION` entirely, so a static call to it reverts
     *      (or, on a non-contract address, returns empty). Either outcome is reported as version 1,
     *      per `src/versions/README.md`. Advisory only — see section (F).
     * @param staker The staker to probe.
     * @return The staker's `STAKER_VERSION`, or 1 when it does not expose one.
     */
    function versionOf(address staker) public view returns (uint256) {
        return _versionOf(staker);
    }

    function _versionOf(address staker) internal view returns (uint256) {
        (bool ok, bytes memory data) = staker.staticcall(abi.encodeWithSignature("STAKER_VERSION()"));
        if (!ok || data.length < 32) return 1;
        return abi.decode(data, (uint256));
    }

    /**
     * @dev Probes `migrator()` on `staker` without widening `IStableStakerMigratable` — the same
     *      shape as {_versionOf}. Public on both V1 (`StableStakerV1.sol`) and V2.
     * @return destMigrator The address the staker currently recognises as its migrator. Meaningless
     *         unless `probed` is true.
     * @return probed True when the getter answered. FALSE MUST NOT BE READ AS A NEGATIVE ANSWER:
     *         `address(0)` from a failed probe compares unequal to `address(this)` and would
     *         hard-revert an unrecognised-but-valid destination, which is precisely the
     *         version-agnosticism section (A) protects. The caller gates on `probed` first.
     */
    function _migratorOf(address staker) internal view returns (address destMigrator, bool probed) {
        (bool ok, bytes memory data) = staker.staticcall(abi.encodeWithSignature("migrator()"));
        if (!ok || data.length < 32) return (address(0), false);
        return (abi.decode(data, (address)), true);
    }

    /**
     * @dev Probes `getStakedTokens()` on `staker` and scans the result for `token`. Public on both
     *      V1 and V2, and the only HONEST registration probe: `poolInfo` returns all zeros for an
     *      unregistered token (its `lastRewardTime != 0` tell is an undocumented coincidence of
     *      `addToken`), and `poolState` reads `Active` for one because `Active` is the zero value.
     *
     *      The scan is O(n) over an externally-controlled array, but the registered-token set is
     *      single-digit and this is an owner-only call made once per token.
     * @return True when the token is registered, OR when the probe itself failed — an unrecognised
     *         destination shape is "unverifiable", not "wrong". See the advisory note in section (C).
     */
    function _isRegisteredOn(address staker, address token) internal view returns (bool) {
        (bool ok, bytes memory data) = staker.staticcall(abi.encodeWithSignature("getStakedTokens()"));
        if (!ok || data.length < 64) return true;
        address[] memory tokens = abi.decode(data, (address[]));
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) return true;
        }
        return false;
    }
}
