# `src/versions/` — frozen deployment snapshots

This directory holds one **immutable subdirectory per deployed `StableStaker`**, containing the
deployed contract's **full source** plus its external-surface interface:

```
src/versions/
  v1/
    StableStakerV1.sol      <- FROZEN full source as deployed. Bugs included.
    IStableStakerV1.sol     <- FROZEN external surface of the same.
    FROZEN.sha256           <- sha256 pins for both, verified by CI.
```

## Why it exists

`stable-staker` follows an *evergreen* model: `src/StableStakerV2.sol` is the current
implementation and is free to evolve. That freedom is only safe while every version that is
still live on chain remains **reachable and reasonable-about** — migrators, deployment scripts,
runbooks, fork tests and audits all need to talk to (and reason about) the contract that is
actually deployed, not to whatever the evergreen has become since.

Precedent for the cost of not doing this: `phase-2-staging/foundry.toml` carries a compile-skip
list because legacy deployment scripts were hard-wired to V1 `yield-claim-nft` contracts that
were later deleted from the submodule. Deleting a live version's shape breaks downstream
consumers.

## Full source, not interface only — and the story-019 correction

Story 016 established this directory as **interface-only** snapshots of a single evergreen
`StableStaker.sol`, and explicitly forbade forking into a `StableStakerV<N>.sol`. Story 019
reversed that, because the model rested on an assumption that turned out to be false here: that
a deployed contract's *behaviour* never needs to be reasoned about again once it is superseded.

The live V1 at `0xbce8ABC09BaEDCabE93419bF875f6186e182079A` has known defects (`ss14m1`,
`ss14l8`) and still holds un-migrated stakers. A recovery runbook, a fork test or an audit that
needs to reason about deployed behaviour must be able to **compile** that behaviour. An
interface cannot be deployed and cannot be fork-tested, so an interface-only snapshot could
never have supported any of that.

So a fork into `StableStakerV<N>.sol` is now the **expected shape**, not a prohibited one. The
interface snapshot is kept alongside it — it is still the cheap, dependency-light handle that
migrators and scripts cast through, and `test/StableStakerV1Snapshot.t.sol` proves the interface
is a faithful subset of the frozen contract.

### Frozen means frozen, bugs included

`StableStakerV1.sol` reproduces `git show c3ec65b:src/StableStaker.sol`, with only the
divergences enumerated in its own header (a contract rename forced by Foundry artifact
resolution, and the header block itself). Its known defects are preserved **on purpose**:

- `ss14m1` — terminal migration bricked by `setYieldStrategy`'s unrecorded idle sweep;
- `ss14l8` — the set-aside buffer is excluded from the migration realized amount `R`.

Fixing them there would make the file lie about the bytecode that is on chain, which is the one
failure mode this directory exists to prevent. Fixes belong in the evergreen `StableStakerV2`
and in the operational recovery plan, never here. An audit run that re-files them against the
frozen copy should be triaged as "deliberately preserved", not actioned.

## The never-edit rule

> **A file in `src/versions/` is never edited after the story that created it.**

If the current implementation gains, loses or reshapes a member, that is a *new version*, not a
correction to an old one. Editing a snapshot does not change the deployed contract; it only
makes the snapshot lie about the deployed contract.

Since story 019 this is enforced rather than merely asserted:
`.github/scripts/check-migration-surface.sh` verifies that every file pinned in
`src/versions/v1/FROZEN.sha256` **exists** and **hashes to its pinned value**. A missing or
modified frozen file is a hard CI failure. Regenerating `FROZEN.sha256` to match an edit
defeats the check and is not an acceptable fix; restore the file instead. The only deliberate
way past the gate is a commit carrying `GOLDEN-RULE-OVERRIDE`, which signals that the live
instance is genuinely dead and its migration surface is being retired on purpose.

The only permitted change to an existing snapshot directory is **deletion**, and only once the
instance it describes is genuinely empty and dead.

## The snapshot-on-deploy ritual

The canonical statement of this ritual lives in the repo's `CLAUDE.md`, under **"Version
snapshots and the evergreen contract"**. What follows is the same ritual with the file-level
detail an author actually needs.

`<N>` is always the **current value of `STAKER_VERSION`** on the evergreen contract at the
moment of the deploy — the version being frozen, not the next one.

**Snapshot from the DEPLOY COMMIT, never from `master` HEAD.** This is the step most easily got
wrong, and getting it wrong silently produces a snapshot that describes something that was never
deployed. Find the commit the deployment actually used — the submodule pointer in
`phase-2-staging` on the deploy day, cross-checked against
`phase-2-staging/broadcast/<Script>.s.sol/1/run-latest.json` and
`phase-2-staging/server/deployments/mainnet-addresses.ts` — and take **both** files from it.
(Audit finding `ss14l4` / `L-04`: the pre-019 ritual said "the exact commit being deployed" but
the surrounding prose read as `master` HEAD, which is only the same thing by luck.)

1. Establish the deploy commit `<C>` and read `STAKER_VERSION` from the evergreen contract **at
   `<C>`**. That is `<N>`.
2. `mkdir src/versions/v<N>` and generate the frozen source **mechanically**:

   ```bash
   git show <C>:src/StableStakerV<N>.sol > src/versions/v<N>/StableStakerV<N>.sol
   ```

   Never hand-transcribe it.
3. Apply only the minimum divergences needed for the copy to coexist and compile — a contract
   rename if the name would collide, import-path and pragma fixes if library pins have moved —
   and **enumerate every one of them in a "Permitted divergences" block in the file header**.
   Anything not on that list is a mistake. Revert strings are ABI-visible behaviour and stay
   verbatim. If only a *logic* edit would make it compile (anything touching storage layout or
   an external signature), **stop and escalate**: at that point the copy can no longer honestly
   claim to be the deployed source, and that is a human decision.
4. Copy the deployed contract's external surface into
   `src/versions/v<N>/IStableStakerV<N>.sol`, taken from that same commit `<C>`.
5. Declare it as `interface IStableStakerV<N> is IStableStakerMigratable`. Every version must
   satisfy the golden rule (`initiateMigration`, `batchMigrate`, `depositFor`) so a migrator can
   always drain one version and credit another; extending the perpetual interface makes that a
   compile-time obligation rather than a convention.
6. Record in the header NatSpec of both files, permanently: the deployed address, the source
   commit, the deploy date, where the deployment is recorded, and an explicit
   **NEVER EDIT THIS FILE** notice.
7. Pin both files:

   ```bash
   sha256sum src/versions/v<N>/StableStakerV<N>.sol src/versions/v<N>/IStableStakerV<N>.sol \
     > src/versions/v<N>/FROZEN.sha256
   ```

   and add the pair to `FROZEN_FILES` in `.github/scripts/check-migration-surface.sh`.
8. Add `test/StableStakerV<N>Frozen.t.sol`: deploy the frozen contract with the **real
   constructor arguments the deployment used** (read them out of the broadcast JSON) and assert
   the golden-rule selectors are present and dispatch. This is the proof the frozen copy is
   *deployable* rather than merely parseable, and it is the tripwire for library pin drift.
9. Add `test/StableStakerV<N>Snapshot.t.sol`, which casts a deployed `StableStakerV<N>` to the
   new interface and calls every declared member — a compile-and-call proof that the interface
   is a faithful subset of the frozen source. Point it at the **frozen** contract, not at the
   evergreen: the evergreen is explicitly free to diverge, so a fidelity assertion against it
   proves nothing about the deployed shape.
10. **Bump `STAKER_VERSION` to `N + 1`** on the evergreen contract, and update
    `test/StakerVersion.t.sol` to the new value. From this commit onward the evergreen once
    again describes something that is not yet deployed — which is exactly the invariant the
    constant encodes.
11. Add a row to the *Current snapshots* table below.
12. Leave every earlier snapshot untouched.

### The V1 exception

`src/versions/v1/` was written retroactively, after `0xbce8…079A` was already live. The deployed
V1 bytecode therefore has **no `STAKER_VERSION` getter at all** — a static call to it reverts.
`STAKER_VERSION` was introduced already set to `2`, because the source had by then moved past the
deployed shape.

Two consequences that are load-bearing:

- Any runtime version probe must treat a reverting `STAKER_VERSION` call as **version 1** rather
  than propagating the failure. `CrossVersionMigrator.versionOf` does exactly this.
- The frozen `StableStakerV1.sol` must therefore **never gain a `STAKER_VERSION` getter**.
  Adding one would both lie about the deployed bytecode and break that probe.
  `test/StableStakerV1Frozen.t.sol` asserts its absence.

## Conventions

- The frozen **contract** is the honest record of deployed behaviour; the frozen **interface** is
  the ergonomic handle callers cast through. Keep both.
- Frozen contracts are never inherited from and never deployed to production — they exist to be
  compiled, deployed in tests, and fork-tested. They do count against `forge build --sizes` in
  the default profile, which is why `foundry.toml` carries a deliberate `code_size_limit`; the
  real deployment profile lives in `phase-2-staging`.
- In snapshot **interfaces**, prefer plain value types over project enums and structs. Returning
  `uint8` for `poolState` instead of re-declaring `enum PoolState` keeps the interface
  self-contained and immune to a later change of that type; document the mapping in NatSpec.
- External types that *must* be imported (`IYieldStrategy`, `IFlax`) are a known coupling: if
  those submodule interfaces change shape, the frozen files inherit the churn. This is the most
  likely reason a frozen contract stops compiling; see step 3 for what is and is not allowed in
  response.

## Current snapshots

| Directory | Contract | Deployed address | Source commit | Deployed |
|---|---|---|---|---|
| `v1/` | `StableStakerV1.sol` + `IStableStakerV1.sol` | `0xbce8ABC09BaEDCabE93419bF875f6186e182079A` | `c3ec65b` | 2026-06-10 |

`StableStakerV2` (`STAKER_VERSION == 2`) is the current evergreen and is **not yet deployed**;
it gets a `v2/` directory at its deploy, following the ritual above.

## V1 RECOVERY — clearing a stuck `initiateMigration` on the deployed V1

`StableStakerV2.initiateMigration` self-heals a strategy principal divergence: it relinquishes
whatever the strategy still books against the staker after the exit, emits `PrincipalDivergence`,
and continues. **The frozen V1 does not**, and cannot — its bytecode is on chain at
`0xbce8ABC09BaEDCabE93419bF875f6186e182079A` and cannot be patched. An operator calling
`initiateMigration` on V1 may therefore still hit:

```
StableStaker: incomplete exit
```

The cause is `setYieldStrategy`'s idle sweep. It deposits the contract's whole idle balance into a
newly wired strategy — set-aside buffer, dust, donations, all protocol money by construction,
since the wiring is gated on an empty pool — without `poolInfo[token].totalStaked` ever learning
about it. `initiateMigration` then withdraws exactly `totalStaked` and asserts the strategy books
nothing further, which it cannot satisfy while that excess is still on the strategy's books.

### The clear

Compute the surplus and write it down **on the strategy**, as the strategy's owner:

```
surplus = strategy.principalOf(token, staker) - staker.poolInfo(token).totalStaked
strategy.relinquishPrincipalAsOwner(staker, surplus)
```

Then re-run `initiateMigration` on the staker.

Four things to get right:

- **The call is on the STRATEGY, not on the staker.** `relinquishPrincipalAsOwner` lives on
  `AYieldStrategy` in `reflax-yield-vault` and is `onlyOwner` *of the strategy*. Nothing is called
  on `StableStaker` to clear this.
- **Never round the surplus up.** Relinquishing more than the divergence writes down principal the
  pool genuinely claims, and the shortfall is then haircut across every migrating user. Compute the
  exact difference; if the two reads cannot be taken atomically, take them in the same block.
- **`relinquishPrincipalAsOwner` is the correct call, not `withdrawAsOwner`.** Both clear the books.
  `withdrawAsOwner` also moves the tokens out to the owner, so the value leaves the position;
  `relinquishPrincipalAsOwner` touches recorded principal only — no vault shares move — and the
  relinquished value stays in the strategy as protocol-owned capital, returning through the yield
  accumulator.
- **This is a prerequisite for shipping the V2 fix, not an alternative to it.** `StableStaker` is a
  plain `Ownable` with no proxy, so the self-heal only reaches chain in a newly deployed staker —
  and reaching a new staker requires `initiateMigration` on the old one. DOLA and USDC on the live
  V1 are both in this state and must be cleared this way first.
