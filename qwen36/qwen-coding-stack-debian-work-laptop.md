# Local Qwen Coding Assistant — Debian (Work Laptop)

**Hardware:** Intel i9-13950HX (24 cores / 32 threads: 8 P-cores + 16 E-cores), 64 GB DDR5-5600, NVIDIA RTX 4000 Ada Laptop (12 GB VRAM, Ada Lovelace, compute capability 8.9), 1 TB NVMe.
**Companion guide:** `qwen-coding-stack-popos.md` covers the home desktop. **Installer:** `qwen-coding-stack-installer.tar.gz` automates this guide (see **Automated install**).

| Layer | Choice |
|---|---|
| OS | Debian 12 (bookworm) or 13 (trixie) |
| GPU driver / CUDA | NVIDIA open kernel driver + CUDA 13.1 (avoid 13.2) from NVIDIA's apt repo |
| Inference server | llama.cpp `llama-server`, built for Ada (sm_89), run as a system service |
| Model | Qwen3.6-35B-A3B, Unsloth `UD-Q4_K_XL` GGUF, most experts in system RAM |
| Coding agent | OpenCode, with subagent delegation disabled |
| Sandbox | Docker container per project, non-root, only the project folder mounted |

> **Work device check:** before installing drivers or Docker, confirm with your IT department that this is allowed, and that running a local model on company code is within policy. Managed laptops often lock Secure Boot and restrict Docker.

> **Different username?** The project path is `/home/tristanv/Development/qwen-coding-stack`. If your work username isn't `tristanv`, change the `QCS=` line at the top of each block; the scripts themselves work from wherever they're installed.

Run the sections in order. Why each choice was made is in **Rationale** at the bottom.

## Project layout

Everything lives in one directory:

```
/home/tristanv/Development/qwen-coding-stack/
├── bin/                   commands: qwen-server, qwen-set, find-ncmoe, sandbox, write-opencode-config
├── config/
│   ├── shell.sh           sourced by ~/.bashrc (adds bin/ to your PATH)
│   ├── server.env         model, GPU/RAM split, context size, CUDA path (single source of truth)
│   └── opencode/
│       └── opencode.json  generated from server.env; mounted read-only into sandboxes
├── llama.cpp/             llama.cpp source and build
├── models/                GGUF model files
├── sandbox/
│   ├── Dockerfile         sandbox image
│   └── opencode-data/     OpenCode sessions, kept between sandbox runs
├── cache/                 downloads, Hugging Face and pip caches, logs
└── venv/                  Python environment for the Hugging Face CLI
```

The only things placed outside it are system-level integration that can't live in a project folder: apt packages and apt settings under `/etc/apt/`, the service file `/etc/systemd/system/qwen-server.service`, the Docker image (in Docker's own storage), and **one line** in `~/.bashrc` that sources `config/shell.sh`.

**Every block in this guide is safe to re-run.** Blocks check before they install or download, scripts are simply rewritten, and your tuned settings in `config/server.env` are never overwritten (it's only created if missing; change it with `qwen-set`). Each block starts by setting `QCS`, so you can paste any block into a fresh terminal.

---

## Automated install (optional)

`qwen-coding-stack-installer.tar.gz` runs every step of this guide for you. It's built from the same commands, so the result is identical, and like the guide it's safe to re-run at any time.

It runs in two phases, separated by one reboot:

| Phase | What it does |
|---|---|
| 1 (system) | Base packages, `contrib`/`non-free` components, NVIDIA's open driver and repo, power-profiles-daemon, CUDA toolkit, Docker. Then reboots (or asks first), because the driver and the docker group only take effect after a reboot. |
| 2 (project) | Project directory, llama.cpp build, model download, settings, commands, sandbox image, system service, performance power profile, a check that the desktop isn't on the NVIDIA GPU, `find-ncmoe` tuning (falls back to a smaller context, then automatic fitting), CPU thread benchmarking, and a final check that the server answers. |

**1. Unpack it into the project directory:**

```bash
mkdir -p /home/tristanv/Development/qwen-coding-stack
tar -xzf ~/Downloads/qwen-coding-stack-installer.tar.gz -C /home/tristanv/Development/qwen-coding-stack
```

**2. Review the settings** (every value has a comment; empty values use this machine's defaults):

```bash
nano /home/tristanv/Development/qwen-coding-stack/installer/install.conf
```

**3. Run it** as your normal user (it asks for your sudo password once):

```bash
/home/tristanv/Development/qwen-coding-stack/installer/install.sh
```

**4. After the reboot, run the same command again** to continue with phase 2:

```bash
/home/tristanv/Development/qwen-coding-stack/installer/install.sh
```

Things it can't do for you: the IT-policy check, switching the BIOS to Hybrid graphics (it warns if needed), and, with Secure Boot on, the blue **MOK management** screen at the first reboot. Phase 1 asks you to choose a one-time password; at that screen choose **Enroll MOK → Continue → Yes** and enter it.

Every run writes a log to `cache/install-<date>.log`. Re-running later pulls and rebuilds llama.cpp (to update OpenCode, use the `--no-cache` rebuild in **Build the sandbox image**), and never overwrites your tuned `config/server.env` (tuning only reruns with `RETUNE=yes` in `install.conf`).

The numbered steps below are the manual equivalent, and the reference for what the installer does.

---

## 1. Create the project directory

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
mkdir -p "$QCS"/{bin,config/opencode,models,sandbox/opencode-data,cache,venv}
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

## 2. Base system packages

Enables the `contrib`, `non-free` and `non-free-firmware` components NVIDIA needs, handling both the classic `sources.list` format (Debian 12) and the newer `debian.sources` format (Debian 13). Each component is only added if it's missing.

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

Uses NVIDIA's own repository for both, since Debian's driver packages lag behind new GPUs.

> **Secure Boot:** if enabled, you'll be prompted to enroll a MOK key during the driver install. Complete the enrollment on the next reboot, or the driver won't load.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
. /etc/os-release
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  wget -qO "$QCS/cache/cuda-keyring.deb" \
    "https://developer.download.nvidia.com/compute/cuda/repos/debian${VERSION_ID}/x86_64/cuda-keyring_1.1-1_all.deb"
  sudo dpkg -i "$QCS/cache/cuda-keyring.deb"
fi
sudo apt update
sudo apt install -y nvidia-open cuda-toolkit-13-1
/usr/local/cuda-13.1/bin/nvcc --version
if [ -e /proc/driver/nvidia/version ]; then
  nvidia-smi
else
  echo ">>> Reboot now (sudo reboot), then run this block again to confirm."
fi
```

**Do not use CUDA 13.2** (known gibberish-output bug with Qwen3.6 in llama.cpp). 13.3 is also fine. Nothing is added to your `~/.bashrc` for CUDA: the build and the server find the toolkit themselves.

---

## 4. Keep the desktop off the NVIDIA GPU

Laptops have two GPUs: the Intel integrated one and the NVIDIA one. If the desktop runs on the NVIDIA GPU it can take 0.5–1.5 GB of your 12 GB.

```bash
nvidia-smi
```

If `Xorg`, `gnome-shell`, `kwin` or a browser appears in the process list, set the BIOS/UEFI graphics mode to **Hybrid / Optimus** (not "Discrete only"), reboot, and check again. In hybrid mode the desktop stays on the Intel GPU and llama.cpp gets the full 12 GB.

For any benchmarking or tuning, plug the laptop in and use the performance profile; on battery or power-saver the results are meaningless:

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

> Membership in the `docker` group is effectively root access. That's normal for a single-user workstation; use rootless Docker if that's a concern.

After logging back in, confirm Docker works and note the bridge address (normally `172.17.0.1`):

```bash
docker run --rm hello-world >/dev/null && echo "Docker OK"
ip -4 -o addr show docker0 | awk '{print $4}'
```

---

## 6. Build llama.cpp

Clones on the first run and pulls updates afterwards; `cmake` only rebuilds what changed. The CUDA toolkit is picked automatically (newest 13.x, skipping 13.2). `-DCMAKE_CUDA_ARCHITECTURES=89` targets the RTX 4000 Ada (Ada Lovelace) only, which keeps the build fast.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
CUDA_HOME=$(ls -d /usr/local/cuda-13.* 2>/dev/null | grep -v 'cuda-13\.2$' | sort -V | tail -1)
[ -n "$CUDA_HOME" ] || { echo "No usable CUDA 13.x toolkit found; redo step 3."; false; }
echo "Using $CUDA_HOME"
if [ -d "$QCS/llama.cpp/.git" ]; then
  git -C "$QCS/llama.cpp" pull --ff-only
else
  git clone https://github.com/ggml-org/llama.cpp "$QCS/llama.cpp"
fi
cmake -S "$QCS/llama.cpp" -B "$QCS/llama.cpp/build" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
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
NCMOE=\${NCMOE:-34}
CTX=\${CTX:-65536}
THREADS=\${THREADS:-8}
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
  --memory "${SANDBOX_MEMORY:-16g}" --cpus "${SANDBOX_CPUS:-8}" \
  -v "$PROJECT":/workspace \
  -v "$QCS/config/opencode":/home/dev/.config/opencode:ro \
  -v "$QCS/sandbox/opencode-data":/home/dev/.local/share/opencode \
  -w /workspace \
  qwen-coding-stack-sandbox:latest "${@:2}"
SCRIPT

chmod +x "$QCS"/bin/*
ls -l "$QCS/bin"
```

Generate the OpenCode config from your settings, and check the commands are on your PATH:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
"$QCS/bin/write-opencode-config"
. "$QCS/config/shell.sh"
command -v qwen-server qwen-set find-ncmoe sandbox
```

What the OpenCode config does:

- `"task": { "*": "deny" }` removes subagents from the model's tool list entirely, so it can't try to delegate. The `general`, `explore` and `scout` subagents are also disabled outright, as a second layer.
- `small_model` and `"share": "disabled"` keep everything local. By default OpenCode sends session-title generation to a hosted model.
- `edit` and `bash` set to `ask` means you approve each change and command. To change permissions, edit `bin/write-opencode-config` (the JSON file itself is regenerated by `qwen-set`).
- The config is mounted **read-only** into sandboxes, so the model can't rewrite its own permissions.

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
find-ncmoe 34 36 38 40
qwen-set
```

Each step of 2 moves roughly 1 GB of expert weights from VRAM to RAM. If nothing in the range works, see **Troubleshooting → GPU out of memory**.

---

## 11. CPU thread tuning

With most expert layers in RAM, the CPU does a lot of the work per token. This CPU mixes 8 fast P-cores with 16 slower E-cores, and spreading work onto E-cores can slow the whole step down, so measure it (takes a few minutes; plugged in, performance profile):

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
set -a; . "$QCS/config/server.env"; set +a
sudo systemctl stop qwen-server 2>/dev/null || true
pkill -f llama-server 2>/dev/null; sleep 2
LD_LIBRARY_PATH="$CUDA_HOME/lib64" "$QCS/llama.cpp/build/bin/llama-bench" \
  -m "$MODEL" -ngl 99 -fa 1 -ncmoe "$NCMOE" -t 8,16,24
```

Save the fastest (`tg` column, tokens/s) and restart:

```bash
qwen-set THREADS=8
```

(Replace `8` with your fastest. If `NCMOE` is `auto`, skip this step.) If you later raise `THREADS` to 16 or 24, run sandboxes with `SANDBOX_CPUS=4` so builds and tests don't compete with the model for cores.

---

## 12. Run the server as a system service

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

## 13. Build the sandbox image

The container runs as a non-root user whose UID matches yours, so files it creates in your project are owned by you. Re-running rebuilds only what changed.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
mkdir -p "$QCS/sandbox/opencode-data"
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

## 14. Daily use

Start a session on a project (commit first; `git diff` / `git checkout .` is your undo button):

```bash
cd /path/to/your/project
git rev-parse --git-dir >/dev/null 2>&1 || git init
git add -A && git commit -qm "checkpoint before AI session" || true
sandbox
```

A shell in the same sandbox, to run tests yourself:

```bash
sandbox . bash
```

Look at or change server settings (changes restart the service and update OpenCode automatically):

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

- It mounts only the project folder, runs as a non-root user with all capabilities dropped, and refuses to mount your whole home directory or the stack itself.
- Default limits are `--memory 16g --cpus 8`. Override per run: `SANDBOX_MEMORY=8g SANDBOX_CPUS=6 sandbox`.
- The container has internet access (for `pip`/`npm`). For stricter isolation, create a dedicated Docker network and firewall its egress except to the server's address and port.

---

## 15. Optional: MTP speculative decoding

Unsloth ships MTP GGUFs. On this MoE model the gain is modest (about 1.15–1.2x), so try it only after everything else works. MTP uses ~1 GB extra memory, so re-run `find-ncmoe` afterwards.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
HF_HOME="$QCS/cache/huggingface" "$QCS/venv/bin/hf" download unsloth/Qwen3.6-35B-A3B-MTP-GGUF \
  --local-dir "$QCS/models/Qwen3.6-35B-A3B-MTP-GGUF" --include "*UD-Q4_K_XL*"
MTP=$(ls "$QCS"/models/Qwen3.6-35B-A3B-MTP-GGUF/*.gguf | sort | head -1)
qwen-set MODEL="$MTP" EXTRA_ARGS="--spec-type draft-mtp --spec-draft-n-max 2"
find-ncmoe 34 36 38 40
```

To turn it off again:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
qwen-set MODEL="$QCS/models/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" EXTRA_ARGS=
```

---

## 16. Optional: Aider instead of OpenCode

For a turn-by-turn chat that edits files and auto-commits, with no autonomous command execution. It installs into the container's temporary storage each run.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
. "$QCS/config/server.env"
sandbox . bash -c "python3 -m venv /tmp/aider && /tmp/aider/bin/pip install -q aider-chat && \
  OPENAI_API_BASE=http://$HOST:$PORT/v1 OPENAI_API_KEY=none /tmp/aider/bin/aider --model openai/qwen-local"
```

---

## 17. Optional: Qwen3-Coder-Next

Not required, but the 64 GB of RAM makes Qwen3-Coder-Next (80B total, 3B active) feasible on this laptop. It's a non-reasoning model, so it answers without a thinking phase. The trade-offs: the 4-bit file is ~46 GB, which leaves little RAM for anything else, and its published SWE-bench Verified score (70.6%) is below Qwen3.6-27B's (77.2%). The 3-bit quant below keeps more headroom.

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
HF_HOME="$QCS/cache/huggingface" "$QCS/venv/bin/hf" download unsloth/Qwen3-Coder-Next-GGUF \
  --local-dir "$QCS/models/Qwen3-Coder-Next-GGUF" --include "*UD-Q3_K_XL*"
CN=$(ls "$QCS"/models/Qwen3-Coder-Next-GGUF/*.gguf "$QCS"/models/Qwen3-Coder-Next-GGUF/*/*.gguf 2>/dev/null | sort | head -1)
echo "Model file: $CN"
qwen-set MODEL="$CN" NCMOE=48 \
  SAMPLING="--temp 1.0 --top-p 0.95 --top-k 40 --min-p 0.01" AGENT_TEMP=1.0
```

All 48 layers' experts go to RAM (`NCMOE=48`). While using it, run sandboxes with less memory: `SANDBOX_MEMORY=8g sandbox`.

Switch back to Qwen3.6-35B-A3B:

```bash
QCS=/home/tristanv/Development/qwen-coding-stack
qwen-set MODEL="$QCS/models/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf" \
  SAMPLING="--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0" AGENT_TEMP=0.6
find-ncmoe 34 36 38 40
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
| `sandbox` says `No such image: qwen-coding-stack-sandbox:latest`, or `Unable to find image ... locally` then `denied` | The sandbox image was never built on this machine: the install stopped before that step, or the build failed | Run the **Build the sandbox image** step (or re-run `install.sh`); `docker images qwen-coding-stack-sandbox` should then list it |
| Container can't reach the server | Server not running, or HOST mismatch | `systemctl status qwen-server`; `. $QCS/config/server.env; curl http://$HOST:$PORT/v1/models` |
| OpenCode errors writing its config | It wants to write to the read-only mount | Remove `:ro` from the config mount in `bin/sandbox` |
| Very slow generation | Too many experts in RAM, or other GPU apps | Re-run `find-ncmoe` with lower values; close GPU-heavy apps |
| `nvidia-smi` fails after reboot | Secure Boot MOK not enrolled, or `nvidia-open` not installed | `sudo dmesg \| grep -i nvidia`; `mokutil --sb-state`; re-run the driver block |
| Much slower than expected | On battery or power-saver, or desktop on the NVIDIA GPU | Plug in, `powerprofilesctl set performance`, check hybrid graphics |

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

If `Xorg`, `gnome-shell`, `kwin` or a browser is using NVIDIA memory, fix that first (see **Keep the desktop off the NVIDIA GPU**). With hybrid graphics working, usage should be near zero.

**2. Find a value that fits** (saves it and restarts the service):

```bash
find-ncmoe 34 36 38 40
```

**3. If nothing in the range works**, every expert layer is already in RAM, so shrink the context:

```bash
qwen-set CTX=32768
find-ncmoe 34 36 38 40
```

**Alternative: automatic fitting.** llama.cpp can choose the split itself from the VRAM free at startup. It adapts if your desktop uses more or less VRAM, but you lose direct control and it may be slower than a tuned value:

```bash
qwen-set NCMOE=auto
sudo journalctl -u qwen-server -n 80 --no-pager | grep -iE "fit|listening|out of memory"
```

To go back to a tuned value, run `find-ncmoe 34 36 38 40` again.

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

**Why the same model as the desktop works here.** An MoE model doesn't need to fit in VRAM; it needs the shared weights and attention on the GPU and enough total memory for the rest. 12 GB VRAM + 64 GB RAM is more total memory than the desktop has. Community tests show a single 12 GB card running Qwen3.6-35B-A3B at usable speed (~38 tokens/s on an RTX 3060). Laptop GPUs are power- and thermal-limited, so expect somewhat less, and noticeably less on battery. Keeping the same model means the same OpenCode behavior on both machines.

**Why the laptop defaults differ.** `NCMOE=34` starts with more experts in RAM for 12 GB, the 64K context leaves room for the cache (raise it with `qwen-set CTX=131072` if `find-ncmoe` shows headroom), `THREADS` is tuned because of the P-core/E-core mix, and the sandbox gets 16 GB / 8 CPUs because 64 GB of RAM leaves room after the model.

**Why sm_89.** The RTX 4000 Ada is compute capability 8.9; a llama.cpp binary built only for Blackwell (12.0) won't run on it.

**Why the NVIDIA repo for the driver.** Debian's own driver packages lag behind new GPU generations; NVIDIA's repo provides the current open driver and the toolkit together.

**Why Qwen3-Coder-Next is optional, not a replacement.** It's only possible because of the 64 GB of RAM, uses most of that RAM, needs different sampling, and its published SWE-bench Verified score is lower than Qwen3.6-27B's.

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
- Unsloth, Qwen3-Coder-Next: https://unsloth.ai/docs/models/qwen3-coder-next
