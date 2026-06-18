#!/bin/bash
# v3-007 lib/settings-merge.sh — Mode A: merge the global statusLine key into
# the user-level ~/.claude/settings.json. bash 3.2 compatible. No LLM, no
# network. Pure merge/path/idempotency logic is side-effect free (testable
# against fixtures); the only side-effecting function is apply_statusline,
# which backs up before writing and degrades safely.
#
# Convention (same as lib/preflight.sh, hooks/lib): status via return code
# (0=true/ok), data via stdout.

# statusline_command <gauge_abs>
#   PURE: builds the statusLine `command` string. Mode A points it at the
#   locally-cloned gauge script (canonical absolute path), matching INSTALL.md
#   §7: `bash "<abs>"`. The double-quotes guard paths with spaces.
statusline_command() {
  printf 'bash "%s"' "$1"
}

# merged_settings_json <file> <gauge_abs>
#   PURE (jq): prints the merged settings JSON — every existing top-level key of
#   <file> preserved untouched, with statusLine set/replaced to point at the
#   local gauge. Executes NO write. A missing/empty <file> is treated as `{}`.
#   Requires jq; callers must check has_jq first and degrade otherwise.
merged_settings_json() {
  local file="$1" gauge="$2" base="{}" cmd
  if [ -s "$file" ]; then
    base=$(cat "$file")
  fi
  cmd=$(statusline_command "$gauge")
  printf '%s' "$base" | jq --arg cmd "$cmd" \
    '.statusLine = {"type": "command", "command": $cmd}'
}

# statusline_matches <file> <gauge_abs>
#   PURE (jq): returns 0 iff <file> already has a statusLine.command equal to the
#   desired local-gauge command; 1 otherwise (different, absent, or no file).
#   The idempotency primitive — apply_statusline no-ops when this returns 0.
statusline_matches() {
  local file="$1" gauge="$2" cmd existing
  [ -s "$file" ] || return 1
  cmd=$(statusline_command "$gauge")
  existing=$(jq -r '.statusLine.command // empty' "$file" 2>/dev/null) || return 1
  [ "$existing" = "$cmd" ]
}

# settings_is_valid_json <file>
#   PURE (jq): returns 0 if <file> is parseable JSON, OR is empty, OR is missing
#   (both empty/missing are treated downstream as `{}`); returns 1 only for a
#   present, NON-empty file that jq cannot parse. Guards apply_statusline from
#   clobbering settings it can't safely merge.
settings_is_valid_json() {
  local file="$1"
  [ -s "$file" ] || return 0
  if jq -e . "$file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# has_jq
#   PURE: 0 iff jq is resolvable in the CURRENT shell's PATH. A fresh `command
#   -v` (no caching assumptions) so a masked PATH genuinely degrades.
has_jq() {
  command -v jq >/dev/null 2>&1
}

# backup_settings <file>
#   SIDE-EFFECTING: if <file> exists, copy it to a timestamped sibling
#   `<file>.bak.<UTC>` so reruns never clobber a prior backup, and so the
#   original is always recoverable. Prints the backup path. No-op (return 0,
#   prints nothing) if the file does not exist.
backup_settings() {
  local file="$1" bak
  [ -f "$file" ] || return 0
  bak="$file.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  # avoid collision within the same second on rerun
  if [ -e "$bak" ]; then
    bak="$bak.$$"
  fi
  cp "$file" "$bak"
  printf '%s' "$bak"
}

# paste_block <file> <gauge_abs>
#   PURE: prints a COPY-PASTEABLE complete statusLine JSON block plus where to
#   paste it and a one-line restore instruction. Used by the no-jq (candidate
#   (b)) and bad-JSON degrade paths — we never silently rewrite the file there.
paste_block() {
  local file="$1" gauge="$2" cmd
  cmd=$(statusline_command "$gauge")
  printf 'Add this top-level key to %s (merge by hand, keep your other keys):\n' "$file"
  printf '  "statusLine": {\n'
  printf '    "type": "command",\n'
  printf '    "command": "bash \\"%s\\""\n' "$gauge"
  printf '  }\n'
  printf 'To restore later: delete the "statusLine" key from %s (or restore the .bak backup).\n' "$file"
}

# apply_statusline <file> <gauge_abs>
#   SIDE-EFFECTING orchestrator for Mode A. Steps:
#     1. If jq is absent -> DO NOT write; print a copy-pasteable JSON block +
#        where to paste + restore note (candidate (b) degrade). Return 0.
#     2. If <file> already has the identical statusLine -> NO-OP (no backup, no
#        write). Print a no-op line. Return 0 (idempotent rerun).
#     3. If <file> is present but UNPARSEABLE -> DO NOT clobber: back it up,
#        print an error + the copy-pasteable block, return non-zero (fail-soft).
#     4. Otherwise -> back up the existing file (if any), then write the merged
#        JSON (other keys preserved, statusLine set). Return 0.
apply_statusline() {
  local file="$1" gauge="$2" merged tmp
  if ! has_jq; then
    printf 'jq not found: not writing %s automatically.\n' "$file"
    paste_block "$file" "$gauge"
    return 0
  fi
  if statusline_matches "$file" "$gauge"; then
    printf 'statusLine already up to date in %s — no-op.\n' "$file"
    return 0
  fi
  local bak
  if ! settings_is_valid_json "$file"; then
    bak=$(backup_settings "$file")
    [ -n "$bak" ] && printf 'Backed up original to %s\n' "$bak" >&2
    printf 'ERROR: %s is not valid JSON; refusing to overwrite (backed up). Paste manually:\n' "$file" >&2
    paste_block "$file" "$gauge"
    return 1
  fi
  bak=$(backup_settings "$file")
  [ -n "$bak" ] && printf 'Backed up original to %s\n' "$bak"
  merged=$(merged_settings_json "$file" "$gauge") || return 1
  tmp=$(mktemp)
  printf '%s\n' "$merged" > "$tmp"
  mv "$tmp" "$file"
  printf 'Wrote statusLine into %s.\n' "$file"
  return 0
}
