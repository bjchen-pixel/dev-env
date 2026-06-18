#!/bin/bash
# v3-008 Slice 1 — hooks/ledger-resume.sh — Decision Ledger Resume Reader.
# Standalone executable. Reads .claude/ledger/ and prints, to stdout, the
# recoverable "negative space" of past decisions: for every ACTIVE decision
# (active = not superseded by any real supersedes edge), its claim + the options
# it rejected and why, plus an aggregated list of open questions.
#
# Deliberately NOT a full decision dump and NOT a confidence score: the value is
# bringing back what was rejected and why, so a cold start does not re-propose a
# previously-killed option. bash 3.2, no LLM, no network.

set -u

ROOT=$(pwd -P)
LIB_DIR=$(cd "$(dirname "$0")" && pwd -P)/lib
# shellcheck source=lib/ledger.sh
. "$LIB_DIR/ledger.sh"

DIR="$ROOT/.claude/ledger"

# _open_questions_of <file> -> emits this entry's open_questions list items.
_open_questions_of() {
  awk '
    /^open_questions:[ \t]*$/ { inblk=1; next }
    inblk && /^[^ \t]/ { inblk=0 }
    inblk && /^[ \t]*-[ \t]*/ {
      v=$0; sub(/^[ \t]*-[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      if (length(v)>0) print v
    }
  ' "$1"
}

# Active ids only — superseded decisions are intentionally omitted.
ACTIVE=$(ledger_active_ids "$ROOT")

OQ_ALL=""

for id in $ACTIVE; do
  file="$DIR/$id.yaml"
  [ -f "$file" ] || continue

  claim=$(_yaml_scalar "$(cat "$file")" claim)
  # Displayed status is COMPUTED, not read from the file: every id we iterate is
  # in the active set (ledger_active_ids), so its computed status is "active".
  # The stored `status:` line is never echoed.
  printf '## %s [active] — %s\n' "$id" "$claim"

  # Rejected options + why (the negative space). Supports multiple rejected
  # entries (list of maps). Each: "  - option: X" then "    why: Y".
  awk '
    /^rejected:[ \t]*$/ { inrej=1; next }
    inrej && /^[^ \t]/ { inrej=0 }
    inrej && /^[ \t]*-?[ \t]*option:[ \t]*/ {
      v=$0; sub(/^[ \t]*-?[ \t]*option:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      printf "  rejected: %s\n", v
      next
    }
    inrej && /^[ \t]*why:[ \t]*/ {
      v=$0; sub(/^[ \t]*why:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      printf "    why: %s\n", v
    }
  ' "$file"

  oq=$(_open_questions_of "$file")
  if [ -n "$oq" ]; then
    OQ_ALL="$OQ_ALL
$oq"
  fi
done

# Aggregated open questions across all active decisions.
if [ -n "$(printf '%s' "$OQ_ALL" | grep -v '^[ \t]*$')" ]; then
  printf '\n## Open questions\n'
  printf '%s\n' "$OQ_ALL" | grep -v '^[ \t]*$' | while IFS= read -r q; do
    printf -- '- %s\n' "$q"
  done
fi

exit 0
