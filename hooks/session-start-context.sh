#!/bin/bash
# v3-005 hooks/session-start-context.sh — SessionStart hook. bash 3.2 compatible.
# NO LLM, NO network. Content comes ONLY from reading local files.
#
# Reads .ai/harness/handoff/resume.md (Slice 3 output) and, if present,
# tasks/current.md, and prints them to stdout (exit 0 — Claude Code adds this
# to the session context).
#
# CRITICAL: the output is prefixed with a "recovery context only" disclaimer
# stating that if the user's current message contains real attachments / file
# paths / a concrete task, the agent MUST prioritise the user's input and not
# let this stale recovery state override the current task. exit 0 always — a
# SessionStart hook must never block (no exit 1 / no exit 2).

set -u

# Drain stdin (Claude Code feeds a JSON payload); we don't need its contents.
cat >/dev/null 2>&1 || true

root=$(pwd -P)
resume="$root/.ai/harness/handoff/resume.md"
current_task="$root/tasks/current.md"

# Emit the recovery-context-only disclaimer whenever ANY stale recovery file is
# present, so injected state is ALWAYS framed and never silently overrides the
# user's current task.
if [ -f "$resume" ] || [ -f "$current_task" ]; then
  printf '===== recovery context only (auto-injected by SessionStart hook) =====\n'
  printf 'This is recovery context only, reconstructed from the previous session.\n'
  printf 'If the user'"'"'s current message contains any real attachment, file path,\n'
  printf 'or concrete task, give priority to the user'"'"'s input — do NOT let this\n'
  printf 'stale recovery state override the current task.\n'
fi

if [ -f "$resume" ]; then
  printf '\n----- previous session handoff (resume.md) -----\n'
  cat "$resume"
fi

if [ -f "$current_task" ]; then
  printf '\n----- current task (tasks/current.md) -----\n'
  cat "$current_task"
fi

# Decision ledger negative space (v3-008). DISTINCT framing from the stale
# recovery context above: these are recorded, human-approved past decisions and
# are to be treated as standing constraints, NOT as stale state that the current
# input may override. Content is the ledger-resume.sh reader's output (reused,
# not reimplemented). The reader exits 0 and prints nothing when there is no
# active decision, so a non-empty capture is exactly the gate (active set
# non-empty), independent of resume.md / current task. stderr is discarded so a
# clean cold start never leaks anything.
ledger_resume="$(dirname "$0")/ledger-resume.sh"
ledger_negative_space=""
if [ -f "$ledger_resume" ]; then
  ledger_negative_space=$(bash "$ledger_resume" 2>/dev/null)
fi
if [ -n "$ledger_negative_space" ]; then
  printf '\n===== recorded decisions (human-approved) — standing constraints, flag for review =====\n'
  printf 'These are recorded, human-approved past decisions and their negative space.\n'
  printf 'Treat them as standing constraints: if your current work conflicts with one,\n'
  printf 'flag for review and let a human decide. Do NOT silently override them; you have\n'
  printf 'no authority to declare them invalid.\n'
  printf '\n----- decision ledger negative space -----\n'
  printf '%s\n' "$ledger_negative_space"
fi

exit 0
