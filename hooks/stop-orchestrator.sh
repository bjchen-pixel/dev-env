#!/bin/bash
# v3-005 hooks/stop-orchestrator.sh — Stop hook. bash 3.2 compatible.
# NO LLM, NO network. Unconditionally refresh the file-backed session handoff,
# then exit 0. A Stop hook must never block (no exit 2 / no exit 1 here).

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/lib/write-handoff.sh"

# Drain stdin (Claude Code feeds a JSON payload); we don't need its contents.
cat >/dev/null 2>&1 || true

write_handoff "session-stop" || true

exit 0
