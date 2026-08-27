#!/usr/bin/env bash
# THE GOLDEN RULE: the StableStaker migration triad is PERMANENT.
#
#   initiateMigration(address)
#   batchMigrate(address,address[])
#   depositFor(address,address,uint256)
#
# Every version of StableStaker — past, present and future — must expose all three.
# They are what a migrator needs to hop a live user base from one deployed version to
# the next: initiateMigration freezes the source pool, batchMigrate drains it, depositFor
# credits the destination. Remove any one of them and the hop is impossible: the users
# staked in the deployed V1 instance
#
#   0xbce8ABC09BaEDCabE93419bF875f6186e182079A   (Ethereum mainnet)
#
# are stranded in a contract nothing can migrate them out of. That is unrecoverable — the
# deployed bytecode can never be changed.
#
# `StableStaker.sol` declares `is IStableStaker`, so the compiler already refuses to build
# a staker missing one of the three. This hook guards the layer the compiler cannot: an
# agent "fixing" that build error by deleting the declaration from the interface as well,
# or from a frozen `src/versions/` snapshot.
#
# PreToolUse hook. Emits a permissionDecision of "deny" on stdout (exit 0) to block the
# call; falls back to exit 2 when `jq` is unavailable, which also blocks.
#
# FAILS CLOSED. If jq is missing, git errors, or the repository state cannot be read, this
# script DENIES rather than waving the call through. A guard over a live user base that
# silently disables itself on error is not a guard.
#
# Escape hatch: put GOLDEN-RULE-OVERRIDE in the commit message (or the tool call) to break
# the rule deliberately — for the day the live V1 instance is genuinely empty and dead.
#
# See the "Golden rule" section of CLAUDE.md, and .claude/hooks/README.md for manual tests.

set -uo pipefail

PROTECTED=(initiateMigration batchMigrate depositFor)
OVERRIDE_MARKER='GOLDEN-RULE-OVERRIDE'

ALARM='
################################################################################
##                                                                            ##
##   ####  GOLDEN RULE VIOLATION — MIGRATION SURFACE UNDER ATTACK  ####        ##
##                                                                            ##
################################################################################
'

RULE_TEXT='EVERY version of StableStaker must expose all three of:

    initiateMigration(address)
    batchMigrate(address,address[])
    depositFor(address,address,uint256)

They are the only way a migrator can move a live user base between versions:
initiateMigration freezes the source pool, batchMigrate drains it, depositFor credits
the destination. Removing even one of them severs that path FOREVER for every deployed
version — including the live mainnet instance at

    0xbce8ABC09BaEDCabE93419bF875f6186e182079A

whose stakers would be stranded in a contract nothing can migrate them out of. Deployed
bytecode cannot be patched; there is no recovery from this.

If the build is complaining that StableStaker does not implement one of the three, the
fix is to RESTORE the function on the contract — never to delete the declaration from
the interface or from a src/versions/ snapshot.

Read the "Golden rule" section of CLAUDE.md before going further. If you genuinely mean
to retire the rule (the live V1 instance is empty and dead), say so explicitly by putting
'"$OVERRIDE_MARKER"' in the commit message.'

# --- deny helpers -------------------------------------------------------------

emit_deny() {
  # $1: full reason text
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg reason "$1" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
  # No jq: exit 2 blocks the tool call and surfaces stderr to the agent.
  printf '%s\n' "$1" >&2
  exit 2
}

deny() {
  emit_deny "$ALARM
$1

$RULE_TEXT"
}

# Fail closed: the guard could not do its job, so it does not let the call through.
deny_unverifiable() {
  emit_deny "$ALARM
GOLDEN-RULE GUARD COULD NOT VERIFY THIS CALL — DENYING (fail-closed).

$1

This hook protects the StableStaker migration triad and refuses to wave a call through
when it cannot check it. Fix the underlying problem (see below) and retry.

$RULE_TEXT"
}

warn_override() {
  printf '%s\n' "$ALARM
GOLDEN-RULE OVERRIDE ACCEPTED — $OVERRIDE_MARKER was present.

The migration triad guard has been BYPASSED for this call. This is only correct once the
live V1 instance at 0xbce8ABC09BaEDCabE93419bF875f6186e182079A is genuinely empty and
dead. If that is not the case, STOP and revert.
" >&2
}

# --- preconditions ------------------------------------------------------------

payload=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  deny_unverifiable "jq is not installed, so the tool payload cannot be parsed."
fi

tool=$(jq -r '.tool_name // ""' <<<"$payload") || deny_unverifiable "The tool payload is not valid JSON."

# Repo root: the session project dir when set, otherwise the working directory.
repo_dir=${CLAUDE_PROJECT_DIR:-$PWD}

# Count protected declarations in a blob of text. $1 = name, stdin = text.
count_decls() {
  grep -cE "function[[:space:]]+$1[[:space:]]*\(" || true
}

case "$tool" in

  Edit|Write|NotebookEdit|MultiEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$payload")
    [[ -z $path ]] && exit 0
    [[ $path != /* ]] && path="$PWD/$path"

    # Only src/ is protected; tests, docs and scripts are free to move.
    case "$path" in
      */src/*) ;;
      *) exit 0 ;;
    esac

    if [[ $tool == Write ]]; then
      new_content=$(jq -r '.tool_input.content // ""' <<<"$payload")
      for name in "${PROTECTED[@]}"; do
        before=0
        [[ -f $path ]] && before=$(count_decls "$name" <"$path")
        after=$(count_decls "$name" <<<"$new_content")
        if (( after < before )); then
          deny "This Write would remove a declaration of \`$name\` from:

  $path

  (declarations before: $before, after: $after)"
        fi
      done
      exit 0
    fi

    # Edit / MultiEdit: compare each replacement's old_string against its new_string.
    # Best-effort early feedback; the git-commit branch below is the authoritative gate.
    edits=$(jq -c 'if .tool_input.edits then .tool_input.edits[] else {old_string: (.tool_input.old_string // ""), new_string: (.tool_input.new_string // "")} end' <<<"$payload")
    while IFS= read -r edit; do
      [[ -z $edit ]] && continue
      old=$(jq -r '.old_string // ""' <<<"$edit")
      new=$(jq -r '.new_string // ""' <<<"$edit")
      for name in "${PROTECTED[@]}"; do
        before=$(count_decls "$name" <<<"$old")
        after=$(count_decls "$name" <<<"$new")
        if (( after < before )); then
          deny "This edit would remove a declaration of \`$name\` from:

  $path

  (the replaced text declares it $before time(s); the replacement declares it $after time(s))"
        fi
      done
    done <<<"$edits"
    exit 0
    ;;

  Bash)
    cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")
    [[ -z $cmd ]] && exit 0

    # Only git commits are gated. Everything else passes; the commit is the point of no
    # return, and a working-tree experiment that is never committed harms nobody.
    grep -Eq '(^|[;&|]|&&)[[:space:]]*git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit\b' <<<"$cmd" || exit 0

    if grep -qF "$OVERRIDE_MARKER" <<<"$cmd"; then
      warn_override
      exit 0
    fi

    if ! command -v git >/dev/null 2>&1; then
      deny_unverifiable "git is not installed, so the staged tree cannot be compared against HEAD."
    fi

    # Honour an explicit `git -C <dir>`.
    if [[ $cmd =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
      target=${BASH_REMATCH[1]}
      target=${target%\"}; target=${target#\"}
      target=${target%\'}; target=${target#\'}
      [[ $target != /* ]] && target="$PWD/$target"
      repo_dir=$target
    fi

    if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
      deny_unverifiable "\`$repo_dir\` is not a git repository, so the commit cannot be checked."
    fi

    # No HEAD yet (initial commit): nothing to compare against, nothing to lose.
    git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1 || exit 0

    # A tree object for the index, i.e. exactly what this commit would record.
    staged_tree=$(git -C "$repo_dir" write-tree 2>/dev/null)
    if [[ -z $staged_tree ]]; then
      deny_unverifiable "\`git write-tree\` failed in \`$repo_dir\` (unmerged index?), so the staged tree cannot be inspected."
    fi

    count_in_tree() {
      # $1 = tree-ish, $2 = function name
      git -C "$repo_dir" grep -hoE "function[[:space:]]+$2[[:space:]]*\(" "$1" -- 'src/' 2>/dev/null | wc -l
    }

    for name in "${PROTECTED[@]}"; do
      head_n=$(count_in_tree HEAD "$name")
      staged_n=$(count_in_tree "$staged_tree" "$name")
      if [[ -z $head_n || -z $staged_n ]]; then
        deny_unverifiable "Could not count declarations of \`$name\` under src/."
      fi
      if (( staged_n < head_n )); then
        deny "This commit removes a declaration of \`$name\` from src/.

  declarations at HEAD : $head_n
  declarations staged  : $staged_n

Run \`git diff --cached -U0 -- src/\` and restore the removed declaration before committing."
      fi
    done
    exit 0
    ;;
esac

exit 0
