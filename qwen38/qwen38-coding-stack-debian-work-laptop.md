# Local Qwen3.8-27B Coding Assistant — Debian (Work Laptop)

**Hardware:** Intel i9-13950HX (8 P-cores + 16 E-cores), 64 GB DDR5-5600, NVIDIA RTX 4000 Ada Laptop (12 GB VRAM, Ada Lovelace), 1 TB NVMe.
**Companion files:** `qwen38-coding-stack-popos.md` (home desktop), `qwen38-coding-stack-installer.tar.gz` (automates this guide). The Qwen3.6 guides and installer are unchanged and can stay installed alongside this.

## Can this machine run it?

**It runs, but slowly. Keep Qwen3.6-35B-A3B as your daily model on this laptop and treat Qwen3.8 as an optional "slow but smarter" mode.**

| Option | Fits in 12 GB VRAM? | Expected generation speed | Verdict |
|---|---|---|---|
| UD-Q4_K_XL (17.6 GB) | No: ~7 GB of weights in RAM | Roughly 5–8 tokens/s | Not worth it |
| **UD-Q3_K_XL (13.1 GB)** | **No: ~4 GB of weights in RAM with a 64K context** | **Roughly 10–14 tokens/s** | **Usable for patient, quality-critical work** |
| UD-Q2_K_XL (9.8 GB) | Yes, with a ~32K context | Roughly 25–35 tokens/s | Fast, but 2-bit loses enough quality that it may not beat Qwen3.6 |

Why: Qwen3.8-27B is a **dense** model: every parameter is read for every token. Unlike the Qwen3.6 Mixture-of-Experts model, which ran well here with most of it in RAM, any part of a dense model in RAM is read over the much slower RAM bus on every token. 13.1 GB of weights plus context simply doesn't fit in 12 GB, so some of it must be in RAM.

What ~12 tokens/s means in practice: with thinking set to `medium`, a typical agent step (a few hundred to a couple of thousand tokens of thinking plus the answer) takes **one to three minutes**, versus well under a minute with Qwen3.6-35B-A3B. Fine for "go fix this test while I do something else"; frustrating for back-and-forth editing.

**Is it wasteful to try?** No, but set expectations. Trying costs a 13 GB download and about an hour, and switching back is one command. If you mostly need quick interactive help, stay with Qwen3.6. If you have harder tasks where better answers matter more than speed, Qwen3.8 at 3-bit is the better model even at this speed.

The speed figures are estimates from memory bandwidth (laptop GPU ~430 GB/s, dual-channel DDR5-5600 ~60–70 GB/s in practice), not measurements; `qwen38-find-fit` and a session will show the real numbers.

> **Work device check:** confirm with IT that installing drivers and Docker, and running a local model on company code, is within policy.

> **Different username?** Change the `Q38=` line at the top of each block; the scripts work from wherever they're installed.

## Project layout

Everything lives in one directory, separate from the Qwen3.6 stack so the two never interfere:

```
/home/tristanv/Development/qwen38-coding-stack/
├── bin/                   commands: qwen38-server, qwen38-set, qwen38-find-fit, qwen38-sandbox, qwen38-stack, qwen38-write-opencode-config
├── config/
│   ├── shell.sh           sourced by ~/.bashrc (adds bin/ to your PATH)
│   ├── server.env         model, GPU layers, context, KV cache, reasoning effort (single source of truth)
│   └── opencode/
│       └── opencode.json  generated from server.env; mounted read-only into sandboxes
├── installer/             the automated installer (optional)
├── llama.cpp/             llama.cpp source and build
├── models/                GGUF model files
├── sandbox/
│   └── Dockerfile         sandbox image
├── sandbox-state/         per project: OpenCode sessions, prompt and shell history, downloaded tools
├── cache/                 downloads, Hugging Face and pip caches, logs
└── venv/                  Python environment for the Hugging Face CLI
```

Outside it: apt packages and apt settings, the service file `/etc/systemd/system/qwen38-server.service`, the Docker image, and **one line** in `~/.bashrc`. The commands are all prefixed `qwen38-` so they never clash with the Qwen3.6 stack's `qwen-set`, `sandbox`, etc. The server listens on port **8081** (the Qwen3.6 stack uses 8080).

**Every block in this guide is safe to re-run.** Blocks check before they install or download, scripts are simply rewritten, and `config/server.env` is only created if missing (change it with `qwen38-set`). Each block starts by setting `Q38`, so you can paste any block into a fresh terminal.

**Already set up the Qwen3.6 stack on this machine?** The driver, CUDA and Docker steps are already done; re-running them changes nothing.

---

## Automated install (optional)

`installer/install.sh` runs every numbered step below; see the [README](../README.md).

---

## 1. Create the project directory

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
mkdir -p "$Q38"/{bin,config/opencode,models,sandbox,sandbox-state,cache,venv}
cat > "$Q38/config/shell.sh" <<EOF
# qwen38-coding-stack: sourced from ~/.bashrc. Safe to source repeatedly.
export Q38="$Q38"
case ":\$PATH:" in *":\$Q38/bin:"*) ;; *) export PATH="\$Q38/bin:\$PATH" ;; esac
EOF
LINE="[ -f \"$Q38/config/shell.sh\" ] && . \"$Q38/config/shell.sh\""
grep -qxF "$LINE" ~/.bashrc || echo "$LINE" >> ~/.bashrc
. "$Q38/config/shell.sh"
echo "Q38=$Q38"
```

---

## 2. Base system packages

Enables `contrib`, `non-free` and `non-free-firmware` (for NVIDIA) in either sources format, only if missing.

```bash
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
  sudo perl -i -pe 'if (/^Components:/) { for my $c (qw(contrib non-free non-free-firmware)) { s/$/ $c/ unless /\s\Q$c\E(\s|$)/ } }' \
    /etc/apt/sources.list.d/debian.sources
fi
if [ -f /etc/apt/sources.list ]; then
  sudo perl -i -pe 'if (/^deb(-src)?\s/ && /\smain(\s|$)/) { for my $c (qw(contrib non-free non-free-firmware)) { s/$/ $c/ unless /\s\Q$c\E(\s|$)/ } }' \
    /etc/apt/sources.list
fi
sudo apt update
sudo apt install -y build-essential cmake git curl wget pciutils iproute2 \
  libcurl4-openssl-dev python3 python3-venv ca-certificates
```

---

## 3. NVIDIA driver and CUDA toolkit

> **Secure Boot:** if enabled, you'll be prompted to enroll a MOK key during the driver install; complete it at the next reboot.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
. /etc/os-release
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  wget -qO "$Q38/cache/cuda-keyring.deb" \
    "https://developer.download.nvidia.com/compute/cuda/repos/debian${VERSION_ID}/x86_64/cuda-keyring_1.1-1_all.deb"
  sudo dpkg -i "$Q38/cache/cuda-keyring.deb"
fi
sudo apt update
sudo apt install -y nvidia-open cuda-toolkit-13-1
/usr/local/cuda-13.1/bin/nvcc --version
if [ -e /proc/driver/nvidia/version ]; then nvidia-smi; else echo ">>> Reboot now, then run this block again to confirm."; fi
```

**Do not use CUDA 13.2.**

---

## 4. Keep the desktop off the NVIDIA GPU, and plug in

With a dense model every MB of VRAM matters even more than with Qwen3.6.

```bash
nvidia-smi
```

If `Xorg`, `gnome-shell`, `kwin` or a browser appears in the process list, set the BIOS/UEFI graphics mode to **Hybrid / Optimus**, reboot, and check again.

Use AC power and the performance profile whenever you run the model. A dense model with layers in RAM is limited by memory speed and CPU, both of which drop sharply on battery.

```bash
sudo apt install -y power-profiles-daemon
powerprofilesctl set performance
powerprofilesctl get
```

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

> Membership in the `docker` group is effectively root access. That's normal for a single-user workstation.

```bash
docker run --rm hello-world >/dev/null && echo "Docker OK"
ip -4 -o addr show docker0 | awk '{print $4}'
```

---

## 6. Build llama.cpp

Clones on the first run and pulls updates afterwards. `-DCMAKE_CUDA_ARCHITECTURES=89` targets the RTX 4000 Ada (Ada Lovelace) only.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
CUDA_HOME=$(ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1)
[ -n "$CUDA_HOME" ] || { echo "No usable CUDA 13.x toolkit found; redo the CUDA step."; false; }
echo "Using $CUDA_HOME"
if [ -d "$Q38/llama.cpp/.git" ]; then
  git -C "$Q38/llama.cpp" pull --ff-only
else
  git clone https://github.com/ggml-org/llama.cpp "$Q38/llama.cpp"
fi
cmake -S "$Q38/llama.cpp" -B "$Q38/llama.cpp/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc"
cmake --build "$Q38/llama.cpp/build" --config Release -j"$(nproc)" \
  --target llama-server llama-cli llama-bench
ls -l "$Q38/llama.cpp/build/bin/llama-server"
```

If you later switch CUDA versions and `cmake` complains that the compiler changed, delete `"$Q38/llama.cpp/build"` once and run this block again.

---

## 7. Download the model

Downloads Unsloth's **UD-Q3_K_XL** quant (13.1 GB). See **Can this machine run it?** for why 3-bit rather than 4-bit. `hf download` skips completed files and resumes partial ones. The vision projector (`mmproj`) is skipped: it isn't needed for coding and would use VRAM.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
if [ ! -x "$Q38/venv/bin/hf" ]; then
  python3 -m venv "$Q38/venv"
  PIP_CACHE_DIR="$Q38/cache/pip" "$Q38/venv/bin/pip" install -U huggingface_hub
fi
HF_HOME="$Q38/cache/huggingface" "$Q38/venv/bin/hf" download unsloth/Qwen3.8-27B-GGUF \
  --local-dir "$Q38/models/Qwen3.8-27B-GGUF" \
  --include "*UD-Q3_K_XL*"
ls -lh "$Q38/models/Qwen3.8-27B-GGUF"
```

---

## 8. Create the server settings file

`config/server.env` is used identically by a terminal run and by the service. This block only creates it if it doesn't exist, so it never undoes your tuning.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
if [ -f "$Q38/config/server.env" ]; then
  echo "server.env already exists; leaving it alone. Change values with: qwen38-set KEY=VALUE"
else
  CUDA_HOME=$(ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1)
  BRIDGE=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  MODEL=$(ls "$Q38"/models/Qwen3.8-27B-GGUF/*UD-Q3_K_XL*.gguf 2>/dev/null | sort | head -1)
  cat > "$Q38/config/server.env" <<EOF
# qwen38-coding-stack server settings. Change with: qwen38-set KEY=VALUE
# Each line keeps a value already set in the environment, so one-off
# overrides work, e.g.:  CTX=32768 qwen38-server
CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}
MODEL=\${MODEL:-$MODEL}
NGL=\${NGL:-44}
CTX=\${CTX:-65536}
CACHE_TYPE=\${CACHE_TYPE:-q8_0}
THREADS=\${THREADS:-8}
HOST=\${HOST:-${BRIDGE:-172.17.0.1}}
PORT=\${PORT:-8081}
REASONING_EFFORT=\${REASONING_EFFORT:-medium}
SAMPLING=\${SAMPLING:---temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0}
EXTRA_ARGS=\${EXTRA_ARGS:-}
AGENT_TEMP=\${AGENT_TEMP:-1.0}
EOF
  echo "Created $Q38/config/server.env"
fi
cat "$Q38/config/server.env"
```

| Setting | Meaning |
|---|---|
| `NGL` | How many of the model's 64 layers go on the GPU. `99` = all. Lower = less VRAM, much slower (this is a dense model: every layer is used for every token). `auto` lets llama.cpp decide. |
| `CTX` | Context window in tokens. `opencode.json` is regenerated to match automatically. |
| `CACHE_TYPE` | Context-cache precision. `q8_0` halves its memory with little quality loss; `f16` (or `bf16`) is full precision. |
| `THREADS` | CPU threads for layers in RAM. Empty = llama.cpp's default. |
| `REASONING_EFFORT` | How long the model thinks: `none`, `low`, `medium`, `xhigh` (Qwen's default). `medium` keeps agent turns reasonably quick. |
| `SAMPLING` | Qwen's recommended thinking-mode sampling. |
| `HOST` / `PORT` | Docker bridge address and port 8081: reachable from your machine and sandboxes, **not** from your network. |
| `AGENT_TEMP` | Temperature OpenCode sends (overrides the server's), so it's set here too. |

The server always runs with `-np 1` (the whole context goes to one request).

---

## 9. Install the project's commands and OpenCode config

Write the project's commands into `bin/`. This block overwrites the scripts every time (they hold no settings), so re-running it is how you pick up fixes to them.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
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
  --memory "${SANDBOX_MEMORY:-16g}" --cpus "${SANDBOX_CPUS:-8}" \
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
  docker build "$@" -t "$IMAGE" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" - < "$Q38/sandbox/Dockerfile"
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
ls -l "$Q38/bin"
```

Generate the OpenCode config from your settings, and check the commands are on your PATH:

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
"$Q38/bin/qwen38-write-opencode-config"
. "$Q38/config/shell.sh"
command -v qwen38-server qwen38-set qwen38-find-fit qwen38-sandbox qwen38-stack
```

The OpenCode config is the same as the Qwen3.6 stack's: subagents are removed from the model's tool list (`"task": { "*": "deny" }`) and disabled outright, everything stays local (`small_model`, `"share": "disabled"`), edits and commands need your approval, and the file is mounted read-only into sandboxes. To change permissions, edit `bin/qwen38-write-opencode-config`.

---

## 10. First run and fitting

Start the server once in a terminal to see it load:

```bash
qwen38-server
```

In a second terminal, test it:

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
. "$Q38/config/server.env"
curl -s "http://$HOST:$PORT/v1/models"
curl -s "http://$HOST:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen38-local","messages":[{"role":"user","content":"Write a Python hello world."}]}'
```

Stop it with **Ctrl+C** in the first terminal.

Find how many layers fit on the GPU next to a 64K context. It stops any running server, tries from most layers to fewest, saves the first that starts minus 2 layers of headroom, and restarts the service if it's installed:

```bash
qwen38-find-fit ngl 99 60 56 52 48 44 40 36 32
qwen38-set
```

Expect a value in the 40s. Every layer moved to RAM costs speed, so if you'd rather have speed than context, try a 32K context and fit again:

```bash
qwen38-set CTX=32768
qwen38-find-fit ngl 99 60 56 52 48 44 40 36 32
```

---

## 11. CPU thread tuning

The layers in RAM are computed by the CPU, which mixes 8 fast P-cores with 16 slower E-cores. Measure which thread count is fastest (a few minutes, plugged in):

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
set -a; . "$Q38/config/server.env"; set +a
sudo systemctl stop qwen38-server 2>/dev/null || true
pkill -f llama-server 2>/dev/null; sleep 2
LD_LIBRARY_PATH="$CUDA_HOME/lib64" "$Q38/llama.cpp/build/bin/llama-bench" \
  -m "$MODEL" -ngl "$NGL" -fa 1 -t 8,16,24 -p 0 -n 128
```

Save the fastest (`tg` tokens/s column):

```bash
qwen38-set THREADS=8
```

(Replace `8` with your fastest; skip this if `NGL` is `auto` or `99`.)

---

## 12. Run the server as a system service

Same design as the Qwen3.6 stack's service, with one addition: `Conflicts=qwen-server.service`. Both models need the whole GPU, so starting one service automatically stops the other. If the Qwen3.6 service is set to start at boot, this block turns that off (it stays installed; see **Switching between Qwen3.6 and Qwen3.8**).

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
pkill -f "$Q38/llama.cpp/build/bin/llama-server" 2>/dev/null || true
if systemctl is-enabled --quiet qwen-server 2>/dev/null; then
  sudo systemctl disable --now qwen-server
  echo "Qwen3.6 service disabled at boot (still installed)."
fi
sudo tee /etc/systemd/system/qwen38-server.service >/dev/null <<EOF
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
EOF
sudo systemctl daemon-reload
sudo systemctl reset-failed qwen38-server 2>/dev/null || true
sudo systemctl enable qwen38-server
sudo systemctl restart qwen38-server
sleep 30
systemctl status qwen38-server --no-pager
```

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
. "$Q38/config/server.env"
curl -s "http://$HOST:$PORT/v1/models"
sudo journalctl -u qwen38-server -n 60 --no-pager
```

---

## 13. Build the sandbox image

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
mkdir -p "$Q38/sandbox"
cat > "$Q38/sandbox/Dockerfile" <<'EOF'
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
docker build -t qwen38-coding-stack-sandbox:latest \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  "$Q38/sandbox"
```

To update OpenCode later, add `--no-cache` to the `docker build` line.

---

## 14. Daily use

Session commands (git checkpoint first, review or undo after): [README](../README.md#use), with `qwen38-stack`.

Each project keeps its sessions and history in `sandbox-state/<folder>-<id>/` (a moved or renamed project starts fresh); sessions from before that are in `sandbox/opencode-data/`.

```bash
qwen38-stack shell ~/code/app   # a shell in that project's sandbox (joins it if it's open)
qwen38-stack status             # server, GPU memory, open sandboxes, projects with saved sessions
qwen38-stack down               # close all sandboxes, stop the server, free the GPU; deletes nothing
qwen38-stack boot off           # don't start the server at boot
```

```bash
qwen38-set                     # show settings
qwen38-set REASONING_EFFORT=low   # shorter thinking, faster turns
systemctl status qwen38-server --no-pager
```

Sandbox limits default to `--memory 16g --cpus 8`; override per run with `SANDBOX_MEMORY=8g SANDBOX_CPUS=6 qwen38-sandbox`.

### Switching between Qwen3.6 and Qwen3.8

Only one model fits on the GPU at a time. The services conflict, so starting one stops the other:

```bash
# Use Qwen3.6-35B-A3B (port 8080, commands: qwen-stack, sandbox, qwen-set)
qwen-stack up --server
```

```bash
# Use Qwen3.8-27B (port 8081, commands: qwen38-stack, qwen38-sandbox, qwen38-set)
qwen38-stack up --server
```

To change which one starts at boot (this also stops the other one starting at boot):

```bash
qwen-stack boot on       # boot into Qwen3.6
```

```bash
qwen38-stack boot on     # boot into Qwen3.8
```

---

## 15. Optional: the 2-bit, fully-on-GPU variant

UD-Q2_K_XL (9.8 GB) fits entirely in 12 GB with a ~32K context, so it's roughly 2–3× faster than 3-bit with offloading. The cost is quality: 2-bit quantization of a dense model loses noticeably more than 3-bit, and on coding it may not beat Qwen3.6-35B-A3B at 4-bit. Worth a side-by-side try if 3-bit feels too slow.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
HF_HOME="$Q38/cache/huggingface" "$Q38/venv/bin/hf" download unsloth/Qwen3.8-27B-GGUF \
  --local-dir "$Q38/models/Qwen3.8-27B-GGUF" --include "*UD-Q2_K_XL*"
Q2=$(ls "$Q38"/models/Qwen3.8-27B-GGUF/*UD-Q2_K_XL*.gguf | sort | head -1)
qwen38-set MODEL="$Q2" NGL=99 THREADS=
qwen38-find-fit ctx 65536 49152 32768 24576
```

Back to 3-bit:

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
Q3=$(ls "$Q38"/models/Qwen3.8-27B-GGUF/*UD-Q3_K_XL*.gguf | sort | head -1)
qwen38-set MODEL="$Q3" CTX=65536
qwen38-find-fit ngl 99 60 56 52 48 44 40 36 32
```

---

## Troubleshooting

```bash
sudo journalctl -u qwen38-server -n 150 --no-pager | grep -iE "error|fail|unable|cannot|not found|out of memory|bind" | tail -20
```

| Symptom | Cause | Fix |
|---|---|---|
| Service shows `status=203/EXEC` | systemd couldn't execute the script | Re-run the **Install the project's commands** step, then the **system service** step. |
| `Start request repeated too quickly` | Hit the 5-failure limit; the real error is earlier in the log | `sudo journalctl -u qwen38-server -n 150 --no-pager \| grep -iE "error\|fail\|memory"`, fix, then `sudo systemctl reset-failed qwen38-server && sudo systemctl restart qwen38-server` |
| `cudaMalloc failed: out of memory` / `failed to create context` | Weights + context cache don't fit | See **GPU out of memory** below. |
| Service stops by itself when the Qwen3.6 one starts | Intended: they conflict | Start the one you want (see **Switching**). |
| `Model not found: ...` | `MODEL` path doesn't match the download | `ls "$Q38/models"/*/`, then `qwen38-set MODEL=<full path>` |
| `Address already in use` | Another server on port 8081 | `pkill -f qwen38-coding-stack/llama.cpp; sudo systemctl restart qwen38-server` |
| `Cannot assign requested address` | Docker bridge IP isn't `HOST` | `ip -4 -o addr show docker0`, then `qwen38-set HOST=<that IP>` |
| `error while loading shared libraries: libcudart.so` | `CUDA_HOME` points at a missing toolkit | `ls -d /usr/local/cuda-*`, then `qwen38-set CUDA_HOME=/usr/local/cuda-13.1` |
| Installer prints `Driver supports CUDA ;` (blank) or stops with "toolkit is newer than the driver" | Older installer couldn't read newer `nvidia-smi` output; `CUDA_VER=13` also installs the newest 13.x | Use the current installer (it asks the driver directly and fixes `CUDA_HOME` in `server.env`), set `CUDA_VER=auto`, and re-run `install.sh` |
| Gibberish output | CUDA 13.2, or quantized context cache | Confirm no 13.2 path in `qwen38-set`; try `qwen38-set CACHE_TYPE=bf16` (uses twice the cache memory; lower `CTX` to match) |
| Very long pauses before answers | The model is thinking | `qwen38-set REASONING_EFFORT=low` (or `none`) |
| Agent forgets the task / tool calls fail | Context too small | Raise `CTX` if `qwen38-find-fit ctx` shows room; keep `qwen38-set` as the only way to change it |
| `qwen38-sandbox` says `No such image: qwen38-coding-stack-sandbox:latest`, or `Unable to find image ... locally` then `denied` | The sandbox image was never built on this machine: the install stopped before that step, or the build failed | `qwen38-stack build` (`qwen38-stack up` also builds it when it's missing). If it says `sandbox/Dockerfile` is missing, run the **Build the sandbox image** step or re-run `install.sh` |
| Container can't reach the server | Server not running, or wrong stack's service is active | `systemctl status qwen38-server`; `. $Q38/config/server.env; curl http://$HOST:$PORT/v1/models` |
| Much slower than expected | On battery or power-saver, or desktop on the NVIDIA GPU | Plug in, `powerprofilesctl set performance`, check hybrid graphics |

### GPU out of memory

**What it looks like** in `sudo journalctl -u qwen38-server`: `cudaMalloc failed: out of memory`, `failed to create context`, `exiting due to model loading error`.

**1. See what else is using VRAM:**

```bash
sudo systemctl stop qwen38-server
pkill -f llama-server; sleep 2
nvidia-smi
```

With hybrid graphics working, usage should be near zero. If `Xorg`, `gnome-shell`, `kwin` or a browser is on the NVIDIA GPU, fix that first (see **Keep the desktop off the NVIDIA GPU**).

**2. Fit the GPU layers again** (other programs' VRAM use may have changed):

```bash
qwen38-find-fit ngl 99 60 56 52 48 44 40 36 32 28 24
```

**3. Or shrink the context** to keep more layers on the GPU:

```bash
qwen38-set CTX=32768
qwen38-find-fit ngl 99 60 56 52 48 44 40 36 32
```

**Alternative: automatic fitting:** `qwen38-set NGL=auto`.

---

## Rationale

**Why Qwen3.8-27B is worth the trouble.** It's a substantial step up from the Qwen3.6 generation on agentic coding: Qwen reports SWE-bench Pro 61.7% vs 53.5% for Qwen3.6-27B, and Terminal Bench 2.1 73.0% vs 63.4%. Qwen3.6-27B was itself stronger than Qwen3.6-35B-A3B on coding, so the quality gap over the model in the Qwen3.6 stack is larger still. These are vendor-run numbers at full precision; quantization and local tooling will lower them somewhat.

**Why it's harder to run than Qwen3.6-35B-A3B.** That model is Mixture-of-Experts: only ~3B parameters are used per token, so most of it could sit in system RAM at little cost. Qwen3.8-27B is **dense**: all 27B parameters are read for every token. Any part of it in system RAM is read over the much slower RAM bus on every token, so speed drops sharply as soon as it doesn't fit in VRAM. The rule of thumb for a dense model: fit it on the GPU, even at a lower-bit quant, rather than spill a higher-bit one.

**Why UD-Q3_K_XL.** At 13.1 GB it's the largest of Unsloth's quants that leaves room for a useful context window on a 16 GB card. Unsloth's dynamic quants keep the most sensitive layers at higher precision, which is why 3-bit remains usable; still, expect some loss versus 4-bit. The 4-bit UD-Q4_K_XL is 17.6 GB, which is more than 16 GB of VRAM before any context is allocated.

**Why a q8_0 context cache.** Only 16 of the 64 layers use full attention (the rest are Gated DeltaNet with a small fixed-size state), with 4 KV heads of dimension 256. That works out to about 64 KB per token at full precision (16 layers × 4 heads × 256 × 2 for K and V × 2 bytes), or ~2 GB per 32K tokens. `q8_0` halves it, doubling the context that fits.

**Why `REASONING_EFFORT=medium`.** Qwen3.8 thinks at "xhigh" effort by default, which can mean thousands of thinking tokens per agent step. Locally, every token costs real time, so `medium` is a better default; switch to `xhigh` for hard problems or `low` for quick edits with `qwen38-set`.

**Why a separate stack.** Keeping Qwen3.8 in its own directory, with its own commands, port and service, leaves the working Qwen3.6 setup untouched and makes switching a single command. The services declare `Conflicts=`, so the two can never fight over the GPU.

**Why the same tools otherwise.** llama.cpp, OpenCode with subagents disabled, the Docker sandbox, the system service, and the one-settings-file design were chosen for the Qwen3.6 stack for reasons that apply equally here (see that guide's Rationale).

**Why fit-by-layers on this machine.** 13.1 GB of weights can't fit in 12 GB, so the question is how many layers can stay on the GPU next to the context. `qwen38-find-fit ngl` measures it; 2 layers of headroom are kept for VRAM used by other programs.

**Why the speed estimate is so much lower than Qwen3.6's on this laptop.** With Qwen3.6-35B-A3B, only ~3B parameters' worth of experts were read per token, so keeping most of the model in RAM cost little. With dense Qwen3.8-27B, every token reads every layer in RAM in full: ~4 GB over a ~60–70 GB/s RAM bus is about 60 ms per token before the GPU's share, which caps generation around 10–14 tokens/s.

**Why not the 2-bit quant by default.** It's fast because it fits, but 2-bit quantization costs dense models noticeably more quality than 3-bit, and the point of switching to Qwen3.8 is better answers. It's offered as an option to compare.

### References

- Unsloth, Qwen3.8 — How to Run Locally (requirements, settings, reasoning effort): https://unsloth.ai/docs/models/qwen3.8
- Unsloth Qwen3.8-27B GGUF (quant sizes, architecture): https://huggingface.co/unsloth/Qwen3.8-27B-GGUF
- Qwen3.8-27B release and benchmarks summary: https://en.immers.cloud/ai/Qwen/qwen3.8-27b/
- Qwen3.8-27B on OpenRouter (release date, capabilities): https://api3.shopot.ai/qwen/qwen3.8-27b
- OpenCode agents & task permissions: https://opencode.ai/docs/agents/
- OpenCode providers (llama.cpp config, `small_model`): https://opencode.ai/docs/providers/
- OpenCode subagent permission bypass report: https://github.com/anomalyco/opencode/issues/20549
- XDA, local agent context limits: https://www.xda-developers.com/stopped-my-local-llm-agent-from-running-out-of-context/
