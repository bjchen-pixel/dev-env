#!/bin/bash
# v3-008 Slice 1 — hooks/lib/ledger.sh — Decision Ledger core (Type A).
# bash 3.2 compatible. No LLM, no network. jq NOT used: pure awk/bash.
#
# Convention: status via return code (0=ok/true, non-0=fail/false);
#             data via stdout. Errors to stderr.
#
# Storage: .claude/ledger/<id>.yaml — one decision per file, file-granularity
# immutable. The directory is created lazily by ledger_add on first entry.

# _yaml_scalar <body> <key>
#   Prints the trimmed scalar value of a top-level `key: value` line from a YAML
#   body (first match), stripping a trailing inline comment. Empty if absent or
#   value is empty. Top-level = no leading indentation.
_yaml_scalar() {
  printf '%s\n' "$1" | awk -v k="$2" '
    {
      line = $0
      if (line ~ "^" k ":[ \t]*") {
        sub("^" k ":[ \t]*", "", line)
        sub(/[ \t]*#.*$/, "", line)
        sub(/[ \t]+$/, "", line)
        print line
        exit
      }
    }'
}

# ledger_validate_entry   (entry body on stdin)
#   Structural schema check for a decision entry. Returns 0 if valid; on the
#   first violation, prints "[ledger] invalid: <reason>" to stderr and returns 1.
#   Checks (Type A, Slice 1):
#     - claim: non-empty
ledger_validate_entry() {
  local body
  body=$(cat)

  if [ -z "$(_yaml_scalar "$body" claim)" ]; then
    printf '[ledger] invalid: missing required field claim\n' >&2
    return 1
  fi

  # evidence.commits: must exist & be non-empty. Find the `commits:` key nested
  # under the top-level `evidence:` block, then require its value to contain at
  # least one hash-like token. Bare `[]` or empty value => invalid.
  local commits
  commits=$(printf '%s\n' "$body" | awk '
    /^evidence:[ \t]*$/ { inev=1; next }
    inev && /^[^ \t]/ { inev=0 }
    inev && /^[ \t]+commits:[ \t]*/ {
      v=$0
      sub(/^[ \t]+commits:[ \t]*/, "", v)
      gsub(/[][, ]/, "", v)
      print v
      exit
    }')
  if [ -z "$commits" ]; then
    printf '[ledger] invalid: evidence.commits is required and must be non-empty\n' >&2
    return 1
  fi

  # Human Gate (structural): the entry must carry an approval reason. Convention:
  # the free-text `note:` block contains an `approval:` line. No approval line =>
  # rejected — the gate is structural, not a politeness.
  if ! printf '%s\n' "$body" | grep -q '[Aa]pproval:'; then
    printf '[ledger] invalid: missing approval reason (Human Gate: note must carry an approval: line)\n' >&2
    return 1
  fi

  return 0
}

# ledger_add <id>   (entry body on stdin)
#   Reads a YAML decision body on stdin and writes it to
#   <root>/.claude/ledger/<id>.yaml. Append-only: never mutates an existing
#   file. Returns 0 on success, non-0 (no write) on rejection.
#   $2 (optional) = repo root (defaults to pwd -P).
ledger_add() {
  local id="$1" root="${2:-$(pwd -P)}"
  local body
  body=$(cat)

  # id is the primary key AND the filename: lock its shape so it can never escape
  # .claude/ledger/ (no `/`, no `..`). Format: ^[A-Z]+-[0-9]+$ (e.g. AUTH-001).
  if ! printf '%s' "$id" | grep -Eq '^[A-Z]+-[0-9]+$'; then
    printf '[ledger_add] rejected: invalid id [%s] (must match ^[A-Z]+-[0-9]+$)\n' "$id" >&2
    return 1
  fi

  local dir="$root/.claude/ledger"
  local file="$dir/$id.yaml"

  if [ -e "$file" ]; then
    printf '[ledger_add] rejected: id %s already exists (append-only)\n' "$id" >&2
    return 1
  fi

  printf '%s' "$body" | ledger_validate_entry || return 1

  mkdir -p "$dir" || return 1
  printf '%s\n' "$body" > "$file" || return 1
  return 0
}

# _ledger_entry_ids <ledger_dir>
#   Emits the id (basename without .yaml) of every entry file, one per line.
#   Empty output if the directory is absent. Uses a glob, not `ls` parsing.
_ledger_entry_ids() {
  local dir="$1" f base
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.yaml; do
    [ -e "$f" ] || continue       # no-match glob guard
    base=$(basename "$f")
    printf '%s\n' "${base%.yaml}"
  done
}

# _ledger_supersedes_of <file>
#   Emits the ids listed in this entry's `supersedes:` field, one per line.
#   Supports inline flow form `supersedes: [A-1, B-2]` and block form
#   `supersedes:\n  - A-1\n  - B-2`. The superseded_by direction is NEVER read.
_ledger_supersedes_of() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    # inline flow form on the same line as the key
    /^supersedes:[ \t]*\[/ {
      v=$0
      sub(/^supersedes:[ \t]*\[/, "", v)
      sub(/\].*$/, "", v)
      n=split(v, a, ",")
      for (i=1; i<=n; i++) {
        gsub(/[ \t]/, "", a[i])
        if (length(a[i])>0) print a[i]
      }
      next
    }
    # block form: open the list, read following `  - id` lines
    /^supersedes:[ \t]*$/ { inblk=1; next }
    inblk && /^[^ \t-]/ { inblk=0 }
    inblk && /^[ \t]*-[ \t]*/ {
      v=$0
      sub(/^[ \t]*-[ \t]*/, "", v)
      sub(/[ \t]*#.*$/, "", v)
      gsub(/[ \t]/, "", v)
      if (length(v)>0) print v
    }
  ' "$file"
}

# ledger_active_ids
#   Prints, one per line, the ids of all entries that are NOT superseded by any
#   real entry. Supersession is computed dynamically: scan every entry's
#   supersedes edges to build the superseded set, then emit entries absent from
#   it. No assoc arrays (bash 3.2): membership via grep over a newline list.
#   The stored `status:` field and any `superseded_by:` field are IGNORED — the
#   only source of truth is real supersedes edges.
#   $1 (optional) = repo root (defaults to pwd -P).
ledger_active_ids() {
  local root="${1:-$(pwd -P)}"
  local dir="$root/.claude/ledger"
  [ -d "$dir" ] || return 0

  # Build the superseded set (newline-delimited) from all real supersedes edges.
  local superseded="" id
  for id in $(_ledger_entry_ids "$dir"); do
    local s
    s=$(_ledger_supersedes_of "$dir/$id.yaml")
    if [ -n "$s" ]; then
      superseded="$superseded
$s"
    fi
  done

  # Emit ids not present in the superseded set.
  for id in $(_ledger_entry_ids "$dir"); do
    if printf '%s\n' "$superseded" | grep -qx "$id"; then
      continue
    fi
    printf '%s\n' "$id"
  done
}
