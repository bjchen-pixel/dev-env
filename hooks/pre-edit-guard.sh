#!/bin/bash
# v3-005 pre-edit-guard.sh — PreToolUse on Edit|Write. bash 3.2 compatible.
# No LLM, no network. Block = exit 2 (stderr); allow = exit 0.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/lib/workflow-state.sh"

# --- read stdin payload ------------------------------------------------------
STDIN=$(cat)

# extract a string value of "file_path" from the flat tool_input.
# jq primary; awk fallback (narrow target, not a general JSON parser).
extract_file_path() {
  local v=""
  if command -v jq >/dev/null 2>&1; then
    v=$(printf '%s' "$STDIN" | jq -r '.tool_input.file_path // .file_path // empty' 2>/dev/null)
  fi
  if [ -z "$v" ]; then
    v=$(printf '%s' "$STDIN" \
      | awk 'match($0,/"file_path"[ \t]*:[ \t]*"/){
               s=substr($0,RSTART+RLENGTH); out="";
               for(i=1;i<=length(s);i++){c=substr(s,i,1);
                 if(c=="\\"){i++; out=out substr(s,i,1); continue}
                 if(c=="\""){print out; exit} out=out c}}')
  fi
  printf '%s' "$v"
}

FILE_PATH=$(extract_file_path)
# fail-soft: no file_path -> allow.
[ -n "$FILE_PATH" ] || exit 0

# --- derive canonical repo root ---------------------------------------------
# prefer stdin .cwd, else git toplevel.
CWD=""
if command -v jq >/dev/null 2>&1; then
  CWD=$(printf '%s' "$STDIN" | jq -r '.cwd // empty' 2>/dev/null)
fi
[ -n "$CWD" ] || CWD=$(pwd)
ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
[ -n "$ROOT" ] || ROOT="$CWD"
ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) || exit 0

# --- relativize file_path to repo root (MUST-1) ------------------------------
# canonicalize the file_path's directory, then re-append basename.
fp_dir=$(dirname "$FILE_PATH")
fp_base=$(basename "$FILE_PATH")
fp_dir_c=$(cd "$fp_dir" 2>/dev/null && pwd -P)
# if the dir does not exist, fall back to raw path (cannot canonicalize).
if [ -n "$fp_dir_c" ]; then
  FILE_ABS="$fp_dir_c/$fp_base"
else
  FILE_ABS="$FILE_PATH"
fi

case "$FILE_ABS" in
  "$ROOT"/*) REL="${FILE_ABS#$ROOT/}" ;;
  *) exit 0 ;;   # outside repo root -> not in scope, allow.
esac

# --- workflow-surface bypass (MUST run before PlanStatusGuard) ----------------
# REL hitting a workflow surface (plans/ tasks/ docs/ .ai/ .claude/ prefix, or
# *.md suffix) is always allowed, silently, in any plan state. This resolves the
# stderr escape-hatch ("go edit the plan") which would otherwise be blocked.
case "$REL" in
  plans/*|tasks/*|docs/*|.ai/*|.claude/*|*.md) exit 0 ;;
esac

# --- gate mode ---------------------------------------------------------------
MODE="${V3_EDIT_PLAN_GATE:-advice}"

# --- PlanStatusGuard ---------------------------------------------------------
# allow-list semantics: only an active plan whose status is exactly "Approved"
# passes. No active plan / any other status (Draft/Annotating/typo/unknown) ->
# unapproved -> block (per mode).
PLAN=$(get_active_plan "$ROOT")
if [ -n "$PLAN" ]; then
  PLAN_DISPLAY="$PLAN"
  STATUS=$(get_plan_status "$ROOT/$PLAN")
  if [ -n "$STATUS" ]; then
    STATUS_DISPLAY="$STATUS"
  else
    STATUS_DISPLAY="(no Status field)"
  fi
else
  PLAN_DISPLAY="(none)"
  STATUS=""
  STATUS_DISPLAY="(no marker)"
fi

if [ "$STATUS" = "Approved" ]; then
  exit 0   # approved -> allow.
fi

# unapproved.
if [ "$MODE" = "enforce" ]; then
  cat >&2 <<EOF
[PlanStatusGuard] BLOCKED (automated quality gate, exit 2 — this is NOT a user rejection).

This repo's pre-edit gate requires an APPROVED plan before editing implementation files.
Reason: the active plan is not approved.
  - active plan: $PLAN_DISPLAY
  - current status: $STATUS_DISPLAY
  - blocked edit target: $REL

This is a deterministic workflow guard, not a human saying no. Do NOT stop and silently wait.
Do NOT edit the Status field yourself; approval is the orchestrator's step. To make progress,
do ONE of these:
  1. Stop editing implementation files and report to the orchestrator that this active plan
     is awaiting approval. Then retry this edit only after it is approved.
  2. Or edit a workflow surface instead (plans/, tasks/, docs/, .ai/, .claude/, *.md) — those
     are always allowed — e.g. improve the plan itself so it can be approved.
  3. Or, if this gate is misfiring, the user can set V3_EDIT_PLAN_GATE=advice (warn-only) or =off.
EOF
  exit 2
fi

exit 0
