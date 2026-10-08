# Phase 2: everything under $Q38 (runs as your user; sudo only for the service).

phase2() {
  log "Phase 2: llama.cpp, Qwen3.8-27B ($QUANT), commands, sandbox, service"
  check_gpu_stack
  setup_project_dir
  build_llama
  download_model
  write_server_env
  write_commands
  "$Q38/bin/qwen38-write-opencode-config"
  [ "${BUILD_SANDBOX_IMAGE:-yes}" = yes ] && build_sandbox_image
  [ "${INSTALL_SERVICE:-yes}" = yes ] && install_service
  [ "$PROFILE" = debian-laptop ] && laptop_prep
  fit_model
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
  local env="$Q38/config/server.env"
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
  log "Project directory: $Q38"
  mkdir -p "$Q38"/{bin,config/opencode,models,sandbox,sandbox-state,cache,venv}
  cat > "$Q38/config/shell.sh" <<SH
# qwen38-coding-stack: sourced from ~/.bashrc. Safe to source repeatedly.
export Q38="$Q38"
case ":\$PATH:" in *":\$Q38/bin:"*) ;; *) export PATH="\$Q38/bin:\$PATH" ;; esac
SH
  local line="[ -f \"$Q38/config/shell.sh\" ] && . \"$Q38/config/shell.sh\""
  grep -qxF "$line" ~/.bashrc || { echo "$line" >> ~/.bashrc; info "Added one line to ~/.bashrc"; }
}

build_llama() {
  if [ ! -d "$Q38/llama.cpp/.git" ]; then
    git clone https://github.com/ggml-org/llama.cpp "$Q38/llama.cpp"
  elif [ "$UPDATE" = yes ]; then
    log "Updating llama.cpp"
    git -C "$Q38/llama.cpp" pull --ff-only
  fi
  # Skip the build when the binaries came from this commit, toolkit and GPU architecture.
  local stamp="$Q38/llama.cpp/build/.qcs-built" want
  want="$(git -C "$Q38/llama.cpp" rev-parse HEAD) $CUDA_HOME sm_$CUDA_ARCH"
  if [ "$(cat "$stamp" 2>/dev/null)" = "$want" ] && ls "$Q38"/llama.cpp/build/bin/llama-{server,cli,bench} >/dev/null 2>&1; then
    info "llama.cpp $(git -C "$Q38/llama.cpp" rev-parse --short HEAD) is already built (install.sh --update pulls and rebuilds it)"
    return
  fi
  log "Building llama.cpp (sm_$CUDA_ARCH) with $CUDA_HOME"
  local cache="$Q38/llama.cpp/build/CMakeCache.txt"
  if [ -f "$cache" ] && ! grep -q "CMAKE_CUDA_COMPILER:.*=$CUDA_HOME/bin/nvcc" "$cache"; then
    info "CUDA toolkit changed since the last build; starting a clean build."
    rm -rf "$Q38/llama.cpp/build"
  fi
  cmake -S "$Q38/llama.cpp" -B "$Q38/llama.cpp/build" \
    -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc"
  cmake --build "$Q38/llama.cpp/build" --config Release -j"$(nproc)" \
    --target llama-server llama-cli llama-bench
  echo "$want" > "$stamp"
  CHANGED=yes; LLAMA_BUILT=yes
}

download_model() {
  local stamp="$MODEL_DIR/.qcs-downloaded-$QUANT"
  MODEL_FILE=$(ls "$MODEL_DIR"/*"${QUANT}"*.gguf 2>/dev/null | sort | head -1 || true)
  if [ -f "$stamp" ] && [ -n "$MODEL_FILE" ]; then info "Model already downloaded: $MODEL_FILE"; return; fi
  log "Model: Qwen3.8-27B $QUANT (resumes if interrupted)"
  if [ ! -x "$Q38/venv/bin/hf" ]; then
    python3 -m venv "$Q38/venv"
    PIP_CACHE_DIR="$Q38/cache/pip" "$Q38/venv/bin/pip" install -q -U huggingface_hub
  fi
  # hf hides its progress bars unless stderr is a terminal, and start_logging sends
  # all output through tee, so give hf the terminal (fd 3). Without this the
  # download shows only "Fetching N files: 0%" until it finishes.
  HF_HOME="$Q38/cache/huggingface" "$Q38/venv/bin/hf" download unsloth/Qwen3.8-27B-GGUF \
    --local-dir "$MODEL_DIR" --include "*${QUANT}*" 2>&3 \
    || die "Model download failed (hf's messages are on screen, not in the log). Re-run to resume."
  MODEL_FILE=$(ls "$MODEL_DIR"/*"${QUANT}"*.gguf 2>/dev/null | sort | head -1 || true)
  [ -n "$MODEL_FILE" ] || die "No $QUANT .gguf found in $MODEL_DIR after download."
  info "Model file: $MODEL_FILE"
  touch "$stamp"; CHANGED=yes
}

write_server_env() {
  local env="$Q38/config/server.env"
  if [ -f "$env" ]; then
    info "server.env exists; keeping your settings (change with: qwen38-set KEY=VALUE)"
    return
  fi
  log "Creating server.env"
  CHANGED=yes
  local bridge
  bridge=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  cat > "$env" <<ENV
# qwen38-coding-stack server settings. Change with: qwen38-set KEY=VALUE
# Each line keeps a value already set in the environment, so one-off
# overrides work, e.g.:  CTX=32768 qwen38-server
CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}
MODEL=\${MODEL:-$MODEL_FILE}
NGL=\${NGL:-$NGL}
CTX=\${CTX:-$CTX}
CACHE_TYPE=\${CACHE_TYPE:-q8_0}
THREADS=\${THREADS:-$THREADS}
HOST=\${HOST:-${bridge:-172.17.0.1}}
PORT=\${PORT:-8081}
REASONING_EFFORT=\${REASONING_EFFORT:-$REASONING_EFFORT}
SAMPLING=\${SAMPLING:---temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0}
EXTRA_ARGS=\${EXTRA_ARGS:-}
AGENT_TEMP=\${AGENT_TEMP:-1.0}
ENV
}

build_sandbox_image() {
  cat > "$Q38/sandbox/Dockerfile" <<'DOCKER'
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
  local hash opts=()
  hash=$({ cat "$Q38/sandbox/Dockerfile"; id -u; id -g; } | sha256sum | cut -c1-16)
  if [ "$UPDATE" = yes ]; then
    opts=(--pull --no-cache)
  elif [ "$(docker image inspect -f '{{index .Config.Labels "qcs.dockerfile"}}' qwen38-coding-stack-sandbox:latest 2>/dev/null)" = "$hash" ]; then
    info "Sandbox image is up to date (install.sh --update rebuilds it with the latest OpenCode)"
    return
  fi
  log "Building sandbox image"
  docker build "${opts[@]}" --label "qcs.dockerfile=$hash" -t qwen38-coding-stack-sandbox:latest \
    --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" "$Q38/sandbox"
}

install_service() {
  log "Installing system service qwen38-server"
  local tmp first=no; tmp=$(mktemp)
  [ -f /etc/systemd/system/qwen38-server.service ] || first=yes
  if [ "$first" = yes ] && [ "${DISABLE_QWEN36_AT_BOOT:-yes}" = yes ] && systemctl is-enabled --quiet qwen-server 2>/dev/null; then
    sudo systemctl disable --now qwen-server
    info "Qwen3.6 service disabled at boot (still installed; start it with: sudo systemctl start qwen-server)"
  fi
  cat > "$tmp" <<UNIT
[Unit]
Description=llama-server (qwen38-coding-stack)
After=docker.service network-online.target
Wants=docker.service
Conflicts=qwen-server.service
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
User=$USER
ExecStartPre=/bin/sh -c 'until ip -4 addr show docker0 2>/dev/null | grep -q "inet "; do sleep 2; done'
ExecStart=/bin/bash $Q38/bin/qwen38-server
Restart=on-failure
RestartSec=15
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT
  if ! cmp -s "$tmp" /etc/systemd/system/qwen38-server.service; then
    sudo install -m 644 "$tmp" /etc/systemd/system/qwen38-server.service
    sudo systemctl daemon-reload
    CHANGED=yes
  fi
  rm -f "$tmp"
  # Enable at boot only on first install, so 'qwen38-stack boot off' sticks.
  [ "$first" = no ] || sudo systemctl enable qwen38-server >/dev/null
}

laptop_prep() {
  log "Laptop: performance profile and GPU check"
  powerprofilesctl set performance 2>/dev/null || warn "Couldn't set the performance power profile."
  local ac
  for ac in /sys/class/power_supply/A{C,DP}*/online; do
    [ -r "$ac" ] && [ "$(cat "$ac")" = 0 ] && warn "Running on battery: fitting and speed will be pessimistic. Plug in."
  done
  if nvidia-smi | grep -qE 'Xorg|gnome-shell|kwin|Xwayland'; then
    warn "The desktop is using the NVIDIA GPU. Set BIOS graphics to Hybrid/Optimus to free VRAM (see the guide)."
  fi
  return 0
}

fit_model() {
  local marker="$Q38/cache/.fitted"
  if [ "${RUN_TUNING:-yes}" != yes ]; then info "Skipping fitting (RUN_TUNING=no)"; return; fi
  if [ -f "$marker" ] && [ "${RETUNE:-no}" != yes ]; then
    info "Already fitted ($(grep -E '^(NGL|CTX)=' "$Q38/config/server.env" | tr '\n' ' ')); set RETUNE=yes to redo"
    return
  fi
  log "Fitting the model to VRAM (qwen38-find-fit $FIT_MODE $FIT_RANGE)"
  CHANGED=yes
  # shellcheck disable=SC2086
  if "$Q38/bin/qwen38-find-fit" "$FIT_MODE" $FIT_RANGE; then touch "$marker"; return; fi
  warn "Nothing fit; retrying with CTX=$FALLBACK_CTX and fewer GPU layers."
  "$Q38/bin/qwen38-set" CTX="$FALLBACK_CTX"
  # shellcheck disable=SC2086
  if "$Q38/bin/qwen38-find-fit" ngl $FALLBACK_NGL_RANGE; then touch "$marker"; return; fi
  warn "Still no fit. Falling back to llama.cpp's automatic fitting (NGL=auto)."
  "$Q38/bin/qwen38-set" NGL=auto
}

tune_threads() {
  local marker="$Q38/cache/.threads-tuned"
  if [ -f "$marker" ] && [ "${RETUNE:-no}" != yes ]; then info "Threads already tuned; set RETUNE=yes to redo"; return; fi
  CHANGED=yes
  (
    set -a; . "$Q38/config/server.env"; set +a
    case "$NGL" in auto|99) info "All layers on GPU or NGL=auto; skipping thread tuning"; exit 0 ;; esac
    log "Measuring CPU thread counts (8, 16, 24) — a few minutes"
    sudo systemctl stop qwen38-server 2>/dev/null || true
    pkill -f "$Q38/llama.cpp/build/bin/llama-server" 2>/dev/null || true; sleep 2
    local csv="$Q38/cache/threads-bench.csv"
    LD_LIBRARY_PATH="$CUDA_HOME/lib64" "$Q38/llama.cpp/build/bin/llama-bench" \
      -m "$MODEL" -ngl "$NGL" -fa 1 -t 8,16,24 -p 0 -n 64 -r 2 -o csv > "$csv"
    local best
    best=$(python3 - "$csv" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r.get("n_gen", "0") not in ("", "0")]
print(max(rows, key=lambda r: float(r["avg_ts"]))["n_threads"] if rows else "")
PY
)
    if [ -n "$best" ]; then
      info "Fastest: $best threads"
      "$Q38/bin/qwen38-set" THREADS="$best"
      touch "$marker"
    else
      warn "Couldn't read benchmark results ($csv); keeping THREADS as is."
    fi
  )
}

start_and_verify() {
  [ "${INSTALL_SERVICE:-yes}" = yes ] || { info "Service not installed; start the server with: qwen38-server"; return; }
  if systemctl is-active --quiet qwen38-server; then
    if [ "${LLAMA_BUILT:-no}" = yes ]; then log "Restarting the service on the new llama.cpp build"; sudo systemctl restart qwen38-server; fi
  elif [ "${CHANGED:-no}" = yes ]; then
    log "Starting the service and waiting for the model to load"
    sudo systemctl reset-failed qwen38-server 2>/dev/null || true
    sudo systemctl start qwen38-server
  else
    info "Nothing changed and the server is stopped; start it with: qwen38-stack up"
    return
  fi
  set -a; . "$Q38/config/server.env"; set +a
  local i
  for i in $(seq 1 60); do
    if curl -sf "http://$HOST:$PORT/v1/models" >/dev/null; then
      info "Server is up at http://$HOST:$PORT/v1"
      return
    fi
    sleep 5
  done
  warn "Server didn't answer within 5 minutes. Check: sudo journalctl -u qwen38-server -n 80 --no-pager"
}

summary() {
  log "Done"
  info "Settings:"
  grep -E '^[A-Z_]+=' "$Q38/config/server.env" | sed 's/^/      /'
  info ""
  info "Open a new terminal (or run: . $Q38/config/shell.sh). For each session:"
  info ""
  info "  cd /path/to/your/project"
  info "  git rev-parse --git-dir >/dev/null 2>&1 || git init"
  info "  git add -A && git commit -qm \"checkpoint before AI session\" || true"
  info "  qwen38-stack up"
  info ""
  info "After quitting OpenCode, review the changes, then keep or discard them:"
  info ""
  info "  git status --short && git diff"
  info "  git add -A && git commit -qm \"AI session\"   # keep"
  info "  git reset --hard && git clean -fd           # or discard"
  info ""
  info "qwen38-stack down stops the server and frees the GPU; qwen38-stack alone lists the other commands."
  info "Switch back to Qwen3.6 with: qwen-stack up --server"
  info ""
  info "Full log: $LOG"
}
