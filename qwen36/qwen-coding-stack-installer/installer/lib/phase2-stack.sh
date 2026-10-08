# Phase 2: everything under $QCS (runs as your user; sudo only for the service).

phase2() {
  log "Phase 2: llama.cpp, model, commands, sandbox, service"
  check_gpu_stack
  setup_project_dir
  [ "$PROFILE" = popos-desktop ] && [ "${MIGRATE_OLD:-no}" = yes ] && migrate_old
  build_llama
  download_model
  write_server_env
  write_commands
  "$QCS/bin/write-opencode-config"
  [ "${BUILD_SANDBOX_IMAGE:-yes}" = yes ] && build_sandbox_image
  [ "${INSTALL_SERVICE:-yes}" = yes ] && install_service
  [ "$PROFILE" = debian-laptop ] && laptop_prep
  tune_split
  [ "$TUNE_THREADS" = yes ] && tune_threads
  start_and_verify
  summary
}

check_gpu_stack() {
  log "Checking driver and CUDA toolkit"
  nvidia-smi >/dev/null 2>&1 || die "nvidia-smi fails. Reboot, then re-run. If it still fails, see the guide's troubleshooting."
  resolve_cuda_ver
  [ -n "$DRIVER_CUDA" ] || warn "Couldn't read the driver's CUDA version; using toolkit $CUDA_VER. If the server fails with 'CUDA driver version is insufficient', set CUDA_VER to an older 13.x in install.conf."
  ensure_toolkit
  info "Driver supports CUDA ${DRIVER_CUDA:-unknown}; using toolkit $CUDA_HOME"
  sync_cuda_home
  id -nG | grep -qw docker || die "The docker group isn't active in this session. Log out and back in (or reboot), then re-run."
}

# Keep CUDA_HOME in an existing server.env pointing at the toolkit chosen above.
sync_cuda_home() {
  local env="$QCS/config/server.env"
  [ -f "$env" ] || return 0
  if ! grep -qxF "CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}" "$env"; then
    if grep -q '^CUDA_HOME=' "$env"; then
      sed -i "s|^CUDA_HOME=.*|CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}|" "$env"
    else
      sed -i "1a CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}" "$env"
    fi
    info "Updated CUDA_HOME in server.env to $CUDA_HOME"
  fi
}

setup_project_dir() {
  log "Project directory: $QCS"
  mkdir -p "$QCS"/{bin,config/opencode,models,sandbox,sandbox-state,cache,venv}
  cat > "$QCS/config/shell.sh" <<SH
# qwen-coding-stack: sourced from ~/.bashrc. Safe to source repeatedly.
export QCS="$QCS"
case ":\$PATH:" in *":\$QCS/bin:"*) ;; *) export PATH="\$QCS/bin:\$PATH" ;; esac
SH
  local line="[ -f \"$QCS/config/shell.sh\" ] && . \"$QCS/config/shell.sh\""
  grep -qxF "$line" ~/.bashrc || { echo "$line" >> ~/.bashrc; info "Added one line to ~/.bashrc"; }
}

migrate_old() {
  log "Migrating from the earlier manual setup"
  local old="$HOME/models/Qwen3.6-35B-A3B-GGUF"
  if [ -d "$old" ] && [ ! -e "$MODEL_DIR" ]; then
    mv "$old" "$MODEL_DIR"; info "Moved existing model to $MODEL_DIR"
  fi
  if [ -f "$HOME/.config/systemd/user/qwen-server.service" ]; then
    systemctl --user disable --now qwen-server 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/qwen-server.service"
    systemctl --user daemon-reload 2>/dev/null || true
    info "Removed old per-user service"
  fi
  pkill -f "$HOME/Development/llama.cpp/build/bin/llama-server" 2>/dev/null || true
  local pat='^export (PATH=\$HOME/bin:\$PATH|PATH=\$HOME/Development/qwen:\$PATH|PATH=/usr/local/cuda-[0-9.]+/bin:\$PATH|LD_LIBRARY_PATH=/usr/local/cuda-[0-9.]+/lib64:)'
  if grep -qE "$pat" ~/.bashrc; then
    cp ~/.bashrc "$QCS/cache/bashrc.backup.$(date +%Y%m%d-%H%M%S)"
    grep -vE "$pat" ~/.bashrc > "$QCS/cache/bashrc.new" && cat "$QCS/cache/bashrc.new" > ~/.bashrc
    rm -f "$QCS/cache/bashrc.new"
    info "Removed old PATH/CUDA lines from ~/.bashrc (backup in $QCS/cache/)"
  fi
}

build_llama() {
  log "Building llama.cpp (sm_$CUDA_ARCH) with $CUDA_HOME"
  if [ -d "$QCS/llama.cpp/.git" ]; then
    git -C "$QCS/llama.cpp" pull --ff-only
  else
    git clone https://github.com/ggml-org/llama.cpp "$QCS/llama.cpp"
  fi
  local cache="$QCS/llama.cpp/build/CMakeCache.txt"
  if [ -f "$cache" ] && ! grep -q "CMAKE_CUDA_COMPILER:.*=$CUDA_HOME/bin/nvcc" "$cache"; then
    info "CUDA toolkit changed since the last build; starting a clean build."
    rm -rf "$QCS/llama.cpp/build"
  fi
  cmake -S "$QCS/llama.cpp" -B "$QCS/llama.cpp/build" \
    -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc"
  cmake --build "$QCS/llama.cpp/build" --config Release -j"$(nproc)" \
    --target llama-server llama-cli llama-bench
}

download_model() {
  log "Model: Qwen3.6-35B-A3B UD-Q4_K_XL (~22 GB; resumes if interrupted)"
  if [ ! -x "$QCS/venv/bin/hf" ]; then
    python3 -m venv "$QCS/venv"
    PIP_CACHE_DIR="$QCS/cache/pip" "$QCS/venv/bin/pip" install -q -U huggingface_hub
  fi
  # hf hides its progress bars unless stderr is a terminal, and start_logging sends
  # all output through tee, so give hf the terminal (fd 3). Without this the
  # download shows only "Fetching N files: 0%" until it finishes.
  HF_HOME="$QCS/cache/huggingface" "$QCS/venv/bin/hf" download unsloth/Qwen3.6-35B-A3B-GGUF \
    --local-dir "$MODEL_DIR" --include "*UD-Q4_K_XL*" 2>&3 \
    || die "Model download failed (hf's messages are on screen, not in the log). Re-run to resume."
  [ -f "$MODEL_FILE" ] || die "Expected model file not found: $MODEL_FILE (see: ls $MODEL_DIR)"
}

write_server_env() {
  local env="$QCS/config/server.env"
  if [ -f "$env" ]; then
    info "server.env exists; keeping your settings (change with: qwen-set KEY=VALUE)"
    return
  fi
  log "Creating server.env"
  local bridge
  bridge=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  cat > "$env" <<ENV
# qwen-coding-stack server settings. Change with: qwen-set KEY=VALUE
# Each line keeps a value already set in the environment, so one-off
# overrides work, e.g.:  NCMOE=30 qwen-server
CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}
MODEL=\${MODEL:-$MODEL_FILE}
NCMOE=\${NCMOE:-$NCMOE}
CTX=\${CTX:-$CTX}
THREADS=\${THREADS:-$THREADS}
HOST=\${HOST:-${bridge:-172.17.0.1}}
PORT=\${PORT:-8080}
SAMPLING=\${SAMPLING:---temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0}
EXTRA_ARGS=\${EXTRA_ARGS:-}
AGENT_TEMP=\${AGENT_TEMP:-0.6}
ENV
}

build_sandbox_image() {
  log "Building sandbox image"
  cat > "$QCS/sandbox/Dockerfile" <<'DOCKER'
FROM debian:bookworm-slim
ARG UID=1000
ARG GID=1000
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git build-essential python3 python3-venv python3-pip \
      nodejs npm unzip ripgrep less procps \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd -g ${GID} dev && useradd -m -u ${UID} -g ${GID} -s /bin/bash dev
USER dev
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/dev/.opencode/bin:${PATH}"
RUN mkdir -p /home/dev/.config/opencode /home/dev/.local/share/opencode
WORKDIR /workspace
CMD ["opencode"]
DOCKER
  docker build -t qwen-coding-stack-sandbox:latest \
    --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" "$QCS/sandbox"
}

install_service() {
  log "Installing system service qwen-server"
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<UNIT
[Unit]
Description=llama-server (qwen-coding-stack)
After=docker.service network-online.target
Wants=docker.service
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
User=$USER
ExecStartPre=/bin/sh -c 'until ip -4 addr show docker0 2>/dev/null | grep -q "inet "; do sleep 2; done'
ExecStart=/bin/bash $QCS/bin/qwen-server
Restart=on-failure
RestartSec=15
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT
  if ! cmp -s "$tmp" /etc/systemd/system/qwen-server.service; then
    sudo install -m 644 "$tmp" /etc/systemd/system/qwen-server.service
    sudo systemctl daemon-reload
  fi
  rm -f "$tmp"
  sudo systemctl enable qwen-server >/dev/null
}

laptop_prep() {
  log "Laptop: performance profile and GPU check"
  powerprofilesctl set performance 2>/dev/null || warn "Couldn't set the performance power profile."
  if ! on_ac_power 2>/dev/null; then
    [ -r /sys/class/power_supply/AC/online ] && [ "$(cat /sys/class/power_supply/AC/online)" = 0 ] \
      && warn "Running on battery: tuning results will be pessimistic. Plug in for best results."
  fi
  if nvidia-smi | grep -qE 'Xorg|gnome-shell|kwin|Xwayland'; then
    warn "The desktop is using the NVIDIA GPU. Set BIOS graphics to Hybrid/Optimus to free VRAM (see the guide)."
  fi
}

tune_split() {
  local marker="$QCS/cache/.ncmoe-tuned"
  if [ "${RUN_TUNING:-yes}" != yes ]; then info "Skipping NCMOE tuning (RUN_TUNING=no)"; return; fi
  if [ -f "$marker" ] && [ "${RETUNE:-no}" != yes ]; then info "NCMOE already tuned ($(grep '^NCMOE=' "$QCS/config/server.env")); set RETUNE=yes to redo"; return; fi
  log "Finding the GPU/RAM split (find-ncmoe $NCMOE_RANGE)"
  # shellcheck disable=SC2086
  if "$QCS/bin/find-ncmoe" $NCMOE_RANGE; then
    touch "$marker"; return
  fi
  warn "No value in the range fit; retrying with a smaller context (CTX=$SMALL_CTX)."
  "$QCS/bin/qwen-set" CTX="$SMALL_CTX"
  # shellcheck disable=SC2086
  if "$QCS/bin/find-ncmoe" $NCMOE_RANGE; then
    touch "$marker"; return
  fi
  warn "Still no fit. Falling back to llama.cpp's automatic fitting (NCMOE=auto)."
  "$QCS/bin/qwen-set" NCMOE=auto
}

tune_threads() {
  local marker="$QCS/cache/.threads-tuned"
  if [ -f "$marker" ] && [ "${RETUNE:-no}" != yes ]; then info "Threads already tuned; set RETUNE=yes to redo"; return; fi
  (
    set -a; . "$QCS/config/server.env"; set +a
    [ "$NCMOE" != auto ] || { info "NCMOE=auto; skipping thread tuning"; exit 0; }
    log "Measuring CPU thread counts (8, 16, 24) — a few minutes"
    sudo systemctl stop qwen-server 2>/dev/null || true
    pkill -f "$QCS/llama.cpp/build/bin/llama-server" 2>/dev/null || true; sleep 2
    local csv="$QCS/cache/threads-bench.csv"
    LD_LIBRARY_PATH="$CUDA_HOME/lib64" "$QCS/llama.cpp/build/bin/llama-bench" \
      -m "$MODEL" -ngl 99 -fa 1 -ncmoe "$NCMOE" -t 8,16,24 -p 0 -n 128 -r 2 -o csv > "$csv"
    local best
    best=$(python3 - "$csv" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r.get("n_gen", "0") not in ("", "0")]
print(max(rows, key=lambda r: float(r["avg_ts"]))["n_threads"] if rows else "")
PY
)
    if [ -n "$best" ]; then
      info "Fastest: $best threads"
      "$QCS/bin/qwen-set" THREADS="$best"
      touch "$marker"
    else
      warn "Couldn't read benchmark results ($csv); keeping THREADS as is."
    fi
  )
}

start_and_verify() {
  [ "${INSTALL_SERVICE:-yes}" = yes ] || { info "Service not installed; start the server with: qwen-server"; return; }
  log "Starting the service and waiting for the model to load"
  systemctl is-active --quiet qwen-server || { sudo systemctl reset-failed qwen-server 2>/dev/null || true; sudo systemctl start qwen-server; }
  set -a; . "$QCS/config/server.env"; set +a
  local i
  for i in $(seq 1 60); do
    if curl -sf "http://$HOST:$PORT/v1/models" >/dev/null; then
      info "Server is up at http://$HOST:$PORT/v1"
      return
    fi
    sleep 5
  done
  warn "Server didn't answer within 5 minutes. Check: sudo journalctl -u qwen-server -n 80 --no-pager"
}

summary() {
  log "Done"
  info "Settings:"
  grep -E '^[A-Z_]+=' "$QCS/config/server.env" | sed 's/^/      /'
  info ""
  info "Open a new terminal (or run: . $QCS/config/shell.sh). For each session:"
  info ""
  info "  cd /path/to/your/project"
  info "  git rev-parse --git-dir >/dev/null 2>&1 || git init"
  info "  git add -A && git commit -qm \"checkpoint before AI session\" || true"
  info "  qwen-stack up"
  info ""
  info "After quitting OpenCode, review the changes, then keep or discard them:"
  info ""
  info "  git status --short && git diff"
  info "  git add -A && git commit -qm \"AI session\"   # keep"
  info "  git reset --hard && git clean -fd           # or discard"
  info ""
  info "qwen-stack down stops the server and frees the GPU; qwen-stack alone lists the other commands."
  [ "$PROFILE" = popos-desktop ] && info "Remove the earlier manual setup's files: $QCS/installer/install.sh --cleanup-old"
  info ""
  info "Full log: $LOG"
}
