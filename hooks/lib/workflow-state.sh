#!/bin/bash
# v3-005 hooks/lib/workflow-state.sh — shared workflow-state helpers.
# bash 3.2 compatible. No LLM, no network.
#
# Convention: status via return code (0=ok/true, non-0=fail/false);
#             data via stdout.

# get_active_plan
#   Reads .ai/harness/active-plan marker (relative to repo root = $1, or CWD).
#   Marker line 1 = plan path (relative to repo root); line 2 = canonical repo root.
#   Returns 0 and prints plan path on stdout if a valid active plan exists.
#   Returns 1 (no stdout) if: no marker / plan file missing / worktree root mismatch.
#
#   $1 (optional) = canonical repo root. Defaults to `pwd -P`.
get_active_plan() {
  local root="${1:-$(pwd -P)}"
  local marker="$root/.ai/harness/active-plan"
  [ -f "$marker" ] || return 1

  local plan_rel marker_root
  plan_rel=$(sed -n '1p' "$marker")
  marker_root=$(sed -n '2p' "$marker")
  [ -n "$plan_rel" ] || return 1

  # worktree consistency: canonical-compare marker root vs current root.
  if [ -n "$marker_root" ] && [ -d "$marker_root" ]; then
    local marker_root_c
    marker_root_c=$(cd "$marker_root" && pwd -P) || return 1
    [ "$marker_root_c" = "$root" ] || return 1
  else
    return 1
  fi

  [ -f "$root/$plan_rel" ] || return 1
  printf '%s' "$plan_rel"
  return 0
}

# contract_allows_path <contract_file> <file_path_rel>
#   Parses the FIRST ```yaml ... ``` block of contract_file, extracts the list
#   items under `allowed_paths:` (lines of the form `  - xxx`), strips inline
#   `#` comments and surrounding whitespace. Match rule:
#     - item ends with `/` => prefix match  (case "$rel" in "$item"*)
#     - otherwise          => glob match    (case "$rel" in $item)
#   Returns 0 if any item matches, 1 otherwise.
contract_allows_path() {
  local contract_file="$1" rel="$2"
  [ -f "$contract_file" ] || return 1

  local items
  items=$(awk '
    /^```yaml[ \t]*$/ { if (!seen) { inblock=1; seen=1; next } }
    inblock && /^```/ { inblock=0 }
    inblock && inlist {
      if ($0 ~ /^[ \t]+-[ \t]*/) { print; next }
      else { inlist=0 }
    }
    inblock && /^allowed_paths:[ \t]*$/ { inlist=1 }
  ' "$contract_file")

  local line item
  IFS='
'
  for line in $items; do
    # strip leading "  - ", inline "# ..." comment, surrounding whitespace.
    item=$line
    item=${item#*-}
    item=${item%%#*}
    # trim leading/trailing whitespace (bash 3.2 safe)
    item="$(printf '%s' "$item" | sed 's/^[ \t]*//; s/[ \t]*$//')"
    [ -n "$item" ] || continue
    case "$item" in
      */)
        case "$rel" in "$item"*) unset IFS; return 0 ;; esac
        ;;
      *)
        case "$rel" in $item) unset IFS; return 0 ;; esac
        ;;
    esac
  done
  unset IFS
  return 1
}

# get_plan_status <plan_file>
#   Prints the first **Status**: field value (trimmed) on stdout, returns 0.
#   Returns 1 (no stdout) if file missing or no Status field found.
get_plan_status() {
  local plan_file="$1"
  [ -f "$plan_file" ] || return 1
  local status
  status=$(awk '/\*\*Status\*\*:/ {sub(/^.*\*\*Status\*\*:[ \t]*/,""); sub(/[ \t]*$/,""); print; exit}' "$plan_file")
  [ -n "$status" ] || return 1
  printf '%s' "$status"
  return 0
}
