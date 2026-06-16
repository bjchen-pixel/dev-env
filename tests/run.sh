#!/bin/bash
# v3-005 Slice 1 — pure-bash test runner (zero deps). bash 3.2 compatible.
# Each test is a shell function returning 0 (PASS) / non-0 (FAIL).
# Runner aggregates failures and exits non-zero if any fail.

set -u

# Repo root = parent dir of this tests/ dir (canonical).
TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$TESTS_DIR/.." && pwd -P)
GUARD="$REPO/hooks/pre-edit-guard.sh"

FAIL_COUNT=0
CUR_TEST=""

fail() {
  # $1 = message
  printf '    FAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  # $1 expected, $2 actual, $3 label
  if [ "$1" != "$2" ]; then
    fail "$3: expected [$1], got [$2]"
  fi
}

assert_contains() {
  # $1 haystack, $2 needle, $3 label
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3: expected to contain [$2], got [$1]" ;;
  esac
}

assert_not_contains() {
  # $1 haystack, $2 needle, $3 label
  case "$1" in
    *"$2"*) fail "$3: expected NOT to contain [$2], but it did" ;;
    *) : ;;
  esac
}

# --- fixture helpers ---------------------------------------------------------

make_fixture_repo() {
  # echoes path to a fresh tmp git repo with signals/x.py, plans/, .ai/harness/
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  mkdir -p "$dir/signals" "$dir/plans" "$dir/.ai/harness"
  : > "$dir/signals/x.py"
  printf '%s' "$dir"
}

# write_plan_status <dir> <status>  -> writes plans/foo.md with given Status field
write_plan_status() {
  local dir="$1" status="$2"
  printf '# foo\n\n**Status**: %s\n' "$status" > "$dir/plans/foo.md"
}

# set_marker <dir> <plan_rel> [root_override]
#   marker line1 = plan_rel; line2 = canonical repo root (or root_override).
set_marker() {
  local dir="$1" plan_rel="$2" root_override="${3:-}"
  local root
  if [ -n "$root_override" ]; then
    root="$root_override"
  else
    root=$(cd "$dir" && pwd -P)
  fi
  printf '%s\n%s\n' "$plan_rel" "$root" > "$dir/.ai/harness/active-plan"
}

# make_stdin <absolute_file_path> <cwd>
# emits the PreToolUse Edit JSON payload. file_path MUST be absolute (real payload shape).
make_stdin() {
  local fp="$1"
  local cwd="$2"
  printf '{"session_id":"t","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' \
    "$cwd" "$fp"
}

# run_guard <dir> <mode> <abs_file_path>  -> sets RC / OUT / ERR globals
run_guard() {
  local dir="$1" mode="$2" fp="$3"
  local cwd
  cwd=$(cd "$dir" && pwd -P)
  local out_f err_f
  out_f=$(mktemp)
  err_f=$(mktemp)
  make_stdin "$fp" "$cwd" \
    | ( cd "$dir" && V3_EDIT_PLAN_GATE="$mode" bash "$GUARD" ) >"$out_f" 2>"$err_f"
  RC=$?
  OUT=$(cat "$out_f")
  ERR=$(cat "$err_f")
  rm -f "$out_f" "$err_f"
}

# --- Slice 2 fixture helpers -------------------------------------------------

# write_investsys_contract <plan_md_path>
#   Writes a plan markdown file embedding the Q7 InvestSys yaml contract block.
#   This is the real allowed_paths sample from the v3-005 plan Q7.
write_investsys_contract() {
  local f="$1"
  cat > "$f" <<'EOF'
# InvestSys active plan

**Status**: Approved

Some prose describing the slice.

```yaml
allowed_paths:
  - signals/        # prefix match (trailing /): all of signals/
  - detectors/
  - scanners/
  - notifiers/
  - analysis/
  - utils/
  - tests/test_*.py # glob match (no trailing /): test files
  - config/*.yaml
```

More prose after the block.
EOF
}

# --- Slice 2 D1 unit tests: contract_allows_path -----------------------------

test_contract_allows_path_prefix_hit() {
  # allowed_paths has `signals/` (trailing-slash => prefix match).
  # `signals/vix.py` is under that prefix => return 0.
  local dir contract
  dir=$(mktemp -d)
  contract="$dir/plan.md"
  write_investsys_contract "$contract"
  ( . "$REPO/hooks/lib/workflow-state.sh"; contract_allows_path "$contract" "signals/vix.py" )
  assert_eq 0 "$?" "signals/vix.py allowed by signals/ prefix"
  rm -rf "$dir"
}

test_contract_allows_path_prefix_miss() {
  # `deploy/secrets.env`: deploy/ is NOT in allowed_paths, and the file matches
  # no glob => return 1.
  local dir contract
  dir=$(mktemp -d)
  contract="$dir/plan.md"
  write_investsys_contract "$contract"
  if ( . "$REPO/hooks/lib/workflow-state.sh"; contract_allows_path "$contract" "deploy/secrets.env" ); then
    fail "deploy/secrets.env must NOT be allowed (got return 0)"
  fi
  rm -rf "$dir"
}

test_contract_allows_path_glob_hit_tests() {
  # `tests/test_*.py` (no trailing slash => glob). `tests/test_vix.py` must
  # match via glob expansion of `*` => return 0. If the impl mistakenly treated
  # this as a prefix, the literal `*` would not expand and this would fail.
  local dir contract
  dir=$(mktemp -d)
  contract="$dir/plan.md"
  write_investsys_contract "$contract"
  ( . "$REPO/hooks/lib/workflow-state.sh"; contract_allows_path "$contract" "tests/test_vix.py" )
  assert_eq 0 "$?" "tests/test_vix.py allowed by tests/test_*.py glob"
  rm -rf "$dir"
}

test_contract_allows_path_glob_hit_config() {
  # `config/*.yaml` glob => `config/foo.yaml` matches => return 0.
  local dir contract
  dir=$(mktemp -d)
  contract="$dir/plan.md"
  write_investsys_contract "$contract"
  ( . "$REPO/hooks/lib/workflow-state.sh"; contract_allows_path "$contract" "config/foo.yaml" )
  assert_eq 0 "$?" "config/foo.yaml allowed by config/*.yaml glob"
  rm -rf "$dir"
}

# --- tests -------------------------------------------------------------------

test_enforce_no_active_plan_edit_impl_blocks_exit2_stderr() {
  # enforce + NO active plan marker + edit impl file -> exit 2, message on stderr.
  local dir
  dir=$(make_fixture_repo)
  # no .ai/harness/active-plan created => no active plan
  run_guard "$dir" enforce "$dir/signals/x.py"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "PlanStatusGuard" "stderr has guard name"
  assert_contains "$ERR" "NOT a user rejection" "stderr has anti-misfire wording"
  assert_not_contains "$OUT" "PlanStatusGuard" "stdout must not carry blocking msg"
  rm -rf "$dir"
}

test_enforce_approved_edit_impl_passes_silent() {
  # enforce + Approved active plan + edit impl file -> exit 0, silent.
  local dir
  dir=$(make_fixture_repo)
  write_plan_status "$dir" Approved
  set_marker "$dir" "plans/foo.md"
  run_guard "$dir" enforce "$dir/signals/x.py"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_enforce_draft_edit_impl_blocks() {
  # enforce + Draft active plan (unapproved) + edit impl -> exit 2, stderr msg.
  local dir
  dir=$(make_fixture_repo)
  write_plan_status "$dir" Draft
  set_marker "$dir" "plans/foo.md"
  run_guard "$dir" enforce "$dir/signals/x.py"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "PlanStatusGuard" "stderr has guard name"
  assert_contains "$ERR" "Draft" "stderr prints current status value"
  rm -rf "$dir"
}

test_enforce_annotating_edit_impl_blocks() {
  # enforce + Annotating active plan (unapproved) + edit impl -> exit 2, stderr.
  local dir
  dir=$(make_fixture_repo)
  write_plan_status "$dir" Annotating
  set_marker "$dir" "plans/foo.md"
  run_guard "$dir" enforce "$dir/signals/x.py"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "PlanStatusGuard" "stderr has guard name"
  assert_contains "$ERR" "Annotating" "stderr prints current status value"
  rm -rf "$dir"
}

test_enforce_no_plan_edit_plan_surface_passes() {
  # enforce + NO active plan + edit a workflow surface (plans/foo.md)
  # -> exit 0 silent. Surface bypass MUST run before PlanStatusGuard.
  local dir
  dir=$(make_fixture_repo)
  # no marker => unapproved; but target is a workflow surface, so allow.
  : > "$dir/plans/foo.md"
  run_guard "$dir" enforce "$dir/plans/foo.md"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_advice_no_plan_edit_impl_warns_exit0() {
  # advice + NO active plan + edit impl -> exit 0, warning on stdout, stderr empty.
  local dir
  dir=$(make_fixture_repo)
  run_guard "$dir" advice "$dir/signals/x.py"
  assert_eq 0 "$RC" "exit code"
  assert_contains "$OUT" "PlanStatusGuard" "stdout has advice"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_off_no_plan_edit_impl_silent() {
  # off + NO active plan + edit impl -> exit 0, fully silent (no stdout/stderr).
  local dir
  dir=$(make_fixture_repo)
  run_guard "$dir" off "$dir/signals/x.py"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_missing_file_path_in_stdin_passes() {
  # stdin payload without a file_path -> fail-soft, exit 0 silent.
  local dir
  dir=$(make_fixture_repo)
  local out_f err_f json
  out_f=$(mktemp); err_f=$(mktemp)
  json='{"session_id":"t","cwd":"'"$(cd "$dir" && pwd -P)"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"old_string":"a","new_string":"b"}}'
  printf '%s' "$json" \
    | ( cd "$dir" && V3_EDIT_PLAN_GATE=enforce bash "$GUARD" ) >"$out_f" 2>"$err_f"
  RC=$?; OUT=$(cat "$out_f"); ERR=$(cat "$err_f"); rm -f "$out_f" "$err_f"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_abs_path_outside_repo_passes() {
  # absolute file_path landing OUTSIDE the repo root -> not in scope, exit 0 silent.
  local dir outside
  dir=$(make_fixture_repo)
  outside=$(mktemp -d)
  : > "$outside/elsewhere.py"
  run_guard "$dir" enforce "$outside/elsewhere.py"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir" "$outside"
}

test_repo_internal_new_file_in_new_dir_gated() {
  # Write a NOT-YET-EXISTING file under a NOT-YET-EXISTING dir, INSIDE the repo.
  # dirname can't be canonicalized -> guard falls back to raw path. The fallback
  # must NOT cause a repo-internal new file to be misjudged as outside-repo.
  # enforce + no plan -> exit 2.
  local dir
  dir=$(make_fixture_repo)
  # signals/new/ does not exist; y.py does not exist.
  run_guard "$dir" enforce "$dir/signals/new/y.py"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "PlanStatusGuard" "stderr has guard name"
  assert_contains "$ERR" "signals/new/y.py" "blocked target is the repo-relative path"
  rm -rf "$dir"
}

test_file_path_extracted_without_jq_matches_jq() {
  # With jq MASKED (PATH stripped of jq), the awk fallback must extract the same
  # file_path -> same gate decision as the jq path. Use enforce+no-plan: the
  # stderr must carry the correct repo-relative target in BOTH runs.
  local dir
  dir=$(make_fixture_repo)
  local cwd; cwd=$(cd "$dir" && pwd -P)

  # Run 1: normal (jq available).
  local out1 err1 rc1
  out1=$(mktemp); err1=$(mktemp)
  make_stdin "$dir/signals/x.py" "$cwd" \
    | ( cd "$dir" && V3_EDIT_PLAN_GATE=enforce bash "$GUARD" ) >"$out1" 2>"$err1"
  rc1=$?

  # Run 2: jq masked. Build a tmp bin with only non-jq tools the guard needs.
  local jqbin; jqbin=$(mktemp -d)
  local t
  for t in bash sh cat awk sed dirname basename pwd git grep env mktemp rm printf; do
    local p; p=$(command -v "$t" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$jqbin/$t"
  done
  # sanity: jq must NOT be resolvable under this PATH
  local out2 err2 rc2
  out2=$(mktemp); err2=$(mktemp)
  make_stdin "$dir/signals/x.py" "$cwd" \
    | ( cd "$dir" && PATH="$jqbin" V3_EDIT_PLAN_GATE=enforce bash "$GUARD" ) >"$out2" 2>"$err2"
  rc2=$?

  if PATH="$jqbin" command -v jq >/dev/null 2>&1; then
    fail "jq mask ineffective: jq still resolvable under masked PATH"
  fi
  assert_eq "$rc1" "$rc2" "exit code parity (jq vs no-jq)"
  assert_eq 2 "$rc2" "no-jq still blocks"
  assert_contains "$(cat "$err2")" "signals/x.py" "no-jq stderr carries correct target"
  assert_eq "$(cat "$err1")" "$(cat "$err2")" "stderr parity (jq vs no-jq)"

  rm -f "$out1" "$err1" "$out2" "$err2"; rm -rf "$dir" "$jqbin"
}

# run_guard_raw_cwd <dir> <mode> <abs_file_path> <raw_cwd> -> sets RC/OUT/ERR
# Feeds raw_cwd verbatim in stdin (may be a symlink path) and runs the guard
# from raw_cwd, forcing the guard to canonicalize it itself.
run_guard_raw_cwd() {
  local dir="$1" mode="$2" fp="$3" raw_cwd="$4"
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  make_stdin "$fp" "$raw_cwd" \
    | ( cd "$raw_cwd" && V3_EDIT_PLAN_GATE="$mode" bash "$GUARD" ) >"$out_f" 2>"$err_f"
  RC=$?; OUT=$(cat "$out_f"); ERR=$(cat "$err_f"); rm -f "$out_f" "$err_f"
}

test_marker_root_worktree_consistency_symlink_match() {
  # case (1) TRUE MATCH via macOS /var -> /private/var symlink.
  # marker line2 = canonical root; cwd fed as the RAW symlink path. The guard
  # canonicalizes cwd, so root matches -> NOT degraded -> normal plan judgment.
  # Plan is Draft (unapproved) -> enforce blocks BECAUSE of the plan, and stderr
  # must name the active plan + its Draft status (proof it went through plan path,
  # not the degraded "no marker" path).
  local dir
  dir=$(make_fixture_repo)          # $dir is a /var symlink path on macOS
  write_plan_status "$dir" Draft
  set_marker "$dir" "plans/foo.md"  # line2 = canonical /private/var root
  # feed RAW symlink cwd and RAW symlink file_path
  run_guard_raw_cwd "$dir" enforce "$dir/signals/x.py" "$dir"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "plans/foo.md" "stderr names active plan (not degraded)"
  assert_contains "$ERR" "Draft" "stderr shows Draft status (went through plan path)"
  rm -rf "$dir"
}

test_marker_root_worktree_consistency_root_mismatch_degrades() {
  # case (2) TRUE MISMATCH: marker line2 points elsewhere -> get_active_plan
  # returns 1 -> degraded to "no active plan" -> enforce blocks with (none)/(no marker).
  local dir other
  dir=$(make_fixture_repo)
  other=$(mktemp -d)   # an unrelated existing dir
  write_plan_status "$dir" Approved   # even Approved must be ignored on mismatch
  set_marker "$dir" "plans/foo.md" "$(cd "$other" && pwd -P)"
  run_guard "$dir" enforce "$dir/signals/x.py"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "active plan: (none)" "degraded: no active plan"
  assert_contains "$ERR" "(no marker)" "degraded: no status"
  rm -rf "$dir" "$other"
}

test_workflow_surface_md_and_docs_pass() {
  # Remaining workflow surfaces (docs/ tasks/ .ai/ .claude/ prefix, *.md suffix
  # outside plans/) must all pass silently under enforce + no plan.
  local dir t fp
  dir=$(make_fixture_repo)
  mkdir -p "$dir/docs" "$dir/tasks" "$dir/.claude"
  : > "$dir/docs/spec.md"
  : > "$dir/tasks/current.md"
  : > "$dir/.ai/harness/notes.txt"
  : > "$dir/.claude/settings.json"
  : > "$dir/README.md"        # *.md at repo root (suffix rule)
  for t in docs/spec.md tasks/current.md .ai/harness/notes.txt .claude/settings.json README.md; do
    run_guard "$dir" enforce "$dir/$t"
    assert_eq 0 "$RC" "exit code for $t"
    assert_eq "" "$OUT" "stdout empty for $t"
    assert_eq "" "$ERR" "stderr empty for $t"
  done
  rm -rf "$dir"
}

# --- driver ------------------------------------------------------------------

TESTS="
test_contract_allows_path_prefix_hit
test_contract_allows_path_prefix_miss
test_contract_allows_path_glob_hit_tests
test_contract_allows_path_glob_hit_config
test_enforce_no_active_plan_edit_impl_blocks_exit2_stderr
test_enforce_approved_edit_impl_passes_silent
test_enforce_draft_edit_impl_blocks
test_enforce_annotating_edit_impl_blocks
test_enforce_no_plan_edit_plan_surface_passes
test_advice_no_plan_edit_impl_warns_exit0
test_off_no_plan_edit_impl_silent
test_missing_file_path_in_stdin_passes
test_abs_path_outside_repo_passes
test_repo_internal_new_file_in_new_dir_gated
test_file_path_extracted_without_jq_matches_jq
test_marker_root_worktree_consistency_symlink_match
test_marker_root_worktree_consistency_root_mismatch_degrades
test_workflow_surface_md_and_docs_pass
"

for t in $TESTS; do
  CUR_TEST="$t"
  before=$FAIL_COUNT
  "$t"
  if [ "$FAIL_COUNT" -eq "$before" ]; then
    printf 'PASS  %s\n' "$t"
  else
    printf 'FAIL  %s\n' "$t"
  fi
done

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '\n%d failing assertion(s)\n' "$FAIL_COUNT" >&2
  exit 1
fi
printf '\nall green\n'
exit 0
