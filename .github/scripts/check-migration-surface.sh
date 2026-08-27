#!/usr/bin/env bash
# CI gate for the GOLDEN RULE: the StableStaker migration triad is permanent.
#
#   initiateMigration(address)
#   batchMigrate(address,address[])
#   depositFor(address,address,uint256)
#
# Every version of StableStaker must expose all three so a migrator can always drain one
# version and credit another. Removing one strands the live mainnet user base at
# 0xbce8ABC09BaEDCabE93419bF875f6186e182079A — deployed bytecode cannot be patched.
#
# This is the layer that works regardless of which directory an agent was driven from: the
# PreToolUse hook in .claude/ only fires when stable-staker is the session's project root,
# and this repo is normally driven as a submodule. CI has no such blind spot.
#
# Three checks:
#   1. The perpetual interface still declares all three.
#   2. The evergreen implementation still declares all three.
#   3. Every frozen snapshot under src/versions/ still inherits the perpetual interface,
#      which is how a snapshot promises the triad without redeclaring it.
#
# Run from anywhere. Exits non-zero on any violation.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

IFACE=src/interfaces/IStableStakerMigratable.sol
IMPL=src/StableStaker.sol
PROTECTED=(initiateMigration batchMigrate depositFor)

status=0

fail() {
  echo "GOLDEN RULE VIOLATION: $1" >&2
  status=1
}

for f in "$IFACE" "$IMPL"; do
  if [[ ! -f $f ]]; then
    fail "$f is missing."
    continue
  fi
  for name in "${PROTECTED[@]}"; do
    if grep -qE "function[[:space:]]+$name[[:space:]]*\(" "$f"; then
      echo "ok: $f declares $name"
    else
      fail "$f no longer declares '$name'."
    fi
  done
done

shopt -s nullglob
snapshots=(src/versions/IStableStakerV*.sol)
if (( ${#snapshots[@]} == 0 )); then
  echo "note: no version snapshots under src/versions/ yet."
fi
for f in "${snapshots[@]}"; do
  if grep -qE "^interface[[:space:]]+[A-Za-z0-9_]+[[:space:]]+is[[:space:]]+.*IStableStakerMigratable" "$f"; then
    echo "ok: $f inherits IStableStakerMigratable"
  else
    fail "$f no longer declares 'is IStableStakerMigratable'. Every frozen version snapshot must inherit the perpetual interface."
  fi
done

if (( status != 0 )); then
  cat >&2 <<'MSG'

################################################################################
##   GOLDEN RULE VIOLATION — MIGRATION SURFACE INCOMPLETE                     ##
################################################################################

EVERY version of StableStaker must expose initiateMigration, batchMigrate and depositFor.
They are the only way a migrator can move a live user base between versions. Removing one
severs that path forever for every deployed version, including the live mainnet instance
at 0xbce8ABC09BaEDCabE93419bF875f6186e182079A.

Restore the missing declaration. See the "Golden rule" section of CLAUDE.md.
MSG
fi

exit $status
