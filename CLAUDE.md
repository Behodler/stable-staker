# CLAUDE.md

Guidance for Claude Code when working in the `stable-staker` submodule.

## Overview

`stable-staker` is a MasterChef-style yield farm that supports any number of staked (stable)
tokens and rewards stakers in **Antimatter** (the `Antimatter` token from the `antimatter`
submodule). Rewards are not pre-funded: this contract is an approved Antimatter **minter** and
mints rewards directly to users on **claim and terminal migration only**. `stake` and `withdraw`
no longer touch Antimatter at all — they *book* the settled amount to the `unclaimedReward`
mapping, which `claim` pays out (story 022). That is deliberate robustness: a revoked minter role,
or any Antimatter revert, can no longer brick a principal path.

**Emissions token, by version (story 023).** The evergreen `src/StableStakerV2.sol` emits
**Antimatter**. The byte-frozen `src/versions/v1/StableStakerV1.sol` emits **phUSD** and always
will — the live mainnet V1 instance is deployed and unpatchable, so that is correct and permanent,
not an oversight. V2 holds only a minimal local `src/interfaces/IAntimatter.sol`
(`mint`, `annihilate`, `toStableAmount` and `phUSD` — nothing more); the concrete `Antimatter` is
deployed in tests from `lib/antimatter`. Authorization is Antimatter's owner-managed whitelist,
`setApprovedMinter(address,bool)`, and an unapproved caller reverts with the custom error
`NotApprovedMinter(address)` — there is no phUSD-style `mintVersion` mass revocation, so
per-minter `setApprovedMinter(x, false)` is the only way to revoke.

**V2 can also mint phUSD, and that is not a reversal of the above (story 026).** The pivot stands:
Antimatter is the sole reward token for claims, withdrawals, deposits, APY accounting and
migration, and nothing about what a staker earns changed. V2 holds a second minimal local
interface, `src/interfaces/IPhUSD.sol` (`mint`, plus `mintVersion` and `authorizedMinters`, which
together form the probe `phUSDMintAvailable()`), for exactly one purpose: covering the shortfall
when `autoAnnihilate`'s yield-strategy exit under-delivers, shifting that exit slippage onto the
protocol as phUSD inflation rather than onto the annihilating user. The token is resolved live via
`phUSDToken()` off Antimatter's mutable `phUSD`, never cached and never a constructor argument.
Story 026 added the capability and no consumer; story 028 is the consumer.

**Naming.** flax-token-v2 is called **phUSD**, never "flax" — mirroring `antimatter/CLAUDE.md`.
`pxUSD` is an unrelated third-party token and never belongs in this repo.

Consequences worth knowing:

- `emergencyWithdraw` forfeits the `unclaimedReward` backlog as well as the live pending — the
  escape hatch stays the single rule "no reward, principal out", and never mints.
- `claim` is still `whenNotPaused`, so a pause now withholds the accumulated backlog too.
- `claimableReward(token, account)` is the read for "what can I claim right now"; it returns
  `unclaimedReward + pendingReward`, exactly what `claim` mints.
- `pendingReward` is unchanged and is the **live projection only**, excluding the backlog — its
  meaning must stay identical to the frozen V1 selector of the same name, because the cross-version
  migrator means both versions are read side by side.
- See `docs/deferred-reward-accrual-plan.md`.

- `src/StableStakerV2.sol` — the farm, and the **evergreen** contract: all forward work happens
  here. Per-token pools, owner-set `antimatterPerDay(token, amount)`
  emission budget, per-token `EnumerableSet` of stakers (`getStakers` / `getStakersRange` /
  `stakerCount`), Behodler3 pausing (`pauser` + `IPausable`), and a permissionless
  `emergencyWithdraw` escape hatch.
- `src/CrossVersionMigrator.sol` — moves a batch of users from one `StableStaker` to another with
  zero user action, preserving principal and minting earned rewards. Both ends are typed on the
  narrow golden-rule interface `IStableStakerMigratable` and are `immutable`, so it works across
  ANY two versions (V1→V2, V2→V3, …) and can never be retargeted by a compromised owner. Uses the
  staker's permissioned terminal-migration hooks `initiateMigration` (once per token) +
  `batchMigrate` / `depositFor` (caller must be the configured `migrator`). Zero-credit dust users
  are skipped rather than reverting the batch, and underwater haircuts are NOT compensated here.
  Carries an advisory `versionOf` probe that reports a staker with no `STAKER_VERSION` getter as
  version 1. See "Terminal migration mode" and "The two migrators" below.
- `src/InPlaceMigrator.sol` — swaps a single staker's yield strategy **in place**, without
  deploying a new `StableStaker`. Drives the same terminal-migration hooks
  (`initiateMigration` → `batchMigrate`/`userMigrate` → `finalizeAndReset`) against one contract
  so an empty pool can be re-wired to a fresh `IYieldStrategy`, with a surplus-funded top-up that
  re-injects the haircut.
- `src/interfaces/IStableStaker.sol` — minimal interface `InPlaceMigrator` depends on (the
  golden-rule triad plus the `userInfo` getter its top-up needs).
- `src/interfaces/IStableStakerMigratable.sol` — the perpetual "golden rule" interface
  (`initiateMigration`, `batchMigrate`, `depositFor`) that every version must satisfy.
- `src/versions/v<N>/` — frozen, never-edited snapshots of each **deployed** staker: the full
  contract source (`StableStakerV<N>.sol`) *and* its interface (`IStableStakerV<N>.sol`), pinned
  by `FROZEN.sha256`. `v1/` is the source of the live mainnet instance
  `0xbce8ABC09BaEDCabE93419bF875f6186e182079A`, bugs included. See "Version snapshots and the
  evergreen contract" below.

## Core safety invariant

No sequence of user actions can **accrue** more than `antimatterPerDay` for a token over any
window, and cumulative *minted* is always `<=` cumulative *accrued*. The only writer of
`accAntimatterPerShare` is `_updatePool`, which folds in exactly `elapsed * antimatterPerSecond`
per update; the sum of all
stakers' pending increase equals that minus integer-division dust (which always rounds DOWN).
Empty-pool windows accrue nothing; flash staking earns nothing; `antimatterPerDay` settles the pool at
the old rate before changing it.

Since story 022, reward is *booked* to `unclaimedReward` rather than transferred on
`stake`/`withdraw`, so minted alone understates what was accrued. The statement carrying the
invariant is `sum(unclaimedReward) + minted <= cap`. Payout timing is strictly downstream of
accrual — no new path writes `accAntimatterPerShare` — so the cap holds a fortiori. Read the claimable
total via `claimableReward`; `pendingReward` remains projection-only and excludes the backlog. See
`test/EmissionCap.t.sol` and `test/DeferredAccrual.t.sol`.

## The claim gate and `autoAnnihilate` (story 025)

`claim()` is gated by an owner-settable `claimEnabled` flag and is **false on deployment**.
While it is down, `autoAnnihilate(address token, uint256 minPhUSDOut)` is the reward path:
it mints the caller's owed Antimatter to the staker itself, annihilates it against a slice of
the caller's **own booked principal**, decrements `userInfo.amount` and `poolInfo.totalStaked`
by the stable half, and Antimatter mints the resulting phUSD straight to the caller. The staker
watches their principal decline and receives phUSD for it, so annihilation becomes something
they have done rather than something they have read about.

This is a **teaching phase, not a permanent design**. `setClaimEnabled(true)` reopens `claim`
in one transaction with no redeploy, which is the entire reason the gate is a flag.

Mechanics worth knowing before touching this code:

- **Decimals.** `owed` is 18-decimal antimatter; principal is in the token's own decimals. The
  annihilated amount is capped at the caller's principal and then **floored** to a multiple of
  `10 ** (18 - decimals)`, because `Antimatter.toStableAmount` reverts `AmountNotRepresentable`
  rather than rounding. The scale is read **live** from `IERC20Metadata(token).decimals()`
  rather than cached at `addToken`: a cache would need backfilling for pools already registered
  on the live instances, and it mis-scales silently if a token's decimals move, whereas a live
  read fails closed. Antimatter cross-checks the same number against the stable minter's
  registration (`DecimalsMismatch`), so the live read has an independent auditor on every call.
- **Sub-unit dust** left by that flooring stays in `unclaimedReward` — not minted, not
  transferred. It accrues to the next call, so it is neither stranded nor a dust-sized bypass of
  a closed gate, and it rounds in the protocol's favour.
- **Sourcing the stable half** goes through `_routeExit(token, amount, true)`, never the raw
  idle balance: with a strategy set the stable lives in the strategy, and the buffer path's
  `relinquishPrincipal` is what keeps `strategy.principalOf` in lockstep with `totalStaked`
  (audit findings ss14m1 / ss14l8). The underwater guard is ON, matching `withdraw` — this is a
  voluntary exit, not an escape hatch.
- **The exit haircut is sized, measured, and charged to the caller** (round 2). A strategy that
  sells its position on exit — `ERC4626MarketYieldStrategy` always does — delivers less than it
  is asked for. `autoAnnihilate` quotes `IYieldStrategy.previewExitFor(token, address(this),
  netWanted)` (vault-RM story 050) for the **gross** it must request, caps that **gross** (never
  the net) at the caller's own `user.amount`, and debits `user.amount` and `pool.totalStaked` by
  it. The Antimatter the haircut displaced joins `excess` and is minted straight to the caller.
  Worked example: 100 of principal against 100 of Antimatter — gross-withdraw 100, receive 98,
  annihilate 98, mint 2. Three things about this are load-bearing:
  - **Capping the gross, not the net, is what keeps the whole-position caller from underflowing**
    `user.amount`. The net cap looks equivalent and is not.
  - **The preview is advisory only.** It reads live AMM state and is manipulable within a block,
    and it is built on the fee-free `convertToAssets` (vault-RM story 049 — `previewRedeem` is
    unusable because Autopool-style vaults mutate state inside it and trap under `STATICCALL`),
    so it over-quotes on a fee-charging vault. The real balance delta across the exit is
    therefore **measured**, and a delivery below the pro-rated guarantee reverts
    `"StableStaker: exit shortfall"`. A lying preview must fail the transaction.
  - **The floor carries a ROUNDING allowance, and only a rounding allowance**
    (`EXIT_ROUNDING_ALLOWANCE` = 2 raw units, plus `EXIT_ROUNDING_ALLOWANCE_BPS` = 1 bp). Without
    it the check is an exact equality — `AYieldStrategy.previewExitFor`'s default is the capped
    *identity*, so `netGuaranteed == grossToRequest` — while `ERC4626YieldStrategy._disposeShares`
    redeems `vault.convertToShares(amount)` and the vault floors the assets back, rounding down
    twice and delivering `amount - 1` or less at any non-integral share price. That combination
    made `autoAnnihilate` revert on essentially every call against a plain ERC4626 vault that had
    accrued yield, which with `claimEnabled` false is the only reward path there is. One basis
    point is far below any real haircut, so a genuinely short delivery — or a preview lying to
    widen the raw-mint path around the closed `claim` — still reverts.
  - **The idle buffer is never the payer** *on a solvent strategy*. Charging the net and letting
    the shortfall fall on the contract's idle balance socialises one caller's routine exit loss across every staker,
    because that balance is the shared underwater-withdrawal buffer. Symmetrically, anything the
    exit over-delivers is forwarded to the caller rather than left to grow the buffer at their
    expense. The user absorbing their own haircut is the same outcome as withdrawing manually and
    annihilating in their own wallet, and every other principal-moving path (`withdraw`,
    `emergencyWithdraw`) already works this way.

    The carve-out is the **underwater** path, which `autoAnnihilate` shares with `withdraw` and
    does not change: when `_isUnderwater` is true, `_routeExit` pays the whole request out of the
    idle balance plus `relinquishPrincipal` and returns the nominal amount without measuring
    anything. That is the buffer doing exactly the job it exists for, and it is deliberate — see
    "idle balance is automatically buffer" above — but it means "the buffer is untouched" is a
    statement about the normal path, not an invariant of every call.

  A strategy that can guarantee nothing at all — the market strategy at a 100% slippage
  tolerance, which answers `(0, 0)` to every preview — makes `autoAnnihilateAvailable(token)`
  false and `autoAnnihilate` revert, rather than minting the whole reward raw through the
  `excess` path and handing the caller a bypass of a closed `claim`.
- **Self-sandwiching is bounded and accepted.** A worse AMM rate annihilates less and mints more
  raw Antimatter, which is what the closed `claim` exists to prevent — but
  `ERC4626MarketYieldStrategy` enforces its own `minOut` from `slippageToleranceBps` and reverts
  before `autoAnnihilate` sees the proceeds, so the extractable amount is capped at the tolerance
  and costs a real AMM round trip. Ordinary sandwiching of the exit is not new: a plain
  `withdraw` sells into the same AMM with the same protection.
- **`PoolState.Active` is required**, unlike `claim`, because this moves principal and would
  otherwise corrupt the terminal-migration `P` snapshot.
- **Registered-stable coupling.** `Antimatter.toStableAmount` reverts `StablecoinNotRegistered`
  unless the pool token is also registered with `PhusdStableMinter`. **Registering a pool token
  with the stable minter is now part of the pool-registration runbook.** `autoAnnihilate`
  pre-flights this and reverts `"StableStaker: token not annihilatable"`, and the view
  `autoAnnihilateAvailable(token)` exposes it, so the UI never has to interpret a foreign
  contract's custom error.
- **The migration carve-out.** The Antimatter mint inside `_exitPosition` is deliberately **not**
  gated by `claimEnabled`. Gating it would let a closed claim gate brick migration.
- **The two-pause deadlock.** `Antimatter.annihilate` is `whenNotPaused` against *Antimatter's*
  own Phoenix pauser, which StableStaker does not control. With `claimEnabled == false`, an
  antimatter-side pause leaves stakers with no reward path at all. The intended response is
  operational, not a code path: **the owner flips `claimEnabled` to true for the duration of any
  antimatter pause.** That is an obligation on whoever holds the StableStaker owner key.

### Auditor note — annihilation exceeding principal

When a user's claimable antimatter exceeds their booked principal, the excess cannot be
annihilated — there is no principal left to annihilate it against. Of the available responses
(revert, hold the excess indefinitely, force a partial claim), we deliberately choose to **mint
the excess directly to the user, exactly as a claim would**.

This is a knowing, documented loophole around the disabled `claim()`. We accept it because:

- The alternative — reverting — strands a user whose rewards have outgrown their stake, with no
  path to their own accrued value. That is a far worse failure than a leak in a temporary
  teaching gate.
- The condition requires reward accrual to exceed staked principal, which at realistic emission
  rates takes a long time relative to how long the gate is intended to stay closed.
- `claimEnabled` is expected to be flipped on within weeks. The gate is pedagogy, not a security
  boundary, and should never be relied upon as one.

Auditors should read `claimEnabled` as a UX mechanism with a deliberate escape valve, **not** as
an access control. Nothing in the protocol's safety argument may depend on antimatter being
unobtainable while the flag is false.

## Wiring (deployment)

1. Deploy `StableStakerV2(antimatter, owner)`.
2. Antimatter owner calls `antimatter.setApprovedMinter(address(staker), true)`.
3. phUSD owner calls `phUSD.setMinter(address(staker), true)`. **This is not a reward-token
   change.** Antimatter remains the sole thing a staker earns; the phUSD grant exists ONLY so that
   `autoAnnihilate` can cover a yield-strategy exit shortfall out of protocol inflation instead of
   shortchanging the annihilating user. Read `staker.phUSDMintAvailable()` back afterwards — it is
   the two-condition probe (`canMint` AND a current `mintVersion`) and is the only honest check
   that the grant took. Note that `staker.phUSDToken()` resolves live off `antimatter.phUSD()`, so
   this step must come after Antimatter's `setPhUSD`, and a later `setPhUSD` rotation needs the
   grant re-issued on the incoming token.
4. `staker.addToken(token)` for each stable, then `staker.antimatterPerDay(token, amountPerDay)`.
5. Optional: `staker.setPauser(pauser)`, `staker.setMigrator(migrator)`.
6. Register each pool token with `PhusdStableMinter` (`registerStablecoin` + `approveYS`), or
   `autoAnnihilate` is unavailable for it — check with `staker.autoAnnihilateAvailable(token)`.
7. `claimEnabled` starts **false** and is meant to stay false for the teaching phase; open it with
   `staker.setClaimEnabled(true)` when the phase ends, or for the duration of an antimatter pause.

Beware `phUSD.revokeAllMintPrivileges()`: it bumps a GLOBAL `mintVersion` and de-authorises every
minter at once, with no per-minter transaction and no event naming the staker. Step 3 has to be
re-run after any such sweep, and `phUSDMintAvailable()` is what detects it.

For migration, both old and new stakers must have the migrator set (`setMigrator`) and the new
staker must have the token registered (`addToken`). V2 and onward need **both** grants: approved
minter on Antimatter, which is the reward token, and phUSD minter rights, which are purely
shortfall cover for `autoAnnihilate`. The frozen V1 needs only phUSD, which *was* its reward token
— the two grants mean entirely different things on the two versions and V2 holding phUSD rights is
not a partial reversal of the emissions pivot.

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

**Yield stays protocol-owned.** Stakers only ever get their *principal* back plus Antimatter
emissions. Reward accounting (`accAntimatterPerShare`, `rewardDebt`, `totalStaked`, `_updatePool`, `_settle`) is
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
snapshot. The `CrossVersionMigrator` exposes an owner-only `initiateMigration` forwarder (call once
per token before the first `migrate` batch).

## The two migrators

There are exactly TWO migrators, and the choice between them is the source/target question:

| Contract | Source → target | Use it for |
|---|---|---|
| `src/CrossVersionMigrator.sol` | staker A → staker B (different contracts, any versions) | a true replacement deploy, or a version hop |
| `src/InPlaceMigrator.sol` | staker A → staker A (same contract) | swapping a live pool's `IYieldStrategy`, which `setYieldStrategy`'s empty-pool gate makes impossible in place |

Only `InPlaceMigrator` makes users whole after an underwater exit: its story-013 surplus-funded
top-up (`_reinjectWithTopup`) re-injects the haircut. `CrossVersionMigrator` deliberately does NOT
carry that logic — a cross-version migration through an underwater strategy credits the uniform
snapshot haircut. That asymmetry is a real product difference and wants a human decision before a
cross-version migration is run on a live, underwater user base.

Both pin their targets as `immutable`: an owner-mutable target is a drain vector, so a new pair of
stakers always means a NEW migrator deployment plus re-wiring `setMigrator` on both sides.

**A third migrator, `src/StableStakerMigrator.sol`, was REMOVED in story 018.** It was the original
cross-staker tool and `CrossVersionMigrator` is a strict functional superset of it (same forwarder,
same `batchMigrate` → sum → `forceApprove` → `depositFor` flow, same zero-credit skip, same
immutable ends), so keeping both would have left two overlapping tools with no rule for choosing
between them. No instance of it was ever recorded in
`reflax-mint/phase-2-staging/server/deployments/mainnet-addresses.ts`, and the one saga that would
have used it (the temp-staker "ys-swap" saga) was abandoned in favour of the `InPlaceMigrator`
route. The source is recoverable from git history if a cross-staker-only tool is ever wanted back:

```bash
git log --all --diff-filter=D -- src/StableStakerMigrator.sol
git show <commit>^:src/StableStakerMigrator.sol
```

Known fallout, deliberately left unrepaired and tracked as a cross-repo follow-up: in the sibling
`reflax-mint/phase-2-staging` repo, `script/DeployTempStableStakerAndMigrators.s.sol` and
`test/YsSwapMigrationHardening.t.sol` import the deleted contract and no longer compile. Both
belong to the abandoned saga. `script/SkimAndLeg1Migration.s.sol` and `script/Leg2Migration.s.sol`
declare their own local interfaces and are unaffected.

## Golden rule — the migration triad is permanent

**EVERY version of `StableStaker`, past, present and future, must expose all three of:**

| Function | Frozen signature | Selector |
|---|---|---|
| `initiateMigration` | `initiateMigration(address)` | `0x71726c92` |
| `batchMigrate` | `batchMigrate(address,address[])` | `0x0ad9aeb9` |
| `depositFor` | `depositFor(address,address,uint256)` | `0xb3db428b` |

They are declared in `src/interfaces/IStableStakerMigratable.sol` and are the whole of a
cross-version hop: `initiateMigration` freezes the source pool, `batchMigrate` drains it,
`depositFor` credits the destination. Every version snapshot under `src/versions/` inherits that
interface: the frozen `src/versions/v1/IStableStakerV1.sol` declares
`is IStableStakerMigratable`, and the evergreen `StableStakerV2` declares `is IStableStaker`
(which extends it).

**Why it is permanent.** Remove one — or reshape a signature, which is the same thing at the wire
level — and the users staked in the deployed V1 instance
`0xbce8ABC09BaEDCabE93419bF875f6186e182079A` (Ethereum mainnet) are stranded in a contract nothing
can migrate them out of. Deployed bytecode cannot be patched. There is no recovery, so there is no
"we'll fix it in the next version".

The `token` first parameter is load-bearing: a `StableStaker` is multi-pool. A future one-pool
redesign that dropped it would break the golden rule by construction — see the long note in
`IStableStakerMigratable.sol`.

**If the build complains** that `StableStakerV2` does not implement one of the three, the fix is to
RESTORE the function on the contract. Never delete the declaration from the interface, and never
edit anything under `src/versions/` to make the error go away — that is the exact failure the
layers below exist to catch.

### Four layers of enforcement

1. **The compiler.** `StableStakerV2 is IStableStaker`, so deleting one of the three from the
   evergreen contract fails the build (story 014).
2. **A `PreToolUse` hook** — `.claude/hooks/protect-migration-surface.sh`, registered in
   `.claude/settings.json`. Denies an `Edit`/`Write` under `src/` that removes a protected
   declaration, and denies a `git commit` whose staged tree declares one fewer time than `HEAD`.
   Fails closed. **Known gap**: a hook only fires when `stable-staker` is the session's project
   root, and this repo is normally driven as a submodule — see `.claude/hooks/README.md`.
3. **A CI gate** — `.github/scripts/check-migration-surface.sh`, run on every push. Checks the
   perpetual interface, the evergreen implementation (`src/StableStakerV2.sol`), that every
   `src/versions/v*/IStableStakerV*.sol` still reads `is IStableStakerMigratable`, and — since
   story 019 — that the frozen V1 files still **exist** and still **hash** to the values pinned in
   `src/versions/v1/FROZEN.sha256`. That last check closes audit finding `ss14l3` / `L-03`: the
   gate used to catch mutation of the migration surface but treated a deleted snapshot as a mere
   note. No blind spot about which directory an agent was driven from.
4. **`test/GoldenRule.t.sol`** and **`test/StableStakerV1Frozen.t.sol`** — the former pins the three selectors to hard-coded byte constants, so a
   coordinated redesign that changes interface and implementation together still fails. Those
   constants are not a magic number to update when the test goes red; they are the wire format the
   live instance answers to. The latter deploys the frozen `StableStakerV1` with the real mainnet
   constructor arguments and asserts the same three selectors dispatch on it, so V1's compliance is
   proven against a deployable contract rather than an interface. `test/GoldenRuleInterface.t.sol`
   additionally asserts the triad stays `onlyMigrator`-gated and reachable through the interface.

### Overriding the rule

For the day the live V1 instance is genuinely empty and dead: put `GOLDEN-RULE-OVERRIDE` in the
commit message. The hook allows the commit and prints a loud warning. A rule with no sanctioned
exit gets worked around destructively — this one has a door, and using it is recorded permanently
in git history. Using it while V1 still holds stakers is a decision to strand them.

## Version snapshots and the evergreen contract

`src/StableStakerV2.sol` is the **evergreen** contract: the permanently-current implementation and
the one file you edit for forward work. Alongside it, `src/versions/v<N>/` holds a **frozen full
copy of every version that has actually been deployed**, source and interface both.

### Fork on DEPLOY, not on change — and the story-019 correction

Story 016 established a single evergreen `StableStaker.sol` with interface-only snapshots, and
explicitly instructed that it must **never** be forked into a `StableStakerV2.sol`. **Story 019
reversed that instruction.** If you find a leftover statement anywhere in this repo forbidding a
`StableStakerV<N>.sol`, it is stale — this section is the current rule.

The distinction that makes both stories right is *when* you fork:

- **Never fork on a change.** The tradition being rejected lives in `reflax-mint/phlimbo-ea`,
  where `Phlimbo.sol`, `PhlimboV2.sol` and `PhlimboV3.sol` coexist as rival current
  implementations. Forking per change multiplies near-identical files, splits every bug fix
  across N copies, and leaves each consumer guessing which file is current. There is exactly one
  evergreen, and it is `StableStakerV2.sol`.
- **Always fork on a deploy.** A deployed contract is immutable and its behaviour must remain
  reasonable-about forever. Story 016 assumed that once a version is superseded nobody needs to
  reason about its behaviour again — an interface would do. That assumption failed: the live V1
  at `0xbce8ABC09BaEDCabE93419bF875f6186e182079A` has known defects (`ss14m1`, `ss14l8`) and
  still holds un-migrated stakers. A recovery runbook, a fork test or an audit that needs to
  reason about deployed behaviour must be able to **compile** it, and an interface can be neither
  deployed nor fork-tested.

The frozen copies are not rival implementations: nothing inherits from them, nothing deploys them
to production, and they are never edited. They are historical records that happen to compile.

### Frozen means frozen — including the bugs

`src/versions/v1/StableStakerV1.sol` reproduces `git show c3ec65b:src/StableStaker.sol`, with only
the divergences enumerated in its own header (a contract rename forced by Foundry artifact
resolution, plus that header). Its known defects — `ss14m1` (terminal migration bricked by
`setYieldStrategy`'s unrecorded idle sweep) and `ss14l8` (set-aside buffer excluded from the
migration realized amount `R`) — are preserved **deliberately**. Fixing them there would make the
file lie about bytecode that is already on chain, which is the single failure mode `src/versions/`
exists to prevent. Fix them in the evergreen `StableStakerV2` and in the operational recovery plan.
An audit that re-files those two findings against `src/versions/` should be triaged as
"deliberately preserved", not actioned.

`.github/scripts/check-migration-surface.sh` enforces this: a missing or modified frozen file is a
hard CI failure. Regenerating `FROZEN.sha256` to match an edit defeats the check and is not an
acceptable fix — restore the file instead.

### Version identity

`StableStakerV2.STAKER_VERSION` is a `uint256 public constant` naming the *source's* shape. It is
currently `2`, and it is **not** renumbered by the V1/V2 file split.

It is deliberately not `1`: the deployed instance `0xbce8ABC09BaEDCabE93419bF875f6186e182079A` is
V1 and predates the constant entirely, so the moment `STAKER_VERSION` was added the evergreen
source stopped describing the deployed bytecode. `src/versions/v1/` is the only accurate
description of that live instance.

Because V1 has no `STAKER_VERSION` getter, **a static call to it reverts**. Any code that probes a
staker's version must treat a revert as "version 1" rather than propagating the failure — use a
low-level `staticcall` and branch on success, never a plain typed call.
`CrossVersionMigrator.versionOf` does exactly this. It follows that the frozen
`StableStakerV1.sol` must **never gain a `STAKER_VERSION` getter**: adding one would both lie
about the deployed bytecode and break that probe. `test/StableStakerV1Frozen.t.sol` asserts its
absence.

There is deliberately no `version()` *function*: a `public constant` costs no storage and matches
the existing `ACC_PRECISION` / `SECONDS_PER_DAY` idiom in the same file.

### The snapshot-on-deploy ritual

On **any** deploy of `src/StableStakerV2.sol`, where `<N>` is its current `STAKER_VERSION` and
`<C>` is the commit actually deployed:

1. **Establish `<C>` from deployment evidence, not from `master` HEAD.** Cross-check the
   `phase-2-staging` submodule pointer on the deploy day, the broadcast JSON under
   `phase-2-staging/broadcast/`, and `phase-2-staging/server/deployments/mainnet-addresses.ts`.
   Snapshotting from HEAD is only correct by luck; this is audit finding `ss14l4` / `L-04`.
2. Generate the frozen source **mechanically** —
   `git show <C>:src/StableStakerV<N>.sol > src/versions/v<N>/StableStakerV<N>.sol` — never by
   hand. Freeze its external surface into `src/versions/v<N>/IStableStakerV<N>.sol` from the same
   commit.
3. Apply only the minimum divergences needed to coexist and compile (contract rename on collision;
   import-path and pragma fixes if library pins have moved) and **enumerate every one in a
   "Permitted divergences" block in the file header**. Revert strings are ABI-visible behaviour and
   stay verbatim. If only a *logic* edit would make it compile — anything touching storage layout
   or an external signature — **stop and escalate to a human**: the copy could no longer honestly
   claim to be the deployed source.
4. Those files are **never edited again**. Pin them with `sha256sum … > FROZEN.sha256` and add the
   pair to `FROZEN_FILES` in `.github/scripts/check-migration-surface.sh`.
5. Record the deployed address, source commit, deploy date and a **NEVER EDIT THIS FILE** notice in
   both files' NatSpec.
6. Add `test/StableStakerV<N>Frozen.t.sol` (deploys the frozen contract with the real broadcast
   constructor arguments; proves it is deployable, not merely parseable) and
   `test/StableStakerV<N>Snapshot.t.sol` (casts the **frozen** contract through the new interface
   and exercises every member). Point fidelity tests at the frozen contract, never at the
   evergreen — the evergreen is free to diverge, so a fidelity assertion against it proves nothing.
7. Bump `STAKER_VERSION` to `N + 1` in `src/StableStakerV2.sol` and update
   `test/StakerVersion.t.sol`. (Rename the evergreen contract only if a human decides to; the
   constant, not the filename, is the identity.)
8. Every snapshot interface `is IStableStakerMigratable` — no exceptions. That is the golden rule,
   and extending the perpetual interface makes it a compile-time obligation rather than a
   convention.

`src/versions/README.md` carries the same ritual with the file-level conventions spelled out.

## Dependencies

Plain git submodules under `lib/` (no "mutable dependency" mechanism):

- `lib/openzeppelin-contracts` — external, pinned to tag `v5.6.1`.
- `lib/forge-std` — external, pinned to tag `v1.16.1`.
- `lib/flax-token` — **REMOVED** (story 024). phUSD is still the emissions token of the frozen V1
  snapshot, but the two reachable source files are now vendored verbatim at
  `src/versions/v1/vendor/IFlax.sol` and `src/versions/v1/vendor/FlaxToken.sol`
  (from `Behodler/flax-token-v2@f5300117e94bd30349fb88f426d434ef1ccddce0`), and the `flax-token/`
  remapping points there. Keeping the remapping NAME is what spares every import site — the two
  hash-pinned frozen files and the V1-covering tests — from any change. See
  `src/versions/README.md` for the retirement steps.
- `lib/antimatter` — phoenix project, pinned at `a5570ce`. Provides the `Antimatter` emissions
  token that `StableStakerV2` mints (story 023). Remapped as `antimatter/=lib/antimatter/src/`,
  with the transitive `@phUSD/`, `@phUSDMinter/` and `@pauser/` remappings its sources need.
  Requires `git submodule update --init --recursive`: antimatter's own `lib/pauser` and its
  `lib/phUSD-stable-minter/lib/pauser` are not initialized by a shallow init. Test files import it
  as `import {Antimatter} from "antimatter/Antimatter.sol";` — the named form is required, because
  a plain import drags a second `IPausable` declaration into scope and collides with this repo's
  own `pauser/interfaces/IPausable.sol`.
- `lib/pauser` — phoenix project, tracks `master` HEAD.
- `lib/reflax-yield-vault` — phoenix project, tracks `master` HEAD. Provides
  `IYieldStrategy` / `AYieldStrategy` / `ERC4626YieldStrategy` (see "Yield strategies" above).
  Remapped as `reflax-yield-vault/=lib/reflax-yield-vault/src/`. Pinned at `cdd0743`, which is
  where `IYieldStrategy.previewExitFor` arrives (vault-RM story 050); `autoAnnihilate` needs it,
  and every direct implementer of the interface in this repo's tests must declare it or the
  suite will not compile.

Remappings live in `foundry.toml` and `remappings.txt`. OZ v5.6.1 requires `solc >= 0.8.24`;
the project pins `solc = "0.8.28"`.

## Commands

- `forge build` — compile.
- `forge test` / `forge test -vvv` — run tests (TDD; tests live in `test/`).
- `forge fmt` — format.

All development follows TDD with Foundry (no Hardhat/Truffle).
