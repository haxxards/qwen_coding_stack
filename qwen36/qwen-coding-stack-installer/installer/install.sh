#!/usr/bin/env bash
# qwen-coding-stack one-shot installer.
#
# Usage (as your normal user, not root; sudo is used where needed):
#   ./install.sh                 install, or continue after a reboot
#   ./install.sh --cleanup-old   Pop!_OS: delete files left by the earlier manual setup
#
# Settings are in install.conf. Safe to re-run at any time: every step checks
# what's already done. Phase 1 (system packages, driver, Docker) usually needs
# one reboot; run ./install.sh again afterwards and it continues with phase 2.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/phase1-system.sh"
. "$HERE/lib/phase2-stack.sh"
. "$HERE/lib/write-commands.sh"
. "$HERE/lib/cleanup-old.sh"

load_config "$HERE"
start_logging
keep_sudo_alive

case "${1:-}" in
  "") ;;
  --cleanup-old) cleanup_old; exit 0 ;;
  -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  *) die "Unknown option: $1 (try --help)" ;;
esac

phase1 "$HERE"
if reboot_needed; then
  offer_reboot
  exit 0
fi
phase2
