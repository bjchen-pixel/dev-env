#!/bin/bash
# v3-007 lib/menu.sh — Slice 4: interactive main menu + --update.
# bash 3.2 compatible. No LLM, no network (except the single git pull in
# update_pull, which is injectable/stubbable for tests). Pure choice-dispatch
# logic is side-effect free (testable); the side-effecting orchestrators
# (run_menu, do_update) dispatch into apply_statusline (Mode A) / adopt_repo
# (Mode B), which the caller must have sourced.
#
# Convention (same as lib/preflight.sh, lib/settings-merge.sh, lib/adopt.sh):
# status via return code (0=true/ok), data via stdout.

# menu_choice_to_modes <choice>
#   PURE heart of the interactive menu: normalize a user's menu choice into a
#   stable mode token printed on stdout. No tty, no file — the testable core.
#     a / A           -> a      (Mode A: machine-level statusLine)
#     b / B           -> b      (Mode B: adopt into a project)
#     both / ab / c   -> both   (do both)
#     q / quit / *    -> none   (quit / empty / anything else: do nothing)
menu_choice_to_modes() {
  case "$1" in
    a|A) printf 'a' ;;
    b|B) printf 'b' ;;
    both|ab|c|C) printf 'both' ;;
    *) printf 'none' ;;
  esac
}

# menu_read_line  -> reads ONE line from stdin and prints it. Reading from stdin
#   (not /dev/tty) keeps the menu input INJECTABLE: tests pipe the choice in on
#   stdin, and in real interactive use stdin IS the terminal. Using /dev/tty
#   would bypass a piped stdin and make the menu untestable, so stdin it is.
menu_read_line() {
  local line
  read -r line || line=""
  printf '%s' "$line"
}

# run_menu <settings_file> <gauge> <src_root>
#   SIDE-EFFECTING orchestrator for the interactive main menu. Prints the menu,
#   reads the user's choice (via menu_read_line: tty if available, else stdin),
#   normalizes it with menu_choice_to_modes, and dispatches:
#     a    -> apply_statusline <settings_file> <gauge>            (Mode A)
#     b    -> read a target repo line, adopt_repo <src> <target>  (Mode B)
#     both -> Mode A, then read target + Mode B
#     none -> do nothing
#   The caller must have sourced lib/settings-merge.sh and lib/adopt.sh.
# menu_seed_user_config <src_root>
#   SIDE-EFFECTING: seed the version-controlled user-level runtime files
#   (<src_root>/user-config/*) into the user-level Claude dir, copy-if-absent,
#   so the machine-setting menu choice lands them in one run (matching
#   install.sh --mode-a). Dest is CLAUDE_USER_DIR (injectable for tests; defaults
#   to ~/.claude). Requires the caller to have sourced lib/user-config.sh.
menu_seed_user_config() {
  local src_root="$1" dest
  dest="${CLAUDE_USER_DIR:-$HOME/.claude}"
  printf 'Seeding user-level runtime files into %s\n' "$dest"
  deploy_user_config "$src_root/user-config" "$dest"
}

run_menu() {
  local settings="$1" gauge="$2" src="$3" choice modes
  printf 'Choose what to install:\n'
  printf '  a)    machine-level (Mode A: wire the global statusLine)\n'
  printf '  b)    adopt into a project (Mode B: --adopt a target repo)\n'
  printf '  both) do both\n'
  printf '  q)    quit / skip\n'
  printf 'Your choice [a/b/both/q]: '
  choice=$(menu_read_line)
  modes=$(menu_choice_to_modes "$choice")
  local target
  case "$modes" in
    a)
      apply_statusline "$settings" "$gauge"
      menu_seed_user_config "$src"
      ;;
    b)
      printf 'Target git repository to adopt into: '
      target=$(menu_read_line)
      adopt_repo "$src" "$target"
      ;;
    both)
      apply_statusline "$settings" "$gauge"
      menu_seed_user_config "$src"
      printf 'Target git repository to adopt into: '
      target=$(menu_read_line)
      adopt_repo "$src" "$target"
      ;;
  esac
}

# update_pull <repo_root>
#   SIDE-EFFECTING (the ONLY network step): update THIS clone. If UPDATE_PULL_CMD
#   is set (tests / overrides), eval it INSTEAD of the real pull — so the pull
#   step is observable without touching the network. Otherwise run a real
#   fast-forward-only pull (`git -C <root> pull --ff-only`), the safer form: it
#   refuses to create a merge commit on local divergence rather than risking a
#   conflicted state. This real-pull line is covered by `bash -n` + a manual
#   smoke run, NOT by the automated tests (network side effect).
update_pull() {
  local root="$1"
  if [ -n "${UPDATE_PULL_CMD:-}" ]; then
    eval "$UPDATE_PULL_CMD"
    return $?
  fi
  git -C "$root" pull --ff-only
}

# do_update <repo_root> <settings_file> <gauge>
#   SIDE-EFFECTING orchestrator for --update: (1) update this clone via
#   update_pull (the only network step, stubbable), then (2) idempotently
#   re-apply Mode A (apply_statusline — a no-op when already up to date, so a
#   rerun is safe). The caller must have sourced lib/settings-merge.sh.
do_update() {
  local root="$1" settings="$2" gauge="$3"
  printf 'Updating this clone...\n'
  update_pull "$root"
  printf 'Re-applying Mode A (machine-level statusLine)...\n'
  apply_statusline "$settings" "$gauge"
  # Mode B target repos are not tracked (no registry). Tell the user to refresh
  # each adopted project repo themselves — adopt_repo is idempotent, so re-running
  # --adopt after pulling is safe.
  printf '\nMode B (adopted project repos) are not tracked by --update.\n'
  printf 'For each repo you adopted, run: git -C <repo> pull && install.sh --adopt <repo>\n'
}
