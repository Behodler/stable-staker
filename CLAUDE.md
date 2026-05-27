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
  zero user action, preserving principal and minting earned rewards. Uses the staker's
  permissioned `migrateOut` / `depositFor` hooks (caller must be the configured `migrator`).
- `src/interfaces/IStableStaker.sol` — minimal interface the migrator depends on.

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
original behaviour). All five principal-moving paths (`stake`, `withdraw`, `emergencyWithdraw`,
`migrateOut`, `depositFor`) route through the strategy when one is set.

**Wiring a strategy (two sides, both required):**

1. **On the strategy** (done by the *strategy's* owner, not `StableStaker`):
   `strategy.setClient(address(staker), true)`. Until this is done the strategy's
   `deposit`/`withdraw` revert (`AYieldStrategy: unauthorized, only authorized clients`), so a
   `stake` into a token whose strategy hasn't authorized the farm will revert.
2. **On the staker** (owner): `staker.setYieldStrategy(token, strategy)`. This `forceApprove`s the
   strategy for unlimited `token`, **sweeps any idle balance** already in the contract into the new
   strategy, and emits `YieldStrategySet`. Clearing or replacing a strategy resets the *old*
   strategy's allowance to 0. Replacing an in-use strategy does **not** auto-migrate funds out of
   the old one — drain it first (via the old strategy's owner flow) or replace only while
   `totalStaked == 0`.

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
non-migrating user cannot be forced to realise a loss. `emergencyWithdraw` and `migrateOut` are
**not** blocked — they accept the haircut so the escape hatch and migrations always work.
`withdrawDisabled(token)` is a cheap public view returning `true` while withdraw is blocked
(and `false` when no strategy is set).

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
