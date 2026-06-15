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

# --- driver ------------------------------------------------------------------

TESTS="
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
