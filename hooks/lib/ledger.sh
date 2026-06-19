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

  # RETURN-CODE FIREWALL: consult the conflict check, but its exit status must be
  # STRUCTURALLY unable to reach add's control flow. We capture only its stdout
  # (the flag text) into a variable, with `|| true` swallowing ANY non-zero exit
  # — including a hit, or the check erroring on a corrupt ledger. There is no
  # `if`/`return` on the check's status anywhere below: a conflict can never
  # block an entry. Computed BEFORE the write so the new entry is not yet in the
  # active set and cannot self-flag.
  local conflict_flag
  conflict_flag=$( printf '%s' "$body" | ledger_check_conflict "$root" 2>/dev/null || true )

  mkdir -p "$dir" || return 1
  printf '%s\n' "$body" > "$file" || return 1

  # Only after a SUCCESSFUL write do we surface the advisory warning, and only to
  # stderr — never stdout, never into the entry file. A failed add emits nothing.
  if [ -n "$conflict_flag" ]; then
    printf '%s\n' "$conflict_flag" >&2
  fi
  return 0
}

# _ledger_rejected_of <file>
#   Emits this entry's rejected items, one per line, as "option\twhy" (tab-sep).
#   Reuses the rejected-block awk pattern from ledger-resume.sh (list of maps:
#   "  - option: X" then "    why: Y"). why may be empty.
_ledger_rejected_of() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    function flush() {
      if (have_opt) { printf "%s\t%s\n", opt, why; have_opt=0; opt=""; why="" }
    }
    /^rejected:[ \t]*$/ { inrej=1; next }
    inrej && /^[^ \t]/ { flush(); inrej=0 }
    inrej && /^[ \t]*-?[ \t]*option:[ \t]*/ {
      flush()
      v=$0; sub(/^[ \t]*-?[ \t]*option:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      opt=v; have_opt=1; next
    }
    inrej && /^[ \t]*why:[ \t]*/ {
      v=$0; sub(/^[ \t]*why:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
      why=v
    }
    END { flush() }
  ' "$file"
}

# _ledger_norm <string>
#   Conservative normalization for conflict matching: trim, lowercase, collapse
#   internal whitespace runs to a single space. bash 3.2: lowercasing via tr
#   (NOT ${var^^}). Deliberately loose — false positives are cheap, a missed
#   drift is the expensive failure we exist to prevent.
_ledger_norm() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | awk '{ $1=$1; print }'
}

# ledger_check_conflict [root]   (draft entry body on stdin)
#   Read-only drift check. Reads a draft YAML body on stdin and scans every
#   ACTIVE decision's rejected options. If the draft's claim re-proposes an
#   option that an active decision previously rejected (loose, bidirectional
#   substring match on normalized text), prints a "review required" flag line to
#   stdout naming the rejecter id and its recorded why — one line per hit.
#   Returns 0 when there is no conflict, non-zero (a review-required SIGNAL, not
#   a veto) when at least one hit is found. Writes nothing, mutates nothing.
#   $1 (optional) = repo root (defaults to pwd -P).
ledger_check_conflict() {
  local root="${1:-$(pwd -P)}"
  local dir="$root/.claude/ledger"
  local body
  body=$(cat)

  local claim claim_n
  claim=$(_yaml_scalar "$body" claim)
  [ -n "$claim" ] || return 0
  claim_n=$(_ledger_norm "$claim")

  local hit=0 id
  for id in $(ledger_active_ids "$root"); do
    local file="$dir/$id.yaml"
    [ -f "$file" ] || continue
    local line opt why opt_n
    while IFS=$'\t' read -r opt why; do
      [ -n "$opt" ] || continue
      opt_n=$(_ledger_norm "$opt")
      case "$claim_n" in *"$opt_n"*)
        printf '[ledger] review required: %s previously rejected this option — why: %s\n' "$id" "$why"
        hit=1
        continue ;;
      esac
      case "$opt_n" in *"$claim_n"*)
        printf '[ledger] review required: %s previously rejected this option — why: %s\n' "$id" "$why"
        hit=1 ;;
      esac
    done <<EOF
$(_ledger_rejected_of "$file")
EOF
  done

  [ "$hit" -eq 0 ]
}

# _ledger_evidence_files <file>
#   Emits the file paths listed in this entry's `evidence.files`, one per line,
#   each trimmed. Supports inline flow `files: [a, b]` and block form
#   `files:\n  - a\n  - b`, nested under the top-level `evidence:` block. Reuses
#   the same nested-key awk pattern as ledger_validate_entry's evidence.commits.
#   Empty output if the field is absent or empty.
_ledger_evidence_files() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^evidence:[ \t]*$/ { inev=1; next }
    inev && /^[^ \t]/ { inev=0 }
    # inline flow form: files: [a, b]
    inev && /^[ \t]+files:[ \t]*\[/ {
      v=$0
      sub(/^[ \t]+files:[ \t]*\[/, "", v)
      sub(/\].*$/, "", v)
      n=split(v, a, ",")
      for (i=1; i<=n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", a[i])
        if (length(a[i])>0) print a[i]
      }
      next
    }
    # block form: open the files list, read following `    - path` lines
    inev && /^[ \t]+files:[ \t]*$/ { inf=1; next }
    inf && /^[ \t]+[a-z_]+:/ { inf=0 }
    inf && /^[^ \t]/ { inf=0 }
    inf && /^[ \t]*-[ \t]*/ {
      v=$0
      sub(/^[ \t]*-[ \t]*/, "", v)
      sub(/[ \t]*#.*$/, "", v)
      sub(/^[ \t]+|[ \t]+$/, "", v)
      if (length(v)>0) print v
    }
  ' "$file"
}

# ledger_check_scope_conflicts [root]   (no stdin)
#   Read-only structural-drift check over the EXISTING ledger. The active set
#   already guarantees no supersedes edge between any two active entries
#   (ledger_active_ids), so the trigger collapses to: any two ACTIVE decisions
#   whose evidence.files intersect (exact path match) are both governing the
#   same ground — in an append-only world one should supersede the other. For
#   every unordered active pair with a non-empty file intersection, prints one
#   "review required" line naming both ids and the shared file(s). Returns 0 when
#   no such pair exists, non-zero (a review-required SIGNAL, not a veto) when at
#   least one does. Writes nothing, mutates nothing. bash 3.2: pair enumeration
#   via i<j index loop (no assoc arrays).
#   $1 (optional) = repo root (defaults to pwd -P).
ledger_check_scope_conflicts() {
  local root="${1:-$(pwd -P)}"
  local dir="$root/.claude/ledger"

  # Collect active ids into a positional array (bash 3.2: no assoc, no mapfile).
  local ids="" id
  for id in $(ledger_active_ids "$root"); do
    ids="$ids $id"
  done
  set -- $ids
  local n=$#

  local hit=0 i j
  i=1
  while [ "$i" -le "$n" ]; do
    j=$((i + 1))
    while [ "$j" -le "$n" ]; do
      local id_i id_j shared
      eval "id_i=\${$i}"
      eval "id_j=\${$j}"
      # exact-match intersection of the two entries' evidence.files (trimmed).
      shared=$(
        { _ledger_evidence_files "$dir/$id_i.yaml"
          _ledger_evidence_files "$dir/$id_j.yaml"
        } | sort | uniq -d
      )
      if [ -n "$shared" ]; then
        local f
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          printf '[ledger] review required: %s and %s are both active over %s — should one supersede the other?\n' \
            "$id_i" "$id_j" "$f"
        done <<EOF
$shared
EOF
        hit=1
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  [ "$hit" -eq 0 ]
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
