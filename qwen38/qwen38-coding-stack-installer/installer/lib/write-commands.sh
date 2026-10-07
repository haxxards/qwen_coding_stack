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
if systemctl is-enabled --quiet qwen38-server 2>/dev/null; then
  sudo systemctl reset-failed qwen38-server 2>/dev/null || true
  sudo systemctl restart qwen38-server
  echo "qwen38-server service restarted"
fi
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
if systemctl is-active --quiet qwen38-server 2>/dev/null; then sudo systemctl stop qwen38-server; fi
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
#   qwen38-sandbox ~/code/app bash  a shell in the same sandbox
set -euo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PROJECT="$(realpath "${1:-$PWD}")"
case "$PROJECT" in "$Q38"|"$Q38"/*) echo "Refusing to mount the stack's own directory." >&2; exit 1 ;; esac
[ "$PROJECT" != "$HOME" ] || { echo "Refusing to mount your whole home directory." >&2; exit 1; }
NAME="q38-$(basename "$PROJECT" | tr -c 'a-zA-Z0-9_.-' '-')"
exec docker run -it --rm --name "$NAME" \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  --memory "${SANDBOX_MEMORY:-@@SBMEM@@}" --cpus "${SANDBOX_CPUS:-@@SBCPU@@}" \
  -v "$PROJECT":/workspace \
  -v "$Q38/config/opencode":/home/dev/.config/opencode:ro \
  -v "$Q38/sandbox/opencode-data":/home/dev/.local/share/opencode \
  -w /workspace \
  qwen38-coding-stack-sandbox:latest "${@:2}"
SCRIPT

chmod +x "$Q38"/bin/*
  sed -i "s/@@SBMEM@@/$SANDBOX_MEMORY/; s/@@SBCPU@@/$SANDBOX_CPUS/" "$Q38/bin/qwen38-sandbox"
}
