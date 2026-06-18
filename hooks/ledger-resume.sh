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

# Active ids only — superseded decisions are intentionally omitted.
ACTIVE=$(ledger_active_ids "$ROOT")

for id in $ACTIVE; do
  file="$DIR/$id.yaml"
  [ -f "$file" ] || continue

  claim=$(_yaml_scalar "$(cat "$file")" claim)
  printf '## %s — %s\n' "$id" "$claim"

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
done

exit 0
