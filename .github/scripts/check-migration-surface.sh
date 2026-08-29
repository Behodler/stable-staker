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
#   3. Every frozen interface snapshot under src/versions/ still inherits the perpetual
#      interface, which is how a snapshot promises the triad without redeclaring it.
#   4. The frozen V1 files still EXIST and still hash to their pinned sha256 values.
#      (Audit finding ss14l3 / L-03: checks 1-3 catch MUTATION of the migration surface but
#      are blind to DELETION of a frozen snapshot - zero snapshots used to be a mere note.
#      Now that src/versions/v1/ holds a full compilable copy of the deployed contract,
#      that blindness is the bigger hole: silently deleting or "tidying" the frozen source
#      destroys the only honest description of live mainnet bytecode.)
#
# Run from anywhere. Exits non-zero on any violation.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

IFACE=src/interfaces/IStableStakerMigratable.sol
IMPL=src/StableStakerV2.sol
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
snapshots=(src/versions/v*/IStableStakerV*.sol)
if (( ${#snapshots[@]} == 0 )); then
  fail "no version snapshots found under src/versions/v*/. At least IStableStakerV1.sol must exist."
fi
for f in "${snapshots[@]}"; do
  if grep -qE "^interface[[:space:]]+[A-Za-z0-9_]+[[:space:]]+is[[:space:]]+.*IStableStakerMigratable" "$f"; then
    echo "ok: $f inherits IStableStakerMigratable"
  else
    fail "$f no longer declares 'is IStableStakerMigratable'. Every frozen version snapshot must inherit the perpetual interface."
  fi
done

# ---------------------------------------------------------------------------
# 4. The frozen V1 files exist and are byte-identical to their pinned hashes.
# ---------------------------------------------------------------------------
#
# src/versions/v1/ holds the SOURCE AS DEPLOYED of the live mainnet instance
# 0xbce8ABC09BaEDCabE93419bF875f6186e182079A, reproducible with
#
#     git show c3ec65b:src/StableStaker.sol
#
# plus exactly the divergences listed in that file's own header. It is never edited. Its
# known bugs (ss14m1, ss14l8) are deliberately preserved: fixing them there would make the
# file lie about what is on chain. Deleting it does not make the deployed contract go away;
# it only destroys our ability to compile, fork-test and reason about it.
#
# So: existence AND content are both pinned here.

FROZEN_MANIFEST=src/versions/v1/FROZEN.sha256
FROZEN_FILES=(src/versions/v1/StableStakerV1.sol src/versions/v1/IStableStakerV1.sol)

for f in "${FROZEN_FILES[@]}"; do
  if [[ ! -f $f ]]; then
    fail "FROZEN FILE MISSING: $f. The frozen source of the deployed V1 must never be deleted."
  fi
done

if [[ ! -f $FROZEN_MANIFEST ]]; then
  fail "FROZEN MANIFEST MISSING: $FROZEN_MANIFEST. Without it nothing pins the frozen V1 content."
elif ! command -v sha256sum >/dev/null 2>&1; then
  echo "note: sha256sum unavailable; skipping the frozen-file hash verification." >&2
else
  # Every path named in the manifest must also be one we expect, so the manifest cannot be
  # emptied out to make this check vacuous.
  manifest_count=$(grep -cvE '^\s*(#|$)' "$FROZEN_MANIFEST" || true)
  if (( manifest_count != ${#FROZEN_FILES[@]} )); then
    fail "$FROZEN_MANIFEST pins $manifest_count file(s); expected ${#FROZEN_FILES[@]}."
  fi
  if sha256sum --quiet --check "$FROZEN_MANIFEST" >/dev/null 2>&1; then
    echo "ok: frozen V1 files match their pinned sha256 values"
  else
    sha256sum --check "$FROZEN_MANIFEST" >&2 || true
    fail "FROZEN FILE MODIFIED: content under src/versions/v1/ no longer matches $FROZEN_MANIFEST."
  fi
fi

if (( status != 0 )); then
  cat >&2 <<'MSG'

################################################################################
##   GOLDEN RULE VIOLATION — MIGRATION SURFACE OR FROZEN V1 COMPROMISED       ##
################################################################################

EVERY version of StableStaker must expose initiateMigration, batchMigrate and depositFor.
They are the only way a migrator can move a live user base between versions. Removing one
severs that path forever for every deployed version, including the live mainnet instance
at 0xbce8ABC09BaEDCabE93419bF875f6186e182079A.

If a triad declaration is missing: restore it on the contract. Never delete it from
src/interfaces/IStableStakerMigratable.sol to make a build pass.

If a frozen file under src/versions/v1/ is missing or modified: restore it with

    git show c3ec65b:src/StableStaker.sol

(then re-apply only the divergences listed in that file's own header), or `git checkout` it.
Do NOT regenerate FROZEN.sha256 to match an edit - that defeats the entire check. The frozen
copy describes bytecode that is already on chain and can never change; editing it only makes
it lie. Its known bugs (ss14m1, ss14l8) are preserved ON PURPOSE.

The ONLY deliberate way past this gate is a commit message carrying GOLDEN-RULE-OVERRIDE,
which signals that the live V1 instance is genuinely dead and the migration surface is being
retired on purpose. If you are not doing that, this is a bug in your change.

See the "Golden rule" section of CLAUDE.md.
MSG
fi

exit $status
