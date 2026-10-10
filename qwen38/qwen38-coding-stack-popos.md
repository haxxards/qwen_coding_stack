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
cat > "$Q38/config/opencode/AGENTS.md" <<'EOF'
# Sandbox rules

You are running in a Docker sandbox as the user `dev`, without root and without `sudo`.
`apt`, `apt-get`, `dpkg -i` and `sudo` will always fail here. Do not try them, and do
not try to work around them.

- System libraries are installed when the sandbox image is built. If a program fails
  because a shared library (`lib*.so*`) or system tool is missing, stop and tell the user
  which Debian bookworm package provides it, so they can add it to
  `SANDBOX_EXTRA_PACKAGES` in the installer's `install.conf` and re-run `install.sh`.
- Install Python packages into a virtual environment inside the project
  (`python3 -m venv .venv`), never with `pip install --user` or `--break-system-packages`.
- Install Node packages locally in the project (`npm install`), never with `-g`.
- Download tools into the project (for example a `.tools/` folder) rather than system paths.
- There is no display. For programs that need one, use `xvfb-run -a <command>`.
- Godot prints some `ERROR:` lines in headless mode that are harmless; judge a build by
  its test results, not by those lines alone.
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

# --- qwen38-github: read-only GitHub access for the sandbox (deploy keys, held by an ssh-agent) ---
cat > "$Q38/bin/qwen38-github" <<'SCRIPT'
#!/usr/bin/env bash
# Read-only GitHub access for the sandbox, one deploy key per repository:
#   qwen38-stack github                         list repositories and the state of their keys
#   qwen38-stack github add OWNER/REPO          make a key (or use one already in place), show the
#                                            public key to add on GitHub, then check it
#   qwen38-stack github add OWNER/REPO --paste  paste an existing private key instead of making one
#   qwen38-stack github check [OWNER/REPO]      check again: fetching must work, pushing must be refused
#   qwen38-stack github remove OWNER/REPO       delete a repository's key from this machine
# Keys live in config/github/OWNER/REPO/deploy_key (+ deploy_key.pub). A key put there by hand
# is picked up the next time a sandbox opens. A key reaches a sandbox only after GitHub has
# confirmed it is a deploy key for that one repository and refuses pushes with it, and even
# then only through an ssh-agent outside the container: the private key never enters it.
set -euo pipefail
Q38="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
GH="$Q38/config/github"
ME="qwen38-stack github"
RECHECK_DAYS=7
MNT=/opt/github-readonly   # where the sandbox sees the generated files
umask 077

# GitHub's SSH host keys, checked against the SHA256 fingerprints GitHub publishes at
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
KNOWN_HOSTS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$KNOWN_HOSTS" > "$TMP/known_hosts"

die() { echo "$*" >&2; exit 1; }
need() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || die "$c isn't installed: sudo apt install openssh-client git"; done
}
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# OWNER/REPO, from OWNER/REPO, git@github.com:OWNER/REPO.git or https://github.com/OWNER/REPO
repo_name() {
  local r=$1
  r=${r#git@github.com:}; r=${r#ssh://git@github.com/}; r=${r#https://github.com/}; r=${r%/}; r=${r%.git}
  [[ $r =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] && [ "${r#*/}" != . ] && [ "${r#*/}" != .. ] \
    || die "Not a GitHub repository: $1 (expected OWNER/REPO)"
  printf '%s' "$r"
}

# Private keys must never end up in a git repository (the installer's own repository is public).
guard() {
  mkdir -p "$GH"; chmod 700 "$GH"
  if git -C "$GH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$GH is inside a git repository; refusing to keep private keys there."
  fi
}

repos() {  # every OWNER/REPO that has a key
  local k r
  for k in "$GH"/*/*/deploy_key; do
    [ -f "$k" ] || continue
    r=${k#"$GH/"}; printf '%s\n' "${r%/deploy_key}"
  done
}

# Tighten permissions (ssh refuses keys others can read), drop Windows line endings from a
# pasted key, and derive the public key if only the private one was put in place.
tidy() {
  local repo=$1 dir="$GH/$1"
  chmod 700 "$GH/${repo%/*}" "$dir"
  chmod 600 "$dir/deploy_key"
  if grep -q $'\r' "$dir/deploy_key"; then sed -i 's/\r$//' "$dir/deploy_key"; fi
  if [ ! -s "$dir/deploy_key.pub" ]; then
    ssh-keygen -y -f "$dir/deploy_key" > "$TMP/pub" 2>/dev/null \
      || { echo "$repo: $dir/deploy_key isn't a usable private key (or its passphrase was wrong); skipped." >&2; return 1; }
    mv "$TMP/pub" "$dir/deploy_key.pub"
  fi
  chmod 600 "$dir/deploy_key.pub"
}

fingerprint() { ssh-keygen -lf "$GH/$1/deploy_key.pub" | awk '{print $2}'; }

state() {  # ok | stale (checked over RECHECK_DAYS ago) | new (never checked, or the key changed)
  local f="$GH/$1/checked" fp at
  [ -f "$f" ] || { echo new; return; }
  read -r fp at < "$f" || true
  [ "$fp" = "$(fingerprint "$1")" ] || { echo new; return; }
  if [ $(( $(date +%s) - ${at:-0} )) -gt $(( RECHECK_DAYS * 86400 )) ]; then echo stale; else echo ok; fi
}

# Ask GitHub about the key directly (not through any agent). Returns 0 when it is a deploy key
# for exactly this repository, fetching works and pushing is refused; 1 when it must not be used;
# 2 when GitHub couldn't be reached; 3 when GitHub doesn't know the key yet.
check_key() {
  local repo=$1 key="$GH/$1/deploy_key" out
  local o=(-F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none
           -o UserKnownHostsFile="$TMP/known_hosts" -o GlobalKnownHostsFile=/dev/null
           -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=20)
  [ -t 0 ] || o+=(-o BatchMode=yes)
  out=$(ssh "${o[@]}" -T git@github.com </dev/null 2>&1) || true
  case "$(lower "$out")" in
    *"hi $(lower "$repo")!"*) ;;
    *"permission denied"*)
      echo "  GitHub doesn't accept this key yet: it hasn't been added as a deploy key for $repo."; return 3 ;;
    *"hi "*/*"!"*)
      echo "  REFUSED: this is the deploy key of another repository: $(grep -o 'Hi [^!]*' <<<"$out" | head -n1 | cut -c4-)"
      echo "  Give $repo its own key: $ME remove $repo && $ME add $repo"; return 1 ;;
    *"hi "*)
      echo "  REFUSED: this is a personal (account) key, not a deploy key. It would give the sandbox every"
      echo "  repository of that account, with push access. Replace it with a deploy key:"
      echo "  $ME remove $repo && $ME add $repo"; return 1 ;;
    *) echo "  Couldn't check the key with GitHub over SSH: $(tail -n1 <<<"$out")"; return 2 ;;
  esac
  if ! GIT_SSH_COMMAND="ssh $(printf '%q ' "${o[@]}")" git ls-remote "git@github.com:$repo.git" >/dev/null 2>"$TMP/err"; then
    echo "  The key is accepted, but fetching $repo failed: $(tail -n1 "$TMP/err")"; return 1
  fi
  # Ask for the push service and send nothing: GitHub refuses it at once for a read-only key;
  # for a key that can push it lists the branches and waits, and the empty input ends it unchanged.
  out=$(ssh "${o[@]}" git@github.com "git-receive-pack '$repo.git'" </dev/null 2>&1 | tr -d '\0') || true
  case "$(lower "$out")" in
    *"read only"*|*"read-only"*) ;;
    *)
      echo "  REFUSED: this key can push to $repo ('Allow write access' is ticked for it on GitHub)."
      echo "  Untick it at https://github.com/$repo/settings/keys, then: $ME check $repo"; return 1 ;;
  esac
  printf '%s %s\n' "$(fingerprint "$repo")" "$(date +%s)" > "$GH/$repo/checked"
}

check_report() {  # check_report REPO -> same return codes as check_key
  local rc=0
  echo "Checking the GitHub key for $1 ..."
  check_key "$1" || rc=$?
  if [ $rc -eq 0 ]; then
    echo "  OK: a read-only deploy key for $1 (fetch works, push is refused)."
  elif [ $rc -ne 2 ]; then
    rm -f "$GH/$1/checked"   # no longer usable; a network failure keeps the earlier result
  fi
  return $rc
}

show_instructions() {
  local repo=$1
  cat <<EOF

Add this public key to GitHub as a deploy key for $repo:
  1. Open https://github.com/$repo/settings/keys/new
  2. Title: anything, e.g. "qwen sandbox on $(uname -n)"
  3. Key: paste this line:

$(cat "$GH/$repo/deploy_key.pub")

  4. Leave "Allow write access" UNTICKED, then click "Add key".
EOF
}

cmd_add() {
  local repo="" paste=no wait=yes a dir
  for a in "$@"; do
    case "$a" in
      --paste) paste=yes ;;
      --no-wait) wait=no ;;
      -*) die "usage: $ME add OWNER/REPO [--paste]" ;;
      *) repo=$(repo_name "$a") ;;
    esac
  done
  [ -n "$repo" ] || die "usage: $ME add OWNER/REPO [--paste]"
  need ssh ssh-keygen git; guard
  dir="$GH/$repo"; mkdir -p "$dir"
  local fresh=no
  if [ -f "$dir/deploy_key" ]; then
    [ "$paste" = no ] || die "$repo already has a key. To replace it: $ME remove $repo, then add it again."
    echo "Using the key already in $dir"
  elif [ "$paste" = yes ]; then
    echo "Paste the private key (every line, BEGIN to END), then press Enter and Ctrl+D:"
    tr -d '\r' > "$TMP/key"
    ssh-keygen -y -f "$TMP/key" > "$TMP/key.pub" || die "That isn't a valid private key (or the passphrase was wrong)."
    mv "$TMP/key" "$dir/deploy_key"; mv "$TMP/key.pub" "$dir/deploy_key.pub"
    echo "Saved to $dir/deploy_key"
  else
    ssh-keygen -q -t ed25519 -N "" -C "read-only deploy key for $repo, qwen sandbox on $(uname -n)" -f "$dir/deploy_key"
    echo "Made a new key for $repo in $dir"
    fresh=yes
  fi
  tidy "$repo" || exit 1
  if [ "$(state "$repo")" = ok ]; then echo "$repo: already checked, read-only."; return; fi
  # A key that existed already may be on GitHub: try it before asking. A key GitHub refuses
  # for good reason (personal, can push, another repository's) is not offered again.
  local rc=3
  if [ $fresh = no ]; then
    rc=0; check_report "$repo" || rc=$?
    case $rc in 0) return ;; 1) exit 1 ;; esac
  fi
  show_instructions "$repo"
  if [ $wait = yes ] && [ -t 0 ]; then
    read -r -p "Press Enter once it's added (or Ctrl+C, and later: $ME check $repo) "
    check_report "$repo" || exit 1
  else
    echo "Then check it with: $ME check $repo   (a sandbox also checks it when it opens)"
  fi
}

cmd_check() {
  local r list fail=0
  need ssh ssh-keygen git; guard
  if [ $# -gt 0 ]; then list=$(repo_name "$1"); [ -f "$GH/$list/deploy_key" ] || die "No key for $list. Add one: $ME add $list"
  else list=$(repos); [ -n "$list" ] || die "No keys yet. Add one: $ME add OWNER/REPO"
  fi
  for r in $list; do
    tidy "$r" && check_report "$r" || fail=1
  done
  return $fail
}

cmd_list() {
  local r s list
  [ -d "$GH" ] && list=$(repos) || list=""
  if [ -z "$list" ]; then
    echo "No GitHub keys. Give the sandbox read-only access to a repository with: $ME add OWNER/REPO"
    return
  fi
  for r in $list; do
    if [ -s "$GH/$r/deploy_key.pub" ]; then
      case "$(state "$r")" in
        ok) s="read-only, checked" ;; stale) s="read-only, re-checked when a sandbox opens" ;; *) s="not checked yet: $ME check $r" ;;
      esac
      printf '  %-40s %s  %s\n' "$r" "$(fingerprint "$r")" "$s"
    else
      printf '  %-40s %s\n' "$r" "no public key yet: $ME check $r"
    fi
  done
}

cmd_remove() {
  local repo
  repo=$(repo_name "${1:-}")
  [ -d "$GH/$repo" ] || die "No key for $repo."
  rm -rf "${GH:?}/$repo"
  rmdir "$GH/${repo%/*}" 2>/dev/null || true
  echo "Deleted the key for $repo from this machine. Also delete it on GitHub: https://github.com/$repo/settings/keys"
}

# Used by the sandbox command: checks keys, then writes OUT/ with what the container mounts
# (ssh config, pinned known_hosts, PUBLIC keys, git URL rewrites) plus the private-key list for
# the agent and the agent rules. Exit 0 = at least one key is ready, 3 = none.
cmd_prepare() {
  local out=${1:?} r rc list ready=()
  [ -d "$GH" ] || exit 3
  list=$(repos); [ -n "$list" ] || exit 3
  for c in ssh ssh-keygen ssh-agent ssh-add git; do
    command -v "$c" >/dev/null || { echo "GitHub keys skipped: $c isn't installed (sudo apt install openssh-client git)" >&2; exit 3; }
  done
  ( guard ) || exit 3
  for r in $list; do
    tidy "$r" || continue
    case "$(state "$r")" in
      ok) ;;
      stale)
        rc=0; check_report "$r" >&2 || rc=$?
        if [ $rc -eq 2 ]; then
          echo "  Using the earlier check for $r." >&2
          printf '%s %s\n' "$(fingerprint "$r")" "$(( $(date +%s) - (RECHECK_DAYS - 1) * 86400 ))" > "$GH/$r/checked"
        elif [ $rc -ne 0 ]; then echo "  $r is not available in this sandbox." >&2; continue
        fi ;;
      new)
        check_report "$r" >&2 || { echo "  $r is not available in this sandbox." >&2; continue; } ;;
    esac
    ready+=("$r")
  done
  [ ${#ready[@]} -gt 0 ] || exit 3

  rm -rf "$out"; mkdir -p "$out/mount/keys"
  cp "$TMP/known_hosts" "$out/mount/known_hosts"
  : > "$out/agent-keys"
  {
    echo "# Generated by $ME for one sandbox. Deploy keys held by an ssh-agent outside the container."
    for r in "${ready[@]}"; do
      local a="github-${r/\//-}" pub="${r/\//__}.pub"
      cp "$GH/$r/deploy_key.pub" "$out/mount/keys/$pub"
      printf '%s\n' "$GH/$r/deploy_key" >> "$out/agent-keys"
      printf '\nHost %s\n  HostName github.com\n  User git\n  IdentityFile %s/keys/%s\n  IdentitiesOnly yes\n' "$a" "$MNT" "$pub"
      printf '  UserKnownHostsFile %s/known_hosts\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking yes\n  UpdateHostKeys no\n  BatchMode yes\n' "$MNT"
    done
  } > "$out/mount/ssh_config"
  {
    echo "# Generated by $ME: send these repositories' GitHub URLs through their deploy keys."
    for r in "${ready[@]}"; do
      printf '[url "git@github-%s:%s"]\n' "${r/\//-}" "$r"
      printf '\tinsteadOf = git@github.com:%s\n\tinsteadOf = ssh://git@github.com/%s\n\tinsteadOf = https://github.com/%s\n' "$r" "$r" "$r"
    done
  } > "$out/mount/gitconfig"
  {
    cat "$Q38/config/opencode/AGENTS.md"
    printf '\n## GitHub (read-only)\n\nYou can clone, fetch and pull these GitHub repositories, and only these:\n\n'
    for r in "${ready[@]}"; do printf -- '- `%s`: `git@github.com:%s.git`\n' "$r" "$r"; done
    cat <<'EOF'

Any github.com URL form for them works: git routes it through the right key. Pushing is
refused by GitHub, on purpose: these are read-only deploy keys. Do not try to push, do not
look for other credentials, and do not try to read, copy or move SSH keys or the agent socket.
To share work, commit locally and tell the user; they review and push it themselves.
EOF
  } > "$out/AGENTS.md"
  chmod -R go-rwx "$out"
}

case "${1:-list}" in
  list) cmd_list ;;
  add) shift; cmd_add "$@" ;;
  check) shift; cmd_check "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  prepare) shift; cmd_prepare "$@" ;;
  -h|--help|help) sed -n '2,12p' "$0" ;;
  *) sed -n '2,12p' "$0" >&2; exit 1 ;;
esac
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
export DOCKER_HOST=unix:///var/run/docker.sock   # the system Docker: rootless Docker and Docker Desktop remap user IDs, so the sandbox couldn't write your files
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
[ -f "$Q38/config/opencode/AGENTS.md" ] || "$Q38/bin/qwen38-write-opencode-config" >/dev/null   # older installs: create the sandbox rules file
mkdir -p "$STATE"/{data,state,cache}
printf '%s\n' "$PROJECT" > "$STATE/path"
# Read-only GitHub access (qwen38-stack github): the deploy keys stay on this machine, in an
# ssh-agent that lives only as long as this sandbox. The container gets the agent's socket,
# the public keys, an ssh config with GitHub's pinned host keys, and git URL rewrites.
AGENTS="$Q38/config/opencode/AGENTS.md"; GITHUB=()
if [ -x "$Q38/bin/qwen38-github" ] && "$Q38/bin/qwen38-github" prepare "$STATE/github"; then
  SOCK="${XDG_RUNTIME_DIR:-/tmp}/qwen38-coding-stack-${ID##*-}.agent"
  [ ! -f "$STATE/github.agent-pid" ] || kill "$(cat "$STATE/github.agent-pid")" 2>/dev/null || true
  rm -f "$SOCK"
  eval "$(ssh-agent -s -a "$SOCK")" >/dev/null
  echo "$SSH_AGENT_PID" > "$STATE/github.agent-pid"
  trap 'kill "$SSH_AGENT_PID" 2>/dev/null; rm -f "$SOCK" "$STATE/github.agent-pid"' EXIT
  mapfile -t KEYS < "$STATE/github/agent-keys"
  SSH_AUTH_SOCK="$SOCK" ssh-add -q "${KEYS[@]}"
  AGENTS="$STATE/github/AGENTS.md"
  GITHUB=(-v "$STATE/github/mount":/opt/github-readonly:ro -v "$SOCK":/run/ssh-agent.sock
          -e SSH_AUTH_SOCK=/run/ssh-agent.sock -e GIT_CONFIG_SYSTEM=/opt/github-readonly/gitconfig
          -e "GIT_SSH_COMMAND=ssh -F /opt/github-readonly/ssh_config")
fi
RUN=(docker run -it --rm --name "$NAME" --label "qwen38-coding-stack.project=$PROJECT" \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  --memory "${SANDBOX_MEMORY:-6g}" --cpus "${SANDBOX_CPUS:-4}" \
  -v "$PROJECT":/workspace \
  -v "$Q38/config/opencode/opencode.json":/home/dev/.config/opencode/opencode.json:ro \
  -v "$AGENTS":/home/dev/.config/opencode/AGENTS.md:ro \
  "${GITHUB[@]}" \
  -v "$STATE/data":/home/dev/.local/share/opencode \
  -v "$STATE/state":/home/dev/.local/state \
  -v "$STATE/cache":/home/dev/.cache \
  -e HISTFILE=/home/dev/.local/state/bash_history \
  -w /workspace \
  qwen38-coding-stack-sandbox:latest "${@:2}")
# With an agent to stop afterwards, stay around until the container exits; otherwise hand over.
if [ ${#GITHUB[@]} -gt 0 ]; then "${RUN[@]}"; else exec "${RUN[@]}"; fi
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
#   qwen38-stack github [add|check|remove] read-only GitHub access for the sandbox (qwen38-stack github help)
set -euo pipefail
export DOCKER_HOST=unix:///var/run/docker.sock   # the system Docker: rootless Docker and Docker Desktop remap user IDs, so the sandbox couldn't write your files
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
  echo "GitHub (read-only):"
  "$Q38/bin/qwen38-github" list 2>/dev/null | sed 's/^  //; s/^/  /' || true
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
  github) shift; exec "$Q38/bin/qwen38-github" "$@" ;;
  ""|-h|--help|help) sed -n '2,11p' "$0" ;;
  *) sed -n '2,11p' "$0" >&2; exit 1 ;;
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

The container runs as a non-root user with no root and no `sudo`, so the agent can't `apt-get install` anything: every system library a project needs is installed here, at build time. The list covers Godot (headless and under `xvfb-run`), headless Blender (`bpy`) and Python audio; to add more, put them on the `RUN apt-get` line (or in `SANDBOX_EXTRA_PACKAGES` in the installer's `install.conf`) and rebuild.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
mkdir -p "$Q38/sandbox"
cat > "$Q38/sandbox/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
ARG UID=1000
ARG GID=1000
# Installed as root at build time: inside the sandbox the agent runs as a non-root user
# with no sudo, so it can't apt-get install anything itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client build-essential python3 python3-venv python3-pip \
      nodejs npm unzip zip xz-utils file ripgrep less procps \
      `# Godot headless (tests, import): system fonts, desktop dirs, D-Bus, udev` \
      fontconfig fonts-dejavu-core xdg-user-dirs libdbus-1-3 libudev1 \
      `# Godot with a display (xvfb-run, OpenGL 3 / Vulkan on Mesa's software renderer)` \
      xvfb xauth libgl1 libegl1 libgles2 libgl1-mesa-dri libglx-mesa0 \
      libx11-6 libxcursor1 libxext6 libxi6 libxinerama1 libxrandr2 libxrender1 libxkbcommon0 \
      libwayland-client0 libwayland-cursor0 libwayland-egl1 libvulkan1 mesa-vulkan-drivers libasound2 \
      `# Blender as a Python module (bpy, Python 3.11) loads these even headless` \
      libsm6 libice6 libxfixes3 libxxf86vm1 \
      `# Python audio (soundfile writes Ogg Vorbis)` \
      libsndfile1 \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd -g ${GID} dev && useradd -m -u ${UID} -g ${GID} -s /bin/bash dev
USER dev
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/dev/.opencode/bin:${PATH}"
RUN mkdir -p /home/dev/.config/opencode /home/dev/.local/share/opencode
WORKDIR /workspace
CMD ["opencode"]
EOF
"$Q38/bin/qwen38-stack" build
```

To update OpenCode later: `qwen38-stack build --no-cache`.

---

## 12. Daily use

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

Sandbox limits default to `--memory 6g --cpus 4`; override per run with `SANDBOX_MEMORY=8g SANDBOX_CPUS=6 qwen38-sandbox`.

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

### Read-only GitHub access

Give the sandbox its own key to one GitHub repository, so the agent can clone, fetch and pull it but never push. Use a **deploy key**: GitHub ties it to that one repository and, unless you tick "Allow write access", refuses pushes with it. `qwen38-stack github` refuses to use a key that can push, or a personal account key (which would open every repository you own).

```bash
qwen38-stack github add haxxards/godot          # makes a key and shows the public key to add on GitHub
qwen38-stack github                             # lists keys and whether they've been checked
```

Already have a key for that repository? Either paste it:

```bash
qwen38-stack github add haxxards/godot --paste  # paste the private key, then Enter and Ctrl+D
```

or put the files in place; the next sandbox picks them up and checks them:

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
mkdir -p "$Q38/config/github/haxxards/godot"
cp /path/to/key "$Q38/config/github/haxxards/godot/deploy_key"   # the .pub file is optional
```

`GITHUB_READONLY_REPOS` in the installer's `install.conf` does the same for a list of repositories on each run. Never put a private key in `install.conf`: it is part of a public repository.

How it's kept read-only and contained:

- **GitHub enforces it.** Each key is checked against GitHub before a sandbox uses it: the greeting must name exactly that repository (a personal key names an account), fetching must work, and the push service must be refused. The check is cached and repeated weekly.
- **The private key never enters the sandbox.** When a sandbox opens, `qwen38-sandbox` starts an `ssh-agent` on this machine with the checked keys and gives the container only the agent's socket, the public keys, an ssh config pinning GitHub's published host keys, and git rules that send `git@github.com:`, `ssh://` and `https://github.com/` URLs for those repositories through their key. The agent stops when the sandbox closes.
- **The agent is told.** The sandbox rules (`AGENTS.md`) list the repositories it can pull and say pushing is refused on purpose.

Anything the sandbox can read, a determined agent could still send elsewhere; a read-only deploy key limits that to reading one repository, and deleting the key on GitHub (Settings > Deploy keys) revokes it at once. Remove it here with `qwen38-stack github remove haxxards/godot`. The two stacks keep separate keys; to share one, copy its folder from one `config/github/` to the other.

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
| The agent tries `apt-get`/`sudo`, or a build fails with `error while loading shared libraries: lib….so` inside the sandbox | The sandbox runs without root on purpose, so nothing can be installed from inside it | Add the Debian package to `SANDBOX_EXTRA_PACKAGES` in the installer's `install.conf` and re-run `install.sh` (the image rebuilds). To find the package for a library: `apt-file search libfoo.so.1` on the host. Godot, Blender (`bpy`), `xvfb-run` and `soundfile` libraries are already included |
| `qwen38-stack github` says the key isn't accepted (`Permission denied`) | The public key isn't on GitHub yet, or was added to another repository | Add it at `https://github.com/OWNER/REPO/settings/keys/new` (shown again by `qwen38-stack github add OWNER/REPO`), then `qwen38-stack github check` |
| `REFUSED: this key can push` / `REFUSED: this is a personal (account) key` | The key has "Allow write access", or it's your account key | Untick write access on GitHub (or make a deploy key with `qwen38-stack github add`), then `qwen38-stack github check` |
| `Couldn't check the key with GitHub over SSH` | Port 22 to github.com is blocked, or no network | The sandbox opens without GitHub access; a key checked before keeps working for a week. Try again on another network |
| `git pull` in the sandbox says `ssh: not found` | The sandbox image predates GitHub access | Re-run `install.sh` (it rebuilds the image with `openssh-client`) |
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
