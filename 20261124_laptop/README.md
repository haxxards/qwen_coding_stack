# Local Qwen3.8-27B Coding Assistant — Debian (Work Laptop)

**Hardware:** Intel i9-13950HX (8 P-cores + 16 E-cores), 64 GB DDR5-5600, NVIDIA RTX 4000 Ada Laptop (12 GB VRAM, Ada Lovelace), 1 TB NVMe.
**Setup of 2026-11-24** (folder `20261124_laptop`): the current pick for this laptop. The older Qwen3.6 setup, [`20261007_laptop`](../20261007_laptop/), can stay installed alongside it.

## Can this machine run it?

**Yes, at a usable speed: the 3-bit UD-IQ3_XXS file fits entirely in the 12 GB GPU, with a ~32K context.**

| Option | Fits in 12 GB VRAM? | Expected generation speed | Verdict |
|---|---|---|---|
| UD-Q3_K_XL (13.1 GB) | No: ~4 GB of weights in RAM | Roughly 10–14 tokens/s | Better answers, but slow |
| **UD-IQ3_XXS (10.9 GB)** | **Yes, with ~1 GB left for a ~32K `q8_0` context** | **Roughly 30 tokens/s** | **Recommended** |
| UD-Q2_K_XL (9.8 GB) | Yes | Slightly faster | 2-bit loses more quality, for little gain |

Why: Qwen3.8-27B is a **dense** model: every parameter is read for every token, so it's fast only when all of it is in VRAM. UD-IQ3_XXS is the 3-bit file that fits, leaving room for about 32K tokens of context: enough for most agent tasks, but long sessions fill it. For those, the Qwen3.6 setup ([`20261007_laptop`](../20261007_laptop/)) has a 64K context; switching is one command (see **Switching**).

The speeds are estimates; `qwen38-stack logs` shows the real tokens/s while it answers.

**Not set up here: Flint** (40B total, 2.5B active, released October 2026). It beats Qwen3.6 on paper, but its scores are self-reported, llama.cpp support only landed on Oct 21 (with a known 10–30% slowdown and an open report of tool calls getting lost with OpenCode), and its 4-bit file (~23 GB) doesn't fit this GPU. Worth trying on your own work once that settles.

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

## Quick start

`installer/install.sh` runs every numbered step below. Run it as your normal user (it asks for your sudo password once):

```bash
git clone -b main git@github.com:haxxards/qwen_coding_stack.git ~/Development/qwen_coding_stack   # once; later: git -C ~/Development/qwen_coding_stack pull origin main
~/Development/qwen_coding_stack/20261124_laptop/installer/install.sh
```

If it asks to reboot, run the same command again afterwards. If the Qwen3.6 setup is already installed, there's nothing to reboot for. With Secure Boot on, a reboot shows a blue **MOK management** screen: **Enroll MOK → Continue → Yes**, then the password you chose. Settings are in `installer/install.conf`. Re-running skips finished steps; `install.sh --update` also updates llama.cpp and OpenCode.

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

Downloads Unsloth's **UD-IQ3_XXS** quant (10.9 GB). See **Can this machine run it?** for why this file. `hf download` skips completed files and resumes partial ones. The vision projector (`mmproj`) is skipped: it isn't needed for coding and would use VRAM.

```bash
Q38=/home/tristanv/Development/qwen38-coding-stack
if [ ! -x "$Q38/venv/bin/hf" ]; then
  python3 -m venv "$Q38/venv"
  PIP_CACHE_DIR="$Q38/cache/pip" "$Q38/venv/bin/pip" install -U huggingface_hub
fi
HF_HOME="$Q38/cache/huggingface" "$Q38/venv/bin/hf" download unsloth/Qwen3.8-27B-GGUF \
  --local-dir "$Q38/models/Qwen3.8-27B-GGUF" \
  --include "*UD-IQ3_XXS*"
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
  MODEL=$(ls "$Q38"/models/Qwen3.8-27B-GGUF/*UD-IQ3_XXS*.gguf 2>/dev/null | sort | head -1)
  cat > "$Q38/config/server.env" <<EOF
# qwen38-coding-stack server settings. Change with: qwen38-set KEY=VALUE
# Each line keeps a value already set in the environment, so one-off
# overrides work, e.g.:  CTX=32768 qwen38-server
CUDA_HOME=\${CUDA_HOME:-$CUDA_HOME}
MODEL=\${MODEL:-$MODEL}
NGL=\${NGL:-99}
CTX=\${CTX:-32768}
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

The commands are in this folder's `installer/lib/write-commands.sh`. This writes them into `bin/`, replacing earlier versions (they hold no settings, so re-running it is how you pick up fixes), and generates the OpenCode config from your settings:

```bash
~/Development/qwen_coding_stack/20261124_laptop/installer/install.sh --commands
. "/home/tristanv/Development/qwen38-coding-stack/config/shell.sh"
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

Find the largest context that fits with the whole model on the GPU. It stops any running server, tries each size from largest to smallest, saves the first that starts, and restarts the service if it's installed:

```bash
qwen38-find-fit ctx 40960 32768 28672 24576 20480 16384
qwen38-set
```

Expect around **32768** with the desktop off the NVIDIA GPU (see **Keep the desktop off the NVIDIA GPU**). If even 16384 fails, see **Troubleshooting → GPU out of memory**.

---

## 11. Run the server as a system service

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

## 12. Build the sandbox image

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

## 13. Daily use

```bash
~/Development/qwen_coding_stack/start.sh --folder 20261124_laptop ~/path/to/project
```

It commits the project as a git checkpoint, starts the server if needed, opens OpenCode with the project's earlier sessions, and afterwards prints the commands to keep or discard the work. `qwen38-stack up` alone skips the checkpoint.

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

Only one model fits on the GPU at a time (Qwen3.6 is the [`20261007_laptop`](../20261007_laptop/) setup). The services conflict, so starting one stops the other:

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

## 14. Optional: the larger UD-Q3_K_XL file

UD-Q3_K_XL (13.1 GB) loses less quality than UD-IQ3_XXS but doesn't fit in 12 GB, so some layers move to RAM, at roughly a third of the speed. To try it, set `QUANT=UD-Q3_K_XL` in `installer/install.conf` and re-run `install.sh`: it downloads the file, switches the server to it and fits it again. Set `QUANT=UD-IQ3_XXS` and re-run to switch back.

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

**2. Fit the context again** (other programs' VRAM use may have changed):

```bash
qwen38-find-fit ctx 40960 32768 28672 24576 20480 16384
```

**3. If even 16384 doesn't fit**, keep a 32K context and move a few layers to RAM (slower; each layer moved costs speed):

```bash
qwen38-set CTX=32768
qwen38-find-fit ngl 99 62 60 58 56 54 52
```

**Alternative: automatic fitting:** `qwen38-set NGL=auto`.

---

## Rationale

**Why Qwen3.8-27B is worth the trouble.** It's a substantial step up from the Qwen3.6 generation on agentic coding: Qwen reports SWE-bench Pro 61.7% vs 53.5% for Qwen3.6-27B, and Terminal Bench 2.1 73.0% vs 63.4%. Qwen3.6-27B was itself stronger than Qwen3.6-35B-A3B on coding, so the quality gap over the model in the Qwen3.6 stack is larger still. These are vendor-run numbers at full precision; quantization and local tooling will lower them somewhat.

**Why it's harder to run than Qwen3.6-35B-A3B.** That model is Mixture-of-Experts: only ~3B parameters are used per token, so most of it could sit in system RAM at little cost. Qwen3.8-27B is **dense**: all 27B parameters are read for every token. Any part of it in system RAM is read over the much slower RAM bus on every token, so speed drops sharply as soon as it doesn't fit in VRAM. The rule of thumb for a dense model: fit it on the GPU, even at a lower-bit quant, rather than spill a higher-bit one.

**Why UD-IQ3_XXS.** At 10.9 GB it's the 3-bit file that fits in 12 GB with room for a useful context. Unsloth's dynamic quants keep the most sensitive layers at higher precision, so 3-bit remains usable, but expect some loss against the desktop's UD-Q3_K_XL (13.1 GB), which doesn't fit here.

**Why a q8_0 context cache.** Only 16 of the 64 layers use full attention (the rest are Gated DeltaNet with a small fixed-size state), with 4 KV heads of dimension 256. That works out to about 64 KB per token at full precision (16 layers × 4 heads × 256 × 2 for K and V × 2 bytes), or ~2 GB per 32K tokens. `q8_0` halves it, doubling the context that fits.

**Why `REASONING_EFFORT=medium`.** Qwen3.8 thinks at "xhigh" effort by default, which can mean thousands of thinking tokens per agent step. Locally, every token costs real time, so `medium` is a better default; switch to `xhigh` for hard problems or `low` for quick edits with `qwen38-set`.

**Why a separate stack.** Keeping Qwen3.8 in its own directory, with its own commands, port and service, leaves the working Qwen3.6 setup untouched and makes switching a single command. The services declare `Conflicts=`, so the two can never fight over the GPU.

**Why the same tools otherwise.** llama.cpp, OpenCode with subagents disabled, the Docker sandbox, the system service, and the one-settings-file design were chosen for the Qwen3.6 stack for reasons that apply equally here (see the Rationale in [`20261007_laptop`](../20261007_laptop/)).

**Why fit-by-context on this machine.** With every layer on the GPU, the only variable is how much context fits beside it, and that depends on what else uses VRAM. `qwen38-find-fit ctx` measures it instead of guessing.

**Why ~30 tokens/s.** Each token reads all 10.9 GB of weights from VRAM. At the laptop GPU's ~430 GB/s that's about 25 ms, a ceiling near 40 tokens/s, and roughly 30 in practice. With layers in RAM instead, each token also reads them over the ~60–70 GB/s RAM bus, which is why UD-Q3_K_XL drops to 10–14 tokens/s.

**Why not 2-bit.** UD-Q2_K_XL fits too, but 2-bit costs a dense model noticeably more quality than 3-bit for only a little more speed.

### References

- Unsloth, Qwen3.8 — How to Run Locally (requirements, settings, reasoning effort): https://unsloth.ai/docs/models/qwen3.8
- Unsloth Qwen3.8-27B GGUF (quant sizes, architecture): https://huggingface.co/unsloth/Qwen3.8-27B-GGUF
- Qwen3.8-27B release and benchmarks summary: https://en.immers.cloud/ai/Qwen/qwen3.8-27b/
- Qwen3.8-27B on OpenRouter (release date, capabilities): https://api3.shopot.ai/qwen/qwen3.8-27b
- OpenCode agents & task permissions: https://opencode.ai/docs/agents/
- OpenCode providers (llama.cpp config, `small_model`): https://opencode.ai/docs/providers/
- OpenCode subagent permission bypass report: https://github.com/anomalyco/opencode/issues/20549
- XDA, local agent context limits: https://www.xda-developers.com/stopped-my-local-llm-agent-from-running-out-of-context/
- llama.cpp Flint support (merged Oct 21, 2026; notes the slowdown): https://github.com/ggml-org/llama.cpp/pull/30928
- Flint tool calls with OpenCode (open report): https://github.com/ggml-org/llama.cpp/issues/31000
