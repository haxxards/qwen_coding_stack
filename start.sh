#!/usr/bin/env bash
# One command per coding session, on the desktop or the laptop:
#   ./start.sh myapp                            OpenCode on ~/Development/qwen-projects/myapp (made if new)
#   ./start.sh ~/code/app                       OpenCode on a folder elsewhere (a path: ./app, . and anything with a /)
#   ./start.sh --folder 20261007_desktop myapp  use another of this machine's setups
#   ./stop.sh                                   stop the model servers and sandboxes, free the GPU
# start.sh uses this machine's newest folder and installs it on first use (if the installer asks
# for a reboot, run start.sh again afterwards). It commits the project as a git checkpoint, opens
# OpenCode, and when OpenCode closes prints how to keep or discard the work.
set -euo pipefail

REPO=$(dirname "$(readlink -f "$0")")
PROJECTS=$(readlink -m -- "${QWEN_PROJECTS:-$HOME/Development/qwen-projects}")
ME=start.sh
die() { echo "$ME: $*" >&2; exit 1; }
say() { echo "$ME: $*"; }
within() { local a=${1%/} b=${2%/}; case "$a/" in "$b/"*) return 0 ;; esac; return 1; }   # $1 is $2 or inside it

folders() { local f; for f in "$REPO"/2*_"$MACHINE"/; do [ -d "$f" ] && basename "$f"; done; return 0; }
projects() { local p; for p in "$PROJECTS"/*/; do [ -d "$p" ] && basename "$p"; done; return 0; }

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
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    --stop) STOP=yes ME=stop.sh; shift ;;
    --folder)
      [ -n "${2:-}" ] || die "usage: start.sh --folder 2026MMDD_machine PROJECT"
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
    [ -x "$DIR/bin/$CMD" ] || DIR=$HOME/Development/${CMD%-stack}-coding-stack   # not moved to its new place yet
    [ -x "$DIR/bin/$CMD" ] || continue
    case "$seen" in *" $DIR "*) continue ;; esac
    seen="$seen$DIR " found=yes
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

# A name is a project in $PROJECTS; a path (., .. or anything with a /) is a folder anywhere else.
P=${PROJECTS/#$HOME/\~}
HINT="Give a project name instead: $ME NAME opens $P/NAME (made if it's new)."
case "$PROJECT" in
  "") die "Which project?
  $ME NAME   a project in $P (made if it's new)$( [ -z "$(projects)" ] || printf '; so far: %s' "$(projects | xargs)")
  $ME PATH   a folder elsewhere, e.g. ~/code/app, or . for the current folder" ;;
  .|..|*/*) [ -d "$PROJECT" ] || die "No such folder: $PROJECT. $HINT"
            PROJECT=$(readlink -f -- "$PROJECT") ;;
  .*) die "A project name can't start with a dot: $PROJECT" ;;
  *) PROJECT=$PROJECTS/$PROJECT ;;
esac
if within "$PROJECT" "$REPO"; then
  [ "$PROJECT" = "$REPO" ] || HINT="Use a project name instead: $ME ${PROJECT##*/} opens $P/${PROJECT##*/} (made if it's new)."
  die "$PROJECT is inside this repository, so it can't be a project. $HINT"
elif within "$PROJECT" "$DIR"; then
  die "$PROJECT is inside the install ($DIR), so it can't be a project. $HINT"
elif within "$REPO" "$PROJECT" || within "$DIR" "$PROJECT" || within "$PROJECTS" "$PROJECT" || within "$(readlink -f "$HOME")" "$PROJECT"; then
  die "$PROJECT contains this repository, the install or your other projects, so it can't be a project. $HINT"
fi

if [ -z "$(git config user.name)" ] || [ -z "$(git config user.email)" ]; then
  die "git needs your name and email for the checkpoint commit. Set them once:
  git config --global user.name \"Your Name\"
  git config --global user.email you@example.com"
fi

if [ ! -e "$DIR/cache/.installed" ]; then
  say "$FOLDER isn't installed (or moved to $DIR) yet: running its installer."
  "$REPO/$FOLDER/installer/install.sh"
  [ -e "$DIR/cache/.installed" ] || { say "Finish the install (reboot if it asked you to), then run start.sh again."; exit 0; }
fi

[ -d "$PROJECT" ] || { mkdir -p "$PROJECT"; say "New project: $PROJECT"; }

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
