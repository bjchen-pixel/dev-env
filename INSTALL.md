# INSTALL — v3-005 Plan-Gate Hook + File-Backed Handoff

This repo ships a deterministic, zero-LLM, zero-network guard layer for the
RELIABLE_WORKFLOW v3 triangle. It blocks (or warns about) editing implementation
files until there is an **Approved** active plan, mechanically writes a session
handoff at Stop, and re-injects it at SessionStart.

Everything is pure `bash` (3.2 compatible) and depends only on `git` + optional
`jq` (an `awk` fallback covers the no-jq case). All wiring lives in the
**project-level** `.claude/settings.json` — your user-level `~/.claude/` is never
touched, so the worst-case rollback is deleting one repo-local file.

---

## 1. Files

| File | Role |
|---|---|
| `hooks/pre-edit-guard.sh` | `PreToolUse` on `Edit\|Write` — the plan/scope gate. |
| `hooks/stop-orchestrator.sh` | `Stop` — writes `.ai/harness/handoff/resume.md`. |
| `hooks/session-start-context.sh` | `SessionStart` — injects `resume.md` as recovery-only context. |
| `hooks/lib/*.sh` | shared helpers (`workflow-state.sh`, `write-handoff.sh`). |
| `.claude/settings.json` | wires the three hooks (`timeout: 30`, repo root via `git rev-parse`). |
| `templates/policy.json` | per-repo policy template — copy to `.ai/harness/policy.json`. |

To adopt in a target repo, copy `hooks/`, `.claude/settings.json`, and (optionally)
`templates/policy.json` into it. Hooks resolve the repo root with
`git rev-parse --show-toplevel`, so they work from any subdirectory.

---

## 2. The two switch surfaces and the three modes

The plan gate (`pre-edit-guard.sh`) runs in one of three **modes**:

| Mode | Behavior on an unapproved/out-of-scope implementation edit |
|---|---|
| `advice` | **Default.** Prints a warning to **stdout**, exit 0 — never blocks. |
| `enforce` | Prints the reason to **stderr**, `exit 2` — Claude Code blocks the edit. |
| `off` | Completely silent, exit 0 — the guard is a no-op. |

Workflow-surface edits (`plans/ tasks/ docs/ .ai/ .claude/` and any `*.md`) are
**always allowed** in every mode and every plan state.

The mode is resolved by this exact **precedence** (first hit wins):

1. **Environment variable** `V3_EDIT_PLAN_GATE` — `enforce` / `advice` / `off`.
   Highest priority; overrides everything. Great for a one-off override or for
   an emergency downgrade.
2. **`.ai/harness/policy.json`** key `guards.edit_plan_gate` — the per-repo
   default, committed with the repo so the whole team shares it.
3. **Built-in default** `advice` — if neither of the above is set.

### Switch A — environment variable (transient, highest priority)

```sh
export V3_EDIT_PLAN_GATE=advice    # warn only
export V3_EDIT_PLAN_GATE=enforce   # hard block
export V3_EDIT_PLAN_GATE=off       # disable the gate
```

### Switch B — `policy.json` (per-repo, committed)

```sh
mkdir -p .ai/harness
cp templates/policy.json .ai/harness/policy.json
# then edit guards.edit_plan_gate to "advice" | "enforce" | "off"
```

```json
{
  "guards": {
    "edit_plan_gate": "advice"
  }
}
```

`policy.json` is read by `policy_get()` (jq primary, awk fallback). If the file
is missing or the key is absent, the gate falls back to `advice`.

---

## 3. Gradual rollout: prove zero false-blocks under `advice`, then flip to `enforce`

The safe adoption path is to run in `advice` first, watch for **any** edit you'd
consider a false block, and only then promote to `enforce`.

1. **Install in `advice`.** Copy the hooks + settings + `policy.json` (default is
   already `advice`). Do real work for a while.
2. **Watch the warnings.** In `advice` mode every gate decision that *would* have
   blocked prints a `[PlanStatusGuard] advice: ...` / `[ContractScopeGuard]
   advice: ...` line to stdout. Treat each one as a dry-run alarm.
3. **Confirm zero false positives.** A false positive = the gate warned about an
   edit that was actually legitimate (e.g. it mis-classified a path as
   implementation, or your repo's plan/approval flow differs). If you see any,
   fix the plan/contract or report the misfire — do **not** flip to enforce yet.
4. **Promote to `enforce`.** Once the warnings only fire on edits you genuinely
   want blocked, set `guards.edit_plan_gate` to `enforce` in `policy.json`
   (or `export V3_EDIT_PLAN_GATE=enforce`).
5. **Keep `advice` as the team default if you prefer soft enforcement** and let
   individuals opt into `enforce` via the env var.

---

## 4. One-key disable / rollback (kill switch)

Three layers, lightest first:

1. **Downgrade the mode (no file changes):**
   ```sh
   export V3_EDIT_PLAN_GATE=off     # or =advice
   ```
   Because env precedence is highest, this instantly stops the gate from
   blocking, without editing any file.

2. **Official global kill switch.** In `.claude/settings.json` set:
   ```json
   { "disableAllHooks": true }
   ```
   This disables **all** hooks for the repo in one line (Claude Code built-in).

3. **Unwire / restore.** Remove the relevant block(s) under
   `hooks.PreToolUse` / `hooks.Stop` / `hooks.SessionStart` in
   `.claude/settings.json`, or just restore the whole file:
   ```sh
   git checkout .claude/settings.json
   ```
   Since all wiring is repo-local and nothing touches `~/.claude/`, deleting the
   repo's `.claude/settings.json` fully detaches the guard layer and affects no
   other project.

---

## 5. Worked example — read-only `advice` dry-run against a real repo

The guard never needs to be installed into a target repo to be *tested* against
it: feed a synthetic `PreToolUse` stdin payload whose `cwd` and `file_path`
point at the real repo, and run `pre-edit-guard.sh` in `advice` mode. This is
fully non-invasive — it reads paths, writes nothing.

```sh
REPO=/path/to/this/dev-env-v3
TARGET=/path/to/your/repo

# editing an implementation file under an unapproved plan -> advice WARNS, exit 0
printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' \
  "$TARGET" "$TARGET/signals/foo.py" \
  | ( cd "$TARGET" && V3_EDIT_PLAN_GATE=advice bash "$REPO/hooks/pre-edit-guard.sh" )
echo "exit=$?"

# editing a workflow surface (*.md) -> always allowed, silent, exit 0
printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' \
  "$TARGET" "$TARGET/docs/NOTES.md" \
  | ( cd "$TARGET" && V3_EDIT_PLAN_GATE=advice bash "$REPO/hooks/pre-edit-guard.sh" )
echo "exit=$?"
```

A concrete run of exactly this, against the real InvestSys repo, is recorded in
the section below — it warns (never blocks) on `signals/*.py`, silently allows
`*.md`, and correctly relativizes absolute paths (in-repo vs out-of-repo)
**without writing a single byte into that repo**.

---

## 6. Real, non-invasive `advice` dry-run against InvestSys (recorded evidence)

Run against the real `/Volumes/Data 4T/Projects/0-InvestSys` repo with synthetic
stdin only. Nothing was written into InvestSys: no hook installed, no `.ai/`
created, `.claude/` untouched, and `git status --porcelain` was byte-identical
before and after.

```sh
REPO=/Volumes/Data\ 4T/Projects/dev-env-v3
INV=/Volumes/Data\ 4T/Projects/0-InvestSys
GUARD="$REPO/hooks/pre-edit-guard.sh"
```

| # | Edit target | Mode | Result |
|---|---|---|---|
| 1 | `signals/_common.py` (implementation) | `advice` | exit 0, **stdout** warning, never blocked |
| 2 | `docs/BACKLOG.md` (workflow surface) | `advice` | exit 0, silent allow |
| 3a | `/tmp/somewhere_else.py` (outside repo) | `advice` | exit 0, silent allow (out of scope) |
| 3b | `NEXT_STEPS.md` (repo-root `*.md`) | `advice` | exit 0, silent allow |
| 4 | `detectors/__init__.py` (implementation) | `enforce` | exit 2, stderr block — relativization correct |
| 5 | `scanners/__init__.py` (implementation) | `off` | exit 0, silent allow |

Scenario 1 (advice warns, never blocks an InvestSys impl edit):

```
$ printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' \
    "$INV" "$INV/signals/_common.py" \
    | ( cd "$INV" && V3_EDIT_PLAN_GATE=advice bash "$GUARD" )
[PlanStatusGuard] advice: active plan not approved (status: (no marker)) for signals/_common.py. Not blocking (advice mode).
exit=0   (stderr empty)
```

Scenario 4 (enforce would block — same path machinery, repo-relative target):

```
[PlanStatusGuard] BLOCKED (automated quality gate, exit 2 — this is NOT a user rejection).
...
  - blocked edit target: detectors/__init__.py
exit=2   (stdout empty)
```

Non-invasion proof:

```
$ git -C "$INV" status --porcelain   # before == after, byte-identical
$ ls "$INV/.ai"                       # No such file or directory (never created)
```

