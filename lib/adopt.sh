#!/bin/bash
# v3-007 lib/adopt.sh — Mode B: "adopt" the workflow guard into a TARGET repo.
# bash 3.2 compatible. No LLM, no network. Pure merge/idempotency logic is
# side-effect free (testable against fixtures); the only side-effecting
# functions copy files / write the target settings, and degrade safely when jq
# is absent.
#
# Convention (same as lib/preflight.sh, lib/settings-merge.sh, hooks/lib):
# status via return code (0=true/ok), data via stdout.

# adopt_hook_command <script-rel>
#   PURE: builds the `command` string for a hook entry in the TARGET repo's
#   .claude/settings.json. The literal `$(git rev-parse --show-toplevel)` is
#   kept VERBATIM (single-quoted here, NOT expanded) so the target repo resolves
#   its own root at hook time — the portability key (move the target repo and the
#   path still resolves). Matches this repo's .claude/settings.json shape.
adopt_hook_command() {
  printf 'bash "$(git rev-parse --show-toplevel)/hooks/%s"' "$1"
}

# adopt_merged_settings_json <file>
#   PURE (jq): prints the merged target settings JSON wiring the three workflow
#   hooks — SessionStart / PreToolUse(Edit|Write) / Stop — each with the literal
#   $(git rev-parse ...) command and timeout 30. Every existing top-level key and
#   every existing (non-workflow) hook entry of <file> is preserved untouched.
#   IDEMPOTENT: an event's group is appended ONLY if no existing hook in that
#   event already carries the desired command, so reruns never duplicate it.
#   Executes NO write. A missing/empty <file> is treated as `{}`. Requires jq.
adopt_merged_settings_json() {
  local file="$1" base="{}" ss pt st
  if [ -s "$file" ]; then
    base=$(cat "$file")
  fi
  ss=$(adopt_hook_command "session-start-context.sh")
  pt=$(adopt_hook_command "pre-edit-guard.sh")
  st=$(adopt_hook_command "stop-orchestrator.sh")
  printf '%s' "$base" | jq \
    --arg ss "$ss" --arg pt "$pt" --arg st "$st" '
    # add_hook(event; group): append group to .hooks[event] unless some existing
    # hook entry there already has the same command (idempotent).
    def add_hook($event; $group):
      (.hooks // {}) as $h
      | ($h[$event] // []) as $arr
      | ([ $arr[].hooks[]?.command ] | index($group.hooks[0].command)) as $dup
      | if $dup == null
        then .hooks = ($h + {($event): ($arr + [$group])})
        else . end ;
    add_hook("SessionStart";
             {hooks: [{type:"command", command:$ss, timeout:30}]})
    | add_hook("PreToolUse";
             {matcher:"Edit|Write", hooks: [{type:"command", command:$pt, timeout:30}]})
    | add_hook("Stop";
             {hooks: [{type:"command", command:$st, timeout:30}]})
  '
}

# adopt_hooks_present <file>
#   PURE (jq): returns 0 iff ALL THREE workflow hook commands are already wired in
#   <file>'s hooks (SessionStart/session-start-context.sh, PreToolUse/pre-edit-
#   guard.sh, Stop/stop-orchestrator.sh); 1 otherwise (none/partial/absent/bad
#   file). Idempotency primitive: orchestrator no-ops the settings write when 0.
adopt_hooks_present() {
  local file="$1"
  [ -s "$file" ] || return 1
  jq -e '
    ([ .hooks.SessionStart[]?.hooks[]?.command ] | any(test("session-start-context.sh")))
    and ([ .hooks.PreToolUse[]?.hooks[]?.command ] | any(test("pre-edit-guard.sh")))
    and ([ .hooks.Stop[]?.hooks[]?.command ]       | any(test("stop-orchestrator.sh")))
  ' "$file" >/dev/null 2>&1
}

# adopt_paste_block <file>
#   PURE: prints a COPY-PASTEABLE complete three-hook JSON block (SessionStart /
#   PreToolUse Edit|Write / Stop), each command being the literal
#   $(git rev-parse --show-toplevel)/hooks/<script> form with timeout 30, plus
#   where to paste it and a restore note. Used by the no-jq (candidate (b))
#   degrade path — we never silently rewrite the target settings there. The inner
#   double-quotes are JSON-escaped (\") and the $(...) is single-quoted so it is
#   NOT expanded by this shell.
adopt_paste_block() {
  local file="$1"
  printf 'jq not found: not merging %s automatically.\n' "$file"
  printf 'Merge this "hooks" block into %s by hand (keep your other keys/hooks):\n' "$file"
  cat <<'EOF'
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"$(git rev-parse --show-toplevel)/hooks/session-start-context.sh\"", "timeout": 30 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "bash \"$(git rev-parse --show-toplevel)/hooks/pre-edit-guard.sh\"", "timeout": 30 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash \"$(git rev-parse --show-toplevel)/hooks/stop-orchestrator.sh\"", "timeout": 30 } ] }
    ]
  }
EOF
  printf 'To restore later: delete those three workflow hook entries from %s.\n' "$file"
}

# copy_workflow_files <src-root> <target-root>
#   SIDE-EFFECTING: copy the WHOLE hooks/ tree (including hooks/lib/) and
#   templates/policy.json from <src-root> into <target-root> at the matching
#   locations (<target>/hooks/, <target>/templates/policy.json). Creates parent
#   dirs as needed. cp -R overwrites existing copies, so reruns are safe
#   (idempotent: same bytes land again). Returns non-zero if src files are
#   missing. Does NOT touch any user-level ~/.claude/ — Mode B only writes inside
#   the target repo.
copy_workflow_files() {
  local src="$1" target="$2"
  [ -d "$src/hooks" ] || return 1
  [ -f "$src/templates/policy.json" ] || return 1
  mkdir -p "$target/hooks" "$target/templates" || return 1
  cp -R "$src/hooks/." "$target/hooks/" || return 1
  cp "$src/templates/policy.json" "$target/templates/policy.json" || return 1
  return 0
}

# adopt_has_jq
#   PURE: 0 iff jq is resolvable in the CURRENT shell's PATH (fresh command -v, no
#   caching assumptions) so a masked PATH genuinely degrades.
adopt_has_jq() {
  command -v jq >/dev/null 2>&1
}

# adopt_repo <src-root> <target-root>
#   SIDE-EFFECTING orchestrator for Mode B. Steps:
#     1. Validate <target-root>: must exist, be a directory, and be a git repo
#        (the injected hooks rely on $(git rev-parse --show-toplevel), so a
#        non-git target would wire hooks that never resolve — fail loud, return
#        non-zero, touch nothing). Path missing / not a dir -> same.
#     2. Copy the hooks tree + templates/policy.json (file copy needs no jq).
#     3. Ensure <target>/.claude/ exists (auto-create on first adopt).
#     4. Settings merge into <target>/.claude/settings.json:
#        - jq absent -> DO NOT write; print the copy-pasteable three-hook block
#          (candidate (b) degrade). Return 0 (files were still copied).
#        - already fully wired -> NO-OP (no backup, no write). Return 0.
#        - otherwise -> back up an existing settings file, then write the merged
#          JSON (other keys + foreign hooks preserved). Return 0.
#   Only writes inside <target-root>; never touches user-level ~/.claude/.
adopt_repo() {
  local src="$1" target="$2" settings merged tmp bak
  if [ ! -d "$target" ]; then
    printf 'ERROR: adopt target "%s" does not exist or is not a directory.\n' "$target" >&2
    return 1
  fi
  if ! git -C "$target" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'ERROR: adopt target "%s" is not a git repository.\n' "$target" >&2
    printf 'Mode B wires hooks via $(git rev-parse --show-toplevel); the target must be a git repo.\n' >&2
    return 1
  fi
  copy_workflow_files "$src" "$target" || {
    printf 'ERROR: failed to copy workflow files into "%s".\n' "$target" >&2
    return 1
  }
  printf 'Copied hooks/ and templates/policy.json into %s\n' "$target"
  mkdir -p "$target/.claude" || return 1
  settings="$target/.claude/settings.json"
  if ! adopt_has_jq; then
    adopt_paste_block "$settings"
    return 0
  fi
  if adopt_hooks_present "$settings"; then
    printf 'Workflow hooks already wired in %s — no-op.\n' "$settings"
    return 0
  fi
  if [ -f "$settings" ]; then
    bak="$settings.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    [ -e "$bak" ] && bak="$bak.$$"
    cp "$settings" "$bak"
    printf 'Backed up existing settings to %s\n' "$bak"
  fi
  merged=$(adopt_merged_settings_json "$settings") || return 1
  tmp=$(mktemp)
  printf '%s\n' "$merged" > "$tmp"
  mv "$tmp" "$settings"
  printf 'Wired the three workflow hooks into %s\n' "$settings"
  return 0
}
