#!/bin/bash
# v3 lib/user-config.sh — seed the version-controlled user-level runtime files
# (user-config/CLAUDE.md, user-config/agents/*.md) into ~/.claude/ on a fresh
# machine, so a normal install also lands the collaboration discipline + agent
# definitions. bash 3.2 compatible. No LLM, no network.
#
# Convention (same as lib/settings-merge.sh, lib/menu.sh): status via return
# code (0=ok), data via stdout.
#
# copy-if-absent: an existing dest file is NEVER overwritten, so there is no
# backup logic to carry (unlike apply_statusline) — the original is untouched
# by construction.

# deploy_user_config <src_dir> <dest_dir>
#   SIDE-EFFECTING orchestrator: walk every file under <src_dir> (recursive,
#   preserving relative paths) and seed it into <dest_dir> at the matching
#   relative path.
#     - dest file ABSENT  -> mkdir -p its parent, cp it over, print
#                            `seeded <rel>`.
#     - dest file PRESENT -> skip (never overwrite), print
#                            `exists — skipped <rel>`.
#   Both src and dest are injected purely by argument (tests point them at
#   mktemp dirs, never the real ~/.claude/). Returns 0.
deploy_user_config() {
  local src="$1" dest="$2" abs rel
  while IFS= read -r abs; do
    rel="${abs#$src/}"
    if [ -e "$dest/$rel" ]; then
      printf 'exists — skipped %s\n' "$rel"
    else
      mkdir -p "$(dirname "$dest/$rel")"
      cp "$abs" "$dest/$rel"
      printf 'seeded %s\n' "$rel"
    fi
  done <<EOF
$(find "$src" -type f)
EOF
  return 0
}
