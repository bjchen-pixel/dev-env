#!/bin/bash
# v3-005 hooks/lib/write-handoff.sh — file-backed session handoff.
# bash 3.2 compatible. NO LLM, NO network. Everything is git/file-derived.
#
# write_handoff(reason):
#   Writes .ai/harness/handoff/resume.md (idempotent overwrite) with:
#     - generation time (UTC ISO8601) + reason
#     - active plan path + status (via get_active_plan / get_plan_status)
#     - changed files: (git diff --name-only HEAD) U (git ls-files --others
#       --exclude-standard), de-duplicated + sorted, truncated past 80 lines
#     - git diff --shortstat HEAD
#   Non-git repo: degrades to time + reason only (no git errors leak).

# Resolve and source workflow-state.sh relative to THIS file.
_WH_HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)
# shellcheck source=workflow-state.sh
. "$_WH_HERE/workflow-state.sh"

write_handoff() {
  local reason="${1:-unspecified}"
  local root
  root=$(pwd -P)

  local out_dir="$root/.ai/harness/handoff"
  local out="$out_dir/resume.md"
  mkdir -p "$out_dir" || return 1

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Detect git work tree. Non-git -> degrade to time + reason only.
  local is_git=0
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_git=1
  fi

  if [ "$is_git" -ne 1 ]; then
    {
      printf '# Session handoff (recovery context)\n\n'
      printf '%s\n' "- generated: $now"
      printf '%s\n' "- reason: $reason"
      printf '\n_(not a git repository — changed-files and diff-stat omitted)_\n'
    } > "$out"
    return 0
  fi

  # active plan + status (git/file-derived; allow-list display, no model text).
  local plan status
  plan=$(get_active_plan "$root")
  if [ -n "$plan" ]; then
    status=$(get_plan_status "$root/$plan")
    [ -n "$status" ] || status="(no Status field)"
  else
    plan="(none)"
    status="(no marker)"
  fi

  # changed files: union of tracked-modified and untracked, dedup + sorted.
  local changed total
  changed=$( { git diff --name-only HEAD 2>/dev/null
               git ls-files --others --exclude-standard 2>/dev/null
             } | sort -u )
  if [ -n "$changed" ]; then
    total=$(printf '%s\n' "$changed" | grep -c .)
  else
    total=0
  fi

  # git diff --shortstat HEAD (one line, leading whitespace trimmed).
  local shortstat
  shortstat=$(git diff --shortstat HEAD 2>/dev/null | sed 's/^[ \t]*//')

  {
    printf '# Session handoff (recovery context)\n\n'
    printf '%s\n' "- generated: $now"
    printf '%s\n' "- reason: $reason"
    printf '\n## Active plan\n\n'
    printf '%s\n' "- plan: $plan"
    printf '%s\n' "- status: $status"
    printf '\n## Changed files\n\n'
    if [ -n "$changed" ]; then
      printf '%s\n' "$changed" | head -80 | while IFS= read -r f; do
        [ -n "$f" ] && printf '%s\n' "- $f"
      done
      if [ "$total" -gt 80 ]; then
        printf '\n%s\n' "... (truncated, $total total)"
      fi
    fi
    printf '\n## Diff stat\n\n'
    if [ -n "$shortstat" ]; then
      printf '%s\n' "$shortstat"
    else
      printf '%s\n' "(no changes)"
    fi
  } > "$out"

  return 0
}
