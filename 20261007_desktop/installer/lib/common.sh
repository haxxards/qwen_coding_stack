# Shared helpers for the Qwen3.6 installer.

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# version_lt A B  -> true if A < B (e.g. 13.0 < 13.1)
version_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

# Installs only the packages that are missing, so a re-run skips apt entirely and
# never upgrades what's already installed (such as the NVIDIA driver).
apt_install() {
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
  done
  [ ${#missing[@]} -gt 0 ] || return 0
  [ -n "${APT_UPDATED:-}" ] || { sudo apt-get update; APT_UPDATED=yes; }
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${missing[@]}"
}

load_config() {
  local here=$1
  [ "$(id -u)" -ne 0 ] || die "Run as your normal user, not root. The installer uses sudo where needed."
  [ -f "$here/install.conf" ] || die "install.conf not found next to install.sh"
  # shellcheck disable=SC1091
  . "$here/install.conf"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=$ID
  # Each folder of the repository sets up one machine: refuse to set up the other with it.
  case "${PROFILE:-}/$OS_ID" in
    popos-desktop/pop|debian-laptop/debian) ;;
    *) die "This folder's installer is for the ${PROFILE:-?} machine, but this one runs '$OS_ID'. Use the folder for this machine (see the README at the top of the repository)." ;;
  esac
  case "$PROFILE" in
    popos-desktop)
      D_ARCH=120; D_NCMOE=24; D_CTX=131072; D_THREADS=""; D_RANGE="26 28 30 32 34 36 38 40"
      D_SMALLCTX=65536; D_SBMEM=6g; D_SBCPU=4; D_TUNE_THREADS=no ;;
    debian-laptop)
      D_ARCH=89; D_NCMOE=34; D_CTX=65536; D_THREADS=8; D_RANGE="34 36 38 40"
      D_SMALLCTX=32768; D_SBMEM=16g; D_SBCPU=8; D_TUNE_THREADS=yes ;;
    *) die "Unknown PROFILE '$PROFILE' (use popos-desktop or debian-laptop)" ;;
  esac
  CUDA_ARCH=$D_ARCH
  NCMOE=${NCMOE:-$D_NCMOE}
  CTX=${CTX:-$D_CTX}
  THREADS=${THREADS:-$D_THREADS}
  NCMOE_RANGE=${NCMOE_RANGE:-$D_RANGE}
  SMALL_CTX=$D_SMALLCTX
  SANDBOX_MEMORY=${SANDBOX_MEMORY:-$D_SBMEM}
  SANDBOX_CPUS=${SANDBOX_CPUS:-$D_SBCPU}
  [ "${TUNE_THREADS:-auto}" = auto ] && TUNE_THREADS=$D_TUNE_THREADS
  CUDA_VER=${CUDA_VER:-auto}
  MODEL_DIR="$QCS/models/Qwen3.6-35B-A3B-GGUF"
  MODEL_FILE="$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
}

# Installs before 2026-11-25 lived in ~/Development/qwen(38)-coding-stack, a name too close to the
# repository's. Move such an install to its new place and fix what recorded the old path.
move_old_install() {
  local old=$1 new=$2 cmd=$3 line tmp
  if [ ! -d "$old" ] || [ -L "$old" ]; then return 0; fi
  rmdir "$new" 2>/dev/null || true   # an empty leftover can be replaced
  [ ! -e "$new" ] || die "Both $old and $new exist. Keep one (move what you need into it), delete the other, then run this again."
  log "Moving the install from $old to $new"
  if [ -x "$old/bin/$cmd" ]; then "$old/bin/$cmd" down; fi   # closes its sandboxes and stops its server
  mkdir -p "$(dirname "$new")"
  mv "$old" "$new"
  if [ -f "$new/config/server.env" ]; then
    sed -i "s|$old/|$new/|g; 1s|^# [a-z0-9]*-coding-stack server settings|# Server settings|" "$new/config/server.env"
  fi
  rm -rf "$new/venv"   # a Python venv can't be moved; it's made again when a download needs it
  # The binaries don't depend on the path: keep them, and let the next rebuild configure afresh.
  if [ -d "$new/llama.cpp/build" ]; then
    find "$new/llama.cpp/build" -mindepth 1 -maxdepth 1 ! -name bin ! -name .qcs-built -exec rm -rf {} +
  fi
  line="[ -f \"$old/config/shell.sh\" ] && . \"$old/config/shell.sh\""
  if grep -qxF "$line" ~/.bashrc 2>/dev/null; then
    tmp=$(mktemp); grep -vxF "$line" ~/.bashrc > "$tmp" || true
    cat "$tmp" > ~/.bashrc; rm -f "$tmp"
  fi
  info "Moved. Open a new terminal afterwards: terminals already open look for the commands in $old."
}

start_logging() {
  mkdir -p "$QCS/cache"
  LOG="$QCS/cache/install-$(date +%Y%m%d-%H%M%S).log"
  exec 3>&2   # the terminal itself, for download progress bars (see download_model)
  exec > >(tee -a "$LOG") 2>&1
  log "Qwen3.6 installer — profile: $PROFILE — log: $LOG"
}

keep_sudo_alive() {
  sudo -v || die "sudo is required."
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) >/dev/null 2>&1 &
}

# Highest CUDA version the loaded driver supports, as MAJOR.MINOR (empty if unknown).
# Asks the driver library directly; falls back to parsing nvidia-smi, whose
# wording differs between driver releases.
driver_cuda_version() {
  local v=""
  v=$(python3 - 2>/dev/null <<'PY2'
import ctypes
try:
    lib = ctypes.CDLL("libcuda.so.1")
    n = ctypes.c_int()
    if lib.cuDriverGetVersion(ctypes.byref(n)) == 0 and n.value:
        print(f"{n.value // 1000}.{(n.value % 1000) // 10}")
except OSError:
    pass
PY2
) || true
  if [ -z "$v" ]; then
    v=$( { nvidia-smi --version 2>/dev/null; nvidia-smi 2>/dev/null; } \
         | grep -oiE 'CUDA (Driver )?Version *: *[0-9]+\.[0-9]+' | head -1 \
         | grep -oE '[0-9]+\.[0-9]+$' ) || true
  fi
  printf '%s' "$v"
}

# Decide the toolkit version from CUDA_VER (auto | 13 | 13.x) and the driver, and set
# CUDA_VER / CUDA_HOME. Never picks 13.2, never picks a version newer than the driver.
resolve_cuda_ver() {
  local want=${CUDA_VER:-auto} drv
  drv=$(driver_cuda_version)
  case "$want" in
    auto|13) want=auto ;;
    13.[0-9]|13.[0-9][0-9]) ;;
    *) die "CUDA_VER must be 'auto' or a 13.x version like 13.1 (got '$want')." ;;
  esac
  if [ "$want" = auto ]; then
    if [ -n "$drv" ]; then
      want=$drv
    else
      want=13.1
      info "Couldn't read the driver's CUDA version yet; assuming 13.1 (checked again in phase 2)."
    fi
  fi
  if [ -n "$drv" ]; then
    version_lt "$drv" 13.0 && die "The driver only supports CUDA $drv; CUDA 13 needs a newer NVIDIA driver."
    if version_lt "$drv" "$want"; then
      warn "The driver supports CUDA $drv; using toolkit $drv instead of $want."
      want=$drv
    fi
  fi
  if [ "$want" = 13.2 ]; then
    info "Skipping CUDA 13.2 (gibberish-output bug with Qwen in llama.cpp); using 13.1."
    want=13.1
  fi
  CUDA_VER=$want
  CUDA_HOME=/usr/local/cuda-$CUDA_VER
  DRIVER_CUDA=$drv
}

# Install the chosen toolkit if it isn't there yet.
ensure_toolkit() {
  if [ ! -x "$CUDA_HOME/bin/nvcc" ]; then
    log "Installing CUDA toolkit $CUDA_VER"
    apt_install "cuda-toolkit-${CUDA_VER/./-}"
  fi
  [ -x "$CUDA_HOME/bin/nvcc" ] || die "CUDA toolkit $CUDA_VER didn't install to $CUDA_HOME."
  if dpkg -s cuda-toolkit-13 >/dev/null 2>&1; then
    warn "The unversioned 'cuda-toolkit-13' package is installed; it pulls in every new 13.x (including 13.2)."
    info "It's harmless to keep, but to stop that: sudo apt remove cuda-toolkit-13 && sudo apt autoremove"
  fi
}

detect_cuda_home() {
  ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1
}

