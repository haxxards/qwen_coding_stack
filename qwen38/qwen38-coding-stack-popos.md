# Local Qwen3.8-27B Coding Assistant — Pop!_OS 24.04 (Home Desktop)

**Hardware:** RTX 5080 (16 GB VRAM, Blackwell), 32 GB RAM.
**Companion files:** `qwen38-coding-stack-debian-work-laptop.md` (work laptop), `qwen38-coding-stack-installer.tar.gz` (automates this guide). The Qwen3.6 guides and installer are unchanged and can stay installed alongside this.

## Can this machine run it?

**Yes, and it's worth it, but only at 3-bit and with a 48K–64K context.**

| Option | Fits in 16 GB VRAM? | Expected generation speed | Verdict |
|---|---|---|---|
| UD-Q4_K_XL (17.6 GB) | No: ~3 GB of weights spill to RAM, plus context | Roughly 10–15 tokens/s | Not recommended |
| **UD-Q3_K_XL (13.1 GB)** | **Yes, with ~1.5–2 GB left for a 48K–64K q8_0 context** | **Roughly 40–55 tokens/s** | **Recommended** |
| UD-IQ4_XS (14.3 GB) | Barely: only ~16–24K of context fits | Similar to Q3 | Too little context for agentic coding |

Why: Qwen3.8-27B is a **dense** model (every parameter is used for every token), unlike the Qwen3.6 Mixture-of-Experts model. A dense model is fast only when it's entirely in VRAM. The RTX 5080's memory is roughly 10× faster than system RAM, so even a few GB in RAM dominates the time per token. Unsloth's "4-bit works on an RTX 5080" refers to total RAM + VRAM, which runs, but slowly.

The speed figures are estimates from memory bandwidth (VRAM ~960 GB/s, dual-channel DDR5 ~60–80 GB/s in practice), not measurements; `qwen38-find-fit` and a session will show the real numbers. The desktop session (COSMIC) also uses ~0.5–1.5 GB of VRAM, which is why fitting is done automatically.

**Compared with your Qwen3.6 setup:** expect noticeably better coding and agent reliability (Qwen reports large gains over Qwen3.6-27B, which already beat Qwen3.6-35B-A3B on coding), at similar or slightly lower speed, with about half the context (48K–64K vs 128K). Keep the Qwen3.6 stack for very long sessions; see **Switching between Qwen3.6 and Qwen3.8**.

## Project layout

Everything lives in one directory, separate from the Qwen3.6 stack so the two never interfere:

```
/home/tristanv/Development/qwen38-coding-stack/
├── bin/                   commands: qwen38-server, qwen38-set, qwen38-find-fit, qwen38-sandbox, qwen38-write-opencode-config
├── config/
│   ├── shell.sh           sourced by ~/.bashrc (adds bin/ to your PATH)
│   ├── server.env         model, GPU layers, context, KV cache, reasoning effort (single source of truth)
│   └── opencode/
│       └── opencode.json  generated from server.env; mounted read-only into sandboxes
├── installer/             the automated installer (optional)
├── llama.cpp/             llama.cpp source and build
├── models/                GGUF model files
├── sandbox/
│   ├── Dockerfile         sandbox image
│   └── opencode-data/     OpenCode sessions, kept between sandbox runs
├── cache/                 downloads, Hugging Face and pip caches, logs
└── venv/                  Python environment for the Hugging Face CLI
```

Outside it: apt packages and apt settings, the service file `/etc/systemd/system/qwen38-server.service`, the Docker image, and **one line** in `~/.bashrc`. The commands are all prefixed `qwen38-` so they never clash with the Qwen3.6 stack's `qwen-set`, `sandbox`, etc. The server listens on port **8081** (the Qwen3.6 stack uses 8080).

**Every block in this guide is safe to re-run.** Blocks check before they install or download, scripts are simply rewritten, and `config/server.env` is only created if missing (change it with `qwen38-set`). Each block starts by setting `Q38`, so you can paste any block into a fresh terminal.

**Already set up the Qwen3.6 stack on this machine?** The driver, CUDA and Docker steps are already done; re-running them changes nothing.

---

## Automated install (optional)

`qwen38-coding-stack-installer.tar.gz` runs every step of this guide, in two phases separated by one reboot (phase 1 is a no-op if the Qwen3.6 stack is already installed, so no reboot is needed in that case):

| Phase | What it does |
|---|---|
| 1 (system) | Base packages, System76's NVIDIA driver, NVIDIA's CUDA repo (pinned so it never touches the driver), CUDA toolkit, Docker. Reboots (or asks first) if the driver or docker group needs it. |
| 2 (project) | Project directory, llama.cpp build, model download, settings, commands, sandbox image, system service (disabling the Qwen3.6 service at boot), context fitting (falls back to moving layers to RAM, then automatic fitting), and a final check that the server answers. |

```bash
mkdir -p /home/tristanv/Development/qwen38-coding-stack
tar -xzf ~/Downloads/qwen38-coding-stack-installer.tar.gz -C /home/tristanv/Development/qwen38-coding-stack
nano /home/tristanv/Development/qwen38-coding-stack/installer/install.conf     # optional
/home/tristanv/Development/qwen38-coding-stack/installer/install.sh
```

If it reboots, run the same `install.sh` command again afterwards. Every run logs to `cache/install-<date>.log`, and re-running never overwrites your tuned `server.env` (fitting reruns only with `RETUNE=yes`).

The numbered steps below are the manual equivalent.

---

## 1. Create the project directory

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
mkdir -p "$Q38"/{bin,config/opencode,models,sandbox/opencode-data,cache,venv}
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

```bash
sudo apt update
sudo apt install -y build-essential cmake git curl wget pciutils iproute2 \
  libcurl4-openssl-dev python3 python3-venv ca-certificates
```

---

## 3. NVIDIA driver and CUDA toolkit

Pop!_OS's own driver package installs the **open** kernel module the RTX 5080 requires. NVIDIA's repo is added only for the CUDA toolkit, pinned low so it never replaces Pop's driver.

```bash
sudo apt install -y system76-driver-nvidia
if grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
  echo "Open NVIDIA driver is loaded."
  nvidia-smi | grep -o 'CUDA Version: [0-9.]*'
else
  echo ">>> Reboot now (sudo reboot), then run this block again."
fi
```

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  wget -qO "$Q38/cache/cuda-keyring.deb" \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i "$Q38/cache/cuda-keyring.deb"
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

**Do not use CUDA 13.2.** Use 13.1 if `nvidia-smi` reported 13.1 or higher; if it reported 13.0, set `CUDA_VER=13.0`.

```bash
CUDA_VER=13.1
sudo apt install -y "cuda-toolkit-${CUDA_VER/./-}"
"/usr/local/cuda-${CUDA_VER}/bin/nvcc" --version
```

---

## 4. Install Docker

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

## 5. Build llama.cpp

Clones on the first run and pulls updates afterwards. `-DCMAKE_CUDA_ARCHITECTURES=120` targets the RTX 5080 (Blackwell) only.

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
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc"
cmake --build "$Q38/llama.cpp/build" --config Release -j"$(nproc)" \
  --target llama-server llama-cli llama-bench
ls -l "$Q38/llama.cpp/build/bin/llama-server"
```

If you later switch CUDA versions and `cmake` complains that the compiler changed, delete `"$Q38/llama.cpp/build"` once and run this block again.

---

## 6. Download the model

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

## 7. Create the server settings file

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
NGL=\${NGL:-99}
CTX=\${CTX:-65536}
CACHE_TYPE=\${CACHE_TYPE:-q8_0}
THREADS=\${THREADS:-}
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

## 8. Install the project's commands and OpenCode config

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
  --memory "${SANDBOX_MEMORY:-6g}" --cpus "${SANDBOX_CPUS:-4}" \
  -v "$PROJECT":/workspace \
  -v "$Q38/config/opencode":/home/dev/.config/opencode:ro \
  -v "$Q38/sandbox/opencode-data":/home/dev/.local/share/opencode \
  -w /workspace \
  qwen38-coding-stack-sandbox:latest "${@:2}"
SCRIPT

chmod +x "$Q38"/bin/*
ls -l "$Q38/bin"
```

Generate the OpenCode config from your settings, and check the commands are on your PATH:

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
"$Q38/bin/qwen38-write-opencode-config"
. "$Q38/config/shell.sh"
command -v qwen38-server qwen38-set qwen38-find-fit qwen38-sandbox
```

The OpenCode config is the same as the Qwen3.6 stack's: subagents are removed from the model's tool list (`"task": { "*": "deny" }`) and disabled outright, everything stays local (`small_model`, `"share": "disabled"`), edits and commands need your approval, and the file is mounted read-only into sandboxes. To change permissions, edit `bin/qwen38-write-opencode-config`.

---

## 9. First run and fitting

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

Find the largest context that fits with the whole model on the GPU. It stops any running server, tries each size from largest to smallest, saves the first that starts, and restarts the service if it's installed:

```bash
qwen38-find-fit ctx 131072 98304 65536 49152 32768
qwen38-set
```

Close GPU-heavy apps (browser video, games) first; whatever they use isn't available to the model. Expect **49152 or 65536** with the default `q8_0` cache, depending on how much VRAM the desktop is using. If even 32768 fails, see **Troubleshooting → GPU out of memory**.

---

## 10. Run the server as a system service

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

## 11. Build the sandbox image

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
mkdir -p "$Q38/sandbox/opencode-data"
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

## 12. Daily use

```bash
cd /path/to/your/project
git rev-parse --git-dir >/dev/null 2>&1 || git init
git add -A && git commit -qm "checkpoint before AI session" || true
qwen38-sandbox
```

```bash
qwen38-sandbox . bash          # a shell in the same sandbox
qwen38-set                     # show settings
qwen38-set REASONING_EFFORT=low   # shorter thinking, faster turns
systemctl status qwen38-server --no-pager
```

Sandbox limits default to `--memory 6g --cpus 4`; override per run with `SANDBOX_MEMORY=8g SANDBOX_CPUS=6 qwen38-sandbox`.

### Switching between Qwen3.6 and Qwen3.8

Only one model fits on the GPU at a time. The services conflict, so starting one stops the other:

```bash
# Use Qwen3.6-35B-A3B (port 8080, commands: sandbox, qwen-set)
sudo systemctl start qwen-server
```

```bash
# Use Qwen3.8-27B (port 8081, commands: qwen38-sandbox, qwen38-set)
sudo systemctl start qwen38-server
```

To change which one starts at boot:

```bash
sudo systemctl disable qwen38-server && sudo systemctl enable qwen-server     # boot into Qwen3.6
```

```bash
sudo systemctl disable qwen-server && sudo systemctl enable qwen38-server     # boot into Qwen3.8
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
| Container can't reach the server | Server not running, or wrong stack's service is active | `systemctl status qwen38-server`; `. $Q38/config/server.env; curl http://$HOST:$PORT/v1/models` |

### GPU out of memory

**What it looks like** in `sudo journalctl -u qwen38-server`: `cudaMalloc failed: out of memory`, `failed to create context`, `exiting due to model loading error`.

**1. See what else is using VRAM:**

```bash
sudo systemctl stop qwen38-server
pkill -f llama-server; sleep 2
nvidia-smi
```

On the Pop!_OS desktop the display runs on the NVIDIA card, so `cosmic-comp`, `Xwayland` and browsers appear in the list. With nothing else open, usage should be under ~1.5 GB.

**2. Find the largest context that fits:**

```bash
qwen38-find-fit ctx 131072 98304 65536 49152 32768
```

**3. If even 32768 doesn't fit**, keep a 32K context and move a few layers to RAM (slower; each layer moved costs speed):

```bash
qwen38-set CTX=32768
qwen38-find-fit ngl 99 62 60 58 56 54 52
```

**Alternative: automatic fitting** chooses the layer split from the VRAM free at startup: `qwen38-set NGL=auto`.

---

## Rationale

**Why Qwen3.8-27B is worth the trouble.** It's a substantial step up from the Qwen3.6 generation on agentic coding: Qwen reports SWE-bench Pro 61.7% vs 53.5% for Qwen3.6-27B, and Terminal Bench 2.1 73.0% vs 63.4%. Qwen3.6-27B was itself stronger than Qwen3.6-35B-A3B on coding, so the quality gap over the model in the Qwen3.6 stack is larger still. These are vendor-run numbers at full precision; quantization and local tooling will lower them somewhat.

**Why it's harder to run than Qwen3.6-35B-A3B.** That model is Mixture-of-Experts: only ~3B parameters are used per token, so most of it could sit in system RAM at little cost. Qwen3.8-27B is **dense**: all 27B parameters are read for every token. Any part of it in system RAM is read over the much slower RAM bus on every token, so speed drops sharply as soon as it doesn't fit in VRAM. The rule of thumb for a dense model: fit it on the GPU, even at a lower-bit quant, rather than spill a higher-bit one.

**Why UD-Q3_K_XL.** At 13.1 GB it's the largest of Unsloth's quants that leaves room for a useful context window on a 16 GB card. Unsloth's dynamic quants keep the most sensitive layers at higher precision, which is why 3-bit remains usable; still, expect some loss versus 4-bit. The 4-bit UD-Q4_K_XL is 17.6 GB, which is more than 16 GB of VRAM before any context is allocated.

**Why a q8_0 context cache.** Only 16 of the 64 layers use full attention (the rest are Gated DeltaNet with a small fixed-size state), with 4 KV heads of dimension 256. That works out to about 64 KB per token at full precision (16 layers × 4 heads × 256 × 2 for K and V × 2 bytes), or ~2 GB per 32K tokens. `q8_0` halves it, doubling the context that fits.

**Why `REASONING_EFFORT=medium`.** Qwen3.8 thinks at "xhigh" effort by default, which can mean thousands of thinking tokens per agent step. Locally, every token costs real time, so `medium` is a better default; switch to `xhigh` for hard problems or `low` for quick edits with `qwen38-set`.

**Why a separate stack.** Keeping Qwen3.8 in its own directory, with its own commands, port and service, leaves the working Qwen3.6 setup untouched and makes switching a single command. The services declare `Conflicts=`, so the two can never fight over the GPU.

**Why the same tools otherwise.** llama.cpp, OpenCode with subagents disabled, the Docker sandbox, the system service, and the one-settings-file design were chosen for the Qwen3.6 stack for reasons that apply equally here (see that guide's Rationale).

**Why fit-by-context on this machine.** With the whole model on the GPU, the only variable is how much context fits beside it, and that depends on what the desktop is using at the time. `qwen38-find-fit ctx` measures it instead of guessing.

**Why no MTP here.** Qwen3.8 supports multi-token prediction, but its draft weights add ~1.4 GB, which would cost about 40K tokens of context on this card.

### References

- Unsloth, Qwen3.8 — How to Run Locally (requirements, settings, reasoning effort): https://unsloth.ai/docs/models/qwen3.8
- Unsloth Qwen3.8-27B GGUF (quant sizes, architecture): https://huggingface.co/unsloth/Qwen3.8-27B-GGUF
- Qwen3.8-27B release and benchmarks summary: https://en.immers.cloud/ai/Qwen/qwen3.8-27b/
- Qwen3.8-27B on OpenRouter (release date, capabilities): https://api3.shopot.ai/qwen/qwen3.8-27b
- OpenCode agents & task permissions: https://opencode.ai/docs/agents/
- OpenCode providers (llama.cpp config, `small_model`): https://opencode.ai/docs/providers/
- OpenCode subagent permission bypass report: https://github.com/anomalyco/opencode/issues/20549
- XDA, local agent context limits: https://www.xda-developers.com/stopped-my-local-llm-agent-from-running-out-of-context/
- Pop!_OS open-driver default on 24.04: https://github.com/pop-os/pop/issues/3640
