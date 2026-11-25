#!/usr/bin/env bash
# Qwen3.6 one-shot installer.
#
# Usage (as your normal user, not root; sudo is used where needed):
#   ./install.sh                 install, or continue after a reboot
#   ./install.sh --update        also pull and rebuild llama.cpp, and rebuild the sandbox (latest OpenCode)
#   ./install.sh --commands      only (re)write the commands in bin/ and the OpenCode config
#   ./install.sh --cleanup-old   Pop!_OS: delete files left by the earlier manual setup
#
# Settings are in install.conf. Safe to re-run at any time: every step checks
# what's already done. Phase 1 (system packages, driver, Docker) usually needs
# one reboot; run ./install.sh again afterwards and it continues with phase 2.
set -euo pipefail
export DOCKER_HOST=unix:///var/run/docker.sock   # build on the system Docker, whatever the shell's Docker context
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/phase1-system.sh"
. "$HERE/lib/phase2-stack.sh"
. "$HERE/lib/write-commands.sh"
. "$HERE/lib/cleanup-old.sh"

case "${1:-}" in
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  ""|--cleanup-old|--update|--commands) ;;
  *) die "Unknown option: $1 (try --help)" ;;
esac
load_config "$HERE"
move_old_install "$HOME/Development/qwen-coding-stack" "$QCS" qwen-stack
start_logging

UPDATE=no
case "${1:-}" in
  "") ;;
  --cleanup-old) cleanup_old; exit 0 ;;
  --update) UPDATE=yes ;;
  --commands) write_commands; "$QCS/bin/write-opencode-config"; exit 0 ;;
esac
keep_sudo_alive

phase1 "$HERE"
if reboot_needed; then
  offer_reboot
  exit 0
fi
phase2
