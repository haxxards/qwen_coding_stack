#!/usr/bin/env bash
# Qwen3.8-27B one-shot installer.
#
# Usage (as your normal user, not root; sudo is used where needed):
#   ./install.sh             install, or continue after a reboot
#   ./install.sh --update    also pull and rebuild llama.cpp, and rebuild the sandbox (latest OpenCode)
#   ./install.sh --commands  only (re)write the commands in bin/ and the OpenCode config
#
# Settings are in install.conf. Safe to re-run at any time. Phase 1 (system
# packages, driver, Docker) may need one reboot; run ./install.sh again
# afterwards and it continues with phase 2. If the Qwen3.6 stack is already
# installed, phase 1 has nothing to do and no reboot is needed.
set -euo pipefail
export DOCKER_HOST=unix:///var/run/docker.sock   # build on the system Docker, whatever the shell's Docker context
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/phase1-system.sh"
. "$HERE/lib/phase2-stack.sh"
. "$HERE/lib/write-commands.sh"

case "${1:-}" in
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  ""|--update|--commands) ;;
  *) die "Unknown option: $1 (try --help)" ;;
esac
load_config "$HERE"
move_old_install "$HOME/Development/qwen38-coding-stack" "$Q38" qwen38-stack
start_logging

UPDATE=no
case "${1:-}" in
  "") ;;
  --update) UPDATE=yes ;;
  --commands) write_commands; "$Q38/bin/qwen38-write-opencode-config"; exit 0 ;;
esac
keep_sudo_alive

phase1 "$HERE"
if reboot_needed; then
  offer_reboot
  exit 0
fi
phase2
