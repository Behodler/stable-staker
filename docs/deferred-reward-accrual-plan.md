# Deferred reward accrual

**Status: IMPLEMENTED** — shipped by story-022 on `sprint/no-auto-claim`.
Originally drafted 2026-08-23 as "proposed, not implemented"; re-anchored to
`src/StableStakerV2.sol` and marked implemented on 2026-08-30.

> **Anchoring note.** The original draft was written before story 019 renamed
> `src/StableStaker.sol` to `src/StableStakerV2.sol` and froze V1 under `src/versions/v1/`.
> Every file and line reference below is against the current `src/StableStakerV2.sol`.
> **V2 only** — `src/versions/v1/` is frozen, hash-pinned by `FROZEN.sha256`, reproduces the live
> mainnet instance `0xbce8ABC09BaEDCabE93419bF875f6186e182079A`, and keeps immediate payout.
>
> **Emissions-token note (story 023).** This plan was written while V2 still emitted phUSD. V2 now
> emits **Antimatter** (`src/interfaces/IAntimatter.sol`, concrete token in `lib/antimatter`); the
> frozen V1 keeps emitting phUSD forever. The mechanics below are unchanged by that swap — only the
> token, the identifier names (`accAntimatterPerShare`, `antimatterPerSecond`, `antimatterPerDay`)
> and the minter-authorization call (`setApprovedMinter` rather than `setMinter`) differ.

## 1. What changed

`StableStakerV2` no longer mints its reward token as a side effect of principal movement. Pending reward is
**booked** to a per-user unpaid balance and minted only on an explicit `claim`, or at the terminal
migration exit.

This is the standard accrue-to-balance MasterChef variant (MasterChefV2 / Convex style).
`rewardDebt` keeps its exact previous meaning as the accounting baseline; a second accumulator
holds settled-but-unminted reward:

```solidity
mapping(address => mapping(address => uint256)) public unclaimedReward; // line 96
```

## 2. Why

The headline win is **robustness**. Before this change a revoked minter role — or any reward-token revert
— bricked `stake` and `withdraw` outright, pushing users onto `emergencyWithdraw` and forfeiting
their rewards. The principal paths now never call the reward token at all, so its availability can neither
trap nor degrade principal handling. It also removes an external call from the middle of
`withdraw`, which previously minted before routing the exit.

Secondarily, it is preparation for a coming overhaul of emissions minting — story 023 moved V2 onto
Antimatter: principal movement is now
decoupled from the mint call.

## 3. Call sites

| Line | Function | Behaviour |
|---|---|---|
| 321 | `stake` | settles via `_settle`, which now books; mints nothing |
| 343 | `withdraw` | books `pending` to `unclaimedReward` (line 362); mints nothing |
| 376 | `claim` | mints `unclaimedReward + pending`, zeroing the slot (lines 381–387) |
| 394 | `emergencyWithdraw` | zeroes `unclaimedReward` (line 404) — forfeit, unchanged rule |
| 596 | `_exitPosition` | mints `pending + unclaimedReward`, zeroes the slot (lines 611–620) |
| 696 | `depositFor` | settles via `_settle`; otherwise unchanged |
| 832 | `_settle` | takes `token`, books instead of minting (line 836) |

Exactly two `antimatter.mint(` call sites remain, both on explicit-payout paths: `claim` and
`_exitPosition`. There were four before.

`claim` now succeeds for a user with `amount == 0` and a non-zero backlog (someone who fully
withdrew and has not claimed yet). The revert string `"StableStaker: nothing to claim"` is
unchanged; only its condition moved from `pending > 0` to `owed > 0`.

## 4. Storage: a standalone mapping, NOT a third `UserInfo` field

**This section is cited by `src/versions/v1/IStableStakerV1.sol` and
`test/StableStakerV1Snapshot.t.sol`; keep its number stable.**

Appending a field to `struct UserInfo` would change the arity of the public `userInfo` auto-getter
from a 2-tuple to a 3-tuple. That would break `src/interfaces/IStableStaker.sol` (which declares
the 2-tuple), `src/InPlaceMigrator.sol`, and roughly 82 destructuring sites across the test suite,
and would collide with `test/StableStakerV1Snapshot.t.sol`, which asserts the packed V1 position
is exactly 64 bytes at runtime.

The mapping is therefore standalone, declared beside `userInfo` and `_stakers`, so V2's storage
layout appends cleanly. V2 is not deployed and is not behind a proxy, so this is a clean addition.

**Naming.** An earlier draft called it `accruedReward`. "Accrued" reads as finished-and-settled in
ordinary accounting usage and was misread as *already paid*. `unclaimedReward` says what the
balance actually is: earned, owed, not yet minted.

## 5. Views

`pendingReward` (line 731) is **unchanged in meaning**: the live projection against `rewardDebt`,
deliberately **excluding** the `unclaimedReward` backlog. This is load-bearing. The frozen V1
exposes the same selector with the same body on permanently-deployed mainnet bytecode, and this
project ships a cross-version migrator precisely because two versions are read side by side. A V2
`pendingReward` that meant something different from V1's would be silently mis-read.

`claimableReward(address token, address account)` (line 739) is **new** and returns
`unclaimedReward + pendingReward` — the figure `claim` actually mints. The original draft ruled a
`claimable` view out of scope; that decision was revisited during story-022 planning and the view
is now shipped.

Both views share `_pendingReward` (line 745), a **pure extraction** of the former `pendingReward`
body. `pendingReward` returns an identical value for every input, and every pre-existing
`pendingReward` assertion in the suite passes untouched. There is no `this.pendingReward(...)`
self-call.

Neither `unclaimedReward` nor `claimableReward` is declared on `src/interfaces/IStableStaker.sol`
or `src/interfaces/IStableStakerMigratable.sol`. The golden-rule triad stays exactly three
members, and both interface files are byte-unchanged by this work.

## 6. Why the emission cap still holds

The cap invariant lives entirely in `_updatePool` / `accAntimatterPerShare` and is untouched. Payout
timing is strictly downstream of accrual:

- No new path writes `accAntimatterPerShare`.
- Per-user owed amounts are computed by the same formula, at the same moments.
- Cumulative **minted** becomes `<=` cumulative **accrued** rather than approximately equal to it.

The cap therefore holds *a fortiori*. The statement that now carries the invariant in the tests is
`sum(unclaimedReward) + minted <= cap` — see the companion assertion in
`test/EmissionCap.t.sol::test_emissionCap_holdsUnderChurn`.

## 7. Accepted trade-offs

| Question | Decision |
|---|---|
| Does `emergencyWithdraw` wipe the unclaimed balance? | **Yes.** The hatch stays "forfeit all reward, get principal out" — one rule, no dangling claim for an exited user. |
| Does `claim` stay `whenNotPaused`? | **Yes, unchanged.** A pause now freezes a reward *backlog* as well as live accrual. Accepted. |
| Does `pendingReward` change? | **No** — see §5. |
| Is there a `claimable` view? | **Yes**, `claimableReward`. Reversal of the original draft. |
| Does `MigratedOut.reward` change? | **Yes, silently.** It carries `pending + unclaimed` rather than `pending`. Off-chain consumers will read a different number. |

Known downside carried deliberately: deferral builds an unbounded off-schedule mint liability
realisable all at once. That is a reward-token market-depth concern, not a solvency one, and is what
the coming minting overhaul addresses.

## 8. Tests

`test/DeferredAccrual.t.sol` (new) covers booking-not-minting on `stake`/`withdraw`, the combined
`claim`, `claim` for a fully-withdrawn user, forfeit on `emergencyWithdraw`, path independence,
the `claimableReward` identity and its equality with what `claim` mints, `pendingReward`'s
unchanged projection-only meaning, both terminal-migration exits (`batchMigrate` and
`userMigrate`) paying `pending + unclaimed`, the combined `MigratedOut` field, and the headline
robustness property: with the minter role revoked, `stake`, `withdraw` and `emergencyWithdraw` all
still succeed and only `claim` reverts.
