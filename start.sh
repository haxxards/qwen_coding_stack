#!/usr/bin/env bash
# One command per coding session, on the desktop or the laptop:
#   ./start.sh [PROJECT]                 open OpenCode on PROJECT (default: the current directory)
#   ./start.sh --folder NAME [PROJECT]   use another of this machine's setups, e.g. 20261007_desktop
#   ./stop.sh                            stop the model servers and sandboxes, free the GPU
# start.sh uses this machine's newest folder and installs it on first use (if the installer
# asks for a reboot, run start.sh again afterwards). It commits the project as a git
# checkpoint, opens OpenCode, and when OpenCode closes prints how to keep or discard the work.
set -euo pipefail

REPO=$(dirname "$(readlink -f "$0")")
ME=start.sh
die() { echo "$ME: $*" >&2; exit 1; }
say() { echo "$ME: $*"; }

folders() { local f; for f in "$REPO"/2*_"$MACHINE"/; do [ -d "$f" ] && basename "$f"; done; return 0; }

# Sets DIR (install directory) and CMD (stack command) from a folder's install.conf.
stack_of() {
  local conf=$REPO/$1/installer/install.conf
  [ -f "$conf" ] || die "$1 has no installer/install.conf"
  if grep -q '^Q38=' "$conf"; then CMD=qwen38-stack; else CMD=qwen-stack; fi
  # shellcheck disable=SC1090
  DIR=$(set +u; . "$conf" && printf '%s' "${Q38:-${QCS:-}}")
  [ -n "$DIR" ] || die "$conf sets no install directory"
  DIR=$(readlink -m -- "$DIR")
}

STOP=no FOLDER="" PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    --stop) STOP=yes ME=stop.sh; shift ;;
    --folder)
      [ -n "${2:-}" ] || die "usage: start.sh --folder NAME [PROJECT]"
      FOLDER=${2%/}; FOLDER=${FOLDER##*/}; shift 2 ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *) [ -z "$PROJECT" ] || die "Only one project at a time (try --help)"; PROJECT=$1; shift ;;
  esac
done

[ "$(id -u)" -ne 0 ] || die "Run as your normal user, not root."
# shellcheck disable=SC1091
OS_ID=$(. /etc/os-release && printf '%s' "$ID")
case "$OS_ID" in
  pop) MACHINE=desktop ;;
  debian) MACHINE=laptop ;;
  *) die "No setup here is for '$OS_ID' (the desktop runs Pop!_OS, the laptop Debian)." ;;
esac

if [ "$STOP" = yes ]; then
  [ -z "$FOLDER$PROJECT" ] || die "stop.sh takes no arguments: it stops every setup on this machine."
  seen=" " found=no rc=0
  for f in $(folders); do
    stack_of "$f"
    case "$seen" in *" $DIR "*) continue ;; esac
    seen="$seen$DIR "
    [ -x "$DIR/bin/$CMD" ] || continue
    found=yes
    say "$CMD ($f)"
    "$DIR/bin/$CMD" down || rc=$?
  done
  [ "$found" = yes ] || say "Nothing is installed on this machine yet."
  exit "$rc"
fi

if [ -n "$FOLDER" ]; then
  case "$FOLDER" in *_"$MACHINE") ;; *) die "$FOLDER is not for this machine ($MACHINE). This machine's folders: $(folders | xargs)" ;; esac
  [ -d "$REPO/$FOLDER/installer" ] || die "There is no $FOLDER in $REPO. This machine's folders: $(folders | xargs)"
else
  FOLDER=$(folders | tail -n 1)
  [ -n "$FOLDER" ] || die "$REPO has no folder for the $MACHINE."
fi
stack_of "$FOLDER"

[ -d "${PROJECT:-.}" ] || die "No such directory: ${PROJECT:-.} (create it first with mkdir -p)"
PROJECT=$(readlink -f -- "${PROJECT:-.}")
case "$(readlink -f "$HOME")/" in "${PROJECT%/}/"*) die "Refusing to open $PROJECT: choose a project folder, e.g. ~/Development/myproject" ;; esac
case "$PROJECT/" in "$REPO/"*|"$DIR/"*) die "Refusing to open $PROJECT: it belongs to the stack, not to a project." ;; esac

if [ -z "$(git config user.name)" ] || [ -z "$(git config user.email)" ]; then
  die "git needs your name and email for the checkpoint commit. Set them once:
  git config --global user.name \"Your Name\"
  git config --global user.email you@example.com"
fi

if [ ! -e "$DIR/cache/.installed" ]; then
  say "$FOLDER isn't installed yet: running its installer."
  "$REPO/$FOLDER/installer/install.sh"
  [ -e "$DIR/cache/.installed" ] || { say "Finish the install (reboot if it asked you to), then run start.sh again."; exit 0; }
fi

# Checkpoint: everything in the project is committed, so the session's work can be undone.
HERE=$(readlink -f .)
cd "$PROJECT"
git rev-parse --git-dir >/dev/null 2>&1 || { git init -q; say "Made $PROJECT a git repository."; }
git add -A
if ! git rev-parse -q --verify HEAD >/dev/null || ! git diff --cached --quiet; then
  git commit -q --no-verify --allow-empty -m "checkpoint before AI session"
fi
BASE=$(git rev-parse --short HEAD)

say "$FOLDER ($CMD) on $PROJECT, checkpoint $BASE"
trap ':' INT   # Ctrl-C ends the session, not this script: the summary below still prints
rc=0
"$DIR/bin/$CMD" up "$PROJECT" || rc=$?
trap - INT

echo
if [ -z "$(git status --porcelain)" ] && [ "$(git rev-parse --short HEAD)" = "$BASE" ]; then
  say "No changes since checkpoint $BASE."
else
  say "Changes since checkpoint $BASE:"
  git status --short
  git log --oneline "$BASE..HEAD"
  echo
  echo "Review, then keep or discard:"
  [ "$HERE" = "$PROJECT" ] || printf '  cd %q\n' "$PROJECT"
  echo "  git status --short && git diff $BASE"
  echo "  git add -A && git commit -qm \"AI session\"   # keep"
  echo "  git reset --hard $BASE && git clean -fd     # or discard"
fi
say "The model server keeps running for the next session; stop it with: $REPO/stop.sh"
exit "$rc"
