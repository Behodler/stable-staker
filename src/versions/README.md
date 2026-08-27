# `src/versions/` — frozen deployment snapshots

This directory holds one **immutable interface per deployed `StableStaker`**.

## Why it exists

`stable-staker` follows an *evergreen* model: `src/StableStaker.sol` is always the
current implementation and is free to evolve. That freedom is only safe while every
version that is still live on chain remains reachable — migrators, deployment scripts
and fork tests all need to talk to the contract that is actually deployed, not to
whatever `StableStaker.sol` has become since.

A snapshot records the deployed contract's complete external surface at the moment it
was deployed. Once written, it never changes, so it can never drift away from the
bytecode it describes.

Precedent for the cost of not doing this: `phase-2-staging/foundry.toml` carries a
compile-skip list because legacy deployment scripts were hard-wired to V1
`yield-claim-nft` contracts that were later deleted from the submodule. Deleting a live
version's shape breaks downstream consumers. Keeping it costs nothing — interfaces are
not deployed, so they do not count against `forge build --sizes`.

## The never-edit rule

> **A file in `src/versions/` is never edited after the story that created it.**

If the current implementation gains, loses or reshapes a member, that is a *new version*,
not a correction to an old one. Editing a snapshot does not change the deployed contract;
it only makes the snapshot lie about the deployed contract, which is the single failure
mode this directory exists to prevent.

The only permitted change to an existing snapshot is **deletion**, and only once the
instance it describes is genuinely empty and dead.

## The snapshot-on-deploy ritual

The canonical five-step statement of this ritual lives in the repo's `CLAUDE.md`, under
**"Evergreen contract and version snapshots"**. What follows is the same ritual with the
file-level detail an author actually needs while writing the snapshot.

`<N>` is always the **current value of `StableStaker.STAKER_VERSION`** at the moment of the
deploy — the version being frozen, not the next one.

1. Read `STAKER_VERSION` from `src/StableStaker.sol` at the exact commit being deployed. That
   is `<N>`.
2. Copy the deployed contract's external surface into a new
   `src/versions/IStableStakerV<N>.sol`, taken from that same source commit.
3. Declare it as `interface IStableStakerV<N> is IStableStakerMigratable`. Every version
   must satisfy the golden rule (`initiateMigration`, `batchMigrate`, `depositFor`) so a
   migrator can always drain one version and credit another; extending the perpetual
   interface makes that a compile-time obligation rather than a convention.
4. Record in the header NatSpec, permanently: the deployed address, the source commit,
   the deploy date, and an explicit **NEVER EDIT THIS FILE** notice.
5. Add `test/StableStakerV<N>Snapshot.t.sol`, which casts a deployed `StableStaker` to the
   new interface and calls every declared member — a compile-and-call proof that the
   snapshot is a faithful subset of the source it was taken from.
6. **Bump `STAKER_VERSION` to `N + 1`** in `src/StableStaker.sol`, and update
   `test/StakerVersion.t.sol` to the new value. From this commit onward the source once again
   describes something that is not yet deployed — which is exactly the invariant the constant
   encodes.
7. Add a row to the *Current snapshots* table below.
8. Leave every earlier snapshot untouched.

### The V1 exception

`IStableStakerV1.sol` was written retroactively, after `0xbce8…079A` was already live. The
deployed V1 bytecode therefore has **no `STAKER_VERSION` getter at all** — a static call to it
reverts. `STAKER_VERSION` was introduced already set to `2`, because the source had by then moved
past the deployed shape. Any runtime version probe must treat a reverting `STAKER_VERSION` call as
**version 1** rather than propagating the failure; see `CLAUDE.md` for the rule.

## Conventions

- Snapshots are **interfaces**, not abstract contracts. A deployed version is immutable
  and nothing inherits from it; callers only need to *call* the live instance, so an
  interface is the smaller, safer artifact. An abstract contract only becomes warranted
  if a later version wants to share implementation with a predecessor.
- Prefer plain value types over project enums and structs. Returning `uint8` for
  `poolState` instead of re-declaring `enum PoolState` keeps a snapshot self-contained
  and immune to a later change of that type; document the mapping in NatSpec instead.
- External types that *must* be imported (`IYieldStrategy`, `IFlax`) are a known coupling:
  if those submodule interfaces change shape, the frozen snapshots inherit the churn. Note
  the coupling in the snapshot's header.

## Current snapshots

| File | Deployed address | Source commit | Deployed |
|---|---|---|---|
| `IStableStakerV1.sol` | `0xbce8ABC09BaEDCabE93419bF875f6186e182079A` | `c3ec65b` | 2026-06-10 |
