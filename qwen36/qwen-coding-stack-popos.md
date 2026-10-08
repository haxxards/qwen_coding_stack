# Local Qwen Coding Assistant — Pop!_OS 24.04 (Home Desktop)

**Hardware:** RTX 5080 (16 GB VRAM, Blackwell), 32 GB RAM.
**Companion guide:** `qwen-coding-stack-debian-work-laptop.md` covers the work laptop. **Installer:** `qwen-coding-stack-installer.tar.gz` automates this guide (see **Automated install**).

| Layer | Choice |
|---|---|
| OS | Pop!_OS 24.04 (Ubuntu 24.04 "noble" base) |
| GPU driver | System76's packaged NVIDIA open driver (`system76-driver-nvidia`) |
| CUDA toolkit | CUDA 13.1 (avoid 13.2) from NVIDIA's Ubuntu repo, toolkit only, pinned low |
| Inference server | llama.cpp `llama-server`, built for Blackwell (sm_120), run as a system service |
| Model | Qwen3.6-35B-A3B, Unsloth `UD-Q4_K_XL` GGUF, experts partly offloaded to RAM |
| Coding agent | OpenCode, with subagent delegation disabled |
| Sandbox | Docker container per project, non-root, only the project folder mounted |

Run the sections in order. Why each choice was made is in **Rationale** at the bottom.

## Project layout

Everything lives in one directory:

```
/home/tristanv/Development/qwen-coding-stack/
├── bin/                   commands: qwen-server, qwen-set, find-ncmoe, sandbox, qwen-stack, write-opencode-config
├── config/
│   ├── shell.sh           sourced by ~/.bashrc (adds bin/ to your PATH)
│   ├── server.env         model, GPU/RAM split, context size, CUDA path (single source of truth)
│   └── opencode/
│       └── opencode.json  generated from server.env; mounted read-only into sandboxes
├── llama.cpp/             llama.cpp source and build
├── models/                GGUF model files
├── sandbox/
│   └── Dockerfile         sandbox image
├── sandbox-state/         per project: OpenCode sessions, prompt and shell history, downloaded tools
├── cache/                 downloads, Hugging Face and pip caches, logs
└── venv/                  Python environment for the Hugging Face CLI
```

The only things placed outside it are system-level integration that can't live in a project folder: apt packages and apt settings under `/etc/apt/`, the service file `/etc/systemd/system/qwen-server.service`, the Docker image (in Docker's own storage), and **one line** in `~/.bashrc` that sources `config/shell.sh`.

**Every block in this guide is safe to re-run.** Blocks check before they install or download, scripts are simply rewritten, and your tuned settings in `config/server.env` are never overwritten (it's only created if missing; change it with `qwen-set`). Each block starts by setting `QCS`, so you can paste any block into a fresh terminal.

---

## Automated install (optional)

`installer/install.sh` runs every numbered step below; see the [README](../README.md). It also migrates the earlier manual setup; once everything works, `install.sh --cleanup-old` deletes that setup's leftover files.

---

## 1. Create the project directory

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
mkdir -p "$QCS"/{bin,config/opencode,models,sandbox,sandbox-state,cache,venv}
cat > "$QCS/config/shell.sh" <<EOF
# qwen-coding-stack: sourced from ~/.bashrc. Safe to source repeatedly.
export QCS="$QCS"
case ":\$PATH:" in *":\$QCS/bin:"*) ;; *) export PATH="\$QCS/bin:\$PATH" ;; esac
EOF
LINE="[ -f \"$QCS/config/shell.sh\" ] && . \"$QCS/config/shell.sh\""
grep -qxF "$LINE" ~/.bashrc || echo "$LINE" >> ~/.bashrc
. "$QCS/config/shell.sh"
echo "QCS=$QCS"
```

---

## 2. Migrate from the earlier setup (skip on a fresh install)

Reuses the model you already downloaded (saves a 22 GB download), stops the old per-user service so it doesn't hold the GPU, and removes the PATH/CUDA lines the earlier guide added to `~/.bashrc` (a backup is saved in the project's `cache/` first). The old files themselves are removed later, in **Clean up the old layout**, once the new setup works.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
OLD="$HOME/models/Qwen3.6-35B-A3B-GGUF"
NEW="$QCS/models/Qwen3.6-35B-A3B-GGUF"
if [ -d "$OLD" ] && [ ! -e "$NEW" ]; then mv "$OLD" "$NEW" && echo "Moved model to $NEW"; else echo "Model: nothing to move"; fi
if [ -f "$HOME/.config/systemd/user/qwen-server.service" ]; then
  systemctl --user disable --now qwen-server 2>/dev/null || true
  echo "Stopped old per-user service (its file is removed in the service step)"
fi
pkill -f llama-server 2>/dev/null || true
PATTERNS='^export (PATH=\$HOME/bin:\$PATH|PATH=\$HOME/Development/qwen:\$PATH|PATH=/usr/local/cuda-[0-9.]+/bin:\$PATH|LD_LIBRARY_PATH=/usr/local/cuda-[0-9.]+/lib64:)'
if grep -qE "$PATTERNS" ~/.bashrc; then
  cp ~/.bashrc "$QCS/cache/bashrc.backup.$(date +%Y%m%d-%H%M%S)"
  grep -vE "$PATTERNS" ~/.bashrc > "$QCS/cache/bashrc.new" && cat "$QCS/cache/bashrc.new" > ~/.bashrc
  rm -f "$QCS/cache/bashrc.new"
  echo "Removed old PATH/CUDA lines from ~/.bashrc (backup in $QCS/cache/)"
else
  echo "~/.bashrc: nothing to remove"
fi
```

---

## 3. Base system packages

Pop!_OS already enables every component needed (`main restricted universe multiverse`), so no source edits are required.

```bash
sudo apt update
sudo apt install -y build-essential cmake git curl wget pciutils iproute2 \
  libcurl4-openssl-dev python3 python3-venv ca-certificates
```

---

## 4. NVIDIA driver and CUDA toolkit

**Driver: use Pop!_OS's own package, not NVIDIA's.** Pop!_OS ships and prioritizes its own NVIDIA driver; mixing in a driver from another repo causes package conflicts. On Pop!_OS 24.04 this package installs the **open** kernel module, which RTX 50-series cards require.

```bash
sudo apt install -y system76-driver-nvidia
if grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
  echo "Open NVIDIA driver is loaded."
  nvidia-smi | grep -o 'CUDA Version: [0-9.]*'
else
  echo ">>> Reboot now (sudo reboot), then run this block again."
fi
```

**CUDA toolkit: add NVIDIA's Ubuntu 24.04 repo, pinned low** so it can only supply CUDA toolkit packages and never replaces Pop's driver.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  wget -qO "$QCS/cache/cuda-keyring.deb" \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i "$QCS/cache/cuda-keyring.deb"
fi
sudo tee /etc/apt/preferences.d/nvidia-cuda-toolkit-only >/dev/null <<'EOF'
# Only use NVIDIA's repo for packages nothing else provides (the CUDA toolkit).
# Pop!_OS keeps control of the driver.
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 100
EOF
sudo apt update
```

Install a pinned toolkit. **Do not use CUDA 13.2.** Use 13.1 if `nvidia-smi` above reported 13.1 or higher; if it reported 13.0, set `CUDA_VER=13.0`.

```bash
CUDA_VER=13.1
sudo apt install -y "cuda-toolkit-${CUDA_VER/./-}"
"/usr/local/cuda-${CUDA_VER}/bin/nvcc" --version
```

Nothing is added to your `~/.bashrc` for CUDA: the build and the server find the toolkit themselves.

> **Pop!_OS kernel updates:** Pop ships new kernels often, and occasionally the NVIDIA module fails to build for one. After a kernel update, run `nvidia-smi` before a session. If it fails, reboot, hold **Space** at boot, pick the previous kernel ("oldkern"), and wait for a Pop driver update.

---

## 5. Install Docker

```bash
sudo apt install -y docker.io
sudo systemctl enable --now docker
if id -nG "$USER" | grep -qw docker; then
  echo "Already in the docker group."
else
  sudo usermod -aG docker "$USER"
  echo ">>> Added to the docker group. Log out and back in once, then continue."
fi
```

> Membership in the `docker` group is effectively root access. That's normal for a single-user workstation; use rootless Docker if that's a concern.

After logging back in, confirm Docker works and note the bridge address (normally `172.17.0.1`):

```bash
docker run --rm hello-world >/dev/null && echo "Docker OK"
ip -4 -o addr show docker0 | awk '{print $4}'
```

---

## 6. Build llama.cpp

Clones on the first run and pulls updates afterwards; `cmake` only rebuilds what changed. The CUDA toolkit is picked automatically (newest 13.x, skipping 13.2). `-DCMAKE_CUDA_ARCHITECTURES=120` targets the RTX 5080 (Blackwell) only, which keeps the build fast.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
CUDA_HOME=$(ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1)
[ -n "$CUDA_HOME" ] || { echo "No usable CUDA 13.x toolkit found; redo step 4."; false; }
echo "Using $CUDA_HOME"
if [ -d "$QCS/llama.cpp/.git" ]; then
  git -C "$QCS/llama.cpp" pull --ff-only
else
  git clone https://github.com/ggml-org/llama.cpp "$QCS/llama.cpp"
fi
cmake -S "$QCS/llama.cpp" -B "$QCS/llama.cpp/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc"
cmake --build "$QCS/llama.cpp/build" --config Release -j"$(nproc)" \
  --target llama-server llama-cli llama-bench
ls -l "$QCS/llama.cpp/build/bin/llama-server"
```

If you later switch CUDA versions and `cmake` complains that the compiler changed, delete the build folder once (`rm -rf "$QCS/llama.cpp/build"`) and run this block again.

---

## 7. Download the model

Creates the Hugging Face CLI environment only if it's missing. `hf download` skips files that are already complete and resumes partial ones. The vision projector (`mmproj`) is skipped on purpose: it isn't needed for coding and would use VRAM.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
if [ ! -x "$QCS/venv/bin/hf" ]; then
  python3 -m venv "$QCS/venv"
  PIP_CACHE_DIR="$QCS/cache/pip" "$QCS/venv/bin/pip" install -U huggingface_hub
fi
HF_HOME="$QCS/cache/huggingface" "$QCS/venv/bin/hf" download unsloth/Qwen3.6-35B-A3B-GGUF \
  --local-dir "$QCS/models/Qwen3.6-35B-A3B-GGUF" \
  --include "*UD-Q4_K_XL*"
ls -lh "$QCS/models/Qwen3.6-35B-A3B-GGUF"
```

---

## 8. Create the server settings file

`config/server.env` is the single source of truth for the server, used identically when you run `qwen-server` in a terminal and when systemd runs it. This block only creates it if it doesn't exist, so it never undoes your tuning. The CUDA path and Docker bridge address are detected automatically.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
if [ -f "$QCS/config/server.env" ]; then
  echo "server.env already exists; leaving it alone. Change values with: qwen-set KEY=VALUE"
else
  CUDA_HOME=$(ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1)
  BRIDGE=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  cat > "$QCS/config/server.env" <<EOF
# qwen-coding-stack server settings. Change with: qwen-set KEY=VALUE
# Each line keeps a value already set in the environment, so one-off
# overrides work, e.g.:  NCMOE=30 qwen-server
CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}
MODEL=\${MODEL:-$QCS/models/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}
NCMOE=\${NCMOE:-24}
CTX=\${CTX:-131072}
THREADS=\${THREADS:-}
HOST=\${HOST:-${BRIDGE:-172.17.0.1}}
PORT=\${PORT:-8080}
SAMPLING=\${SAMPLING:---temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0}
EXTRA_ARGS=\${EXTRA_ARGS:-}
AGENT_TEMP=\${AGENT_TEMP:-0.6}
EOF
  echo "Created $QCS/config/server.env"
fi
cat "$QCS/config/server.env"
```

What the settings mean:

| Setting | Meaning |
|---|---|
| `NCMOE` | How many layers keep their expert weights in system RAM instead of VRAM. Higher = less VRAM, a bit slower. `auto` lets llama.cpp decide. |
| `CTX` | Context window in tokens. `opencode.json` is regenerated to match automatically. |
| `THREADS` | CPU threads for the experts in RAM. Empty = llama.cpp's default. |
| `HOST` | The Docker bridge address: reachable from your machine and sandboxes, **not** from your network. |
| `SAMPLING` | Server-side sampling (Qwen's recommended coding settings). |
| `EXTRA_ARGS` | Anything else to pass to `llama-server` (e.g. MTP, KV-cache type). |
| `AGENT_TEMP` | Temperature OpenCode sends; it overrides the server's, so it's set here too. |

The server always runs with `-np 1` (the whole context goes to one request; splitting it between parallel slots recreates the small-context failures you had with Ollama).

---

## 9. Install the project's commands and OpenCode config

Write the project's commands into `bin/`. This block overwrites the scripts every time (they hold no settings), so re-running it is how you pick up fixes to them.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
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
# Restart the service only if it's running (or failed): a server stopped with 'qwen-stack down' stays down.
case "$(systemctl show -p ActiveState --value qwen-server 2>/dev/null || true)" in
  active|activating|failed)
    sudo systemctl reset-failed qwen-server 2>/dev/null || true
    sudo systemctl restart qwen-server
    echo "qwen-server service restarted" ;;
  *)
    if pgrep -ax llama-server | grep -qF "$QCS/llama.cpp/build/bin/llama-server"; then
      echo "Restart the running server to apply this: qwen-stack down, then qwen-stack up --server"
    fi ;;
esac
SCRIPT

# --- find-ncmoe: finds the lowest NCMOE that fits in VRAM and saves it ---
cat > "$QCS/bin/find-ncmoe" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: find-ncmoe N [N ...]   e.g. find-ncmoe 26 28 30 32
# Starts the server with each value in turn; saves the first that works (+2 headroom).
set -uo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: find-ncmoe N [N ...]"; exit 1; }
was_active=no
if systemctl is-active --quiet qwen-server 2>/dev/null; then was_active=yes; sudo systemctl stop qwen-server; fi
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
      [ "$was_active" = no ] || sudo systemctl start qwen-server
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
#   sandbox ~/code/app bash a shell in the same sandbox (joins it if it's already open)
# Each project keeps its OpenCode sessions, prompt and shell history, and the tools
# OpenCode downloads in sandbox-state/<project>/, so the next session picks them up.
set -euo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PROJECT="$(realpath "${1:-$PWD}")"
case "$PROJECT" in "$QCS"|"$QCS"/*) echo "Refusing to mount the stack's own directory." >&2; exit 1 ;; esac
[ "$PROJECT" != "$HOME" ] || { echo "Refusing to mount your whole home directory." >&2; exit 1; }
ID="$(printf '%s' "${PROJECT##*/}" | tr -c 'a-zA-Z0-9_.-' '-')-$(printf '%s' "$PROJECT" | sha256sum | cut -c1-8)"
NAME="qcs-$ID"
STATE="$QCS/sandbox-state/$ID"
docker image inspect qwen-coding-stack-sandbox:latest >/dev/null || {
  echo "If the image is missing, build it: qwen-stack build" >&2
  exit 1
}
# Already open in another terminal: join that container.
if [ "$(docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]; then
  [ $# -gt 1 ] || set -- . opencode
  exec docker exec -it -w /workspace "$NAME" "${@:2}"
fi
mkdir -p "$STATE"/{data,state,cache}
printf '%s\n' "$PROJECT" > "$STATE/path"
exec docker run -it --rm --name "$NAME" --label "qwen-coding-stack.project=$PROJECT" \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  --memory "${SANDBOX_MEMORY:-6g}" --cpus "${SANDBOX_CPUS:-4}" \
  -v "$PROJECT":/workspace \
  -v "$QCS/config/opencode/opencode.json":/home/dev/.config/opencode/opencode.json:ro \
  -v "$STATE/data":/home/dev/.local/share/opencode \
  -v "$STATE/state":/home/dev/.local/state \
  -v "$STATE/cache":/home/dev/.cache \
  -e HISTFILE=/home/dev/.local/state/bash_history \
  -w /workspace \
  qwen-coding-stack-sandbox:latest "${@:2}"
SCRIPT

# --- qwen-stack: bring the server and a project's sandbox up, and take them down ---
cat > "$QCS/bin/qwen-stack" <<'SCRIPT'
#!/usr/bin/env bash
# Day-to-day control of the stack. Nothing here deletes projects or saved sessions.
#   qwen-stack up [DIR]            start the server if needed, then open OpenCode on DIR (default: .)
#   qwen-stack up --server         only start the server
#   qwen-stack shell [DIR]         a bash shell in DIR's sandbox (joins it if it's already open)
#   qwen-stack down                close all sandboxes and stop the server (frees the GPU)
#   qwen-stack status              server, GPU memory, open sandboxes, projects with saved sessions
#   qwen-stack logs                follow the server log
#   qwen-stack build [--no-cache]  build the sandbox image (--no-cache also updates OpenCode)
#   qwen-stack boot on|off         start the server at boot, or not
set -euo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SVC=qwen-server; OTHER_SVC=qwen38-server
IMAGE=qwen-coding-stack-sandbox:latest; LABEL=qwen-coding-stack.project
SERVER_BIN="$QCS/llama.cpp/build/bin/llama-server"; SERVER_LOG="$QCS/cache/server.log"
set -a; . "$QCS/config/server.env"; set +a
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
    nohup "$QCS/bin/qwen-server" > "$SERVER_LOG" 2>&1 < /dev/null &
    pid=$!   # stays the same when qwen-server execs llama-server
  fi
  others=$(pgrep -ax llama-server | grep -vF "$SERVER_BIN" || true)
  [ -z "$others" ] || printf 'Note: another llama-server is running and may hold GPU memory:\n%s\n' "$others" >&2
  printf 'Loading the model'
  for _ in $(seq 1 120); do
    if ready; then printf '\nServer is up at %s/v1\n' "$URL"; return; fi
    if has_service; then
      case "$(svc ActiveState)/$(svc SubState)" in
        active/*|activating/start*) ;;
        *) echo; server_log 30 >&2; die "The server didn't start (log above). Full log: qwen-stack logs" ;;
      esac
    elif ! running && ! { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; then
      echo; server_log 30 >&2; die "The server exited (log above; full log: $SERVER_LOG)"
    fi
    printf .; sleep 3
  done
  echo; die "The server isn't answering after 6 minutes. Check: qwen-stack logs"
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
  [ -f "$QCS/sandbox/Dockerfile" ] \
    || die "$QCS/sandbox/Dockerfile is missing: re-run install.sh, or the guide's 'Build the sandbox image' step."
  docker build "$@" -t "$IMAGE" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" - < "$QCS/sandbox/Dockerfile"
}

ensure_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 && return
  echo "The sandbox image isn't built yet. Building it now (first time only, a few minutes)."
  build_image
}

status() {
  local state=stopped f p
  if ready; then state="ready at $URL/v1"
  elif has_service && [ "$(svc ActiveState)" = failed ]; then state="failed (see: qwen-stack logs)"
  elif running || { has_service && [ "$(svc ActiveState)" = activating ]; }; then state=loading
  fi
  echo "Server:      $state"
  echo "Model:       $(basename "$MODEL" .gguf), context $CTX"
  if has_service; then
    echo "At boot:     $(systemctl is-enabled "$SVC" 2>/dev/null || true)  (change with: qwen-stack boot on|off)"
  fi
  if command -v nvidia-smi >/dev/null; then
    echo "GPU memory:  $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | head -1 | sed 's/, / used of /')"
  fi
  echo "Open sandboxes:"
  docker ps --filter "label=$LABEL" --format "{{.Label \"$LABEL\"}}  ({{.Status}})" 2>/dev/null | sed 's/^/  /' | grep . || echo "  none"
  echo "Projects with saved sessions:"
  for f in "$QCS"/sandbox-state/*/path; do
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
      echo "$SVC no longer starts at boot. Start it when you need it: qwen-stack up" ;;
    *) die "usage: qwen-stack boot on|off" ;;
  esac
}

case "${1:-}" in
  up)
    if [ "${2:-}" = --server ]; then start_server; exit 0; fi
    [ -d "${2:-.}" ] || die "No such directory: ${2:-.}"
    ensure_image
    start_server
    exec "$QCS/bin/sandbox" "${2:-.}" ;;
  shell) ensure_image; exec "$QCS/bin/sandbox" "${2:-.}" bash ;;
  down) stop_all ;;
  status) status ;;
  logs)
    if has_service; then exec sudo journalctl -u "$SVC" -n 50 -f; else exec tail -n 50 -F "$SERVER_LOG"; fi ;;
  build)
    case "${2:-}" in ""|--no-cache) ;; *) die "usage: qwen-stack build [--no-cache]" ;; esac
    build_image ${2:+"$2"} ;;
  boot) boot "${2:-}" ;;
  ""|-h|--help|help) sed -n '2,10p' "$0" ;;
  *) sed -n '2,10p' "$0" >&2; exit 1 ;;
esac
SCRIPT

chmod +x "$QCS"/bin/*
ls -l "$QCS/bin"
```

Generate the OpenCode config from your settings, and check the commands are on your PATH:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
"$QCS/bin/write-opencode-config"
. "$QCS/config/shell.sh"
command -v qwen-server qwen-set find-ncmoe sandbox qwen-stack
```

What the OpenCode config does:

- `"task": { "*": "deny" }` removes subagents from the model's tool list entirely, so it can't try to delegate. The `general`, `explore` and `scout` subagents are also disabled outright, as a second layer.
- `small_model` and `"share": "disabled"` keep everything local. By default OpenCode sends session-title generation to a hosted model.
- `edit` and `bash` set to `ask` means you approve each change and command. To change permissions, edit `bin/write-opencode-config` (the JSON file itself is regenerated by `qwen-set`).
- `opencode.json` is mounted **read-only** into sandboxes, so the model can't rewrite its own permissions. The rest of `~/.config/opencode` stays writable inside the container, because OpenCode writes files there at startup.

---

## 10. First run and GPU/RAM tuning

Start the server once in a terminal to see it load:

```bash
qwen-server
```

In a second terminal, test it:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
. "$QCS/config/server.env"
curl -s "http://$HOST:$PORT/v1/models"
curl -s "http://$HOST:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-local","messages":[{"role":"user","content":"Write a Python hello world."}]}'
```

Stop it with **Ctrl+C** in the first terminal.

If it fails with `cudaMalloc failed: out of memory` (or simply to find the fastest setting), let `find-ncmoe` find the lowest value that fits. It stops any running server, tries each value, saves the first that works plus 2 for headroom, and restarts the service if it's installed:

```bash
find-ncmoe 26 28 30 32 34 36 38 40
qwen-set
```

Each step of 2 moves roughly 1 GB of expert weights from VRAM to RAM. If nothing in the range works, see **Troubleshooting → GPU out of memory**.

---

## 11. Run the server as a system service

A system service starts at boot without needing you to log in, and its file lives in `/etc/systemd/system/` rather than in your home directory. It runs as your user, through the same `qwen-server` script, so it uses exactly the same settings as a terminal run. It waits for Docker's bridge before starting and stops retrying after 5 failures so the real error stays visible.

This block also removes the older per-user service if one exists.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
if [ -f "$HOME/.config/systemd/user/qwen-server.service" ]; then
  systemctl --user disable --now qwen-server 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/qwen-server.service"
  systemctl --user daemon-reload
  echo "Removed old per-user service."
fi
pkill -f "$QCS/llama.cpp/build/bin/llama-server" 2>/dev/null || true
sudo tee /etc/systemd/system/qwen-server.service >/dev/null <<EOF
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
EOF
sudo systemctl daemon-reload
sudo systemctl reset-failed qwen-server 2>/dev/null || true
sudo systemctl enable qwen-server
sudo systemctl restart qwen-server
sleep 30
systemctl status qwen-server --no-pager
```

Check it's answering:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
. "$QCS/config/server.env"
curl -s "http://$HOST:$PORT/v1/models"
```

Logs:

```bash
sudo journalctl -u qwen-server -n 60 --no-pager
```

---

## 12. Build the sandbox image

The container runs as a non-root user whose UID matches yours, so files it creates in your project are owned by you. Re-running rebuilds only what changed.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
mkdir -p "$QCS/sandbox"
cat > "$QCS/sandbox/Dockerfile" <<'EOF'
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
EOF
docker build -t qwen-coding-stack-sandbox:latest \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  "$QCS/sandbox"
```

To update OpenCode later, rebuild without the cache:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
docker build --no-cache -t qwen-coding-stack-sandbox:latest \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" "$QCS/sandbox"
```

If the OpenCode install script ever fails, replace that `RUN curl ...` line with `RUN npm config set prefix ~/.npm-global && npm i -g opencode-ai` and set `ENV PATH="/home/dev/.npm-global/bin:${PATH}"`.

---

## 13. Daily use

Session commands (git checkpoint first, review or undo after): [README](../README.md#use).

```bash
qwen-stack shell ~/code/app   # a shell in that project's sandbox, to run tests yourself
qwen-stack status             # server, GPU memory, open sandboxes, projects with saved sessions
qwen-stack down               # close all sandboxes, stop the server, free the GPU; deletes nothing
qwen-stack boot off           # don't start the server at boot; 'qwen-stack up' starts it when needed
qwen-stack logs               # follow the server log
```

Look at or change server settings (changes update OpenCode and restart the server if it's running):

```bash
qwen-set
qwen-set CTX=65536
```

Service status and logs:

```bash
systemctl status qwen-server --no-pager
sudo journalctl -u qwen-server -n 60 --no-pager
```

Update everything (llama.cpp, OpenCode in the image) by re-running the **Build llama.cpp** and **Build the sandbox image** steps, then:

```bash
sudo systemctl restart qwen-server
```

Sandbox notes:

- Each project's OpenCode sessions, prompt and shell history, and the tools OpenCode downloads are kept in `sandbox-state/<folder>-<id>/` and mounted again next time. The id comes from the folder's full path, so a moved or renamed project starts without them.
- Running `sandbox` (or `qwen-stack shell`) on a project that's already open joins the same container; it closes when the first window closes.
- Sessions from before per-project storage stay in `sandbox/opencode-data/`; copy them into a project's `sandbox-state/<folder>-<id>/data/` to continue them there.
- It mounts only the project folder, runs as a non-root user with all capabilities dropped, and refuses to mount your whole home directory or the stack itself.
- Default limits are `--memory 6g --cpus 4`. Override per run: `SANDBOX_MEMORY=8g SANDBOX_CPUS=6 sandbox`.
- The container has internet access (for `pip`/`npm`). For stricter isolation, create a dedicated Docker network and firewall its egress except to the server's address and port.

---

## 14. Optional: MTP speculative decoding

Unsloth ships MTP GGUFs. On this MoE model the gain is modest (about 1.15–1.2x), so try it only after everything else works. MTP uses ~1 GB extra memory, so re-run `find-ncmoe` afterwards.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
HF_HOME="$QCS/cache/huggingface" "$QCS/venv/bin/hf" download unsloth/Qwen3.6-35B-A3B-MTP-GGUF \
  --local-dir "$QCS/models/Qwen3.6-35B-A3B-MTP-GGUF" --include "*UD-Q4_K_XL*"
MTP=$(ls "$QCS"/models/Qwen3.6-35B-A3B-MTP-GGUF/*.gguf | sort | head -1)
qwen-set MODEL="$MTP" EXTRA_ARGS="--spec-type draft-mtp --spec-draft-n-max 2"
find-ncmoe 26 28 30 32 34 36 38 40
```

To turn it off again:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
qwen-set MODEL="$QCS/models/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" EXTRA_ARGS=
```

---

## 15. Optional: Aider instead of OpenCode

For a turn-by-turn chat that edits files and auto-commits, with no autonomous command execution. It installs into the container's temporary storage each run.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
. "$QCS/config/server.env"
sandbox . bash -c "python3 -m venv /tmp/aider && /tmp/aider/bin/pip install -q aider-chat && \
  OPENAI_API_BASE=http://$HOST:$PORT/v1 OPENAI_API_KEY=none /tmp/aider/bin/aider --model openai/qwen-local"
```

---

## 16. Clean up the old layout (optional, after the new setup works)

Removes only what the earlier guide created outside the project. Safe to re-run.

```bash
rm -f "$HOME/Development/qwen/qwen-server" "$HOME/bin/sandbox"
rmdir "$HOME/Development/qwen" "$HOME/bin" 2>/dev/null || true
rm -rf "$HOME/llm-sandbox" "$HOME/.venvs/hf"
rmdir "$HOME/.venvs" "$HOME/models" 2>/dev/null || true
docker volume rm opencode-data 2>/dev/null || true
docker image rm llm-sandbox:latest 2>/dev/null || true
echo "Done. The old llama.cpp checkout is left in place:"
ls -d "$HOME/Development/llama.cpp" 2>/dev/null && echo "Remove it with: rm -rf $HOME/Development/llama.cpp"
```

---

## Troubleshooting

Start with the log; the lines just before `exiting` name the cause:

```bash
sudo journalctl -u qwen-server -n 150 --no-pager | grep -iE "error|fail|unable|cannot|not found|out of memory|bind" | tail -20
```

| Symptom | Cause | Fix |
|---|---|---|
| Service shows `status=203/EXEC` | systemd couldn't execute the script: wrong path or not executable | Re-run the **Install the project's commands** step, then the **system service** step. |
| `Start request repeated too quickly` | The service hit its 5-failure limit; the real error is earlier in the log | `sudo journalctl -u qwen-server -n 150 --no-pager \| grep -iE "error\|fail\|memory"`, fix, then `sudo systemctl reset-failed qwen-server && sudo systemctl restart qwen-server` |
| `cudaMalloc failed: out of memory` / `failed to allocate buffer for rs cache` | Model weights filled the GPU, no room for the context cache | See **GPU out of memory** below. |
| `Model not found: ...` | `MODEL` path doesn't match the downloaded file | `ls "$QCS/models"/*/` then `qwen-set MODEL=<full path>` |
| `couldn't bind HTTP server socket` / `Address already in use` | Another llama-server is running (often a terminal test) | `pkill -f llama-server; sudo systemctl restart qwen-server` |
| `Cannot assign requested address` | Docker bridge IP isn't the configured `HOST` | `ip -4 -o addr show docker0`, then `qwen-set HOST=<that IP>` |
| `error while loading shared libraries: libcudart.so` / `libcublas.so` | `CUDA_HOME` points at a toolkit that isn't installed | `ls -d /usr/local/cuda-*`, then `qwen-set CUDA_HOME=/usr/local/cuda-13.1` (your version) |
| `CUDA driver version is insufficient` | Toolkit newer than the driver supports | Compare `nvidia-smi` "CUDA Version" with `CUDA_HOME`; install the matching toolkit, rebuild llama.cpp |
| Installer prints `Driver supports CUDA ;` (blank) or stops with "toolkit is newer than the driver" | Older installer couldn't read newer `nvidia-smi` output; `CUDA_VER=13` also installs the newest 13.x | Use the current installer (it asks the driver directly and fixes `CUDA_HOME` in `server.env`), set `CUDA_VER=auto`, and re-run `install.sh` |
| Gibberish output | CUDA 13.2, or a KV-cache issue | Confirm `qwen-set` shows no 13.2 path; try `qwen-set EXTRA_ARGS="--cache-type-k bf16 --cache-type-v bf16"` |
| Agent "forgets" the task / tool calls fail | Context too small or mismatched | `qwen-set` keeps OpenCode in sync; if you edited `opencode.json` by hand, run `write-opencode-config` |
| `sandbox` says `No such image: qwen-coding-stack-sandbox:latest`, or `Unable to find image ... locally` then `denied` | The sandbox image was never built on this machine: the install stopped before that step, or the build failed | `qwen-stack build` (`qwen-stack up` also builds it when it's missing). If it says `sandbox/Dockerfile` is missing, run the **Build the sandbox image** step or re-run `install.sh` |
| Container can't reach the server | Server not running, or HOST mismatch | `systemctl status qwen-server`; `. $QCS/config/server.env; curl http://$HOST:$PORT/v1/models` |
| OpenCode stops at startup with `FileSystem.writeFile (/home/dev/.config/opencode/.gitignore)` | An older `bin/sandbox` mounted the whole config folder read-only, and current OpenCode writes files there | Re-run the **Install the project's commands** step (or `install.sh`); now only `opencode.json` is read-only |
| Very slow generation | Too many experts in RAM, or other GPU apps | Re-run `find-ncmoe` with lower values; close GPU-heavy apps |
| `nvidia-smi` fails after a kernel update | NVIDIA module didn't build for the new kernel | Boot the previous kernel (hold Space at boot → oldkern); `sudo dkms status`; then `sudo apt update && sudo apt full-upgrade` once a fixed driver is out |
| apt wants to replace Pop's NVIDIA driver | NVIDIA repo pin missing | `cat /etc/apt/preferences.d/nvidia-cuda-toolkit-only`; re-run the CUDA repo block |

### GPU out of memory

**What it looks like** in `sudo journalctl -u qwen-server`:

```
cudaMalloc failed: out of memory
failed to initialize the context: failed to allocate buffer for rs cache
llama_server: exiting due to model loading error
```

You may also see `common_fit_params: failed to fit params to free device memory: n_gpu_layers already set by user to 99, abort`. That's llama.cpp's automatic memory fitting switching itself off because a fixed `NCMOE` is set. It's informational, not the cause.

**What it means:** the weights loaded, but there was no room left for the context cache. Usually the shortfall is small. Other programs also use VRAM, so a value that worked once can fail later.

**1. See what's already using VRAM** (stop the server first so it isn't counted):

```bash
sudo systemctl stop qwen-server
pkill -f llama-server; sleep 2
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
nvidia-smi
```

On the Pop!_OS desktop the display runs on the NVIDIA card, so `cosmic-comp`, `Xwayland` and browsers appear in the list. With nothing else open, usage should be under ~1.5 GB. Close GPU-heavy apps (video in browsers, games) before starting the server, or accept a higher `NCMOE`.

**2. Find a value that fits** (saves it and restarts the service):

```bash
find-ncmoe 26 28 30 32 34 36 38 40
```

**3. If nothing in the range works**, every expert layer is already in RAM, so shrink the context:

```bash
qwen-set CTX=65536
find-ncmoe 26 28 30 32 34 36 38 40
```

**Alternative: automatic fitting.** llama.cpp can choose the split itself from the VRAM free at startup. It adapts if your desktop uses more or less VRAM, but you lose direct control and it may be slower than a tuned value:

```bash
qwen-set NCMOE=auto
sudo journalctl -u qwen-server -n 80 --no-pager | grep -iE "fit|listening|out of memory"
```

To go back to a tuned value, run `find-ncmoe 26 28 30 32 34 36 38 40` again.

---

## Rationale

**Why Qwen3.6-35B-A3B.** It's a Mixture-of-Experts model with about 3B parameters active per token. With `--n-cpu-moe`, attention and shared weights stay on the GPU while expert weights sit in system RAM, and only the few experts selected per token move across PCIe. That makes a ~22 GB model usable on a GPU with less VRAM than that. The dense Qwen3.6-27B needs ~18 GB at 4-bit; once part of a dense model spills to RAM, every token slows down, and slow generation causes agent timeouts.

**Why the Unsloth `UD-Q4_K_XL` quant.** Unsloth's dynamic quants are calibrated on real-world data, and their chat-template fixes improve tool calling for Qwen3.6, which agentic coding depends on. 4-bit is the usual balance of quality and size.

**Why llama.cpp instead of Ollama.** The original subagent failures most likely came from context size. Ollama defaults to a 4K context on GPUs under 24 GB, and agents start subagents with a fresh session containing the full system prompt and every tool definition, which overflows a small window immediately. `llama-server` makes context size, slot count, GPU/CPU split and sampling explicit, has first-class MoE offload controls, and exposes the OpenAI-compatible API every agent supports.

**Why OpenCode.** It's the most widely used open-source terminal coding agent, is actively released, and documents a llama.cpp provider configuration directly. Its permission system can remove the Task (subagent) tool from the model's view entirely, and each built-in subagent can be disabled. Per-edit and per-command approvals fit collaborative coding. Aider is a good git-native pair programmer, but its development slowed noticeably in 2026, so it's optional here.

**Why a Docker sandbox, and not agent permissions alone.** Agent permissions are a UX control, not a security boundary: there are documented cases of an agent routing around disabled write permissions through a subagent. The container enforces isolation at the OS level: only the project directory is visible, it runs as a non-root user with all capabilities dropped, resources are capped, and the agent's config is read-only. The model server stays on the host for direct GPU access and binds only to the Docker bridge, so it's never exposed to your network.

**Why one project directory with one settings file.** Every earlier service failure came from the terminal and the service seeing different things: a CUDA path only in `~/.bashrc`, a script at a different path than the unit expected, a tuned value that only existed in one place. Now `qwen-server` reads `config/server.env` itself, so the terminal and the service always run with identical settings, and `qwen-set` is the one place to change them (it also regenerates the OpenCode config so context sizes can't drift apart). Keeping everything in one folder also makes the setup easy to back up, move, or delete.

**Why a system service instead of a per-user one.** A per-user unit has to live in `~/.config/systemd/user/` and needs "lingering" enabled to start without a login. A system unit in `/etc/systemd/system/` keeps your home directory clean, starts at boot, and still runs as your user via `User=`.

**Why the guide is idempotent.** Each block checks before it installs, clones or downloads; scripts are rewritten wholesale; and `server.env` is created only if missing. Re-running any step (or the whole guide) repairs or updates the setup without undoing your tuning.

**Why CUDA 13.x but not 13.2.** CUDA 13.2 has a reported bug that produces gibberish with Qwen3.6 in llama.cpp, so the build and the settings file pick the newest installed 13.x toolkit other than 13.2.

**Why the driver comes from Pop!_OS and only the toolkit from NVIDIA.** Pop!_OS 24.04's `system76-driver-nvidia` installs NVIDIA's open kernel module (580/595 series at the time of writing), which RTX 50-series cards need, and System76 tests it against their kernels. Pop's repository takes priority over other sources, so installing NVIDIA's driver on top leads to dependency conflicts. NVIDIA's repo is added only for the CUDA toolkit, with a low apt pin so it can never replace the driver.

**Why these defaults for the RTX 5080.** `NCMOE=24` and a 128K context are a starting point for 16 GB; `find-ncmoe` adjusts for whatever the desktop is using. Community tests on a 16 GB card with 32 GB RAM show roughly 30–50 tokens/s with this model. `-DCMAKE_CUDA_ARCHITECTURES=120` builds only for Blackwell.

### References

- Unsloth, Qwen3.6 — How to Run Locally: https://unsloth.ai/docs/models/qwen3.6
- Qwen, Qwen3.6-35B-A3B announcement: https://qwen.ai/blog?id=qwen3.6-35b-a3b
- InsiderLLM, Best way to run Qwen 3.6 35B MoE locally: https://insiderllm.com/guides/best-way-run-qwen-3-6-35b-moe-locally/
- llama.cpp discussion on `--n-cpu-moe`: https://github.com/ggml-org/llama.cpp/discussions/22183
- XDA, local agent context limits: https://www.xda-developers.com/stopped-my-local-llm-agent-from-running-out-of-context/
- Hermes agent subagent context bug: https://github.com/NousResearch/hermes-agent/issues/44207
- Ollama / Qwen Code context mismatch: https://github.com/ollama/ollama/issues/18256
- OpenCode agents & task permissions: https://opencode.ai/docs/agents/
- OpenCode providers (llama.cpp config, `small_model`): https://opencode.ai/docs/providers/
- OpenCode subagent permission bypass report: https://github.com/anomalyco/opencode/issues/20549
- OpenCode recursion warning for global `task` permission: https://github.com/anomalyco/opencode/issues/17721
- Coding agent comparison incl. Aider release status (Sept 2026): https://www.morphllm.com/best-ai-coding-agents-2026
- Aider OpenAI-compatible API docs: https://aider.chat/docs/llms/openai-compat.html
- Pop!_OS open-driver default on 24.04: https://github.com/pop-os/pop/issues/3640
- Pop!_OS repo priority overriding other driver sources: https://github.com/pop-os/pop/issues/3579
