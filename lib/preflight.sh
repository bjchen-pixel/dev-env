#!/bin/bash
# v3-007 lib/preflight.sh — deployer preflight (dependency doctor).
# bash 3.2 compatible. No LLM, no network. Pure detection/classification
# functions are side-effect free (testable without installing anything);
# the only side-effecting function is run_install, which is gated.
#
# Convention (same as hooks/lib): status via return code (0=true/ok),
# data via stdout.

# install_cmd_for <pkg_manager> <dep>
#   PURE mapping: given a package manager and a dependency, print the exact
#   install command STRING that would install it. Executes nothing.
#   Unknown combination -> empty stdout, return 1.
install_cmd_for() {
  local mgr="$1" dep="$2"
  case "$mgr" in
    brew) printf 'brew install %s' "$dep" ;;
    apt) printf 'sudo apt-get install -y %s' "$dep" ;;
    dnf) printf 'sudo dnf install -y %s' "$dep" ;;
    yum) printf 'sudo yum install -y %s' "$dep" ;;
    pacman) printf 'sudo pacman -S --noconfirm %s' "$dep" ;;
    zypper) printf 'sudo zypper install -y %s' "$dep" ;;
    winget) printf 'winget install jqlang.%s' "$dep" ;;
    *) return 1 ;;
  esac
}

# should_install <auto_flag> <answer>
#   PURE consent decision (input is injectable; no `read` here).
#     auto_flag=1 (--auto)  -> always 0 (install; unattended, never prompts).
#     auto_flag=0           -> install only on an affirmative answer
#                              (y/Y/yes/YES); anything else, INCLUDING empty
#                              (bare Enter), returns 1 (conservative: never
#                              silently escalate).
should_install() {
  local auto="$1" answer="$2"
  [ "$auto" = "1" ] && return 0
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# dep_tier <name>
#   Classifies a dependency:
#     required    -> needed to bootstrap; never auto-installed if it's the
#                    bootstrap tool itself (git/bash) -> print link and stop.
#     optional    -> nice to have; offer to install, but never block.
#     detect-only -> prerequisite tool we report but NEVER auto-install
#                    (Claude Code itself).
#   Unknown deps default to `optional` (the safe default: don't block on
#   something we don't recognize). Pure. Uses case (no `declare -A`; bash 3.2).
dep_tier() {
  case "$1" in
    git|bash) printf 'required' ;;
    jq) printf 'optional' ;;
    claude|claude-code) printf 'detect-only' ;;
    *) printf 'optional' ;;
  esac
}

# dep_present <name>
#   Returns 0 if the named dependency resolves on PATH, 1 otherwise. Pure.
dep_present() {
  command -v "$1" >/dev/null 2>&1
}

# run_install <cmd_string>
#   THE ONLY side-effecting function: executes the given install command
#   string. It performs NO consent decision of its own — callers MUST gate it
#   with should_install first. Kept tiny and separate so pure detection stays
#   testable without touching the system.
run_install() {
  local cmd="$1"
  [ -n "$cmd" ] || return 1
  eval "$cmd"
}

# dep_version <name>
#   Prints a best-effort one-line version string for the dependency (stdout),
#   or nothing if it can't be determined. Pure (only runs `<tool> --version`,
#   which reports a version and does not mutate state). Returns 0 always.
dep_version() {
  local name="$1" raw="" v=""
  dep_present "$name" || return 0
  raw=$("$name" --version 2>/dev/null)
  # first line only, via parameter expansion (no external `head`; bash 3.2 ok).
  v="${raw%%$'\n'*}"
  printf '%s' "$v"
  return 0
}

# PREFLIGHT_DEPS — the dependency set the report covers (space-separated; no
# associative arrays, bash 3.2). git/bash required, jq optional, claude
# detect-only.
PREFLIGHT_DEPS="git bash jq claude"

# preflight_report
#   Pure, side-effect-free layered report. For each dependency in
#   PREFLIGHT_DEPS, prints one line: "<status>  <name>  (<tier>)[  <version>]".
#   Writes nothing; deterministic across runs. Returns 0.
preflight_report() {
  local dep tier status ver
  for dep in $PREFLIGHT_DEPS; do
    tier=$(dep_tier "$dep")
    if dep_present "$dep"; then
      status="present"
      ver=$(dep_version "$dep")
    else
      status="missing"
      ver=""
    fi
    if [ -n "$ver" ]; then
      printf '%s  %s  (%s)  %s\n' "$status" "$dep" "$tier" "$ver"
    else
      printf '%s  %s  (%s)\n' "$status" "$dep" "$tier"
    fi
  done
  return 0
}

# detect_pkg_manager
#   Detects an available system package manager. Prints a single token on
#   stdout (brew/apt/dnf/yum/pacman/zypper/winget) and returns 0 on the first
#   hit; prints nothing and returns 1 if none is found. Pure: uses `command -v`
#   only, installs nothing.
detect_pkg_manager() {
  if command -v brew >/dev/null 2>&1; then printf 'brew'; return 0; fi
  if command -v apt-get >/dev/null 2>&1; then printf 'apt'; return 0; fi
  if command -v dnf >/dev/null 2>&1; then printf 'dnf'; return 0; fi
  if command -v yum >/dev/null 2>&1; then printf 'yum'; return 0; fi
  if command -v pacman >/dev/null 2>&1; then printf 'pacman'; return 0; fi
  if command -v zypper >/dev/null 2>&1; then printf 'zypper'; return 0; fi
  if command -v winget >/dev/null 2>&1; then printf 'winget'; return 0; fi
  return 1
}
