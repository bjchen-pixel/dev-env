#!/bin/bash
# v3-006 Slice 1 — pure-bash test runner for the context-usage gauge.
# Sibling of tests/run.sh, same conventions (zero deps, bash 3.2 compatible).
# Each test is a shell function returning 0 (PASS) / non-0 (FAIL).
# Runner aggregates failures and exits non-zero if any fail.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$TESTS_DIR/.." && pwd -P)
GAUGE="$REPO/statusline/context-gauge.sh"

FAIL_COUNT=0
CUR_TEST=""

fail() {
  printf '    FAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    fail "$3: expected [$1], got [$2]"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3: expected to contain [$2], got [$1]" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3: expected NOT to contain [$2], but it did" ;;
    *) : ;;
  esac
}

# --- fixture helpers ---------------------------------------------------------

# stdin_total <total_input_tokens> [context_window_size]
#   Emits a statusLine JSON payload using the primary field
#   .context_window.total_input_tokens.
stdin_total() {
  local total="$1" size="${2:-200000}"
  printf '{"context_window":{"total_input_tokens":%s,"context_window_size":%s}}' \
    "$total" "$size"
}

# stdin_usage_parts <input_tokens> <cache_creation> <cache_read> [size]
#   Emits a payload WITHOUT total_input_tokens, forcing the fallback sum of
#   .context_window.current_usage.{input_tokens,cache_creation_input_tokens,
#   cache_read_input_tokens}.
stdin_usage_parts() {
  local it="$1" cc="$2" cr="$3" size="${4:-200000}"
  printf '{"context_window":{"context_window_size":%s,"current_usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}' \
    "$size" "$it" "$cc" "$cr"
}

# run_gauge <stdin_json>  -> sets RC / OUT / ERR globals.
run_gauge() {
  local json="$1"
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  printf '%s' "$json" | bash "$GAUGE" >"$out_f" 2>"$err_f"
  RC=$?
  OUT=$(cat "$out_f")
  ERR=$(cat "$err_f")
  rm -f "$out_f" "$err_f"
}

# run_gauge_path <stdin_json> <PATH override>  -> sets RC / OUT / ERR.
run_gauge_path() {
  local json="$1" path="$2"
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  printf '%s' "$json" | ( PATH="$path" bash "$GAUGE" ) >"$out_f" 2>"$err_f"
  RC=$?
  OUT=$(cat "$out_f")
  ERR=$(cat "$err_f")
  rm -f "$out_f" "$err_f"
}

# ESC is the literal ANSI escape byte.
ESC=$(printf '\033')
# SETCOLOR is the actual "set foreground color" SGR sequence the on-line render
# opens with. Asserting THIS (not a bare ESC) pins down that the line is really
# colored: a stray trailing reset (\033[0m) alone still contains an ESC byte but
# leaves the text uncolored on screen, so a bare-ESC assertion is a false green.
SETCOLOR="${ESC}[33m"

# assert_empty <value> <msg>
assert_empty() {
  if [ -n "$1" ]; then
    fail "$2: expected empty, got [$1]"
  fi
}

# assert_failsoft  — the universal fail-soft contract for one bad input:
#   RC==0, stderr completely empty, no handoff-zone cue (no false alarm).
# Assumes a prior run_gauge / run_gauge_path set RC / OUT / ERR.
assert_failsoft() {
  assert_eq 0 "$RC" "$1: exit 0"
  assert_empty "$ERR" "$1: stderr is completely empty"
  assert_not_contains "$OUT" "換手區" "$1: no handoff-zone cue (no false alarm)"
}

# masked_path  — make a temp dir of symlinks to the everyday tools the gauge
# needs but WITHOUT jq, so the awk fallback path is exercised. Echoes the dir.
masked_path() {
  local d t p
  d=$(mktemp -d)
  for t in bash sh cat awk sed grep printf env mktemp rm; do
    p=$(command -v "$t" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$d/$t"
  done
  printf '%s' "$d"
}

# --- tests -------------------------------------------------------------------

test_over_threshold_shows_handoff_zone_cue() {
  # SOUL of this slice. occupancy >= 100k -> stdout must (a) carry a soft
  # "handoff zone" cue, (b) carry a color (ANSI escape), (c) NOT carry any
  # command-style stop wording. 100k is a soft line, not a cliff.
  run_gauge "$(stdin_total 150000)"
  assert_eq 0 "$RC" "exit 0"
  assert_contains "$OUT" "換手區" "stdout carries the handoff-zone cue"
  assert_contains "$OUT" "$SETCOLOR" "stdout opens with the set-color SGR (actually colored, not a bare reset)"
  assert_not_contains "$OUT" "該換手了" "no command-style stop wording (該換手了)"
  assert_not_contains "$OUT" "STOP" "no command-style stop wording (STOP)"
  assert_not_contains "$OUT" "立刻" "no command-style stop wording (立刻)"
  assert_not_contains "$OUT" "馬上" "no command-style stop wording (馬上)"
}

test_under_threshold_shows_usage_no_cue() {
  # occupancy < 100k -> neutral usage display, NO handoff-zone cue and NONE of
  # the command-style stop wording. Must still report the token number.
  run_gauge "$(stdin_total 40000)"
  assert_eq 0 "$RC" "exit 0"
  assert_contains "$OUT" "40000" "stdout reports the token usage number"
  assert_not_contains "$OUT" "換手區" "under-line: no handoff-zone cue"
  assert_not_contains "$OUT" "該換手了" "under-line: no stop wording"
}

test_boundary_99k_is_under_line() {
  # 99000 < 100000 -> under-line: neutral usage, no cue.
  run_gauge "$(stdin_total 99000)"
  assert_eq 0 "$RC" "exit 0"
  assert_not_contains "$OUT" "換手區" "99k is below the soft line -> no cue"
  assert_contains "$OUT" "99000" "99k reports usage number"
}

test_boundary_exactly_100k_is_on_line() {
  # EXACT boundary: 100000 >= 100000 -> on-line (equality counts). Kills a `>`
  # (strict) mutant that would treat exactly-100k as still below the line.
  run_gauge "$(stdin_total 100000)"
  assert_eq 0 "$RC" "exit 0"
  assert_contains "$OUT" "換手區" "exactly 100k is ON the soft line (>= includes equality)"
  assert_contains "$OUT" "$SETCOLOR" "on-line opens with the set-color SGR (actually colored)"
}

test_boundary_101k_is_on_line() {
  # 101000 > 100000 -> on-line: cue + color.
  run_gauge "$(stdin_total 101000)"
  assert_eq 0 "$RC" "exit 0"
  assert_contains "$OUT" "換手區" "101k is over the soft line -> cue"
  assert_contains "$OUT" "$SETCOLOR" "101k opens with the set-color SGR (actually colored)"
}

test_fallback_sum_when_total_absent() {
  # primary .total_input_tokens absent -> fallback sums current_usage parts:
  # 30000 + 60000 + 20000 = 110000 >= 100k -> on-line. Proves the fallback is
  # both wired AND summed (not just reading one part).
  run_gauge "$(stdin_usage_parts 30000 60000 20000)"
  assert_eq 0 "$RC" "exit 0"
  assert_contains "$OUT" "換手區" "fallback sum (110k) crosses the line -> cue"
  assert_contains "$OUT" "110000" "fallback reports the summed total"
}

test_awk_fallback_matches_jq_primary() {
  # PARITY: with jq MASKED (PATH stripped of jq), the awk narrow-target fallback
  # must reach the SAME decision and report the SAME number for the primary field
  # .context_window.total_input_tokens as the jq path. Use an over-line value so
  # both the threshold decision (cue) and the number are observable.
  local json
  json=$(stdin_total 150000)

  # jq path
  run_gauge "$json"
  local jq_out="$OUT" jq_rc="$RC"

  # masked PATH: only the non-jq tools the gauge needs.
  local jqbin t p
  jqbin=$(mktemp -d)
  for t in bash sh cat awk sed grep printf env mktemp rm; do
    p=$(command -v "$t" 2>/dev/null)
    [ -n "$p" ] && ln -sf "$p" "$jqbin/$t"
  done
  if PATH="$jqbin" bash -c 'command -v jq >/dev/null 2>&1'; then
    fail "jq mask ineffective: jq still resolvable under masked PATH"
  fi
  run_gauge_path "$json" "$jqbin"

  assert_eq "$jq_rc" "$RC" "exit-code parity (jq vs awk)"
  assert_eq "$jq_out" "$OUT" "rendered-line parity (jq vs awk fallback)"
  assert_contains "$OUT" "換手區" "awk fallback also crosses the line -> cue"
  assert_contains "$OUT" "150000" "awk fallback extracts the same number"
  rm -rf "$jqbin"
}

# --- fail-soft matrix --------------------------------------------------------

test_non_numeric_total_degrades_no_stderr() {
  # ROOT CAUSE / first red. A non-integer total ("abc") reaches the numeric
  # comparison `[ "$total" -ge ... ]`, which on bash emits
  #   [: abc: integer expression expected
  # to stderr (polluting every statusLine refresh) and falls into the else
  # branch printing the garbage value. The gauge must validate ^[0-9]+$ BEFORE
  # comparing: non-integer total => treated as unavailable => clean degrade.
  run_gauge '{"context_window":{"total_input_tokens":"abc"}}'
  assert_failsoft "non-numeric total"
  assert_not_contains "$OUT" "abc" "non-numeric total: must not echo the garbage value"
}

test_missing_context_window_degrades_clean() {
  # Legal JSON but the whole context_window object is absent. There is no
  # occupancy to report, so the gauge must NOT fabricate a "context 0 / 200000"
  # crippled render — it must degrade to the same clean, non-alarm output as any
  # other unavailable input. (Distinguishes "extracted 0" from "got nothing".)
  run_gauge '{"model":{"id":"x"}}'
  assert_failsoft "missing context_window"
  assert_not_contains "$OUT" "context " "missing cw: no crippled usage render"
  assert_not_contains "$OUT" "/ 200000" "missing cw: no fabricated size render"
}

test_empty_stdin_degrades_clean() {
  # No input at all (statusLine fed nothing). Must degrade cleanly: exit 0,
  # silent stderr, no cue, no fabricated render.
  run_gauge ''
  assert_failsoft "empty stdin"
  assert_not_contains "$OUT" "context " "empty stdin: no crippled usage render"
}

test_garbage_json_degrades_clean() {
  # Non-JSON garbage on stdin. jq fails to parse (suppressed), awk finds no
  # numeric field. Must degrade cleanly with no stderr and no cue.
  run_gauge 'not json {{'
  assert_failsoft "garbage json"
  assert_not_contains "$OUT" "context " "garbage json: no crippled usage render"
}

test_jq_absent_garbage_degrades_clean() {
  # Worst case for the fallback path: jq MASKED *and* garbage input. The awk
  # narrow-target fallback finds no numeric field; the gauge must still degrade
  # cleanly (exit 0, silent stderr, no cue, no crippled render).
  local jqbin
  jqbin=$(masked_path)
  if PATH="$jqbin" bash -c 'command -v jq >/dev/null 2>&1'; then
    fail "jq mask ineffective: jq still resolvable under masked PATH"
  fi
  run_gauge_path 'not json {{' "$jqbin"
  assert_failsoft "jq-absent + garbage"
  assert_not_contains "$OUT" "context " "jq-absent garbage: no crippled render"
  rm -rf "$jqbin"
}

test_jq_absent_legal_over_line_still_cues() {
  # PARITY / regression guard: the fail-soft hardening must NOT break the happy
  # path on the awk fallback. With jq masked and a legal over-line payload, the
  # gauge must STILL render the handoff-zone cue + the number. (Catches an
  # over-aggressive degrade that would swallow valid awk-extracted occupancy.)
  local jqbin
  jqbin=$(masked_path)
  if PATH="$jqbin" bash -c 'command -v jq >/dev/null 2>&1'; then
    fail "jq mask ineffective: jq still resolvable under masked PATH"
  fi
  run_gauge_path "$(stdin_total 150000)" "$jqbin"
  assert_eq 0 "$RC" "jq-absent over-line: exit 0"
  assert_empty "$ERR" "jq-absent over-line: silent stderr"
  assert_contains "$OUT" "換手區" "jq-absent over-line: awk fallback still cues"
  assert_contains "$OUT" "150000" "jq-absent over-line: awk fallback reports number"
  rm -rf "$jqbin"
}

# --- driver ------------------------------------------------------------------

TESTS="
test_over_threshold_shows_handoff_zone_cue
test_under_threshold_shows_usage_no_cue
test_boundary_99k_is_under_line
test_boundary_exactly_100k_is_on_line
test_boundary_101k_is_on_line
test_fallback_sum_when_total_absent
test_awk_fallback_matches_jq_primary
test_non_numeric_total_degrades_no_stderr
test_missing_context_window_degrades_clean
test_empty_stdin_degrades_clean
test_garbage_json_degrades_clean
test_jq_absent_garbage_degrades_clean
test_jq_absent_legal_over_line_still_cues
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
