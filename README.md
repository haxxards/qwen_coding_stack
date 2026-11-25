# qwen_coding_stack

Qwen on the local GPU (llama.cpp) with OpenCode in a per-project Docker sandbox. Each folder is one machine's setup as of a date: its README is the full guide, and its `installer/install.sh` does every step.

| Folder | Machine | Model | Use it for |
|---|---|---|---|
| [`20261124_desktop`](20261124_desktop/) | Pop!_OS desktop, RTX 5080 16 GB | Qwen3.8-27B UD-Q3_K_XL, all on GPU, 48K–64K context, ~46–56 tokens/s (measured) | **Daily use** |
| [`20261124_laptop`](20261124_laptop/) | Debian laptop, RTX 4000 Ada 12 GB | Qwen3.8-27B UD-IQ3_XXS, all on GPU, ~32K context, ~30 tokens/s | **Daily use** |
| [`20261007_desktop`](20261007_desktop/) | Pop!_OS desktop | Qwen3.6-35B-A3B UD-Q4_K_XL, experts partly in RAM, 128K context | Very long sessions |
| [`20261007_laptop`](20261007_laptop/) | Debian laptop | Qwen3.6-35B-A3B UD-Q4_K_XL, most experts in RAM, 64K context | Long sessions |

A machine's two setups install side by side (`qwen38-stack` and `qwen-stack`); one model runs at a time. On either machine:

```bash
git clone -b main git@github.com:haxxards/qwen_coding_stack.git ~/Development/qwen_coding_stack
~/Development/qwen_coding_stack/start.sh myproject   # first run installs; if it asks to reboot, reboot and run it again
~/Development/qwen_coding_stack/stop.sh              # stop the server, free the GPU
```

`start.sh myproject` uses the machine's newest folder (`--folder 20261007_desktop` for another), opens `~/Development/qwen-projects/myproject` (made if new; or give a path), commits a git checkpoint, opens OpenCode, then prints the keep/discard commands. Installs live in `~/Development/qwen-runtime/`; older ones in `~/Development/qwen(38)-coding-stack` move there on their next run. Each installer refuses to run on the other machine. `install.conf` is part of this public repository: never put a private key in it.
