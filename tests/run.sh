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

test_contract_allows_path_no_yaml_block_returns_1() {
  # A plan with NO ```yaml allowed_paths block => contract not enabled =>
  # contract_allows_path returns 1 (lib-level basis of the opt-in no-op).
  local dir contract
  dir=$(mktemp -d)
  contract="$dir/plan.md"
  printf '# plain plan\n\n**Status**: Approved\n\nNo yaml here.\n' > "$contract"
  if ( . "$REPO/hooks/lib/workflow-state.sh"; contract_allows_path "$contract" "signals/vix.py" ); then
    fail "no yaml block must return 1 (got 0)"
  fi
  rm -rf "$dir"
}

test_contract_allows_path_prefix_not_treated_as_glob() {
  # Discriminator: `signals/` is a PREFIX item. A deep path under it must match.
  # If a mutant treated it as a glob (case in signals/), `signals/sub/deep.py`
  # would NOT match. This kills that mutant.
  local dir contract
  dir=$(mktemp -d)
  contract="$dir/plan.md"
  write_investsys_contract "$contract"
  ( . "$REPO/hooks/lib/workflow-state.sh"; contract_allows_path "$contract" "signals/sub/deep.py" )
  assert_eq 0 "$?" "deep path under signals/ matches via prefix rule"
  rm -rf "$dir"
}

test_contract_allows_path_glob_not_treated_as_prefix() {
  # Discriminator: `config/*.yaml` is a GLOB item (anchored at end by `.yaml`).
  # `config/foo.yaml.bak` must NOT match (glob requires the path to end .yaml).
  # If a mutant treated it as a prefix (case in "config/*.yaml"*), it would also
  # fail differently; but the sharp signal is: a real glob anchors the tail, so a
  # trailing-extra path is rejected. This kills "glob misused as prefix".
  local dir contract
  dir=$(mktemp -d)
  contract="$dir/plan.md"
  write_investsys_contract "$contract"
  if ( . "$REPO/hooks/lib/workflow-state.sh"; contract_allows_path "$contract" "config/foo.yaml.bak" ); then
    fail "config/foo.yaml.bak must NOT match config/*.yaml glob (tail not anchored)"
  fi
  rm -rf "$dir"
}

# set_contract_plan <dir>
#   Writes plans/foo.md as an APPROVED plan embedding the Q7 InvestSys contract,
#   and points the active-plan marker at it. After this, PlanStatusGuard passes
#   (Approved) and ContractScopeGuard becomes active (yaml block present).
set_contract_plan() {
  local dir="$1"
  write_investsys_contract "$dir/plans/foo.md"
  set_marker "$dir" "plans/foo.md"
}

test_contractscope_enforce_out_of_scope_blocks_exit2_stderr() {
  # Approved plan WITH allowed_paths, edit deploy/secrets.env (deploy/ not in
  # the contract) -> ContractScopeGuard blocks: exit 2 + [ContractScopeGuard]
  # on stderr. PlanStatusGuard already passes (Approved), so this proves the
  # second guard in the chain.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/deploy"; : > "$dir/deploy/secrets.env"
  set_contract_plan "$dir"
  run_guard "$dir" enforce "$dir/deploy/secrets.env"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "[ContractScopeGuard]" "stderr has ContractScopeGuard name"
  assert_contains "$ERR" "NOT a user rejection" "stderr has anti-misfire wording"
  assert_contains "$ERR" "deploy/secrets.env" "stderr names blocked target"
  assert_not_contains "$OUT" "ContractScopeGuard" "stdout must not carry blocking msg"
  rm -rf "$dir"
}

test_contractscope_enforce_in_scope_prefix_passes_silent() {
  # Approved + contract + edit signals/vix.py (under signals/ prefix) -> allow.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/signals"; : > "$dir/signals/vix.py"
  set_contract_plan "$dir"
  run_guard "$dir" enforce "$dir/signals/vix.py"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_contractscope_enforce_in_scope_glob_passes_silent() {
  # Approved + contract + edit tests/test_vix.py (tests/test_*.py glob) -> allow.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/tests"; : > "$dir/tests/test_vix.py"
  set_contract_plan "$dir"
  run_guard "$dir" enforce "$dir/tests/test_vix.py"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_contractscope_enforce_in_scope_config_glob_passes_silent() {
  # Approved + contract + edit config/foo.yaml (config/*.yaml glob) -> allow.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/config"; : > "$dir/config/foo.yaml"
  set_contract_plan "$dir"
  run_guard "$dir" enforce "$dir/config/foo.yaml"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_contractscope_enforce_reporoot_file_blocks() {
  # portfolio.yaml at repo root: matches no prefix and no glob -> blocked.
  local dir
  dir=$(make_fixture_repo)
  : > "$dir/portfolio.yaml"
  set_contract_plan "$dir"
  run_guard "$dir" enforce "$dir/portfolio.yaml"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "[ContractScopeGuard]" "stderr has guard name"
  assert_contains "$ERR" "portfolio.yaml" "stderr names blocked target"
  rm -rf "$dir"
}

test_contractscope_enforce_web_dir_blocks() {
  # web/app.js: web/ not in contract -> blocked.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/web"; : > "$dir/web/app.js"
  set_contract_plan "$dir"
  run_guard "$dir" enforce "$dir/web/app.js"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "[ContractScopeGuard]" "stderr has guard name"
  assert_contains "$ERR" "web/app.js" "stderr names blocked target"
  rm -rf "$dir"
}

test_contractscope_noop_approved_no_yaml_block_passes() {
  # Approved plan WITHOUT a yaml allowed_paths block -> ContractScopeGuard is a
  # no-op (opt-in OFF) -> edit any impl file is allowed silently.
  local dir
  dir=$(make_fixture_repo)
  write_plan_status "$dir" Approved   # plain plan, NO yaml block
  set_marker "$dir" "plans/foo.md"
  run_guard "$dir" enforce "$dir/deploy/secrets.env"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty (no-op opt-in)"
  assert_eq "" "$ERR" "stderr empty (no-op opt-in)"
  rm -rf "$dir"
}

test_contractscope_advice_out_of_scope_warns_exit0() {
  # advice mode + out-of-scope edit -> exit 0, warning on stdout, stderr empty.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/deploy"; : > "$dir/deploy/secrets.env"
  set_contract_plan "$dir"
  run_guard "$dir" advice "$dir/deploy/secrets.env"
  assert_eq 0 "$RC" "exit code"
  assert_contains "$OUT" "ContractScopeGuard" "stdout has advice warning"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_contractscope_off_out_of_scope_silent() {
  # off mode + out-of-scope edit -> exit 0, fully silent.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/deploy"; : > "$dir/deploy/secrets.env"
  set_contract_plan "$dir"
  run_guard "$dir" off "$dir/deploy/secrets.env"
  assert_eq 0 "$RC" "exit code"
  assert_eq "" "$OUT" "stdout empty"
  assert_eq "" "$ERR" "stderr empty"
  rm -rf "$dir"
}

test_chain_order_draft_out_of_scope_blocked_by_planstatus_not_contract() {
  # Chain order proof: plan is Draft (unapproved) AND target is out of contract
  # scope. PlanStatusGuard must fire FIRST -> stderr says [PlanStatusGuard],
  # NOT [ContractScopeGuard]. ContractScopeGuard never runs on unapproved plans.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/deploy"; : > "$dir/deploy/secrets.env"
  # contract plan but Draft status
  write_investsys_contract "$dir/plans/foo.md"
  # overwrite status to Draft (contract block stays)
  sed 's/\*\*Status\*\*: Approved/**Status**: Draft/' "$dir/plans/foo.md" > "$dir/plans/foo.tmp" \
    && mv "$dir/plans/foo.tmp" "$dir/plans/foo.md"
  set_marker "$dir" "plans/foo.md"
  run_guard "$dir" enforce "$dir/deploy/secrets.env"
  assert_eq 2 "$RC" "exit code"
  assert_contains "$ERR" "[PlanStatusGuard]" "PlanStatusGuard fires first"
  assert_not_contains "$ERR" "[ContractScopeGuard]" "ContractScopeGuard must NOT run on unapproved plan"
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

# --- Slice 3 helpers: write-handoff / stop-orchestrator ----------------------

HANDOFF_LIB="$REPO/hooks/lib/write-handoff.sh"
STOP_HOOK="$REPO/hooks/stop-orchestrator.sh"

# call_write_handoff <dir> <reason>
#   Sources the handoff lib INSIDE <dir> and calls write_handoff <reason>.
#   Captures RC; resume.md ends up at <dir>/.ai/harness/handoff/resume.md.
call_write_handoff() {
  local dir="$1" reason="$2"
  ( cd "$dir" && . "$HANDOFF_LIB" && write_handoff "$reason" )
  RC=$?
}

# resume_path <dir> -> echoes the resume.md path for that fixture repo.
resume_path() {
  printf '%s' "$1/.ai/harness/handoff/resume.md"
}

# Independently recompute the expected changed-files set the SAME way the spec
# mandates: (git diff --name-only HEAD) UNION (git ls-files --others
# --exclude-standard), de-duplicated and sorted. Echoes one path per line.
expected_changed_set() {
  local dir="$1"
  ( cd "$dir" && {
      git diff --name-only HEAD 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u )
}

# extract_changed_block <resume_file>
#   Echoes the lines between the "## Changed files" marker and the next "##"
#   header (exclusive), keeping only the actual file entries (lines starting
#   with "- "), with the "- " stripped. Used for the reproducibility lock.
extract_changed_block() {
  awk '
    /^## Changed files/ { inblk=1; next }
    inblk && /^## / { inblk=0 }
    inblk && /^- / { sub(/^- /,""); print }
  ' "$1"
}

# --- Slice 3 D3 tests: write_handoff -----------------------------------------

test_handoff_writes_active_plan_and_status() {
  # With an Approved active plan, resume.md must record the active plan path and
  # its status (both git/file-derived, no model text).
  local dir
  dir=$(make_fixture_repo)
  write_plan_status "$dir" Approved
  set_marker "$dir" "plans/foo.md"
  call_write_handoff "$dir" "session-stop"
  assert_eq 0 "$RC" "write_handoff return code"
  local rf content
  rf=$(resume_path "$dir")
  content=$(cat "$rf" 2>/dev/null)
  assert_contains "$content" "plans/foo.md" "resume.md names the active plan"
  assert_contains "$content" "Approved" "resume.md records the plan status"
  rm -rf "$dir"
}

test_handoff_changed_files_union_dedup_sorted() {
  # changed files = (git diff --name-only HEAD) U (git ls-files --others
  # --exclude-standard), de-duplicated + sorted. Construct a repo with one
  # COMMITTED-then-MODIFIED tracked file (shows in diff) and one UNTRACKED new
  # file (shows in ls-files --others). The block must contain BOTH, sorted, no
  # dups. We deliberately create a tracked file that is ALSO listed nowhere else
  # to ensure union, not just one source.
  local dir
  dir=$(make_fixture_repo)
  # commit an initial tracked file so HEAD exists and diff is meaningful.
  printf 'orig\n' > "$dir/signals/x.py"
  ( cd "$dir" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
  # modify the tracked file (-> git diff --name-only HEAD shows signals/x.py)
  printf 'changed\n' > "$dir/signals/x.py"
  # add an untracked new file (-> git ls-files --others shows signals/a_new.py)
  printf 'new\n' > "$dir/signals/a_new.py"
  call_write_handoff "$dir" "session-stop"
  assert_eq 0 "$RC" "write_handoff return code"
  local rf block
  rf=$(resume_path "$dir")
  block=$(extract_changed_block "$rf")
  assert_contains "$block" "signals/x.py" "changed block has the tracked-modified file"
  assert_contains "$block" "signals/a_new.py" "changed block has the untracked file"
  # sorted: a_new.py must come before x.py
  local first
  first=$(printf '%s\n' "$block" | head -1)
  assert_eq "signals/a_new.py" "$first" "changed block is sorted (a_new before x)"
  rm -rf "$dir"
}

test_handoff_changed_files_truncated_past_80() {
  # With > 80 changed files, the listing is truncated to 80 entries and a
  # truncation marker carrying the TOTAL count is emitted. We create 90 untracked
  # files; the block must list exactly 80 file entries and a "(truncated" marker
  # naming 90 as the total.
  local dir i
  dir=$(make_fixture_repo)
  mkdir -p "$dir/many"
  i=0
  while [ "$i" -lt 90 ]; do
    printf 'x\n' > "$dir/many/f$(printf '%03d' "$i").txt"
    i=$((i + 1))
  done
  # the true total is whatever the spec's union set is (fixture also leaves
  # signals/x.py untracked) -> compute it independently so the marker assertion
  # is reproducible, not a guessed constant.
  local expected_total
  expected_total=$(expected_changed_set "$dir" | grep -c .)
  call_write_handoff "$dir" "session-stop"
  assert_eq 0 "$RC" "write_handoff return code"
  local rf block listed
  rf=$(resume_path "$dir")
  block=$(extract_changed_block "$rf")
  # extract_changed_block keeps only "- " file lines; the truncation marker is
  # NOT a "- " line, so count of file entries must be exactly 80.
  listed=$(printf '%s\n' "$block" | grep -c .)
  assert_eq 80 "$listed" "exactly 80 file entries listed (truncated)"
  # truncation marker with the real total must be present in the file.
  local content
  content=$(cat "$rf")
  assert_contains "$content" "truncated" "resume.md has a truncation marker"
  assert_contains "$content" "$expected_total total" "truncation marker names the total count"
  rm -rf "$dir"
}

test_handoff_shortstat_line_from_git() {
  # The resume.md must carry the `git diff --shortstat HEAD` line, verbatim from
  # git. Commit a file, then modify it; git reports "N file(s) changed, M
  # insertions(+)...". Assert the resume.md contains the SAME shortstat text git
  # produces independently (proves it's git-derived, not fabricated).
  local dir
  dir=$(make_fixture_repo)
  printf 'a\nb\nc\n' > "$dir/signals/x.py"
  ( cd "$dir" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
  printf 'a\nb\nc\nd\ne\n' > "$dir/signals/x.py"   # +2 lines
  local expected_shortstat
  expected_shortstat=$( cd "$dir" && git diff --shortstat HEAD | sed 's/^[ \t]*//' )
  call_write_handoff "$dir" "session-stop"
  assert_eq 0 "$RC" "write_handoff return code"
  local content
  content=$(cat "$(resume_path "$dir")")
  # sanity: git actually produced a non-empty shortstat for this fixture.
  if [ -z "$expected_shortstat" ]; then
    fail "fixture produced empty shortstat (test setup bug)"
  fi
  assert_contains "$content" "$expected_shortstat" "resume.md carries git's shortstat verbatim"
  rm -rf "$dir"
}

test_handoff_records_time_and_reason() {
  # WITNESS: the generation time (UTC ISO8601) and the caller-supplied reason
  # must both appear. Time format asserted structurally (YYYY-MM-DDThh:mm:ssZ).
  local dir
  dir=$(make_fixture_repo)
  call_write_handoff "$dir" "my-custom-reason"
  assert_eq 0 "$RC" "write_handoff return code"
  local content
  content=$(cat "$(resume_path "$dir")")
  assert_contains "$content" "my-custom-reason" "resume.md records the reason"
  # ISO8601 UTC shape check via grep -E (structural, not a fixed timestamp).
  if ! printf '%s\n' "$content" | grep -Eq 'generated: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'; then
    fail "resume.md must carry a UTC ISO8601 generated timestamp"
  fi
  rm -rf "$dir"
}

test_handoff_non_git_repo_degrades() {
  # In a NON-git directory, write_handoff must degrade: write ONLY time + reason,
  # NOT call git in a way that leaks errors, and NOT emit git-derived sections.
  # We run it in a plain mktemp dir (no git init) and capture stderr to prove no
  # git error text leaks.
  local dir
  dir=$(mktemp -d)   # NOT a git repo
  local err_f
  err_f=$(mktemp)
  ( cd "$dir" && . "$HANDOFF_LIB" && write_handoff "stop-no-git" ) 2>"$err_f"
  RC=$?
  local err content
  err=$(cat "$err_f"); rm -f "$err_f"
  assert_eq 0 "$RC" "write_handoff return code (non-git)"
  content=$(cat "$(resume_path "$dir")" 2>/dev/null)
  # time + reason present
  assert_contains "$content" "stop-no-git" "non-git resume.md has the reason"
  if ! printf '%s\n' "$content" | grep -Eq 'generated: [0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    fail "non-git resume.md must still carry a timestamp"
  fi
  # NO git-derived sections (changed files / diff stat headers must be absent).
  assert_not_contains "$content" "## Changed files" "non-git: no changed-files section"
  assert_not_contains "$content" "## Diff stat" "non-git: no diff-stat section"
  # NO git error text leaked to stderr.
  assert_not_contains "$err" "not a git repository" "non-git: no git error leaked"
  assert_not_contains "$err" "fatal:" "non-git: no fatal git error leaked"
  rm -rf "$dir"
}

test_handoff_changed_block_reproducible_lock() {
  # REPRODUCIBILITY LOCK: the changed-files block in resume.md, line by line,
  # must EQUAL the set computed independently as
  #   (git diff --name-only HEAD) U (git ls-files --others --exclude-standard)
  # de-duplicated + sorted. Exact string equality proves zero model-generated
  # content. Mix tracked-modified + untracked + a duplicate-source path to make
  # the union/dedup observable. Stay <=80 so nothing is truncated.
  local dir
  dir=$(make_fixture_repo)
  # commit two tracked files, then modify one (-> diff) and stage-delete none.
  printf 'a\n' > "$dir/signals/x.py"
  mkdir -p "$dir/detectors"; printf 'b\n' > "$dir/detectors/d.py"
  ( cd "$dir" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init )
  printf 'a2\n' > "$dir/signals/x.py"          # tracked-modified
  printf 'n\n'  > "$dir/scanners_new.py"        # untracked (repo root)
  mkdir -p "$dir/notifiers"; printf 'm\n' > "$dir/notifiers/n.py"  # untracked nested
  # independent expected set (the spec's exact recipe)
  local expected
  expected=$(expected_changed_set "$dir")
  call_write_handoff "$dir" "session-stop"
  assert_eq 0 "$RC" "write_handoff return code"
  local actual
  actual=$(extract_changed_block "$(resume_path "$dir")")
  # exact, line-by-line equality (the lock).
  assert_eq "$expected" "$actual" "changed block == independently-computed git union set (line-by-line)"
  rm -rf "$dir"
}

# --- Slice 3 D4 tests: stop-orchestrator hook --------------------------------

test_stop_hook_writes_resume_and_exits_0() {
  # The Stop hook unconditionally refreshes resume.md (reason "session-stop")
  # and exits 0 (a Stop hook must never block). Run it from inside a fixture
  # repo; assert exit 0 and that resume.md exists with the session-stop reason.
  local dir
  dir=$(make_fixture_repo)
  write_plan_status "$dir" Draft
  set_marker "$dir" "plans/foo.md"
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  # Stop hooks receive a JSON stdin payload; feed a minimal one.
  printf '{"hook_event_name":"Stop","session_id":"t"}' \
    | ( cd "$dir" && bash "$STOP_HOOK" ) >"$out_f" 2>"$err_f"
  RC=$?
  OUT=$(cat "$out_f"); ERR=$(cat "$err_f"); rm -f "$out_f" "$err_f"
  assert_eq 0 "$RC" "stop hook exits 0"
  local rf content
  rf=$(resume_path "$dir")
  if [ ! -f "$rf" ]; then
    fail "stop hook must generate resume.md"
  fi
  content=$(cat "$rf" 2>/dev/null)
  assert_contains "$content" "session-stop" "stop hook writes reason session-stop"
  assert_contains "$content" "plans/foo.md" "stop hook handoff carries active plan"
  rm -rf "$dir"
}

test_handoff_idempotent_overwrite() {
  # WITNESS: calling write_handoff twice must OVERWRITE (not append). The header
  # "# Session handoff" must appear exactly once after two calls.
  local dir
  dir=$(make_fixture_repo)
  call_write_handoff "$dir" "first"
  call_write_handoff "$dir" "second"
  assert_eq 0 "$RC" "second write_handoff return code"
  local rf headers content
  rf=$(resume_path "$dir")
  headers=$(grep -c '^# Session handoff' "$rf")
  assert_eq 1 "$headers" "header appears exactly once (overwrite, not append)"
  content=$(cat "$rf")
  assert_contains "$content" "second" "latest reason present"
  assert_not_contains "$content" "first" "stale reason overwritten"
  rm -rf "$dir"
}

# --- Slice 4 helpers: session-start-context --------------------------------

SESSION_START_HOOK="$REPO/hooks/session-start-context.sh"

# run_session_start <dir>  -> sets RC / OUT / ERR globals.
#   Runs the SessionStart hook INSIDE <dir> with an empty SessionStart JSON on
#   stdin (the hook reads files, not stdin content). Captures exit/stdout/stderr.
run_session_start() {
  local dir="$1"
  local out_f err_f
  out_f=$(mktemp)
  err_f=$(mktemp)
  printf '{"hook_event_name":"SessionStart","source":"startup"}' \
    | ( cd "$dir" && bash "$SESSION_START_HOOK" ) >"$out_f" 2>"$err_f"
  RC=$?
  OUT=$(cat "$out_f")
  ERR=$(cat "$err_f")
  rm -f "$out_f" "$err_f"
}

# write_resume <dir> <body>  -> writes .ai/harness/handoff/resume.md
write_resume() {
  local dir="$1" body="$2"
  mkdir -p "$dir/.ai/harness/handoff"
  printf '%s\n' "$body" > "$dir/.ai/harness/handoff/resume.md"
}

# write_current_task <dir> <body>  -> writes tasks/current.md
write_current_task() {
  local dir="$1" body="$2"
  mkdir -p "$dir/tasks"
  printf '%s\n' "$body" > "$dir/tasks/current.md"
}

# --- Slice 4 D5 tests: session-start-context.sh ------------------------------

test_session_start_resume_content_wrapped_in_disclaimer() {
  # SOUL of this slice. When resume.md exists, its content must appear on stdout
  # AND be preceded by the recovery-context-only / current-input-priority
  # disclaimer. exit 0.
  local dir
  dir=$(make_fixture_repo)
  write_resume "$dir" "UNIQUE_RESUME_MARKER_42 active plan: plans/foo.md"
  run_session_start "$dir"
  assert_eq 0 "$RC" "session-start exits 0"
  # disclaimer substrings (the soul):
  assert_contains "$OUT" "recovery context only" "stdout carries recovery-context-only disclaimer"
  assert_contains "$OUT" "user" "disclaimer mentions user input"
  assert_contains "$OUT" "priority" "disclaimer states current input takes priority"
  # resume content actually injected:
  assert_contains "$OUT" "UNIQUE_RESUME_MARKER_42" "resume.md content appears on stdout"
  # disclaimer comes BEFORE the resume content (wraps it):
  local pre
  pre=${OUT%%UNIQUE_RESUME_MARKER_42*}
  assert_contains "$pre" "recovery context only" "disclaimer precedes the resume content"
  rm -rf "$dir"
}

test_session_start_includes_current_task_when_present() {
  # When tasks/current.md exists, its content must be included in the injected
  # context too. exit 0.
  local dir
  dir=$(make_fixture_repo)
  write_resume "$dir" "RESUME_BODY_X"
  write_current_task "$dir" "CURRENT_TASK_MARKER_99 ship slice 4"
  run_session_start "$dir"
  assert_eq 0 "$RC" "session-start exits 0"
  assert_contains "$OUT" "CURRENT_TASK_MARKER_99" "tasks/current.md content is injected"
  rm -rf "$dir"
}

test_session_start_no_resume_degrades_gracefully() {
  # WITNESS-candidate: when resume.md does NOT exist, the hook must still exit 0,
  # not crash, and leak NO error text to stderr.
  local dir
  dir=$(make_fixture_repo)
  # deliberately do NOT create resume.md
  run_session_start "$dir"
  assert_eq 0 "$RC" "session-start exits 0 even without resume.md"
  assert_eq "" "$ERR" "no error leaked to stderr when resume.md absent"
  rm -rf "$dir"
}

test_session_start_no_files_at_all_exits_0() {
  # WITNESS-candidate: extreme case — neither resume.md nor tasks/current.md nor
  # even the .ai/harness tree exists. Must still exit 0, stderr clean.
  local dir
  dir=$(mktemp -d)
  # bare dir, no git, no .ai, no tasks
  run_session_start "$dir"
  assert_eq 0 "$RC" "session-start exits 0 with no files present"
  assert_eq "" "$ERR" "no error leaked to stderr with no files present"
  rm -rf "$dir"
}

# --- driver ------------------------------------------------------------------

TESTS="
test_handoff_writes_active_plan_and_status
test_handoff_changed_files_union_dedup_sorted
test_handoff_changed_files_truncated_past_80
test_handoff_shortstat_line_from_git
test_handoff_records_time_and_reason
test_handoff_non_git_repo_degrades
test_handoff_changed_block_reproducible_lock
test_stop_hook_writes_resume_and_exits_0
test_handoff_idempotent_overwrite
test_contract_allows_path_prefix_hit
test_contract_allows_path_prefix_miss
test_contract_allows_path_glob_hit_tests
test_contract_allows_path_glob_hit_config
test_contract_allows_path_no_yaml_block_returns_1
test_contract_allows_path_prefix_not_treated_as_glob
test_contract_allows_path_glob_not_treated_as_prefix
test_contractscope_enforce_out_of_scope_blocks_exit2_stderr
test_contractscope_enforce_in_scope_prefix_passes_silent
test_contractscope_enforce_in_scope_glob_passes_silent
test_contractscope_enforce_in_scope_config_glob_passes_silent
test_contractscope_enforce_reporoot_file_blocks
test_contractscope_enforce_web_dir_blocks
test_contractscope_noop_approved_no_yaml_block_passes
test_contractscope_advice_out_of_scope_warns_exit0
test_contractscope_off_out_of_scope_silent
test_chain_order_draft_out_of_scope_blocked_by_planstatus_not_contract
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
test_session_start_resume_content_wrapped_in_disclaimer
test_session_start_includes_current_task_when_present
test_session_start_no_resume_degrades_gracefully
test_session_start_no_files_at_all_exits_0
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
