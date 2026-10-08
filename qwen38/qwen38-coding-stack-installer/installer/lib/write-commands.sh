# Writes the project's commands into $Q38/bin (generated from the guide).

write_commands() {
  log "Installing commands into $Q38/bin"
mkdir -p "$Q38/bin"

# --- qwen38-server: starts llama-server with the settings in config/server.env ---
cat > "$Q38/bin/qwen38-server" <<'SCRIPT'
#!/usr/bin/env bash
# Starts llama-server for Qwen3.8-27B using config/server.env.
# One-off overrides work, e.g.:  NGL=40 CTX=32768 qwen38-server
set -euo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
set -a; . "$Q38/config/server.env"; set +a
if [ -z "${CUDA_HOME:-}" ] || [ ! -d "$CUDA_HOME" ]; then
  CUDA_HOME=$(ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1)
fi
[ -n "$CUDA_HOME" ] || { echo "No CUDA 13.x toolkit found under /usr/local" >&2; exit 1; }
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -f "$MODEL" ] || { echo "Model not found: $MODEL" >&2; exit 1; }
args=(--model "$MODEL" --alias qwen38-local -c "$CTX" -np 1 -fa on --jinja
      --host "$HOST" --port "$PORT")
if [ "$NGL" != "auto" ]; then args+=(-ngl "$NGL"); fi
if [ -n "${CACHE_TYPE:-}" ] && [ "$CACHE_TYPE" != "f16" ]; then
  args+=(--cache-type-k "$CACHE_TYPE" --cache-type-v "$CACHE_TYPE")
fi
if [ -n "${THREADS:-}" ]; then args+=(-t "$THREADS"); fi
if [ -n "${REASONING_EFFORT:-}" ]; then
  args+=(--chat-template-kwargs "{\"reasoning_effort\":\"$REASONING_EFFORT\"}")
fi
# shellcheck disable=SC2206
args+=($SAMPLING)
# shellcheck disable=SC2206
if [ -n "${EXTRA_ARGS:-}" ]; then args+=($EXTRA_ARGS); fi
exec "$Q38/llama.cpp/build/bin/llama-server" "${args[@]}"
SCRIPT

# --- qwen38-write-opencode-config: regenerates opencode.json from config/server.env ---
cat > "$Q38/bin/qwen38-write-opencode-config" <<'SCRIPT'
#!/usr/bin/env bash
# Regenerates config/opencode/opencode.json so it always matches config/server.env.
set -euo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
set -a; . "$Q38/config/server.env"; set +a
OUT=$(( CTX >= 131072 ? 32768 : CTX / 4 ))
mkdir -p "$Q38/config/opencode"
cat > "$Q38/config/opencode/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama.cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-server (local Qwen3.8)",
      "options": { "baseURL": "http://$HOST:$PORT/v1", "apiKey": "none" },
      "models": {
        "qwen38-local": {
          "name": "$(basename "$MODEL" .gguf) (local)",
          "limit": { "context": $CTX, "output": $OUT }
        }
      }
    }
  },
  "model": "llama.cpp/qwen38-local",
  "small_model": "llama.cpp/qwen38-local",
  "share": "disabled",
  "permission": {
    "task": { "*": "deny" },
    "edit": "ask",
    "bash": "ask",
    "external_directory": "deny",
    "doom_loop": "ask"
  },
  "agent": {
    "build":   { "temperature": $AGENT_TEMP, "top_p": 0.95 },
    "plan":    { "temperature": $AGENT_TEMP, "top_p": 0.95 },
    "general": { "disable": true },
    "explore": { "disable": true },
    "scout":   { "disable": true }
  }
}
EOF
echo "Wrote $Q38/config/opencode/opencode.json (context $CTX)"
SCRIPT

# --- qwen38-set: change a setting, keep OpenCode in sync, restart the service ---
cat > "$Q38/bin/qwen38-set" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: qwen38-set                  show current settings
#        qwen38-set KEY=VALUE ...    change settings, sync OpenCode, restart the service
set -euo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ENV="$Q38/config/server.env"
if [ $# -eq 0 ]; then grep -E '^[A-Z_]+=' "$ENV"; exit 0; fi
for kv in "$@"; do
  k="${kv%%=*}"; v="${kv#*=}"
  case "$k" in
    CUDA_HOME|MODEL|NGL|CTX|CACHE_TYPE|THREADS|HOST|PORT|SAMPLING|EXTRA_ARGS|AGENT_TEMP|REASONING_EFFORT) ;;
    *) echo "Unknown setting: $k" >&2; exit 1 ;;
  esac
  if grep -q "^$k=" "$ENV"; then
    sed -i "s|^$k=.*|$k=\${$k:-$v}|" "$ENV"
  else
    echo "$k=\${$k:-$v}" >> "$ENV"
  fi
  echo "Set $k=$v"
done
"$Q38/bin/qwen38-write-opencode-config"
# Restart the service only if it's running (or failed): a server stopped with 'qwen38-stack down' stays down.
case "$(systemctl show -p ActiveState --value qwen38-server 2>/dev/null || true)" in
  active|activating|failed)
    sudo systemctl reset-failed qwen38-server 2>/dev/null || true
    sudo systemctl restart qwen38-server
    echo "qwen38-server service restarted" ;;
  *)
    if pgrep -ax llama-server | grep -qF "$Q38/llama.cpp/build/bin/llama-server"; then
      echo "Restart the running server to apply this: qwen38-stack down, then qwen38-stack up --server"
    fi ;;
esac
SCRIPT

# --- qwen38-find-fit: finds the largest context or GPU-layer count that fits in VRAM ---
cat > "$Q38/bin/qwen38-find-fit" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: qwen38-find-fit ctx N [N ...]   try context sizes (largest first), save the first that starts
#        qwen38-find-fit ngl N [N ...]   try GPU layer counts (highest first), save the first that
#                                        starts minus 2 layers of headroom
set -uo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
mode=${1:-}; shift || true
case "$mode" in ctx) KEY=CTX ;; ngl) KEY=NGL ;; *) echo "usage: qwen38-find-fit ctx|ngl N [N ...]"; exit 1 ;; esac
[ $# -gt 0 ] || { echo "usage: qwen38-find-fit ctx|ngl N [N ...]"; exit 1; }
was_active=no
if systemctl is-active --quiet qwen38-server 2>/dev/null; then was_active=yes; sudo systemctl stop qwen38-server; fi
pkill -f "$Q38/llama.cpp/build/bin/llama-server" 2>/dev/null; sleep 2
log="$Q38/cache/find-fit.log"
for n in "$@"; do
  echo "Trying $KEY=$n ..."
  env "$KEY=$n" "$Q38/bin/qwen38-server" > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if grep -qi "listening" "$log"; then
      kill "$pid"; wait "$pid" 2>/dev/null
      save=$n
      if [ "$KEY" = NGL ] && [ "$n" -lt 99 ]; then save=$(( n > 2 ? n - 2 : 0 )); fi
      echo "  OK at $KEY=$n. Saving $KEY=$save."
      "$Q38/bin/qwen38-set" "$KEY=$save"
      [ "$was_active" = no ] || sudo systemctl start qwen38-server
      exit 0
    fi
    sleep 2
  done
  echo "  failed: $(grep -m1 -iE 'out of memory|error|not found' "$log" || tail -n1 "$log")"
done
echo "No value started. Try smaller values, or let llama.cpp decide: qwen38-set NGL=auto"
exit 1
SCRIPT

# --- qwen38-sandbox: runs OpenCode (or any command) in an isolated container ---
cat > "$Q38/bin/qwen38-sandbox" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: qwen38-sandbox [project-dir] [command ...]
#   qwen38-sandbox                  OpenCode on the current directory
#   qwen38-sandbox ~/code/app bash  a shell in the same sandbox (joins it if it's already open)
# Each project keeps its OpenCode sessions, prompt and shell history, and the tools
# OpenCode downloads in sandbox-state/<project>/, so the next session picks them up.
set -euo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PROJECT="$(realpath "${1:-$PWD}")"
case "$PROJECT" in "$Q38"|"$Q38"/*) echo "Refusing to mount the stack's own directory." >&2; exit 1 ;; esac
[ "$PROJECT" != "$HOME" ] || { echo "Refusing to mount your whole home directory." >&2; exit 1; }
ID="$(printf '%s' "${PROJECT##*/}" | tr -c 'a-zA-Z0-9_.-' '-')-$(printf '%s' "$PROJECT" | sha256sum | cut -c1-8)"
NAME="q38-$ID"
STATE="$Q38/sandbox-state/$ID"
docker image inspect qwen38-coding-stack-sandbox:latest >/dev/null || {
  echo "If the image is missing, build it: qwen38-stack build" >&2
  exit 1
}
# Already open in another terminal: join that container.
if [ "$(docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]; then
  [ $# -gt 1 ] || set -- . opencode
  exec docker exec -it -w /workspace "$NAME" "${@:2}"
fi
mkdir -p "$STATE"/{data,state,cache}
printf '%s\n' "$PROJECT" > "$STATE/path"
exec docker run -it --rm --name "$NAME" --label "qwen38-coding-stack.project=$PROJECT" \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  --memory "${SANDBOX_MEMORY:-@@SBMEM@@}" --cpus "${SANDBOX_CPUS:-@@SBCPU@@}" \
  -v "$PROJECT":/workspace \
  -v "$Q38/config/opencode/opencode.json":/home/dev/.config/opencode/opencode.json:ro \
  -v "$STATE/data":/home/dev/.local/share/opencode \
  -v "$STATE/state":/home/dev/.local/state \
  -v "$STATE/cache":/home/dev/.cache \
  -e HISTFILE=/home/dev/.local/state/bash_history \
  -w /workspace \
  qwen38-coding-stack-sandbox:latest "${@:2}"
SCRIPT

# --- qwen38-stack: bring the server and a project's sandbox up, and take them down ---
cat > "$Q38/bin/qwen38-stack" <<'SCRIPT'
#!/usr/bin/env bash
# Day-to-day control of the stack. Nothing here deletes projects or saved sessions.
#   qwen38-stack up [DIR]            start the server if needed, then open OpenCode on DIR (default: .)
#   qwen38-stack up --server         only start the server
#   qwen38-stack shell [DIR]         a bash shell in DIR's sandbox (joins it if it's already open)
#   qwen38-stack down                close all sandboxes and stop the server (frees the GPU)
#   qwen38-stack status              server, GPU memory, open sandboxes, projects with saved sessions
#   qwen38-stack logs                follow the server log
#   qwen38-stack build [--no-cache]  build the sandbox image (--no-cache also updates OpenCode)
#   qwen38-stack boot on|off         start the server at boot, or not
set -euo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SVC=qwen38-server; OTHER_SVC=qwen-server
IMAGE=qwen38-coding-stack-sandbox:latest; LABEL=qwen38-coding-stack.project
SERVER_BIN="$Q38/llama.cpp/build/bin/llama-server"; SERVER_LOG="$Q38/cache/server.log"
set -a; . "$Q38/config/server.env"; set +a
URL="http://$HOST:$PORT"

die() { echo "$*" >&2; exit 1; }
has_service() { [ -f "/etc/systemd/system/$SVC.service" ]; }
svc() { systemctl show -p "$1" --value "$SVC" 2>/dev/null || true; }
# Our llama-server processes: named llama-server, started from this stack's build.
server_pids() { pgrep -ax llama-server | grep -F "$SERVER_BIN" | cut -d' ' -f1 || true; }
running() { [ -n "$(server_pids)" ]; }
ready() { curl -sf "$URL/health" >/dev/null 2>&1; }
server_log() {
  if has_service; then sudo journalctl -u "$SVC" -n "$1" --no-pager; else tail -n "$1" "$SERVER_LOG"; fi
}

start_server() {
  if ready; then echo "Server is up at $URL/v1"; return; fi
  local pid="" others
  ip -4 addr show docker0 2>/dev/null | grep -q "inet " \
    || die "Docker isn't running (the server listens on its docker0 bridge): sudo systemctl start docker"
  if has_service; then
    if systemctl is-active --quiet "$OTHER_SVC" 2>/dev/null; then
      echo "Stopping $OTHER_SVC first: only one model fits on the GPU."
      sudo systemctl stop "$OTHER_SVC"
    fi
    sudo systemctl reset-failed "$SVC" 2>/dev/null || true
    sudo systemctl start "$SVC"
  elif ! running; then
    nohup "$Q38/bin/qwen38-server" > "$SERVER_LOG" 2>&1 < /dev/null &
    pid=$!   # stays the same when qwen38-server execs llama-server
  fi
  others=$(pgrep -ax llama-server | grep -vF "$SERVER_BIN" || true)
  [ -z "$others" ] || printf 'Note: another llama-server is running and may hold GPU memory:\n%s\n' "$others" >&2
  printf 'Loading the model'
  for _ in $(seq 1 120); do
    if ready; then printf '\nServer is up at %s/v1\n' "$URL"; return; fi
    if has_service; then
      case "$(svc ActiveState)/$(svc SubState)" in
        active/*|activating/start*) ;;
        *) echo; server_log 30 >&2; die "The server didn't start (log above). Full log: qwen38-stack logs" ;;
      esac
    elif ! running && ! { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; then
      echo; server_log 30 >&2; die "The server exited (log above; full log: $SERVER_LOG)"
    fi
    printf .; sleep 3
  done
  echo; die "The server isn't answering after 6 minutes. Check: qwen38-stack logs"
}

stop_all() {
  local names
  names=$(docker ps --filter "label=$LABEL" --format '{{.Names}}' 2>/dev/null || true)
  if [ -n "$names" ]; then
    echo "Closing sandboxes: $(echo "$names" | tr '\n' ' ')"
    echo "$names" | xargs docker stop >/dev/null
  fi
  if has_service && [ "$(svc ActiveState)" != inactive ]; then
    sudo systemctl stop "$SVC"
    sudo systemctl reset-failed "$SVC" 2>/dev/null || true
  fi
  server_pids | xargs -r kill 2>/dev/null || true
  for _ in $(seq 1 15); do running || break; sleep 1; done
  ! running || die "llama-server is still running (PID $(server_pids | tr '\n' ' '))"
  echo "Server stopped. Projects and saved sessions are untouched."
}

build_image() {
  [ -f "$Q38/sandbox/Dockerfile" ] \
    || die "$Q38/sandbox/Dockerfile is missing: re-run install.sh, or the guide's 'Build the sandbox image' step."
  # --load: a docker-container builder otherwise keeps the image in its build cache only.
  local build=(docker build)
  docker buildx version >/dev/null 2>&1 && build=(docker buildx build --load)
  "${build[@]}" "$@" -t "$IMAGE" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" - < "$Q38/sandbox/Dockerfile"
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "The build finished but Docker has no $IMAGE image; see the output above."
}

ensure_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 && return
  echo "The sandbox image isn't built yet. Building it now (first time only, a few minutes)."
  build_image
}

status() {
  local state=stopped f p
  if ready; then state="ready at $URL/v1"
  elif has_service && [ "$(svc ActiveState)" = failed ]; then state="failed (see: qwen38-stack logs)"
  elif running || { has_service && [ "$(svc ActiveState)" = activating ]; }; then state=loading
  fi
  echo "Server:      $state"
  echo "Model:       $(basename "$MODEL" .gguf), context $CTX"
  if has_service; then
    echo "At boot:     $(systemctl is-enabled "$SVC" 2>/dev/null || true)  (change with: qwen38-stack boot on|off)"
  fi
  if command -v nvidia-smi >/dev/null; then
    echo "GPU memory:  $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | head -1 | sed 's/, / used of /')"
  fi
  echo "Open sandboxes:"
  docker ps --filter "label=$LABEL" --format "{{.Label \"$LABEL\"}}  ({{.Status}})" 2>/dev/null | sed 's/^/  /' | grep . || echo "  none"
  echo "Projects with saved sessions:"
  for f in "$Q38"/sandbox-state/*/path; do
    [ -f "$f" ] || { echo "  none"; break; }
    p=$(cat "$f")
    printf '  %s  (%s)%s\n' "$p" "$(du -sh "${f%/path}" | cut -f1)" "$([ -d "$p" ] || echo ', folder no longer exists')"
  done
}

boot() {
  has_service || die "No system service is installed (INSTALL_SERVICE=no), so nothing starts at boot."
  case "${1:-}" in
    on)
      if systemctl is-enabled --quiet "$OTHER_SVC" 2>/dev/null; then
        sudo systemctl disable --quiet "$OTHER_SVC"
        echo "$OTHER_SVC no longer starts at boot (only one model fits on the GPU)."
      fi
      sudo systemctl enable --quiet "$SVC"
      echo "$SVC starts at boot." ;;
    off)
      sudo systemctl disable --quiet "$SVC"
      echo "$SVC no longer starts at boot. Start it when you need it: qwen38-stack up" ;;
    *) die "usage: qwen38-stack boot on|off" ;;
  esac
}

case "${1:-}" in
  up)
    if [ "${2:-}" = --server ]; then start_server; exit 0; fi
    [ -d "${2:-.}" ] || die "No such directory: ${2:-.}"
    ensure_image
    start_server
    exec "$Q38/bin/qwen38-sandbox" "${2:-.}" ;;
  shell) ensure_image; exec "$Q38/bin/qwen38-sandbox" "${2:-.}" bash ;;
  down) stop_all ;;
  status) status ;;
  logs)
    if has_service; then exec sudo journalctl -u "$SVC" -n 50 -f; else exec tail -n 50 -F "$SERVER_LOG"; fi ;;
  build)
    case "${2:-}" in ""|--no-cache) ;; *) die "usage: qwen38-stack build [--no-cache]" ;; esac
    build_image ${2:+"$2"} ;;
  boot) boot "${2:-}" ;;
  ""|-h|--help|help) sed -n '2,10p' "$0" ;;
  *) sed -n '2,10p' "$0" >&2; exit 1 ;;
esac
SCRIPT

chmod +x "$Q38"/bin/*
  sed -i "s/@@SBMEM@@/$SANDBOX_MEMORY/; s/@@SBCPU@@/$SANDBOX_CPUS/" "$Q38/bin/qwen38-sandbox"
}
