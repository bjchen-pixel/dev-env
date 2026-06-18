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

  if PATH="$jqbin" bash -c 'command -v jq >/dev/null 2>&1'; then
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

test_session_start_disclaimer_present_when_only_current_task() {
  # The disclaimer is the SOUL: any injected stale state must be framed by the
  # recovery-context-only / current-input-priority disclaimer. Even when ONLY
  # tasks/current.md exists (no resume.md), the disclaimer must still precede the
  # injected task content so it never silently overrides the current task.
  local dir
  dir=$(make_fixture_repo)
  # no resume.md; only current task
  write_current_task "$dir" "ONLY_TASK_MARKER_77"
  run_session_start "$dir"
  assert_eq 0 "$RC" "session-start exits 0"
  assert_contains "$OUT" "ONLY_TASK_MARKER_77" "task content injected"
  assert_contains "$OUT" "recovery context only" "disclaimer present with only current task"
  assert_contains "$OUT" "priority" "current-input-priority stated with only current task"
  local pre
  pre=${OUT%%ONLY_TASK_MARKER_77*}
  assert_contains "$pre" "recovery context only" "disclaimer precedes the task content"
  rm -rf "$dir"
}

test_session_start_disclaimer_soul_substrings_locked() {
  # DEDICATED SOUL LOCK (binding spec #2): assert every load-bearing phrase of
  # the disclaimer actually appears on stdout. This is the slice's soul; if any
  # of these regress, the injected state could silently override the user's task.
  local dir
  dir=$(make_fixture_repo)
  write_resume "$dir" "SOUL_RESUME"
  run_session_start "$dir"
  assert_eq 0 "$RC" "session-start exits 0"
  assert_contains "$OUT" "recovery context only" "lock: 'recovery context only'"
  assert_contains "$OUT" "real attachment, file path" "lock: names real attachment / file path"
  assert_contains "$OUT" "give priority to the user" "lock: current input takes priority"
  assert_contains "$OUT" "override the current task" "lock: must not override the current task"
  rm -rf "$dir"
}

test_settings_wires_session_start_and_preserves_pretooluse_stop() {
  # The project settings.json must register a SessionStart hook pointing at
  # session-start-context.sh, WITHOUT disturbing the existing PreToolUse / Stop
  # entries from earlier slices.
  local settings content
  settings="$REPO/.claude/settings.json"
  content=$(cat "$settings" 2>/dev/null)
  assert_contains "$content" "SessionStart" "settings registers SessionStart"
  assert_contains "$content" "session-start-context.sh" "SessionStart points at the hook script"
  # earlier slices must remain wired:
  assert_contains "$content" "PreToolUse" "PreToolUse entry preserved"
  assert_contains "$content" "pre-edit-guard.sh" "pre-edit-guard wiring preserved"
  assert_contains "$content" "Stop" "Stop entry preserved"
  assert_contains "$content" "stop-orchestrator.sh" "stop-orchestrator wiring preserved"
}

# --- Slice 5 helpers: policy_get ---------------------------------------------

# write_policy <dir> <edit_plan_gate_value>
#   Writes .ai/harness/policy.json with guards.edit_plan_gate set to the value.
write_policy() {
  local dir="$1" val="$2"
  mkdir -p "$dir/.ai/harness"
  cat > "$dir/.ai/harness/policy.json" <<EOF
{
  "guards": {
    "edit_plan_gate": "$val"
  }
}
EOF
}

# --- Slice 5 D1 tests: policy_get --------------------------------------------

test_policy_get_jq_reads_existing_key() {
  # policy.json has guards.edit_plan_gate = "enforce". policy_get must return
  # that value (jq primary path), NOT the default.
  local dir val
  dir=$(make_fixture_repo)
  write_policy "$dir" "enforce"
  val=$( cd "$dir" && . "$REPO/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "advice" )
  assert_eq "enforce" "$val" "policy_get returns the stored value via jq"
  rm -rf "$dir"
}

test_policy_get_jq_missing_key_returns_default() {
  # policy.json exists but does NOT contain the requested key path -> default.
  local dir val
  dir=$(make_fixture_repo)
  mkdir -p "$dir/.ai/harness"
  printf '{"guards":{"other_gate":"enforce"}}\n' > "$dir/.ai/harness/policy.json"
  val=$( cd "$dir" && . "$REPO/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "advice" )
  assert_eq "advice" "$val" "missing key path -> default"
  rm -rf "$dir"
}

test_policy_get_no_file_returns_default() {
  # No policy.json at all -> default (fail-soft, must not crash).
  local dir val
  dir=$(make_fixture_repo)
  # deliberately do NOT create .ai/harness/policy.json
  val=$( cd "$dir" && . "$REPO/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "advice" )
  assert_eq "advice" "$val" "no policy.json -> default"
  rm -rf "$dir"
}

test_policy_get_awk_fallback_matches_jq() {
  # PARITY: with jq MASKED (PATH stripped of jq), the awk fallback must extract
  # the SAME value as the jq path for the flat two-level target
  # guards.edit_plan_gate. Run both ways and assert equal AND assert the masked
  # PATH truly cannot resolve jq (so the fallback is genuinely exercised).
  local dir
  dir=$(make_fixture_repo)
  write_policy "$dir" "enforce"

  # jq path value
  local jq_val
  jq_val=$( cd "$dir" && . "$REPO/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "advice" )

  # build a tmp bin WITHOUT jq, containing only the tools the lib needs.
  local jqbin t p
  jqbin=$(mktemp -d)
  for t in bash sh cat awk sed grep printf pwd dirname basename env mktemp rm; do
    p=$(command -v "$t" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$jqbin/$t"
  done
  # sanity: jq MUST NOT be resolvable under the masked PATH.
  if PATH="$jqbin" bash -c 'command -v jq >/dev/null 2>&1'; then
    fail "jq mask ineffective: jq still resolvable under masked PATH"
  fi

  local awk_val
  awk_val=$( cd "$dir" && PATH="$jqbin" bash -c '. "'"$REPO"'/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "advice"' )

  assert_eq "enforce" "$jq_val" "jq path reads enforce"
  assert_eq "$jq_val" "$awk_val" "awk fallback value == jq value (parity)"
  rm -rf "$dir" "$jqbin"
}

test_policy_get_awk_fallback_respects_section() {
  # PARITY + DISCRIMINATION: a same-named leaf key under a DIFFERENT section must
  # not be returned for guards.edit_plan_gate. Here `other.edit_plan_gate` = off
  # appears first; the awk fallback must skip it and return guards.edit_plan_gate
  # = enforce — same as jq. Kills a section-agnostic mutant.
  local dir
  dir=$(make_fixture_repo)
  mkdir -p "$dir/.ai/harness"
  cat > "$dir/.ai/harness/policy.json" <<'EOF'
{
  "other": {
    "edit_plan_gate": "off"
  },
  "guards": {
    "edit_plan_gate": "enforce"
  }
}
EOF
  local jq_val
  jq_val=$( cd "$dir" && . "$REPO/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "advice" )
  local jqbin t p
  jqbin=$(mktemp -d)
  for t in bash sh cat awk sed grep printf pwd dirname basename env mktemp rm; do
    p=$(command -v "$t" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$jqbin/$t"
  done
  if PATH="$jqbin" bash -c 'command -v jq >/dev/null 2>&1'; then
    fail "jq mask ineffective: jq still resolvable under masked PATH"
  fi
  local awk_val
  awk_val=$( cd "$dir" && PATH="$jqbin" bash -c '. "'"$REPO"'/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "advice"' )
  assert_eq "enforce" "$jq_val" "jq reads guards.edit_plan_gate (not other.)"
  assert_eq "enforce" "$awk_val" "awk fallback respects section (not other.edit_plan_gate)"
  rm -rf "$dir" "$jqbin"
}

# run_guard_no_env <dir> <abs_file_path>  -> sets RC / OUT / ERR globals.
#   Like run_guard but DOES NOT set V3_EDIT_PLAN_GATE, so the guard must resolve
#   its mode from policy.json (or the built-in advice default). Any inherited
#   V3_EDIT_PLAN_GATE is explicitly unset to isolate the policy path.
run_guard_no_env() {
  local dir="$1" fp="$2"
  local cwd out_f err_f
  cwd=$(cd "$dir" && pwd -P)
  out_f=$(mktemp); err_f=$(mktemp)
  make_stdin "$fp" "$cwd" \
    | ( cd "$dir" && unset V3_EDIT_PLAN_GATE && bash "$GUARD" ) >"$out_f" 2>"$err_f"
  RC=$?; OUT=$(cat "$out_f"); ERR=$(cat "$err_f"); rm -f "$out_f" "$err_f"
}

# --- Slice 5 mode-precedence tests (env > policy > advice default) ------------

test_mode_precedence_env_unset_policy_enforce_blocks() {
  # env V3_EDIT_PLAN_GATE UNSET; policy.json guards.edit_plan_gate = enforce.
  # No active plan + edit impl -> the guard must adopt enforce FROM POLICY and
  # block: exit 2 + stderr.
  local dir
  dir=$(make_fixture_repo)
  write_policy "$dir" "enforce"
  # no marker => unapproved
  run_guard_no_env "$dir" "$dir/signals/x.py"
  assert_eq 2 "$RC" "exit code (policy enforce blocks)"
  assert_contains "$ERR" "PlanStatusGuard" "stderr has guard name (policy-driven enforce)"
  rm -rf "$dir"
}

test_mode_precedence_env_unset_no_policy_defaults_advice() {
  # env UNSET and NO policy.json -> built-in default `advice`: no active plan +
  # edit impl -> exit 0 with a stdout advice warning, stderr empty.
  local dir
  dir=$(make_fixture_repo)
  # no policy.json, no marker
  run_guard_no_env "$dir" "$dir/signals/x.py"
  assert_eq 0 "$RC" "exit code (default advice does not block)"
  assert_contains "$OUT" "PlanStatusGuard" "stdout carries advice warning"
  assert_eq "" "$ERR" "stderr empty under default advice"
  rm -rf "$dir"
}

test_mode_precedence_env_wins_over_policy() {
  # REGRESSION GUARD for the 47 existing tests' assumption: when env
  # V3_EDIT_PLAN_GATE is SET, it overrides policy.json. policy says enforce, but
  # env says off -> must allow silently (env wins).
  local dir
  dir=$(make_fixture_repo)
  write_policy "$dir" "enforce"
  # env off must win over policy enforce -> silent allow.
  run_guard "$dir" off "$dir/signals/x.py"
  assert_eq 0 "$RC" "exit code (env off wins over policy enforce)"
  assert_eq "" "$OUT" "stdout empty (off)"
  assert_eq "" "$ERR" "stderr empty (off)"
  rm -rf "$dir"
}

# --- Slice 5 D6 tests: policy.json template + INSTALL.md ----------------------

test_policy_template_default_is_advice_and_readable_by_policy_get() {
  # The shipped policy.json template must default guards.edit_plan_gate to
  # `advice` (the safest mode) AND be consumable by policy_get itself (round
  # trip through the real reader, not just a string grep).
  local tmpl
  tmpl="$REPO/templates/policy.json"
  if [ ! -f "$tmpl" ]; then
    fail "policy.json template missing at templates/policy.json"
    return
  fi
  # valid JSON (jq parse) when jq is present.
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$tmpl" >/dev/null 2>&1; then
      fail "policy.json template is not valid JSON"
    fi
  fi
  # round-trip through policy_get against a fixture repo seeded with the template.
  local dir val
  dir=$(make_fixture_repo)
  mkdir -p "$dir/.ai/harness"
  cp "$tmpl" "$dir/.ai/harness/policy.json"
  val=$( cd "$dir" && . "$REPO/hooks/lib/workflow-state.sh"; policy_get "guards.edit_plan_gate" "SENTINEL" )
  assert_eq "advice" "$val" "template default guards.edit_plan_gate == advice (via policy_get)"
  rm -rf "$dir"
}

test_install_md_documents_switches_and_killswitch() {
  # INSTALL.md must teach: the two switch surfaces (env + policy.json), the
  # three modes, and at least one kill switch (disableAllHooks or off). These are
  # load-bearing for the operator to roll out and roll back.
  local f content
  f="$REPO/INSTALL.md"
  if [ ! -f "$f" ]; then
    fail "INSTALL.md missing"
    return
  fi
  content=$(cat "$f")
  assert_contains "$content" "V3_EDIT_PLAN_GATE" "INSTALL documents the env switch"
  assert_contains "$content" "policy.json" "INSTALL documents the policy.json switch"
  assert_contains "$content" "enforce" "INSTALL documents enforce mode"
  assert_contains "$content" "advice" "INSTALL documents advice mode"
  assert_contains "$content" "disableAllHooks" "INSTALL documents the kill switch"
}

# --- Slice 1 (v3-007) helpers: preflight / doctor ----------------------------

PREFLIGHT_LIB="$REPO/lib/preflight.sh"

# make_pkgmgr_path <name>...
#   Builds a tmp bin dir on $PATH containing only the listed package-manager
#   stubs (each a harmless executable) PLUS the core tools the lib needs, so
#   detect_pkg_manager can be exercised deterministically regardless of what the
#   CI machine actually has installed. Echoes the tmp bin path.
make_pkgmgr_path() {
  local bindir t p
  bindir=$(mktemp -d)
  # core tools the lib + bash need (no package managers among these).
  for t in bash sh cat awk sed grep printf pwd dirname basename env mktemp rm command; do
    p=$(command -v "$t" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$bindir/$t"
  done
  # requested package-manager stubs (harmless: just exit 0).
  for t in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$bindir/$t"
    chmod +x "$bindir/$t"
  done
  printf '%s' "$bindir"
}

# --- Slice 1 (v3-007) tests: lib/preflight.sh --------------------------------

test_install_cmd_for_brew_jq() {
  # install_cmd_for is a PURE mapping (pkg_manager x dep -> install command
  # string). It executes nothing. brew + jq must map to `brew install jq`.
  local out
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for brew jq )
  assert_eq "brew install jq" "$out" "brew x jq install command string"
}

test_install_cmd_for_apt_jq() {
  # apt is a DIFFERENT package manager: its install command differs (sudo +
  # apt-get -y). This forces a second branch, not a hardcoded brew string.
  local out
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for apt jq )
  assert_eq "sudo apt-get install -y jq" "$out" "apt x jq install command string"
}

test_install_cmd_for_all_managers_jq() {
  # The remaining managers each map to their native install command for jq.
  local out
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for dnf jq )
  assert_eq "sudo dnf install -y jq" "$out" "dnf x jq"
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for yum jq )
  assert_eq "sudo yum install -y jq" "$out" "yum x jq"
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for pacman jq )
  assert_eq "sudo pacman -S --noconfirm jq" "$out" "pacman x jq"
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for zypper jq )
  assert_eq "sudo zypper install -y jq" "$out" "zypper x jq"
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for winget jq )
  assert_eq "winget install jqlang.jq" "$out" "winget x jq"
}

test_install_cmd_for_unknown_returns_1() {
  # An unrecognized package manager yields empty stdout and return 1 (so the
  # caller falls through to "print official link and stop").
  local out rc
  out=$( . "$PREFLIGHT_LIB"; install_cmd_for frobnicate jq ); rc=$?
  assert_eq 1 "$rc" "unknown manager returns 1"
  assert_eq "" "$out" "unknown manager prints nothing"
}

test_detect_pkg_manager_picks_brew_when_only_brew() {
  # With a PATH containing ONLY the brew stub (plus core tools), detect must
  # return `brew`. PATH injection makes this deterministic regardless of CI host.
  local bindir out
  bindir=$(make_pkgmgr_path brew)
  out=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; detect_pkg_manager' )
  assert_eq "brew" "$out" "detect picks brew when only brew present"
  rm -rf "$bindir"
}

test_detect_pkg_manager_precedence_brew_over_apt() {
  # With BOTH brew and apt-get present, detect must return brew (defined order),
  # not "whatever it found first by luck". Kills a non-deterministic mutant.
  local bindir out
  bindir=$(make_pkgmgr_path brew apt-get)
  out=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; detect_pkg_manager' )
  assert_eq "brew" "$out" "brew takes precedence over apt"
  rm -rf "$bindir"
}

test_detect_pkg_manager_apt_when_no_brew() {
  # Only apt-get present (no brew) -> detect returns `apt`.
  local bindir out
  bindir=$(make_pkgmgr_path apt-get)
  out=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; detect_pkg_manager' )
  assert_eq "apt" "$out" "detect returns apt when only apt-get present"
  rm -rf "$bindir"
}

test_detect_pkg_manager_none_returns_1() {
  # PATH with NO package manager (only core tools) -> empty stdout, return 1.
  local bindir out rc
  bindir=$(make_pkgmgr_path)   # no managers requested
  out=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; detect_pkg_manager'; )
  rc=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; detect_pkg_manager >/dev/null; echo $?' )
  assert_eq "" "$out" "no manager -> empty stdout"
  assert_eq 1 "$rc" "no manager -> return 1"
  rm -rf "$bindir"
}

test_dep_present_true_for_existing() {
  # dep_present returns 0 when the dependency is resolvable on PATH.
  local bindir rc
  bindir=$(make_pkgmgr_path)   # core tools include `bash`
  rc=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; dep_present bash; echo $?' )
  assert_eq 0 "$rc" "dep_present 0 for an existing tool"
  rm -rf "$bindir"
}

test_dep_present_false_for_missing() {
  # dep_present returns 1 for a tool that is not on PATH.
  local bindir rc
  bindir=$(make_pkgmgr_path)
  rc=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; dep_present definitely_not_a_real_tool_xyz; echo $?' )
  assert_eq 1 "$rc" "dep_present 1 for a missing tool"
  rm -rf "$bindir"
}

test_dep_tier_git_required_jq_optional_claude_detectonly() {
  # The dependency tiering: git is required (can't bootstrap without it), jq is
  # optional (awk fallback / degrade), Claude Code is detect-only (never auto
  # installed — it's a prerequisite tool).
  local t
  t=$( . "$PREFLIGHT_LIB"; dep_tier git );    assert_eq "required" "$t" "git is required"
  t=$( . "$PREFLIGHT_LIB"; dep_tier bash );   assert_eq "required" "$t" "bash is required"
  t=$( . "$PREFLIGHT_LIB"; dep_tier jq );     assert_eq "optional" "$t" "jq is optional"
  t=$( . "$PREFLIGHT_LIB"; dep_tier claude ); assert_eq "detect-only" "$t" "claude is detect-only"
}

test_dep_tier_unknown_defaults_optional() {
  # An unknown dependency defaults to `optional` — the SAFE default: never
  # silently treat an unknown tool as required (which would block the user).
  local t
  t=$( . "$PREFLIGHT_LIB"; dep_tier some_unknown_dep )
  assert_eq "optional" "$t" "unknown dep defaults to optional (safe)"
}

test_should_install_auto_always_yes() {
  # should_install <auto_flag> <answer>: with --auto (auto=1) it must return 0
  # (install) UNCONDITIONALLY, ignoring the answer (unattended one-shot).
  local rc
  rc=$( . "$PREFLIGHT_LIB"; should_install 1 n; echo $? )
  assert_eq 0 "$rc" "auto=1 installs even when answer is n"
}

test_should_install_interactive_y_yes() {
  # Interactive (auto=0) with an affirmative answer -> return 0 (install).
  local rc
  rc=$( . "$PREFLIGHT_LIB"; should_install 0 y; echo $? )
  assert_eq 0 "$rc" "auto=0 + y -> install"
}

test_should_install_interactive_n_or_empty_no() {
  # Interactive (auto=0) with a negative or EMPTY answer (bare Enter) -> return
  # 1 (do NOT install). Empty defaults to NO (conservative; never silently
  # escalate). Kills a mutant that defaults empty to yes.
  local rc
  rc=$( . "$PREFLIGHT_LIB"; should_install 0 n; echo $? )
  assert_eq 1 "$rc" "auto=0 + n -> skip"
  rc=$( . "$PREFLIGHT_LIB"; should_install 0 ""; echo $? )
  assert_eq 1 "$rc" "auto=0 + empty -> skip (conservative default)"
}

test_preflight_report_marks_present_and_missing_with_tier() {
  # preflight_report prints, per dependency, present/missing AND its tier. Use a
  # PATH that HAS git+bash (core tools) but NOT jq/claude, so the report must
  # show git present+required and jq missing+optional. PATH injection makes the
  # present/missing facts deterministic.
  local bindir out
  bindir=$(make_pkgmgr_path)        # core tools include git? ensure git present
  ln -sf "$(command -v git)" "$bindir/git"
  out=$( PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; preflight_report' )
  assert_contains "$out" "git" "report names git"
  assert_contains "$out" "required" "report shows a required tier"
  assert_contains "$out" "present" "report marks something present"
  assert_contains "$out" "jq" "report names jq"
  assert_contains "$out" "optional" "report shows the optional tier"
  assert_contains "$out" "missing" "report marks the absent jq as missing"
  rm -rf "$bindir"
}

test_preflight_report_is_pure_no_writes() {
  # IDEMPOTENCE / PURITY LOCK: preflight_report must be side-effect free — two
  # runs produce identical output AND it writes NO files into the working dir.
  # This is the Slice-1 idempotence anchor (detection has no side effects).
  local bindir wd out1 out2 before after
  bindir=$(make_pkgmgr_path)
  ln -sf "$(command -v git)" "$bindir/git"
  wd=$(mktemp -d)
  before=$( cd "$wd" && ls -A | sort )
  out1=$( cd "$wd" && PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; preflight_report' )
  out2=$( cd "$wd" && PATH="$bindir" bash -c '. "'"$PREFLIGHT_LIB"'"; preflight_report' )
  after=$( cd "$wd" && ls -A | sort )
  assert_eq "$out1" "$out2" "report is deterministic across runs"
  assert_eq "$before" "$after" "report writes no files (pure)"
  rm -rf "$bindir" "$wd"
}

INSTALL_SH="$REPO/install.sh"

# run_install_sh <bindir> [args...]  -> sets RC / OUT / ERR globals.
#   Runs install.sh with PATH restricted to <bindir> so the present/missing set
#   is deterministic. SENTINEL marker for run_install side-effects is captured
#   via INSTALL_CMD_SINK env when relevant.
run_install_sh() {
  local bindir="$1"; shift
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  PATH="$bindir" bash "$INSTALL_SH" "$@" >"$out_f" 2>"$err_f"
  RC=$?
  OUT=$(cat "$out_f"); ERR=$(cat "$err_f"); rm -f "$out_f" "$err_f"
}

test_missing_git_prints_official_link_and_stops() {
  # git is REQUIRED and never auto-installed (bootstrap tool). With git ABSENT,
  # install.sh must print the official git download link and stop with a
  # non-zero exit, attempting NO install command.
  local bindir
  bindir=$(make_pkgmgr_path brew)   # brew present, but git absent
  run_install_sh "$bindir" --preflight-only
  if [ "$RC" -eq 0 ]; then
    fail "missing git must cause a non-zero exit (got 0)"
  fi
  assert_contains "$OUT$ERR" "git-scm.com" "prints the official git download link"
  assert_not_contains "$OUT$ERR" "brew install git" "must NOT attempt to install git"
  rm -rf "$bindir"
}

test_missing_required_no_pkgmgr_prints_link_stops() {
  # A required dep missing AND no package manager detected -> print link + stop.
  # Here git is missing and the PATH has NO package manager at all.
  local bindir
  bindir=$(make_pkgmgr_path)   # no managers, no git
  run_install_sh "$bindir" --preflight-only
  if [ "$RC" -eq 0 ]; then
    fail "missing required + no pkg manager must exit non-zero"
  fi
  assert_contains "$OUT$ERR" "git-scm.com" "prints the official download link"
  rm -rf "$bindir"
}

test_missing_optional_jq_does_not_block() {
  # jq is OPTIONAL: when git+bash are present but jq is absent, preflight must
  # report jq missing yet NOT fail (exit 0) — the awk fallback / degrade path
  # covers no-jq. Run with --auto and answer no implicitly so nothing installs.
  local bindir
  bindir=$(make_pkgmgr_path)   # core tools + git, NO jq, NO manager
  ln -sf "$(command -v git)" "$bindir/git"
  run_install_sh "$bindir" --preflight-only
  assert_eq 0 "$RC" "missing optional jq does not block (exit 0)"
  assert_contains "$OUT$ERR" "jq" "report still names jq"
  rm -rf "$bindir"
}

test_claude_code_detect_only_never_installs() {
  # Claude Code is detect-only: when absent, install.sh reports it missing and
  # may print a link, but must NEVER build/run an install command for it.
  local bindir
  bindir=$(make_pkgmgr_path brew)   # brew present so an install WOULD be possible
  ln -sf "$(command -v git)" "$bindir/git"
  run_install_sh "$bindir" --preflight-only
  assert_not_contains "$OUT$ERR" "install claude" "must NOT attempt to install Claude Code"
  assert_not_contains "$OUT$ERR" "brew install claude" "no brew install for claude"
  rm -rf "$bindir"
}

test_run_install_executes_only_when_gated_yes() {
  # The side-effecting run_install must execute its command ONLY when gated yes.
  # We inject a HARMLESS command (printf SENTINEL) — NOT a real package install —
  # to prove the gate wiring without touching the system.
  local out_yes out_no
  out_yes=$( . "$PREFLIGHT_LIB"; if should_install 1 n; then run_install 'printf SENTINEL_YES'; fi )
  assert_contains "$out_yes" "SENTINEL_YES" "gated yes -> command executes"
  out_no=$( . "$PREFLIGHT_LIB"; if should_install 0 n; then run_install 'printf SENTINEL_NO'; fi )
  assert_not_contains "$out_no" "SENTINEL_NO" "gated no -> command does NOT execute"
}

test_install_cmd_contains_sudo_for_apt_explicit_escalation() {
  # Privilege escalation must be EXPLICIT in the command string (never silent):
  # apt/dnf/etc carry `sudo`; brew (user-level) does not. This locks the
  # ticket's "no silent escalation" principle into the visible command string.
  local apt_cmd brew_cmd
  apt_cmd=$( . "$PREFLIGHT_LIB"; install_cmd_for apt jq )
  brew_cmd=$( . "$PREFLIGHT_LIB"; install_cmd_for brew jq )
  assert_contains "$apt_cmd" "sudo" "apt install command shows explicit sudo"
  assert_not_contains "$brew_cmd" "sudo" "brew install command has no sudo (user-level)"
}

# --- Slice 2 (v3-007) helpers: Mode A statusLine merge -----------------------

SETTINGS_MERGE_LIB="$REPO/lib/settings-merge.sh"

# repo_gauge_path — the canonical absolute path to THIS repo's context-gauge.sh.
# Mode A must point the statusLine command at the locally-cloned gauge script.
repo_gauge_path() {
  printf '%s' "$REPO/statusline/context-gauge.sh"
}

# mask_jq_bin — builds a tmp bin dir with core tools but NO jq, echoes its path.
# Used to drive the no-jq degrade path with a fresh-shell `command -v jq` mask.
mask_jq_bin() {
  local bindir t p
  bindir=$(mktemp -d)
  for t in bash sh cat awk sed grep printf pwd dirname basename env mktemp rm command cp mv date ls; do
    p=$(command -v "$t" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$bindir/$t"
  done
  printf '%s' "$bindir"
}

# --- Slice 2 (v3-007) tests: lib/settings-merge.sh ---------------------------

test_statusline_command_points_at_local_clone_gauge() {
  # PURE: statusline_command builds the `command` STRING for the statusLine key.
  # It must be `bash "<abs>/statusline/context-gauge.sh"` pointing at THIS repo's
  # locally-cloned gauge (canonical absolute path), matching INSTALL.md §7 shape.
  local out gauge
  gauge=$(repo_gauge_path)
  out=$( . "$SETTINGS_MERGE_LIB"; statusline_command "$gauge" )
  assert_eq "bash \"$gauge\"" "$out" "command string wraps the gauge abs path with bash + quotes"
}

test_merged_settings_preserves_other_keys_and_sets_statusline() {
  # PURE (jq): given an existing settings file with OTHER top-level keys
  # (effortLevel/theme/model) and NO statusLine, merged_settings_json must print
  # JSON that (1) keeps every existing key untouched and (2) adds a statusLine
  # whose command points at the local gauge. It writes NOTHING.
  local dir f gauge merged
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high","theme":"dark","model":"opus"}\n' > "$f"
  merged=$( . "$SETTINGS_MERGE_LIB"; merged_settings_json "$f" "$gauge" )
  # other keys preserved (parse the result with jq for structural truth)
  assert_eq "high" "$(printf '%s' "$merged" | jq -r '.effortLevel')" "effortLevel preserved"
  assert_eq "dark" "$(printf '%s' "$merged" | jq -r '.theme')" "theme preserved"
  assert_eq "opus" "$(printf '%s' "$merged" | jq -r '.model')" "model preserved"
  # statusLine added, type=command, command points at the local gauge
  assert_eq "command" "$(printf '%s' "$merged" | jq -r '.statusLine.type')" "statusLine.type=command"
  assert_eq "bash \"$gauge\"" "$(printf '%s' "$merged" | jq -r '.statusLine.command')" "statusLine.command points at local gauge"
  # the source file on disk is untouched (pure: no write)
  assert_not_contains "$(cat "$f")" "statusLine" "source file untouched (no write)"
  rm -rf "$dir"
}

test_merged_settings_replaces_old_statusline_and_keeps_others() {
  # PURE (jq): fixture has an OLD statusLine (different command path) AND other
  # keys. merged_settings_json must REPLACE the statusLine command with the local
  # gauge path (not nest/append) while preserving other keys, and the result must
  # contain exactly one statusLine command (the new one).
  local dir f gauge merged
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"theme":"light","statusLine":{"type":"command","command":"bash \\"/old/elsewhere/context-gauge.sh\\""}}\n' > "$f"
  merged=$( . "$SETTINGS_MERGE_LIB"; merged_settings_json "$f" "$gauge" )
  assert_eq "light" "$(printf '%s' "$merged" | jq -r '.theme')" "theme preserved through replace"
  assert_eq "bash \"$gauge\"" "$(printf '%s' "$merged" | jq -r '.statusLine.command')" "old command replaced with local gauge"
  assert_not_contains "$merged" "/old/elsewhere/" "old path is gone, not appended"
  rm -rf "$dir"
}

test_statusline_matches_true_when_identical_false_otherwise() {
  # PURE (jq): statusline_matches <file> <gauge> returns 0 iff the file ALREADY
  # has a statusLine whose command equals the desired local-gauge command. This
  # is the idempotency primitive: apply must no-op when this returns 0.
  local dir same diff none gauge rc
  dir=$(mktemp -d); gauge=$(repo_gauge_path)
  same="$dir/same.json"; diff="$dir/diff.json"; none="$dir/none.json"
  printf '{"theme":"dark","statusLine":{"type":"command","command":"bash \\"%s\\""}}\n' "$gauge" > "$same"
  printf '{"statusLine":{"type":"command","command":"bash \\"/other/gauge.sh\\""}}\n' > "$diff"
  printf '{"theme":"dark"}\n' > "$none"
  rc=$( . "$SETTINGS_MERGE_LIB"; statusline_matches "$same" "$gauge"; echo $? )
  assert_eq 0 "$rc" "identical statusLine -> match (0)"
  rc=$( . "$SETTINGS_MERGE_LIB"; statusline_matches "$diff" "$gauge"; echo $? )
  assert_eq 1 "$rc" "different statusLine command -> no match (1)"
  rc=$( . "$SETTINGS_MERGE_LIB"; statusline_matches "$none" "$gauge"; echo $? )
  assert_eq 1 "$rc" "no statusLine at all -> no match (1)"
  rm -rf "$dir"
}

test_settings_is_valid_json_true_for_good_empty_missing_false_for_broken() {
  # PURE (jq): settings_is_valid_json <file> returns 0 for parseable JSON, for an
  # empty file, and for a missing file (both treated as empty {} downstream);
  # returns 1 for unparseable (broken) JSON. Guards apply against clobbering a
  # file we can't safely parse.
  local dir good empty broken missing rc
  dir=$(mktemp -d)
  good="$dir/good.json"; empty="$dir/empty.json"; broken="$dir/broken.json"; missing="$dir/nope.json"
  printf '{"theme":"dark"}\n' > "$good"
  : > "$empty"
  printf '{theme: dark,,,\n' > "$broken"
  rc=$( . "$SETTINGS_MERGE_LIB"; settings_is_valid_json "$good"; echo $? )
  assert_eq 0 "$rc" "good JSON -> valid (0)"
  rc=$( . "$SETTINGS_MERGE_LIB"; settings_is_valid_json "$empty"; echo $? )
  assert_eq 0 "$rc" "empty file -> valid (0, treated as {})"
  rc=$( . "$SETTINGS_MERGE_LIB"; settings_is_valid_json "$missing"; echo $? )
  assert_eq 0 "$rc" "missing file -> valid (0, treated as {})"
  rc=$( . "$SETTINGS_MERGE_LIB"; settings_is_valid_json "$broken"; echo $? )
  assert_eq 1 "$rc" "broken JSON -> invalid (1)"
  rm -rf "$dir"
}

test_apply_statusline_clean_creates_then_noop_on_rerun() {
  # FIXTURE (1) clean / no file. apply_statusline must CREATE settings.json with
  # the statusLine pointing at the local gauge, return 0. RERUN must be a NO-OP:
  # identical content AND a no-op signal (not a second write). Idempotency lock.
  local dir f gauge out1 out2 c1 c2
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  # file does NOT exist yet
  out1=$( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" )
  assert_eq 0 "$?" "first apply returns 0"
  if [ ! -f "$f" ]; then fail "first apply must create settings.json"; fi
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "created statusLine points at local gauge"
  c1=$(cat "$f")
  out2=$( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" )
  assert_eq 0 "$?" "rerun returns 0"
  c2=$(cat "$f")
  assert_eq "$c1" "$c2" "rerun leaves content unchanged (idempotent)"
  assert_contains "$out2" "no-op" "rerun reports a no-op (did not rewrite)"
  rm -rf "$dir"
}

test_apply_statusline_otherkeys_backs_up_preserves_then_noop() {
  # FIXTURE (2) other keys, NO statusLine. apply must (a) back up the original
  # FIRST (a .bak.* sibling whose content equals the pre-write original), (b)
  # preserve the other keys, (c) add the statusLine. Rerun -> no-op (no second
  # write, content stable). Backup-before-write + idempotency lock.
  local dir f gauge orig c1 c2 baks
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high","theme":"dark","model":"opus"}\n' > "$f"
  orig=$(cat "$f")
  ( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" ) >/dev/null
  assert_eq 0 "$?" "first apply returns 0"
  # a backup exists and equals the ORIGINAL (proves backed up before overwrite)
  baks=$(ls "$dir"/settings.json.bak.* 2>/dev/null | head -1)
  if [ -z "$baks" ]; then fail "apply must create a .bak backup before writing"; fi
  assert_eq "$orig" "$(cat "$baks" 2>/dev/null)" "backup holds the pre-write original"
  # other keys preserved + statusLine added
  assert_eq "high" "$(jq -r '.effortLevel' "$f")" "effortLevel preserved on disk"
  assert_eq "opus" "$(jq -r '.model' "$f")" "model preserved on disk"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "statusLine written on disk"
  c1=$(cat "$f")
  # rerun -> no-op, content unchanged
  local out2
  out2=$( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" )
  c2=$(cat "$f")
  assert_eq "$c1" "$c2" "rerun unchanged (idempotent)"
  assert_contains "$out2" "no-op" "rerun is a no-op"
  rm -rf "$dir"
}

test_apply_statusline_old_different_updates_then_noop() {
  # FIXTURE (3) existing OLD statusLine with a DIFFERENT command path. First
  # apply must UPDATE it to the local gauge (not no-op), backing up the original
  # (which still holds the old path). Second apply -> no-op. update-when-diff +
  # idempotency lock.
  local dir f gauge baks c1 c2 out1 out2
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"theme":"light","statusLine":{"type":"command","command":"bash \\"/old/elsewhere/context-gauge.sh\\""}}\n' > "$f"
  out1=$( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" )
  assert_not_contains "$out1" "no-op" "first apply must NOT no-op when statusLine differs"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "statusLine updated to local gauge"
  assert_eq "light" "$(jq -r '.theme' "$f")" "other key preserved through update"
  baks=$(ls "$dir"/settings.json.bak.* 2>/dev/null | head -1)
  assert_contains "$(cat "$baks" 2>/dev/null)" "/old/elsewhere/" "backup preserves the old statusLine path"
  c1=$(cat "$f")
  out2=$( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" )
  c2=$(cat "$f")
  assert_eq "$c1" "$c2" "rerun unchanged (idempotent)"
  assert_contains "$out2" "no-op" "rerun is a no-op"
  rm -rf "$dir"
}

test_apply_statusline_broken_json_does_not_clobber_backs_up_and_degrades() {
  # FIXTURE (4) broken JSON. apply must NOT overwrite (no data loss): the file
  # content stays byte-identical, a backup is made, a non-zero return signals
  # "did not write", and a copy-pasteable statusLine block is printed for manual
  # merge. Rerun is equally non-destructive (idempotent in the sense of "never
  # clobbers"). The original content must survive both runs.
  local dir f gauge orig rc out c_after baks
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{ this is : not, valid json ]]]\n' > "$f"
  orig=$(cat "$f")
  out=$( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then fail "broken JSON must NOT return 0 (must signal it did not write)"; fi
  c_after=$(cat "$f")
  assert_eq "$orig" "$c_after" "broken JSON file is NOT clobbered (content intact)"
  baks=$(ls "$dir"/settings.json.bak.* 2>/dev/null | head -1)
  if [ -z "$baks" ]; then fail "broken JSON path must still back up the original"; fi
  assert_eq "$orig" "$(cat "$baks")" "backup holds the broken original verbatim"
  # copy-pasteable complete block printed for manual merge
  assert_contains "$out" "\"statusLine\"" "degrade prints a statusLine JSON block"
  assert_contains "$out" "bash \\\"$gauge\\\"" "block carries the local gauge command"
  # rerun still non-destructive
  ( . "$SETTINGS_MERGE_LIB"; apply_statusline "$f" "$gauge" ) >/dev/null 2>&1
  assert_eq "$orig" "$(cat "$f")" "rerun still does not clobber broken JSON"
  rm -rf "$dir"
}

test_apply_statusline_no_jq_degrades_prints_block_and_does_not_write() {
  # NO-JQ DEGRADE (candidate (b)). With jq MASKED via a fresh-shell command -v
  # mask, apply must NOT write the file; instead print a COMPLETE copy-pasteable
  # statusLine JSON block (type=command + the local-gauge command), say where to
  # paste it, and a restore note. The clean fixture file must remain ABSENT
  # (proves no write). Uses the v3-005 S5-4 fresh-shell mask technique.
  local dir f gauge jqbin out
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  jqbin=$(mask_jq_bin)
  # sanity: jq must NOT be resolvable under the masked PATH
  if PATH="$jqbin" bash -c 'command -v jq >/dev/null 2>&1'; then
    fail "jq mask ineffective: jq still resolvable under masked PATH"
  fi
  out=$( PATH="$jqbin" bash -c '. "'"$SETTINGS_MERGE_LIB"'"; apply_statusline "'"$f"'" "'"$gauge"'"' )
  assert_eq 0 "$?" "no-jq degrade returns 0 (does not hard-fail)"
  if [ -e "$f" ]; then fail "no-jq path must NOT write the settings file"; fi
  # complete, copy-pasteable block
  assert_contains "$out" "\"statusLine\"" "block has the statusLine key"
  assert_contains "$out" "\"type\": \"command\"" "block has type=command"
  assert_contains "$out" "bash \\\"$gauge\\\"" "block carries the local-gauge command"
  assert_contains "$out" "jq not found" "explains why it degraded"
  assert_contains "$out" "restore" "block includes a restore instruction"
  rm -rf "$dir" "$jqbin"
}

test_install_sh_mode_a_writes_statusline_to_injected_settings_file() {
  # END-TO-END (Mode A through install.sh): with --mode-a and an INJECTED target
  # via SETTINGS_FILE (a fixture temp file — NEVER the real ~/.claude/), install.sh
  # must merge a statusLine whose command points at THIS repo's clone of
  # context-gauge.sh (computed install.sh's own way), preserving other keys.
  # Rerun is idempotent (no-op). This test must NOT touch the real HOME.
  local dir f gauge out1 out2 c1 c2 bindir
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high"}\n' > "$f"
  # PATH with the full tool set (cp/mv/date/ls for backup+write) PLUS git+jq so
  # preflight passes and the jq merge runs. mask_jq_bin gives the full core set;
  # we add jq+git back on top.
  bindir=$(mask_jq_bin)
  ln -sf "$(command -v git)" "$bindir/git"
  ln -sf "$(command -v jq)" "$bindir/jq"
  out1=$( PATH="$bindir" SETTINGS_FILE="$f" bash "$INSTALL_SH" --mode-a 2>&1 )
  assert_eq 0 "$?" "install.sh --mode-a returns 0"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "install.sh wired statusLine to local gauge clone"
  assert_eq "high" "$(jq -r '.effortLevel' "$f")" "install.sh preserved the existing key"
  c1=$(cat "$f")
  out2=$( PATH="$bindir" SETTINGS_FILE="$f" bash "$INSTALL_SH" --mode-a 2>&1 )
  c2=$(cat "$f")
  assert_eq "$c1" "$c2" "install.sh --mode-a rerun is idempotent (no change)"
  assert_contains "$out2" "no-op" "install.sh --mode-a rerun reports no-op"
  rm -rf "$dir" "$bindir"
}

# --- Slice 3 (v3-007) helpers: Mode B adopt ----------------------------------

ADOPT_LIB="$REPO/lib/adopt.sh"

# make_target_repo  -> echoes path to a fresh tmp git repo (the Mode B target),
#   with an initial commit so `git rev-parse --show-toplevel` resolves. Used as
#   the adopt target; lives entirely under mktemp (never the real FS / HOME).
make_target_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  printf '# target\n' > "$dir/README.md"
  ( cd "$dir" && git -c user.email=t@t -c user.name=t add -A && \
    git -c user.email=t@t -c user.name=t commit -q -m init )
  printf '%s' "$dir"
}

# --- Slice 3 (v3-007) tests: lib/adopt.sh ------------------------------------

test_adopt_hook_command_preserves_git_rev_parse_literal() {
  # PURE: adopt_hook_command builds the `command` STRING for a hook entry. It MUST
  # keep the literal `$(git rev-parse --show-toplevel)` shell expansion verbatim
  # (NOT resolve it to an absolute path at adopt time) so the target repo self-
  # resolves the path and stays portable if moved. Shape matches this repo's
  # .claude/settings.json: bash "$(git rev-parse --show-toplevel)/hooks/<script>".
  local out
  out=$( . "$ADOPT_LIB"; adopt_hook_command "pre-edit-guard.sh" )
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/pre-edit-guard.sh"' "$out" \
    "command keeps the literal git rev-parse expansion and points at the hook"
  assert_contains "$out" 'git rev-parse --show-toplevel' "literal git rev-parse preserved (portability key)"
}

test_adopt_merged_settings_wires_three_hooks_with_literal_command() {
  # PURE (jq): given an empty/{} target settings, adopt_merged_settings_json must
  # print JSON wiring all THREE hook entries — SessionStart (session-start-
  # context.sh), PreToolUse matcher "Edit|Write" (pre-edit-guard.sh), Stop (stop-
  # orchestrator.sh) — each command being the literal `$(git rev-parse ...)` form
  # with timeout 30. Writes NOTHING.
  local dir f merged
  dir=$(mktemp -d); f="$dir/settings.json"
  printf '{}\n' > "$f"
  merged=$( . "$ADOPT_LIB"; adopt_merged_settings_json "$f" )
  # each event present with the right script in its command
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/session-start-context.sh"' \
    "$(printf '%s' "$merged" | jq -r '.hooks.SessionStart[0].hooks[0].command')" \
    "SessionStart command literal preserved"
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/pre-edit-guard.sh"' \
    "$(printf '%s' "$merged" | jq -r '.hooks.PreToolUse[0].hooks[0].command')" \
    "PreToolUse command literal preserved"
  assert_eq 'Edit|Write' \
    "$(printf '%s' "$merged" | jq -r '.hooks.PreToolUse[0].matcher')" \
    "PreToolUse matcher is Edit|Write"
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/stop-orchestrator.sh"' \
    "$(printf '%s' "$merged" | jq -r '.hooks.Stop[0].hooks[0].command')" \
    "Stop command literal preserved"
  # timeout 30 on each
  assert_eq 30 "$(printf '%s' "$merged" | jq -r '.hooks.SessionStart[0].hooks[0].timeout')" "SessionStart timeout 30"
  assert_eq 30 "$(printf '%s' "$merged" | jq -r '.hooks.PreToolUse[0].hooks[0].timeout')" "PreToolUse timeout 30"
  assert_eq 30 "$(printf '%s' "$merged" | jq -r '.hooks.Stop[0].hooks[0].timeout')" "Stop timeout 30"
  # the literal expansion survives serialization (not resolved to an abs path)
  assert_contains "$merged" 'git rev-parse --show-toplevel' "merged JSON keeps the literal git rev-parse expansion"
  # pure: source file untouched
  assert_eq '{}' "$(cat "$f" | tr -d '[:space:]')" "source file untouched (no write)"
  rm -rf "$dir"
}

test_adopt_merged_settings_idempotent_no_duplicate_entries() {
  # PURE (jq) IDEMPOTENCY LOCK: feeding adopt_merged_settings_json its OWN prior
  # output must NOT add a second copy of any of the three hook entries. After two
  # merges each event must have exactly ONE group whose hook carries the workflow
  # command, and the second merge's output must equal the first's (byte-for-byte
  # via jq -S canonicalization). Kills an "always-append" mutant.
  local dir f once twice n_ss n_pt n_st
  dir=$(mktemp -d); f="$dir/settings.json"
  printf '{}\n' > "$f"
  once=$( . "$ADOPT_LIB"; adopt_merged_settings_json "$f" )
  # feed the first result back in as the existing file
  printf '%s\n' "$once" > "$f"
  twice=$( . "$ADOPT_LIB"; adopt_merged_settings_json "$f" )
  # count groups whose first hook command is the workflow command (must be 1 each)
  n_ss=$(printf '%s' "$twice" | jq '[.hooks.SessionStart[] | select(.hooks[0].command | test("session-start-context.sh"))] | length')
  n_pt=$(printf '%s' "$twice" | jq '[.hooks.PreToolUse[]  | select(.hooks[0].command | test("pre-edit-guard.sh"))]     | length')
  n_st=$(printf '%s' "$twice" | jq '[.hooks.Stop[]        | select(.hooks[0].command | test("stop-orchestrator.sh"))]  | length')
  assert_eq 1 "$n_ss" "SessionStart workflow entry not duplicated on rerun"
  assert_eq 1 "$n_pt" "PreToolUse workflow entry not duplicated on rerun"
  assert_eq 1 "$n_st" "Stop workflow entry not duplicated on rerun"
  # second merge is a fixed point (canonical equality)
  assert_eq "$(printf '%s' "$once" | jq -S .)" "$(printf '%s' "$twice" | jq -S .)" \
    "merge is a fixed point (rerun output identical)"
  rm -rf "$dir"
}

test_adopt_merged_settings_preserves_existing_keys_and_foreign_hooks() {
  # PURE (jq) NON-DESTRUCTIVE LOCK: the target already has an unrelated top-level
  # key (model) AND a pre-existing FOREIGN PreToolUse hook (a Bash matcher that is
  # NOT ours). adopt_merged_settings_json must keep the model key, keep the
  # foreign Bash hook, AND add our three workflow hooks alongside (PreToolUse now
  # has BOTH the foreign Bash group and our Edit|Write group). Kills a "replace
  # .hooks wholesale" mutant.
  local dir f merged
  dir=$(mktemp -d); f="$dir/settings.json"
  cat > "$f" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash /custom/foreign-bash-guard.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
EOF
  merged=$( . "$ADOPT_LIB"; adopt_merged_settings_json "$f" )
  # unrelated top-level key preserved
  assert_eq "opus" "$(printf '%s' "$merged" | jq -r '.model')" "unrelated top-level key preserved"
  # foreign Bash hook still present
  assert_eq 1 "$(printf '%s' "$merged" | jq '[.hooks.PreToolUse[] | select(.matcher=="Bash")] | length')" \
    "foreign Bash PreToolUse hook preserved"
  assert_contains "$merged" "foreign-bash-guard.sh" "foreign hook command kept verbatim"
  # our workflow Edit|Write hook added alongside (PreToolUse now has 2 groups)
  assert_eq 2 "$(printf '%s' "$merged" | jq '.hooks.PreToolUse | length')" \
    "PreToolUse has both the foreign group and our workflow group"
  assert_eq 1 "$(printf '%s' "$merged" | jq '[.hooks.PreToolUse[] | select(.hooks[0].command | test("pre-edit-guard.sh"))] | length')" \
    "our workflow Edit|Write hook added"
  # SessionStart + Stop also wired
  assert_contains "$merged" "session-start-context.sh" "SessionStart wired"
  assert_contains "$merged" "stop-orchestrator.sh" "Stop wired"
  rm -rf "$dir"
}

test_adopt_hooks_present_true_only_when_all_three_wired() {
  # PURE (jq): adopt_hooks_present <file> returns 0 iff ALL THREE workflow hook
  # commands are already wired in <file>; 1 otherwise (none, partial, missing
  # file). The idempotency primitive the orchestrator uses to detect "already
  # adopted -> no settings rewrite needed".
  local dir all none partial gauge rc
  dir=$(mktemp -d)
  all="$dir/all.json"; none="$dir/none.json"; partial="$dir/partial.json"
  # fully wired = the canonical merge output
  ( . "$ADOPT_LIB"; printf '{}' | adopt_merged_settings_json /dev/stdin ) > "$all"
  # none = unrelated settings, no hooks
  printf '{"model":"opus"}\n' > "$none"
  # partial = only SessionStart wired (Stop + PreToolUse missing)
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \\"$(git rev-parse --show-toplevel)/hooks/session-start-context.sh\\"","timeout":30}]}]}}\n' > "$partial"
  rc=$( . "$ADOPT_LIB"; adopt_hooks_present "$all"; echo $? )
  assert_eq 0 "$rc" "all three wired -> present (0)"
  rc=$( . "$ADOPT_LIB"; adopt_hooks_present "$none"; echo $? )
  assert_eq 1 "$rc" "no workflow hooks -> not present (1)"
  rc=$( . "$ADOPT_LIB"; adopt_hooks_present "$partial"; echo $? )
  assert_eq 1 "$rc" "partial (only SessionStart) -> not present (1)"
  rc=$( . "$ADOPT_LIB"; adopt_hooks_present "$dir/nope.json"; echo $? )
  assert_eq 1 "$rc" "missing file -> not present (1)"
  rm -rf "$dir"
}

test_adopt_paste_block_lists_all_three_hooks_with_literal_command() {
  # PURE (candidate (b) degrade): adopt_paste_block <file> prints a copy-pasteable
  # block naming all THREE hook events with the literal $(git rev-parse ...)
  # commands + timeout 30, tells where to paste, and a restore note. Used on the
  # no-jq path — we never silently rewrite the target settings there.
  local dir f out
  dir=$(mktemp -d); f="$dir/.claude/settings.json"
  out=$( . "$ADOPT_LIB"; adopt_paste_block "$f" )
  assert_contains "$out" '"SessionStart"' "block names SessionStart"
  assert_contains "$out" '"PreToolUse"' "block names PreToolUse"
  assert_contains "$out" '"Stop"' "block names Stop"
  assert_contains "$out" "session-start-context.sh" "block carries the SessionStart script"
  assert_contains "$out" "pre-edit-guard.sh" "block carries the PreToolUse script"
  assert_contains "$out" "stop-orchestrator.sh" "block carries the Stop script"
  assert_contains "$out" 'git rev-parse --show-toplevel' "block keeps the literal git rev-parse expansion"
  assert_contains "$out" '"Edit|Write"' "block carries the PreToolUse matcher"
  assert_contains "$out" "$f" "block says which file to paste into"
  assert_contains "$out" "restore" "block includes a restore instruction"
  rm -rf "$dir"
}

test_copy_workflow_files_copies_hooks_tree_and_policy() {
  # SIDE-EFFECT: copy_workflow_files <src-root> <target-root> must copy the WHOLE
  # hooks/ tree (including hooks/lib/) and templates/policy.json from src into
  # target at the matching locations. Use THIS repo as src and a fresh tmp target.
  local target
  target=$(mktemp -d)
  ( . "$ADOPT_LIB"; copy_workflow_files "$REPO" "$target" )
  assert_eq 0 "$?" "copy_workflow_files returns 0"
  for f in hooks/pre-edit-guard.sh hooks/session-start-context.sh \
           hooks/stop-orchestrator.sh hooks/lib/workflow-state.sh \
           hooks/lib/write-handoff.sh templates/policy.json; do
    if [ ! -f "$target/$f" ]; then
      fail "expected $f copied into target"
    fi
  done
  # content fidelity on a representative file
  assert_eq "$(cat "$REPO/templates/policy.json")" "$(cat "$target/templates/policy.json")" \
    "policy.json content copied verbatim"
  rm -rf "$target"
}

test_adopt_repo_end_to_end_copies_files_and_wires_settings() {
  # SIDE-EFFECT ORCHESTRATOR: adopt_repo <src> <target> on a git target must
  # (1) copy the hooks tree + templates/policy.json, (2) create <target>/.claude/
  # if missing, (3) merge the three workflow hooks into <target>/.claude/
  # settings.json with the literal $(git rev-parse ...) commands preserved, while
  # preserving any existing keys. Target is a fresh tmp git repo (never real FS).
  local target s rc
  target=$(make_target_repo)
  # no .claude/ yet -> orchestrator must create it
  if [ -d "$target/.claude" ]; then fail "fixture should start without .claude/"; fi
  ( . "$ADOPT_LIB"; adopt_repo "$REPO" "$target" ) >/dev/null 2>&1
  rc=$?
  assert_eq 0 "$rc" "adopt_repo returns 0 on a git target"
  # files copied
  if [ ! -f "$target/hooks/pre-edit-guard.sh" ]; then fail "hooks copied"; fi
  if [ ! -f "$target/hooks/lib/workflow-state.sh" ]; then fail "hooks/lib copied"; fi
  if [ ! -f "$target/templates/policy.json" ]; then fail "policy.json copied"; fi
  # .claude/ created and settings wired
  s="$target/.claude/settings.json"
  if [ ! -f "$s" ]; then fail "adopt_repo must create .claude/settings.json"; fi
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/session-start-context.sh"' \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")" "SessionStart wired with literal command"
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/pre-edit-guard.sh"' \
    "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s")" "PreToolUse wired with literal command"
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/stop-orchestrator.sh"' \
    "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" "Stop wired with literal command"
  assert_contains "$(cat "$s")" 'git rev-parse --show-toplevel' "settings keeps literal git rev-parse (not resolved)"
  rm -rf "$target"
}

test_adopt_repo_idempotent_rerun_no_duplicate_entries() {
  # IDEMPOTENCY LOCK (end-to-end): running adopt_repo TWICE on the same target
  # must NOT duplicate hook entries (each event still has exactly one workflow
  # group) and the settings content must be byte-identical between the two runs.
  # Also preserves a pre-existing unrelated top-level key across both runs.
  local target s c1 c2
  target=$(make_target_repo)
  mkdir -p "$target/.claude"
  printf '{"model":"opus"}\n' > "$target/.claude/settings.json"
  s="$target/.claude/settings.json"
  ( . "$ADOPT_LIB"; adopt_repo "$REPO" "$target" ) >/dev/null 2>&1
  c1=$(cat "$s")
  ( . "$ADOPT_LIB"; adopt_repo "$REPO" "$target" ) >/dev/null 2>&1
  c2=$(cat "$s")
  assert_eq "$c1" "$c2" "second adopt leaves settings byte-identical (idempotent)"
  assert_eq 1 "$(jq '[.hooks.SessionStart[] | select(.hooks[0].command | test("session-start-context.sh"))] | length' "$s")" \
    "SessionStart not duplicated across two adopts"
  assert_eq 1 "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command | test("pre-edit-guard.sh"))] | length' "$s")" \
    "PreToolUse not duplicated across two adopts"
  assert_eq 1 "$(jq '[.hooks.Stop[] | select(.hooks[0].command | test("stop-orchestrator.sh"))] | length' "$s")" \
    "Stop not duplicated across two adopts"
  assert_eq "opus" "$(jq -r '.model' "$s")" "pre-existing key preserved across adopts"
  rm -rf "$target"
}

test_install_sh_adopt_wires_target_repo() {
  # END-TO-END (Mode B through install.sh): `install.sh --adopt <target>` must
  # adopt the workflow guard into a fresh tmp git repo: (1) exit 0, (2) copy the
  # hooks tree + templates/policy.json into the target, (3) wire the three
  # workflow hooks into <target>/.claude/settings.json with the literal
  # $(git rev-parse --show-toplevel) command preserved. --adopt is a VALUE arg
  # (the next token is the target path). Runs under a masked PATH carrying the
  # full core toolset plus git+jq; NEVER touches the real HOME / ~/.claude/.
  local target bindir out rc s
  target=$(make_target_repo)
  bindir=$(mask_jq_bin)
  ln -sf "$(command -v git)" "$bindir/git"
  ln -sf "$(command -v jq)" "$bindir/jq"
  ln -sf "$(command -v mkdir)" "$bindir/mkdir"  # adopt_repo creates dirs/.claude
  out=$( PATH="$bindir" bash "$INSTALL_SH" --adopt "$target" 2>&1 ); rc=$?
  assert_eq 0 "$rc" "install.sh --adopt returns 0 on a git target"
  if [ ! -f "$target/hooks/pre-edit-guard.sh" ]; then fail "install.sh --adopt copies hooks"; fi
  if [ ! -f "$target/templates/policy.json" ]; then fail "install.sh --adopt copies policy.json"; fi
  s="$target/.claude/settings.json"
  if [ ! -f "$s" ]; then fail "install.sh --adopt creates .claude/settings.json"; fi
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/session-start-context.sh"' \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")" "SessionStart wired with literal command"
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/pre-edit-guard.sh"' \
    "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s")" "PreToolUse wired with literal command"
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/stop-orchestrator.sh"' \
    "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" "Stop wired with literal command"
  assert_contains "$(cat "$s")" 'git rev-parse --show-toplevel' "settings keeps literal git rev-parse (not resolved)"
  rm -rf "$target" "$bindir"
}

test_install_sh_adopt_missing_path_errors() {
  # GUARD: `--adopt` is a value arg; with NO path following it install.sh must
  # fail loud (non-zero exit, error on stderr) and NOT proceed as if adopting.
  local bindir out rc
  bindir=$(mask_jq_bin)
  ln -sf "$(command -v git)" "$bindir/git"
  ln -sf "$(command -v jq)" "$bindir/jq"
  out=$( PATH="$bindir" bash "$INSTALL_SH" --adopt 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then fail "install.sh --adopt with no path must exit non-zero"; fi
  assert_contains "$out" "--adopt" "error names the --adopt flag"
  rm -rf "$bindir"
}

# --- Slice 4 (v3-007) helpers: interactive menu + --update -------------------

MENU_LIB="$REPO/lib/menu.sh"

# choice_modes <choice>  -> echoes the normalized mode token for a menu choice.
choice_modes() {
  ( . "$MENU_LIB"; menu_choice_to_modes "$1" )
}

# --- Slice 4 (v3-007) tests: lib/menu.sh pure dispatch -----------------------

test_menu_choice_a_maps_to_mode_a() {
  # PURE heart of the menu: a user choosing "a"/"A" (Mode A, machine-level) maps
  # to the stable mode token `a`. This is the testable core, no tty / no file.
  assert_eq "a" "$(choice_modes a)" "choice 'a' -> mode a"
  assert_eq "a" "$(choice_modes A)" "choice 'A' -> mode a (case-insensitive)"
}

test_menu_choice_b_maps_to_mode_b() {
  # "b"/"B" (Mode B, adopt into a project) maps to the stable token `b`.
  assert_eq "b" "$(choice_modes b)" "choice 'b' -> mode b"
  assert_eq "b" "$(choice_modes B)" "choice 'B' -> mode b (case-insensitive)"
}

test_menu_choice_both_maps_to_both() {
  # "both"/"ab"/"c" (do both) maps to the stable token `both`.
  assert_eq "both" "$(choice_modes both)" "choice 'both' -> both"
  assert_eq "both" "$(choice_modes ab)" "choice 'ab' -> both"
  assert_eq "both" "$(choice_modes c)" "choice 'c' -> both"
}

test_menu_choice_quit_or_unknown_maps_to_none() {
  # quit / empty / anything unrecognized maps to `none` (conservative: do nothing,
  # never accidentally run a mode on a stray keystroke). Kills a "default to a"
  # mutant.
  assert_eq "none" "$(choice_modes q)" "choice 'q' -> none"
  assert_eq "none" "$(choice_modes quit)" "choice 'quit' -> none"
  assert_eq "none" "$(choice_modes '')" "empty choice -> none"
  assert_eq "none" "$(choice_modes zzz)" "unknown choice -> none"
}

# run_menu_pipe <stdin> <settings_file> <gauge> <src_root>  -> sets RC/OUT/ERR.
#   Feeds <stdin> (the choice, plus a Mode-B target line when needed) into
#   run_menu via a pipe (no tty -> exercises the stdin read branch). The Mode A
#   target is the INJECTED settings fixture; the Mode B target is read from stdin.
run_menu_pipe() {
  local stdin_data="$1" settings="$2" gauge="$3" src="$4"
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  printf '%s' "$stdin_data" \
    | ( . "$MENU_LIB"; . "$SETTINGS_MERGE_LIB"; . "$ADOPT_LIB"; \
        run_menu "$settings" "$gauge" "$src" ) >"$out_f" 2>"$err_f"
  RC=$?
  OUT=$(cat "$out_f"); ERR=$(cat "$err_f"); rm -f "$out_f" "$err_f"
}

test_run_menu_choice_a_dispatches_mode_a_only() {
  # SIDE-EFFECT orchestrator: feeding "a" on stdin must dispatch Mode A
  # (apply_statusline) against the INJECTED settings fixture (never ~/.claude/),
  # writing the statusLine pointing at the gauge — and must NOT adopt any repo.
  local dir f gauge
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high"}\n' > "$f"
  run_menu_pipe 'a
' "$f" "$gauge" "$REPO"
  assert_eq 0 "$RC" "run_menu choice a returns 0"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "Mode A wired the statusLine"
  assert_eq "high" "$(jq -r '.effortLevel' "$f")" "Mode A preserved the existing key"
  rm -rf "$dir"
}

test_run_menu_choice_b_reads_target_and_adopts() {
  # Feeding "b\n<target>\n" must dispatch Mode B (adopt_repo) into the target git
  # repo read from stdin (a fresh tmp repo, never the real FS) and must NOT touch
  # the injected settings fixture (Mode A must not run).
  local dir f gauge target s
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high"}\n' > "$f"
  target=$(make_target_repo)
  run_menu_pipe "b
$target
" "$f" "$gauge" "$REPO"
  assert_eq 0 "$RC" "run_menu choice b returns 0"
  s="$target/.claude/settings.json"
  if [ ! -f "$s" ]; then fail "Mode B must wire the target settings"; fi
  assert_eq 'bash "$(git rev-parse --show-toplevel)/hooks/session-start-context.sh"' \
    "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")" "Mode B wired the target"
  # Mode A must NOT have run: the injected fixture stays without a statusLine.
  assert_eq "null" "$(jq -r '.statusLine // "null"' "$f")" "Mode A did not run on choice b"
  rm -rf "$dir" "$target"
}

test_run_menu_choice_both_dispatches_a_and_b() {
  # Feeding "both\n<target>\n" must run BOTH Mode A (against the injected fixture)
  # and Mode B (adopt into the target read from stdin).
  local dir f gauge target s
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{}\n' > "$f"
  target=$(make_target_repo)
  run_menu_pipe "both
$target
" "$f" "$gauge" "$REPO"
  assert_eq 0 "$RC" "run_menu choice both returns 0"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "Mode A ran (statusLine wired)"
  s="$target/.claude/settings.json"
  if [ ! -f "$s" ]; then fail "Mode B must wire the target settings"; fi
  assert_contains "$(cat "$s")" "session-start-context.sh" "Mode B ran (target wired)"
  rm -rf "$dir" "$target"
}

test_run_menu_choice_quit_does_nothing() {
  # Feeding "q" must dispatch NOTHING: the injected settings fixture stays
  # untouched (no statusLine written) and exit is 0.
  local dir f gauge before after
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high"}\n' > "$f"
  before=$(cat "$f")
  run_menu_pipe 'q
' "$f" "$gauge" "$REPO"
  assert_eq 0 "$RC" "run_menu quit returns 0"
  after=$(cat "$f")
  assert_eq "$before" "$after" "quit left the settings fixture untouched"
  rm -rf "$dir"
}

test_install_sh_no_flags_menu_choice_a_wires_mode_a() {
  # END-TO-END (interactive menu through install.sh): with NO mode flag, install.sh
  # runs preflight then the menu. Feeding "a" on stdin must wire Mode A into the
  # INJECTED SETTINGS_FILE fixture (never ~/.claude/). PATH carries the full core
  # set + git + jq so preflight passes and the merge runs.
  local dir f gauge bindir out rc
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high"}\n' > "$f"
  bindir=$(mask_jq_bin)
  ln -sf "$(command -v git)" "$bindir/git"
  ln -sf "$(command -v jq)" "$bindir/jq"
  out=$( printf 'a\n' | PATH="$bindir" SETTINGS_FILE="$f" bash "$INSTALL_SH" 2>&1 ); rc=$?
  assert_eq 0 "$rc" "install.sh (no flags) + menu choice a returns 0"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "menu choice a wired statusLine via install.sh"
  assert_eq "high" "$(jq -r '.effortLevel' "$f")" "existing key preserved"
  rm -rf "$dir" "$bindir"
}

test_install_sh_auto_does_not_enter_menu() {
  # --auto is non-interactive: it must NOT block on the menu. With --auto and NO
  # mode flag and EMPTY stdin, install.sh must still exit 0 without hanging on a
  # read and without dispatching a mode (the injected fixture stays untouched).
  local dir f bindir out rc before after
  dir=$(mktemp -d); f="$dir/settings.json"
  printf '{"effortLevel":"high"}\n' > "$f"
  before=$(cat "$f")
  bindir=$(mask_jq_bin)
  ln -sf "$(command -v git)" "$bindir/git"
  ln -sf "$(command -v jq)" "$bindir/jq"
  out=$( printf '' | PATH="$bindir" SETTINGS_FILE="$f" bash "$INSTALL_SH" --auto 2>&1 ); rc=$?
  assert_eq 0 "$rc" "install.sh --auto returns 0 without entering the menu"
  after=$(cat "$f")
  assert_eq "$before" "$after" "--auto did not dispatch a mode (fixture untouched)"
  rm -rf "$dir" "$bindir"
}

# --- Slice 4 (v3-007) tests: --update (pull/reapply separation) --------------

test_update_pull_is_stubbable_via_env() {
  # --update's git pull is a network side effect. update_pull must run the
  # injected UPDATE_PULL_CMD (a harmless command here) INSTEAD of touching the
  # network, so the pull step is observable in tests without a real pull.
  local out
  out=$( . "$MENU_LIB"; UPDATE_PULL_CMD='printf PULL_SENTINEL' update_pull "$REPO" )
  assert_contains "$out" "PULL_SENTINEL" "update_pull runs the injected stub command"
}

test_do_update_pulls_then_reapplies_mode_a_idempotent() {
  # do_update must (1) call the (stubbed) pull, then (2) idempotently re-apply
  # Mode A against the INJECTED settings fixture. First run writes the statusLine;
  # a SECOND do_update re-pulls (stub) and re-applies as a NO-OP (idempotent
  # reapply — the update-is-safe-to-rerun guarantee). Never touches the network
  # or ~/.claude/.
  local dir f gauge out1 out2 c1 c2
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high"}\n' > "$f"
  out1=$( . "$MENU_LIB"; . "$SETTINGS_MERGE_LIB"; \
          UPDATE_PULL_CMD='printf PULL1' do_update "$REPO" "$f" "$gauge" )
  assert_contains "$out1" "PULL1" "do_update calls the (stubbed) pull"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "do_update re-applied Mode A"
  c1=$(cat "$f")
  out2=$( . "$MENU_LIB"; . "$SETTINGS_MERGE_LIB"; \
          UPDATE_PULL_CMD='printf PULL2' do_update "$REPO" "$f" "$gauge" )
  c2=$(cat "$f")
  assert_eq "$c1" "$c2" "do_update reapply is idempotent (no change on rerun)"
  assert_contains "$out2" "no-op" "do_update rerun reports the idempotent no-op"
  rm -rf "$dir"
}

test_do_update_prints_mode_b_hint() {
  # Mode B target repos are not tracked (no registry). do_update must print a hint
  # telling the user to update each adopted repo themselves (git pull + re-adopt),
  # rather than silently doing nothing about Mode B.
  local dir f gauge out
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{}\n' > "$f"
  out=$( . "$MENU_LIB"; . "$SETTINGS_MERGE_LIB"; \
         UPDATE_PULL_CMD='true' do_update "$REPO" "$f" "$gauge" )
  assert_contains "$out" "--adopt" "Mode B hint tells user to re-run --adopt"
  rm -rf "$dir"
}

test_install_sh_update_flag_reapplies_mode_a() {
  # END-TO-END (--update through install.sh): with --update and the pull stubbed
  # via UPDATE_PULL_CMD, install.sh must re-apply Mode A into the INJECTED
  # SETTINGS_FILE fixture (never ~/.claude/) and exit 0. --update must NOT enter
  # the interactive menu (it is an explicit mode).
  local dir f gauge bindir out rc
  dir=$(mktemp -d); f="$dir/settings.json"; gauge=$(repo_gauge_path)
  printf '{"effortLevel":"high"}\n' > "$f"
  bindir=$(mask_jq_bin)
  ln -sf "$(command -v git)" "$bindir/git"
  ln -sf "$(command -v jq)" "$bindir/jq"
  ln -sf "$(command -v true)" "$bindir/true"
  out=$( printf '' | PATH="$bindir" SETTINGS_FILE="$f" UPDATE_PULL_CMD='printf PULLED' \
         bash "$INSTALL_SH" --update 2>&1 ); rc=$?
  assert_eq 0 "$rc" "install.sh --update returns 0"
  assert_contains "$out" "PULLED" "install.sh --update ran the (stubbed) pull"
  assert_eq "bash \"$gauge\"" "$(jq -r '.statusLine.command' "$f")" "install.sh --update re-applied Mode A"
  rm -rf "$dir" "$bindir"
}

# --- driver ------------------------------------------------------------------

TESTS="
test_menu_choice_a_maps_to_mode_a
test_menu_choice_b_maps_to_mode_b
test_menu_choice_both_maps_to_both
test_menu_choice_quit_or_unknown_maps_to_none
test_run_menu_choice_a_dispatches_mode_a_only
test_run_menu_choice_b_reads_target_and_adopts
test_run_menu_choice_both_dispatches_a_and_b
test_run_menu_choice_quit_does_nothing
test_install_sh_no_flags_menu_choice_a_wires_mode_a
test_install_sh_auto_does_not_enter_menu
test_update_pull_is_stubbable_via_env
test_do_update_pulls_then_reapplies_mode_a_idempotent
test_do_update_prints_mode_b_hint
test_install_sh_update_flag_reapplies_mode_a
test_adopt_hook_command_preserves_git_rev_parse_literal
test_adopt_merged_settings_wires_three_hooks_with_literal_command
test_adopt_merged_settings_idempotent_no_duplicate_entries
test_adopt_merged_settings_preserves_existing_keys_and_foreign_hooks
test_adopt_hooks_present_true_only_when_all_three_wired
test_adopt_paste_block_lists_all_three_hooks_with_literal_command
test_copy_workflow_files_copies_hooks_tree_and_policy
test_adopt_repo_end_to_end_copies_files_and_wires_settings
test_adopt_repo_idempotent_rerun_no_duplicate_entries
test_install_sh_adopt_wires_target_repo
test_install_sh_adopt_missing_path_errors
test_statusline_command_points_at_local_clone_gauge
test_merged_settings_preserves_other_keys_and_sets_statusline
test_merged_settings_replaces_old_statusline_and_keeps_others
test_statusline_matches_true_when_identical_false_otherwise
test_settings_is_valid_json_true_for_good_empty_missing_false_for_broken
test_apply_statusline_clean_creates_then_noop_on_rerun
test_apply_statusline_otherkeys_backs_up_preserves_then_noop
test_apply_statusline_old_different_updates_then_noop
test_apply_statusline_broken_json_does_not_clobber_backs_up_and_degrades
test_apply_statusline_no_jq_degrades_prints_block_and_does_not_write
test_install_sh_mode_a_writes_statusline_to_injected_settings_file
test_install_cmd_for_brew_jq
test_install_cmd_for_apt_jq
test_install_cmd_for_all_managers_jq
test_install_cmd_for_unknown_returns_1
test_detect_pkg_manager_picks_brew_when_only_brew
test_detect_pkg_manager_precedence_brew_over_apt
test_detect_pkg_manager_apt_when_no_brew
test_detect_pkg_manager_none_returns_1
test_dep_present_true_for_existing
test_dep_present_false_for_missing
test_dep_tier_git_required_jq_optional_claude_detectonly
test_dep_tier_unknown_defaults_optional
test_should_install_auto_always_yes
test_should_install_interactive_y_yes
test_should_install_interactive_n_or_empty_no
test_preflight_report_marks_present_and_missing_with_tier
test_preflight_report_is_pure_no_writes
test_missing_git_prints_official_link_and_stops
test_missing_required_no_pkgmgr_prints_link_stops
test_missing_optional_jq_does_not_block
test_claude_code_detect_only_never_installs
test_run_install_executes_only_when_gated_yes
test_install_cmd_contains_sudo_for_apt_explicit_escalation
test_policy_get_jq_reads_existing_key
test_policy_get_jq_missing_key_returns_default
test_policy_get_no_file_returns_default
test_policy_get_awk_fallback_matches_jq
test_policy_get_awk_fallback_respects_section
test_mode_precedence_env_unset_policy_enforce_blocks
test_mode_precedence_env_unset_no_policy_defaults_advice
test_mode_precedence_env_wins_over_policy
test_policy_template_default_is_advice_and_readable_by_policy_get
test_install_md_documents_switches_and_killswitch
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
test_session_start_disclaimer_present_when_only_current_task
test_session_start_disclaimer_soul_substrings_locked
test_settings_wires_session_start_and_preserves_pretooluse_stop
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
