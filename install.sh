#!/bin/bash
# v3-007 install.sh — cross-platform one-shot deployer (entry).
# bash 3.2 compatible. No LLM, no network (except git clone/pull in later
# slices). Slice 1 scope: preflight (dependency doctor) + dependency gate.
# Modes A/B, interactive menu, --update arrive in later slices.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/lib/preflight.sh"
. "$HERE/lib/settings-merge.sh"
. "$HERE/lib/adopt.sh"
. "$HERE/lib/menu.sh"

# Canonical absolute path to THIS clone's context-gauge.sh (Mode A points the
# user-level statusLine command here). Same HERE-based technique as Slice 1.
GAUGE_PATH="$HERE/statusline/context-gauge.sh"

# User-level settings target. Injectable via SETTINGS_FILE so tests never touch
# the real ~/.claude/. Defaults to the real user-level file otherwise.
SETTINGS_FILE="${SETTINGS_FILE:-$HOME/.claude/settings.json}"

# --- official download links for tools we NEVER auto-install -----------------
official_link() {
  case "$1" in
    git) printf 'https://git-scm.com/downloads' ;;
    claude|claude-code) printf 'https://docs.claude.com/en/docs/claude-code/overview' ;;
    *) printf '' ;;
  esac
}

# --- arg parse ---------------------------------------------------------------
AUTO=0
PREFLIGHT_ONLY=0
MODE_A=0
ADOPT_TARGET=""
DO_ADOPT=0
DO_UPDATE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --auto|--yes) AUTO=1 ;;
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    --mode-a) MODE_A=1 ;;
    --update) DO_UPDATE=1 ;;
    --adopt)
      # value arg: the NEXT token is the target repo path.
      if [ "$#" -lt 2 ]; then
        printf 'ERROR: --adopt requires a target repository path: install.sh --adopt <repo>\n' >&2
        exit 2
      fi
      DO_ADOPT=1
      ADOPT_TARGET="$2"
      shift
      ;;
    --help|-h)
      cat <<EOF
Usage: install.sh [--auto] [--preflight-only] [--mode-a] [--adopt <repo>] [--update]
  --auto             non-interactive; auto-consent to optional installs
  --preflight-only   run dependency doctor only, then exit
  --update           refresh this clone (git pull --ff-only) then idempotently
                     re-apply Mode A. Mode B repos are not tracked; prints a hint
                     to re-run --adopt on each. Then exits.
  --mode-a           machine-level install: merge the global statusLine into
                     the user-level ~/.claude/settings.json (points at this
                     clone's context-gauge.sh). Backs up first; idempotent.
  --adopt <repo>     Mode B: adopt the workflow guard into the TARGET git repo
                     (copies hooks/ + templates/policy.json and wires the three
                     workflow hooks into <repo>/.claude/settings.json). The
                     target must be a git repo; idempotent. Then exits.
EOF
      exit 0
      ;;
    *) ;;   # unknown flags are ignored (forward-compatible)
  esac
  shift
done

# --- preflight ---------------------------------------------------------------
printf 'Preflight — dependency check:\n'
preflight_report

# --- required-dependency gate ------------------------------------------------
# git is required AND is the bootstrap tool: never auto-installed. If absent,
# print the official link and stop (non-zero). Same for any required dep when no
# package manager is detected.
PKG_MGR=$(detect_pkg_manager)

gate_failed=0
for dep in $PREFLIGHT_DEPS; do
  [ "$(dep_tier "$dep")" = "required" ] || continue
  dep_present "$dep" && continue
  # a required dep is missing.
  if [ "$dep" = "git" ] || [ "$dep" = "bash" ]; then
    printf '\nERROR: required dependency "%s" is missing and cannot be auto-installed (bootstrap tool).\n' "$dep" >&2
    printf 'Install it from: %s\n' "$(official_link "$dep")" >&2
    gate_failed=1
    continue
  fi
  if [ -z "$PKG_MGR" ]; then
    printf '\nERROR: required dependency "%s" is missing and no package manager was detected.\n' "$dep" >&2
    printf 'Install it manually: %s\n' "$(official_link "$dep")" >&2
    gate_failed=1
  fi
done

if [ "$gate_failed" -eq 1 ]; then
  exit 1
fi

# --- optional dependencies (jq): offer to install, never block ---------------
# detect-only deps (claude) are reported by preflight_report and NEVER installed.
for dep in $PREFLIGHT_DEPS; do
  [ "$(dep_tier "$dep")" = "optional" ] || continue
  dep_present "$dep" && continue
  link=$(official_link "$dep")
  if [ -z "$PKG_MGR" ]; then
    printf '\nOptional dependency "%s" is missing and no package manager was detected; continuing (a fallback covers it).\n' "$dep"
    [ -n "$link" ] && printf 'To install it manually, see: %s\n' "$link"
    continue
  fi
  cmd=$(install_cmd_for "$PKG_MGR" "$dep") || cmd=""
  if [ -z "$cmd" ]; then
    printf '\nOptional dependency "%s" is missing; no known install command for "%s". Continuing.\n' "$dep" "$PKG_MGR"
    continue
  fi
  printf '\nOptional dependency "%s" is missing. The following command would install it:\n  %s\n' "$dep" "$cmd"
  answer=""
  if [ "$AUTO" -ne 1 ]; then
    printf 'Install it now? [y/N] '
    if [ -r /dev/tty ]; then
      read -r answer </dev/tty || answer=""
    else
      read -r answer || answer=""
    fi
  fi
  if should_install "$AUTO" "$answer"; then
    run_install "$cmd"
  else
    printf 'Skipped installing %s (a fallback covers the no-%s case).\n' "$dep" "$dep"
  fi
done

if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
  exit 0
fi

# --- --update: pull this clone, then idempotently re-apply Mode A ------------
# do_update separates the (network) pull from the idempotent reapply: it runs
# update_pull (the only network step) then re-applies apply_statusline (a no-op
# when already current). Mode B repos are not tracked; do_update prints a hint to
# re-adopt them. --update is an explicit mode: it does NOT enter the menu.
if [ "$DO_UPDATE" -eq 1 ]; then
  printf '\n--update — refreshing this clone and re-applying Mode A\n'
  do_update "$HERE" "$SETTINGS_FILE" "$GAUGE_PATH"
  exit $?
fi

# --- Mode B: adopt the workflow guard into a TARGET git repo ------------------
# adopt_repo copies hooks/ + templates/policy.json into the target and wires the
# three workflow hooks into <target>/.claude/settings.json (literal
# $(git rev-parse ...) preserved; idempotent; fails loud on a non-git target).
# --adopt does ONLY the adopt, then exits with adopt_repo's return code.
if [ "$DO_ADOPT" -eq 1 ]; then
  printf '\nMode B — adopting the workflow guard into %s\n' "$ADOPT_TARGET"
  adopt_repo "$HERE" "$ADOPT_TARGET"
  exit $?
fi

# --- Mode A: machine-level statusLine merge ----------------------------------
# Merge the global statusLine into the user-level settings file, pointing at
# this clone's context-gauge.sh. apply_statusline backs up before writing, is
# idempotent, refuses to clobber broken JSON, and degrades (prints a paste
# block) when jq is absent.
if [ "$MODE_A" -eq 1 ]; then
  printf '\nMode A — wiring the global statusLine into %s\n' "$SETTINGS_FILE"
  apply_statusline "$SETTINGS_FILE" "$GAUGE_PATH"
  exit $?
fi

# --- interactive main menu ---------------------------------------------------
# No mode flag was given. In non-interactive --auto mode we never block on a
# menu (unattended runs must not hang on a read); otherwise present the menu and
# dispatch by the user's choice (read from stdin). run_menu calls apply_statusline
# (Mode A) / adopt_repo (Mode B) per the choice.
if [ "$AUTO" -eq 1 ]; then
  printf '\nPreflight complete. (--auto with no mode flag: nothing to do; pass --mode-a/--adopt/--update.)\n'
  exit 0
fi

printf '\n'
run_menu "$SETTINGS_FILE" "$GAUGE_PATH" "$HERE"
exit $?
