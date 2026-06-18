#!/bin/bash
# v3-008 Slice 1 — hooks/lib/ledger.sh — Decision Ledger core (Type A).
# bash 3.2 compatible. No LLM, no network. jq NOT used: pure awk/bash.
#
# Convention: status via return code (0=ok/true, non-0=fail/false);
#             data via stdout. Errors to stderr.
#
# Storage: .claude/ledger/<id>.yaml — one decision per file, file-granularity
# immutable. The directory is created lazily by ledger_add on first entry.

# ledger_add <id>   (entry body on stdin)
#   Reads a YAML decision body on stdin and writes it to
#   <root>/.claude/ledger/<id>.yaml. Append-only: never mutates an existing
#   file. Returns 0 on success, non-0 (no write) on rejection.
#   $2 (optional) = repo root (defaults to pwd -P).
ledger_add() {
  local id="$1" root="${2:-$(pwd -P)}"
  local body
  body=$(cat)

  local dir="$root/.claude/ledger"
  local file="$dir/$id.yaml"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$body" > "$file" || return 1
  return 0
}
