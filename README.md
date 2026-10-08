# qwen_coding_stack

Qwen on the local GPU (llama.cpp) with OpenCode in a per-project Docker sandbox. Two independent stacks; one model fits on the GPU at a time.

| Model | Commands | Guides (every step, explained) |
|---|---|---|
| Qwen3.6-35B-A3B | `qwen-stack`, `sandbox`, `qwen-set` | [Pop!_OS desktop](qwen36/qwen-coding-stack-popos.md) · [Debian laptop](qwen36/qwen-coding-stack-debian-work-laptop.md) |
| Qwen3.8-27B | `qwen38-stack`, `qwen38-sandbox`, `qwen38-set` | [Pop!_OS desktop](qwen38/qwen38-coding-stack-popos.md) · [Debian laptop](qwen38/qwen38-coding-stack-debian-work-laptop.md) |

## Install

```bash
sudo apt update && sudo apt install -y git
git clone -b main git@github.com:haxxards/qwen_coding_stack.git ~/Development/qwen_coding_stack
cd ~/Development/qwen_coding_stack
nano qwen36/qwen-coding-stack-installer/installer/install.conf   # optional
qwen36/qwen-coding-stack-installer/installer/install.sh
```

The first run installs the driver, CUDA and Docker, then asks to reboot (on the laptop with Secure Boot: Enroll MOK → Continue → Yes at the blue screen). Run `install.sh` again after the reboot to build llama.cpp, download the model, build the sandbox and start the server. Re-running is always safe.

## Use

```bash
. ~/Development/qwen-coding-stack/config/shell.sh   # or open a new terminal
cd ~/path/to/project
git rev-parse --git-dir >/dev/null 2>&1 || git init
git add -A && git commit -qm "checkpoint before AI session" || true
qwen-stack up
```

`up` starts the server if needed and opens OpenCode with the project's earlier sessions. `qwen-stack down` stops everything and deletes nothing; `qwen-stack` alone lists the rest (`shell`, `status`, `logs`, `build`, `boot`).

## Update

```bash
cd ~/Development/qwen_coding_stack && git pull origin main
qwen36/qwen-coding-stack-installer/installer/install.sh
```

## Qwen3.8

Same steps with `qwen38/qwen38-coding-stack-installer/installer/install.sh` (no reboot once Qwen3.6 is installed) and `qwen38-stack`. `qwen-stack up --server` or `qwen38-stack up --server` switches models.
