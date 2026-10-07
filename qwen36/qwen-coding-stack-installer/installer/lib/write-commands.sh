# Writes the project's commands into $QCS/bin (generated from the guide).

write_commands() {
  log "Installing commands into $QCS/bin"
mkdir -p "$QCS/bin"

# --- qwen-server: starts llama-server with the settings in config/server.env ---
cat > "$QCS/bin/qwen-server" <<'SCRIPT'
#!/usr/bin/env bash
# Starts llama-server using config/server.env.
# One-off overrides work, e.g.:  NCMOE=30 CTX=65536 qwen-server
set -euo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
set -a; . "$QCS/config/server.env"; set +a
if [ -z "${CUDA_HOME:-}" ] || [ ! -d "$CUDA_HOME" ]; then
  CUDA_HOME=$(ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1)
fi
[ -n "$CUDA_HOME" ] || { echo "No CUDA 13.x toolkit found under /usr/local" >&2; exit 1; }
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -f "$MODEL" ] || { echo "Model not found: $MODEL" >&2; exit 1; }
args=(--model "$MODEL" --alias qwen-local -c "$CTX" -np 1 -fa on --jinja
      --host "$HOST" --port "$PORT")
if [ "$NCMOE" != "auto" ]; then args+=(-ngl 99 --n-cpu-moe "$NCMOE"); fi
if [ -n "${THREADS:-}" ]; then args+=(-t "$THREADS"); fi
# shellcheck disable=SC2206
args+=($SAMPLING)
# shellcheck disable=SC2206
if [ -n "${EXTRA_ARGS:-}" ]; then args+=($EXTRA_ARGS); fi
exec "$QCS/llama.cpp/build/bin/llama-server" "${args[@]}"
SCRIPT

# --- write-opencode-config: regenerates opencode.json from config/server.env ---
cat > "$QCS/bin/write-opencode-config" <<'SCRIPT'
#!/usr/bin/env bash
# Regenerates config/opencode/opencode.json so it always matches config/server.env.
set -euo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
set -a; . "$QCS/config/server.env"; set +a
OUT=$(( CTX >= 131072 ? 32768 : CTX / 4 ))
mkdir -p "$QCS/config/opencode"
cat > "$QCS/config/opencode/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama.cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-server (local)",
      "options": { "baseURL": "http://$HOST:$PORT/v1", "apiKey": "none" },
      "models": {
        "qwen-local": {
          "name": "$(basename "$MODEL" .gguf) (local)",
          "limit": { "context": $CTX, "output": $OUT }
        }
      }
    }
  },
  "model": "llama.cpp/qwen-local",
  "small_model": "llama.cpp/qwen-local",
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
echo "Wrote $QCS/config/opencode/opencode.json (context $CTX)"
SCRIPT

# --- qwen-set: change a setting, keep OpenCode in sync, restart the service ---
cat > "$QCS/bin/qwen-set" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: qwen-set                  show current settings
#        qwen-set KEY=VALUE ...    change settings, sync OpenCode, restart the service
set -euo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ENV="$QCS/config/server.env"
if [ $# -eq 0 ]; then grep -E '^[A-Z_]+=' "$ENV"; exit 0; fi
for kv in "$@"; do
  k="${kv%%=*}"; v="${kv#*=}"
  case "$k" in
    CUDA_HOME|MODEL|NCMOE|CTX|THREADS|HOST|PORT|SAMPLING|EXTRA_ARGS|AGENT_TEMP) ;;
    *) echo "Unknown setting: $k" >&2; exit 1 ;;
  esac
  if grep -q "^$k=" "$ENV"; then
    sed -i "s|^$k=.*|$k=\${$k:-$v}|" "$ENV"
  else
    echo "$k=\${$k:-$v}" >> "$ENV"
  fi
  echo "Set $k=$v"
done
"$QCS/bin/write-opencode-config"
if systemctl is-enabled --quiet qwen-server 2>/dev/null; then
  sudo systemctl reset-failed qwen-server 2>/dev/null || true
  sudo systemctl restart qwen-server
  echo "qwen-server service restarted"
fi
SCRIPT

# --- find-ncmoe: finds the lowest NCMOE that fits in VRAM and saves it ---
cat > "$QCS/bin/find-ncmoe" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: find-ncmoe N [N ...]   e.g. find-ncmoe 26 28 30 32
# Starts the server with each value in turn; saves the first that works (+2 headroom).
set -uo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: find-ncmoe N [N ...]"; exit 1; }
if systemctl is-active --quiet qwen-server 2>/dev/null; then sudo systemctl stop qwen-server; fi
pkill -f "$QCS/llama.cpp/build/bin/llama-server" 2>/dev/null; sleep 2
log="$QCS/cache/find-ncmoe.log"
for n in "$@"; do
  echo "Trying NCMOE=$n ..."
  NCMOE=$n "$QCS/bin/qwen-server" > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if grep -qi "listening" "$log"; then
      kill "$pid"; wait "$pid" 2>/dev/null
      echo "  OK at $n. Saving NCMOE=$((n + 2)) (2 layers of headroom)."
      "$QCS/bin/qwen-set" NCMOE="$((n + 2))"
      exit 0
    fi
    sleep 2
  done
  echo "  failed: $(grep -m1 -iE 'out of memory|error|not found' "$log")"
done
echo "No value started. Try higher values, lower the context (qwen-set CTX=65536), or use NCMOE=auto."
exit 1
SCRIPT

# --- sandbox: runs OpenCode (or any command) in an isolated container ---
cat > "$QCS/bin/sandbox" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: sandbox [project-dir] [command ...]
#   sandbox                 OpenCode on the current directory
#   sandbox ~/code/app bash a shell in the same sandbox
set -euo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PROJECT="$(realpath "${1:-$PWD}")"
case "$PROJECT" in "$QCS"|"$QCS"/*) echo "Refusing to mount the stack's own directory." >&2; exit 1 ;; esac
[ "$PROJECT" != "$HOME" ] || { echo "Refusing to mount your whole home directory." >&2; exit 1; }
NAME="qcs-$(basename "$PROJECT" | tr -c 'a-zA-Z0-9_.-' '-')"
docker image inspect qwen-coding-stack-sandbox:latest >/dev/null || {
  echo "If the image is missing, build it: re-run install.sh, or the guide's 'Build the sandbox image' step." >&2
  exit 1
}
exec docker run -it --rm --name "$NAME" \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  --memory "${SANDBOX_MEMORY:-@@SBMEM@@}" --cpus "${SANDBOX_CPUS:-@@SBCPU@@}" \
  -v "$PROJECT":/workspace \
  -v "$QCS/config/opencode":/home/dev/.config/opencode:ro \
  -v "$QCS/sandbox/opencode-data":/home/dev/.local/share/opencode \
  -w /workspace \
  qwen-coding-stack-sandbox:latest "${@:2}"
SCRIPT

chmod +x "$QCS"/bin/*
  sed -i "s/@@SBMEM@@/$SANDBOX_MEMORY/; s/@@SBCPU@@/$SANDBOX_CPUS/" "$QCS/bin/sandbox"
}
