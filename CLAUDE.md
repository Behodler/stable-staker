# CLAUDE.md

Guidance for Claude Code when working in the `stable-staker` submodule.

## Overview

`stable-staker` is a MasterChef-style yield farm that supports any number of staked (stable)
tokens and rewards stakers in **phUSD** (the `FlaxToken` from the `flax-token` dependency).
Rewards are not pre-funded: this contract is an authorized phUSD **minter** and mints rewards
directly to users on claim / withdraw / migration.

- `src/StableStaker.sol` — the farm. Per-token pools, owner-set `phUSDPerDay(token, amount)`
  emission budget, per-token `EnumerableSet` of stakers (`getStakers` / `getStakersRange` /
  `stakerCount`), Behodler3 pausing (`pauser` + `IPausable`), and a permissionless
  `emergencyWithdraw` escape hatch.
- `src/StableStakerMigrator.sol` — moves a batch of users from one `StableStaker` to another with
  zero user action, preserving principal and minting earned rewards. Uses the staker's permissioned
  terminal-migration hooks `initiateMigration` (once per token) + `batchMigrate` / `depositFor`
  (caller must be the configured `migrator`). See "Terminal migration mode" below.
- `src/InPlaceMigrator.sol` — swaps a single staker's yield strategy **in place**, without
  deploying a new `StableStaker`. Drives the same terminal-migration hooks
  (`initiateMigration` → `batchMigrate`/`userMigrate` → `finalizeAndReset`) against one contract
  so an empty pool can be re-wired to a fresh `IYieldStrategy`, with a surplus-funded top-up that
  re-injects the haircut.
- `src/interfaces/IStableStaker.sol` — minimal interface the migrator depends on.
- `src/interfaces/IStableStakerMigratable.sol` — the perpetual "golden rule" interface
  (`initiateMigration`, `batchMigrate`, `depositFor`) that every version must satisfy.
- `src/versions/` — frozen, never-edited interface snapshots of each deployed `StableStaker`.
  See "Evergreen contract and version snapshots" below.

## Core safety invariant

No sequence of user actions can mint more than `phUSDPerDay` for a token over any window. The only
writer of `accPhusdPerShare` is `_updatePool`, which folds in exactly `elapsed * phusdPerSecond`
per update; the sum of all stakers' pending increase equals that minus integer-division dust
(which always rounds DOWN). Empty-pool windows accrue nothing; flash staking earns nothing;
`phUSDPerDay` settles the pool at the old rate before changing it. See `test/EmissionCap.t.sol`.

## Wiring (deployment)

1. Deploy `StableStaker(phUSD, owner)`.
2. phUSD owner calls `phUSD.setMinter(address(staker), true)`.
3. `staker.addToken(token)` for each stable, then `staker.phUSDPerDay(token, amountPerDay)`.
4. Optional: `staker.setPauser(pauser)`, `staker.setMigrator(migrator)`.

For migration, both old and new stakers must have the migrator set (`setMigrator`) and the new
staker must have the token registered (`addToken`); the new staker must also be a phUSD minter.

## Yield strategies (per-token principal custody)

By default a staked token sits **idle** in the contract. A token can optionally route its principal
through a per-token `IYieldStrategy` adapter (from the `reflax-yield-vault` submodule) so the
staked stables earn yield instead of sitting idle. This is opt-in per token via
`setYieldStrategy(token, strategy)` (`onlyOwner`, `poolExists`); `address(0)` ⇒ idle-hold (the
original behaviour). The principal-moving paths (`stake`, `withdraw`, `emergencyWithdraw`,
`initiateMigration`, `depositFor`) route through the strategy when one is set. `initiateMigration`
realizes the whole position once (via the client-callable `strategy.withdraw`) and then decouples
the strategy; `batchMigrate` / `userMigrate` thereafter pay from the realized idle pile only.

**Wiring a strategy (two sides, both required):**

1. **On the strategy** (done by the *strategy's* owner, not `StableStaker`):
   `strategy.setClient(address(staker), true)`. Until this is done the strategy's
   `deposit`/`withdraw` revert (`AYieldStrategy: unauthorized, only authorized clients`), so a
   `stake` into a token whose strategy hasn't authorized the farm will revert.
2. **On the staker** (owner): `staker.setYieldStrategy(token, strategy)`. This `forceApprove`s the
   strategy for unlimited `token`, **sweeps any idle balance** already in the contract into the new
   strategy, and emits `YieldStrategySet`. Clearing or replacing a strategy resets the *old*
   strategy's allowance to 0. **`setYieldStrategy` reverts (`"StableStaker: pool not empty"`) unless `totalStaked == 0`** — strategy (un)wiring is an empty-pool-only operation. To change strategy on a live pool, drain it to empty via the terminal migration runbook (`initiateMigration → batchMigrate/userMigrate → finalizeAndReset`) and then wire the fresh strategy on the revived empty pool.

The farm pools all users under a single strategy client account (`recipient = address(this)` for
both deposit and withdraw); it forwards the redeemed tokens to the real user afterward. Exits
forward the **actual received** amount (balance delta), while internal principal accounting is
decremented by the **requested** amount — sub-amount differences remain protocol-owned yield/loss
(consistent with `ERC4626YieldStrategy`'s rounding rule).

**Yield stays protocol-owned.** Stakers only ever get their *principal* back plus phUSD emissions.
Reward accounting (`accPhusdPerShare`, `rewardDebt`, `totalStaked`, `_updatePool`, `_settle`) is
untouched by this routing; the farm never reads `totalBalanceOf` to credit a user. Accrued yield
accumulates inside the strategy as protocol-owned surplus (skimmed elsewhere via the strategy's
`skimSurplus`).

**Underwater withdraw block.** A strategy is "underwater" / below par when
`totalBalanceOf(token, staker) < principalOf(token, staker)` (negative yield). While a token's
strategy is underwater, `withdraw` reverts (`StableStaker: strategy underwater`) so a
non-migrating user cannot be forced to realise a loss. `emergencyWithdraw` and `initiateMigration`
are **not** blocked by the underwater guard — they accept the haircut so the escape hatch and
migrations always work. `withdrawDisabled(token)` is a cheap public view returning `true` while
withdraw is blocked (and `false` when no strategy is set).

## Terminal migration mode

`initiateMigration(token)` (`onlyMigrator`) engages a **terminal, per-token** migration: it settles
& freezes emissions, snapshots `P = totalStaked`, realizes the whole strategy position once into
idle balance as `R` (via the client-callable `strategy.withdraw`, NOT `totalWithdrawal` — see the
source comment for why), decouples the strategy, and sets `active = true`. Thereafter every exit —
operator `batchMigrate` or permissionless `userMigrate` — pays a fixed credit `p_i·min(R,P)/P` from
the idle pile, so payouts are independent of batch composition, ordering, and batch-vs-self.
Equal principal ⇒ equal payout (closes ss2m1 / M-01). Migration is terminal: once engaged a token's
pool can never resume healthy operation (no resume path), and `stake` / `withdraw` /
`emergencyWithdraw` / the old staker's `depositFor` are blocked while `active` to preserve the
snapshot. The `StableStakerMigrator` exposes an owner-only `initiateMigration` forwarder (call once
per token before the first `migrate` batch).

## Evergreen contract and version snapshots

`src/StableStaker.sol` is **evergreen**: it is the permanently-current implementation and is
always the one file you edit. It is **never forked into a `StableStakerV2.sol` sitting alongside
it**, and neither is any other contract in this repo.

Why not: the tradition being rejected lives in `reflax-mint/phlimbo-ea`, where `Phlimbo.sol`,
`PhlimboV2.sol` and `PhlimboV3.sol` coexist. Forking multiplies near-identical files, splits every
bug fix across N copies, and leaves each consumer guessing which file is current. The evergreen
model keeps exactly one canonical implementation and pushes versioning into cheap, non-deployed
interface snapshots under `src/versions/` — interfaces are not deployed, so a snapshot costs
nothing against `forge build --sizes`.

### Version identity

`StableStaker.STAKER_VERSION` is a `uint256 public constant` naming the *source's* shape. It is
currently `2`.

It is deliberately **not** `1`: the deployed instance
`0xbce8ABC09BaEDCabE93419bF875f6186e182079A` is V1 and predates the constant entirely, so the
moment `STAKER_VERSION` was added the source stopped describing the deployed bytecode.
`src/versions/IStableStakerV1.sol` is the only accurate description of that live instance.

Because V1 has no `STAKER_VERSION` getter, **a static call to it reverts**. Any code that probes a
staker's version must treat a revert as "version 1" rather than propagating the failure. Use a
low-level `staticcall` and branch on success — never a plain typed call.

There is deliberately no `version()` *function*: a `public constant` costs no storage and matches
the existing `ACC_PRECISION` / `SECONDS_PER_DAY` idiom in the same file.

### The snapshot-on-deploy ritual

On **any** deploy of `src/StableStaker.sol`:

1. Freeze the current external surface into `src/versions/IStableStakerV<N>.sol`, where `<N>` is
   the current value of `STAKER_VERSION`.
2. That file is **never edited again** — it is a historical record, not a source file.
3. Bump `STAKER_VERSION` to `N + 1` in `src/StableStaker.sol`.
4. Record the deployed address and the source commit in the new snapshot's NatSpec.
5. Every snapshot `is IStableStakerMigratable` — no exceptions. That is the golden rule, and
   extending the perpetual interface makes it a compile-time obligation rather than a convention.

`src/versions/README.md` carries the same ritual with the file-level conventions (interfaces not
abstract contracts, plain value types over project enums, the snapshot test) spelled out.

## Dependencies

Plain git submodules under `lib/` (no "mutable dependency" mechanism):

- `lib/openzeppelin-contracts` — external, pinned to tag `v5.6.1`.
- `lib/forge-std` — external, pinned to tag `v1.16.1`.
- `lib/flax-token` — phoenix project, tracks `master` HEAD.
- `lib/pauser` — phoenix project, tracks `master` HEAD.
- `lib/reflax-yield-vault` — phoenix project, tracks `master` HEAD. Provides
  `IYieldStrategy` / `AYieldStrategy` / `ERC4626YieldStrategy` (see "Yield strategies" above).
  Remapped as `reflax-yield-vault/=lib/reflax-yield-vault/src/`.

Remappings live in `foundry.toml` and `remappings.txt`. OZ v5.6.1 requires `solc >= 0.8.24`;
the project pins `solc = "0.8.28"`.

## Commands

- `forge build` — compile.
- `forge test` / `forge test -vvv` — run tests (TDD; tests live in `test/`).
- `forge fmt` — format.

All development follows TDD with Foundry (no Hardhat/Truffle).
