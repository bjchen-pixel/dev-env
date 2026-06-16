#!/bin/bash
# v3-006 statusline/context-gauge.sh — Context-usage gauge for Claude Code's
# statusLine. Reads a statusLine JSON payload on stdin, computes input-side
# context occupancy, compares against the absolute 100k soft line, and renders
# one line to stdout. bash 3.2 compatible. No LLM, no network. Only exit is 0.

set -u

THRESHOLD=100000

input=$(cat)

# _num_field <key>
#   Narrow-target extractor for an integer JSON field named <key>. NOT a general
#   parser — finds the first `"<key>": <digits>` in the payload. Used only as the
#   awk fallback when jq is unavailable.
_num_field() {
  printf '%s' "$input" | awk -v want="$1" '
    {
      line = $0
      while (match(line, /"[^"]*"[ \t]*:[ \t]*[0-9]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        key = tok; sub(/^"/, "", key); sub(/".*$/, "", key)
        num = tok; sub(/^[^:]*:[ \t]*/, "", num)
        if (key == want) { print num; exit }
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

total=""
size=""
if command -v jq >/dev/null 2>&1; then
  # Primary: .context_window.total_input_tokens.
  total=$(printf '%s' "$input" \
    | jq -r '.context_window.total_input_tokens // empty' 2>/dev/null)
  # Fallback: sum of current_usage.{input_tokens,cache_creation_input_tokens,
  # cache_read_input_tokens} when the primary field is absent.
  if [ -z "$total" ]; then
    # Only sum when current_usage actually exists; otherwise yield empty so an
    # absent context_window degrades (rather than fabricating a 0 occupancy).
    total=$(printf '%s' "$input" | jq -r '
      .context_window.current_usage as $u
      | if $u == null then empty
        else ( ($u.input_tokens // 0)
             + ($u.cache_creation_input_tokens // 0)
             + ($u.cache_read_input_tokens // 0) )
        end' 2>/dev/null)
  fi
  size=$(printf '%s' "$input" \
    | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
fi

# awk narrow-target fallback (jq absent or yielded nothing).
if [ -z "$total" ]; then
  total=$(_num_field total_input_tokens)
  if [ -z "$total" ]; then
    local_it=$(_num_field input_tokens)
    local_cc=$(_num_field cache_creation_input_tokens)
    local_cr=$(_num_field cache_read_input_tokens)
    # Only synthesize a sum when at least one usage part was actually found;
    # if none were, leave total empty so the input degrades (no fabricated 0).
    if [ -n "$local_it" ] || [ -n "$local_cc" ] || [ -n "$local_cr" ]; then
      [ -n "$local_it" ] || local_it=0
      [ -n "$local_cc" ] || local_cc=0
      [ -n "$local_cr" ] || local_cr=0
      total=$((local_it + local_cc + local_cr))
    fi
  fi
fi
[ -n "$size" ] || size=$(_num_field context_window_size)
[ -n "$size" ] || size=200000

# Fail-soft gate. The gauge runs on EVERY statusLine refresh in EVERY project;
# a bad payload must never break the status line. If we could not extract a
# usable non-negative integer occupancy (empty / non-numeric / fractional /
# context_window absent), degrade silently: clean empty output, no stderr, and
# crucially NO handoff-zone cue (never a false alarm). The integer check must
# run BEFORE the numeric comparison `-ge`, which would otherwise emit
# "integer expression expected" to stderr on a non-integer value.
case "$total" in
  '' | *[!0-9]* )
    exit 0
    ;;
esac

# size must likewise be a clean integer for the render; fall back to default.
case "$size" in
  '' | *[!0-9]* )
    size=200000
    ;;
esac

if [ "$total" -ge "$THRESHOLD" ]; then
  printf '\033[33m進入換手區(%s / %s)。不急,告一段落再交接。\033[0m' "$total" "$size"
else
  printf 'context %s / %s' "$total" "$size"
fi

exit 0
