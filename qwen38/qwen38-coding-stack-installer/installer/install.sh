#!/usr/bin/env bash
# qwen38-coding-stack one-shot installer (Qwen3.8-27B).
#
# Usage (as your normal user, not root; sudo is used where needed):
#   ./install.sh        install, or continue after a reboot
#
# Settings are in install.conf. Safe to re-run at any time. Phase 1 (system
# packages, driver, Docker) may need one reboot; run ./install.sh again
# afterwards and it continues with phase 2. If the Qwen3.6 stack is already
# installed, phase 1 has nothing to do and no reboot is needed.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/phase1-system.sh"
. "$HERE/lib/phase2-stack.sh"
. "$HERE/lib/write-commands.sh"

load_config "$HERE"
start_logging
keep_sudo_alive

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  *) die "Unknown option: $1 (try --help)" ;;
esac

phase1 "$HERE"
if reboot_needed; then
  offer_reboot
  exit 0
fi
phase2
