# Claude Code hooks — `stable-staker`

## `protect-migration-surface.sh`

### Purpose

Guards **the golden rule**: every version of `StableStaker` — past, present and future — must
expose the migration triad

| Function | Signature | Selector |
|---|---|---|
| `initiateMigration` | `initiateMigration(address)` | `0x71726c92` |
| `batchMigrate` | `batchMigrate(address,address[])` | `0x0ad9aeb9` |
| `depositFor` | `depositFor(address,address,uint256)` | `0xb3db428b` |

Those three are the whole of a cross-version hop: `initiateMigration` freezes the source pool,
`batchMigrate` drains it, `depositFor` credits the destination. Remove one and the users staked
in the deployed V1 instance `0xbce8ABC09BaEDCabE93419bF875f6186e182079A` (Ethereum mainnet) are
stranded in a contract nothing can migrate them out of. Deployed bytecode cannot be patched;
there is no recovery.

### Why a hook, when the compiler already enforces it

`StableStaker.sol` declares `is IStableStaker`, so deleting one of the three from the contract
fails the build (story 014). This hook guards the layer the compiler cannot: an agent "fixing"
that build error by deleting the declaration from `IStableStakerMigratable` as well, or from a
frozen `src/versions/` snapshot. At that point everything compiles again and the rule is gone.

### Triggers

Registered on two `PreToolUse` matchers:

| Matcher | What it checks |
|---|---|
| `Edit\|Write\|NotebookEdit\|MultiEdit` | Only paths under `src/`. Denies a `Write` whose new content declares a protected function fewer times than the file on disk, and an `Edit`/`MultiEdit` whose `old_string` declares one that its `new_string` does not. Cheap, early, best-effort. |
| `Bash` | Only `git commit` commands. Compares protected-declaration counts in the **staged tree** (`git write-tree`) against `HEAD`, across `src/`. Denies on any decrease. This is the authoritative gate. |

Everything else passes untouched: reads, builds, tests, and edits outside `src/`. A working-tree
experiment that is never committed harms nobody.

### Escape hatch

Put `GOLDEN-RULE-OVERRIDE` in the commit message to break the rule deliberately — for the day the
live V1 instance is genuinely empty and dead. The hook then allows the call and prints a loud
warning to stderr. A rule with no sanctioned exit gets worked around destructively; this one has
a door, and using it is recorded permanently in the commit message.

### Fail-closed

Unlike the `deployment-staging` precedent (`except Exception: pass`), this hook **denies** when it
cannot do its job: missing `jq`, missing `git`, an unparseable payload, a non-repository project
dir, or a `git write-tree` failure. A guard over a live user base that silently disables itself on
error is not a guard.

### Exit codes and output

| Situation | Behaviour |
|---|---|
| Allowed | exit `0`, no stdout |
| Denied | exit `0` with `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}` on stdout |
| Denied, `jq` unavailable | exit `2` with the reason on stderr (also blocks the call) |
| Override accepted | exit `0`, loud warning on stderr |

### Configuration

Registered in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|NotebookEdit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/protect-migration-surface.sh\"",
            "statusMessage": "Checking StableStaker golden-rule migration surface"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR/.claude/hooks/protect-migration-surface.sh\"",
            "statusMessage": "Checking StableStaker golden-rule migration surface"
          }
        ]
      }
    ]
  }
}
```

`$CLAUDE_PROJECT_DIR` is quoted deliberately — the `deployment-staging` precedent uses a fragile
relative path.

### Known gap — read this before relying on the hook

A `PreToolUse` hook only fires when **`stable-staker` is the session's project root**. This repo is
normally driven as a submodule from a `product-owner` worktree, in which case *this hook does not
fire at all*. That is a deliberate, human-made scope decision (story 017).

The layers that work everywhere are:

- `.github/scripts/check-migration-surface.sh`, run by CI on every push, and
- `test/GoldenRule.t.sol`, which pins the three selectors to hard-coded bytes.

If the hook proves toothless in practice, registering it in `product-owner/.claude/settings.json`
is a one-line follow-up.

### Manual tests

Run from the repository root.

```bash
# Allowed: an ordinary commit that touches nothing protected (no output, exit 0)
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' \
  | .claude/hooks/protect-migration-surface.sh; echo "exit=$?"

# Allowed: anything that is not a git commit
echo '{"tool_name":"Bash","tool_input":{"command":"forge test -vvv"}}' \
  | .claude/hooks/protect-migration-surface.sh; echo "exit=$?"

# DENIED: an edit that removes a protected declaration from src/
jq -cn '{tool_name:"Edit",tool_input:{
    file_path:"src/interfaces/IStableStakerMigratable.sol",
    old_string:"function depositFor(address token, address user, uint256 amount) external;",
    new_string:""}}' \
  | .claude/hooks/protect-migration-surface.sh

# Allowed: the same edit outside src/
jq -cn '{tool_name:"Edit",tool_input:{
    file_path:"test/GoldenRuleInterface.t.sol",
    old_string:"function depositFor(address a, address b, uint256 c) external;",
    new_string:""}}' \
  | .claude/hooks/protect-migration-surface.sh; echo "exit=$?"

# DENIED (fail-closed): project dir is not a git repository
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' \
  | CLAUDE_PROJECT_DIR=/tmp .claude/hooks/protect-migration-surface.sh

# Override: same commit, sanctioned bypass — allowed with a loud stderr warning
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"retire v1 GOLDEN-RULE-OVERRIDE\""}}' \
  | .claude/hooks/protect-migration-surface.sh; echo "exit=$?"
```

To exercise the authoritative commit gate end to end, stage a removal in a throwaway clone:

```bash
git clone --local --no-hardlinks . /tmp/gr-test && cd /tmp/gr-test
export CLAUDE_PROJECT_DIR=$PWD
sed -i '/function depositFor(address token, address user, uint256 amount) external;/d' \
  src/interfaces/IStableStakerMigratable.sol
git add src/interfaces/IStableStakerMigratable.sol
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m drop"}}' \
  | .claude/hooks/protect-migration-surface.sh | jq -r '.hookSpecificOutput.permissionDecision'
# => deny
```

### The CI gate

```bash
.github/scripts/check-migration-surface.sh   # exit 0 when the surface is intact
```

It asserts three things: `src/interfaces/IStableStakerMigratable.sol` declares all three,
`src/StableStaker.sol` declares all three, and every `src/versions/IStableStakerV*.sol` still
reads `is IStableStakerMigratable`.
