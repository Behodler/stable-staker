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

## Dependencies

Plain git submodules under `lib/` (no "mutable dependency" mechanism):

- `lib/openzeppelin-contracts` — external, pinned to tag `v5.6.1`.
- `lib/forge-std` — external, pinned to tag `v1.16.1`.
- `lib/flax-token` — phoenix project, tracks `master` HEAD.
- `lib/pauser` — phoenix project, tracks `master` HEAD.

Remappings live in `foundry.toml` and `remappings.txt`. OZ v5.6.1 requires `solc >= 0.8.24`;
the project pins `solc = "0.8.28"`.

## Commands

- `forge build` — compile.
- `forge test` / `forge test -vvv` — run tests (TDD; tests live in `test/`).
- `forge fmt` — format.

All development follows TDD with Foundry (no Hardhat/Truffle).
