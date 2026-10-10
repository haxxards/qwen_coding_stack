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
cat > "$QCS/config/opencode/AGENTS.md" <<'EOF'
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

# --- qwen-github: read-only GitHub access for the sandbox (deploy keys, held by an ssh-agent) ---
cat > "$QCS/bin/qwen-github" <<'SCRIPT'
#!/usr/bin/env bash
# Read-only GitHub access for the sandbox, one deploy key per repository:
#   qwen-stack github                         list repositories and the state of their keys
#   qwen-stack github add OWNER/REPO          make a key (or use one already in place), show the
#                                            public key to add on GitHub, then check it
#   qwen-stack github add OWNER/REPO --paste  paste an existing private key instead of making one
#   qwen-stack github check [OWNER/REPO]      check again: fetching must work, pushing must be refused
#   qwen-stack github remove OWNER/REPO       delete a repository's key from this machine
# Keys live in config/github/OWNER/REPO/deploy_key (+ deploy_key.pub). A key put there by hand
# is picked up the next time a sandbox opens. A key reaches a sandbox only after GitHub has
# confirmed it is a deploy key for that one repository and refuses pushes with it, and even
# then only through an ssh-agent outside the container: the private key never enters it.
set -euo pipefail
QCS="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
GH="$QCS/config/github"
ME="qwen-stack github"
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
    cat "$QCS/config/opencode/AGENTS.md"
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

# --- sandbox: runs OpenCode (or any command) in an isolated container ---
cat > "$QCS/bin/sandbox" <<'SCRIPT'
#!/usr/bin/env bash
# Usage: sandbox [project-dir] [command ...]
#   sandbox                 OpenCode on the current directory
#   sandbox ~/code/app bash a shell in the same sandbox (joins it if it's already open)
# Each project keeps its OpenCode sessions, prompt and shell history, and the tools
# OpenCode downloads in sandbox-state/<project>/, so the next session picks them up.
set -euo pipefail
export DOCKER_HOST=unix:///var/run/docker.sock   # the system Docker: rootless Docker and Docker Desktop remap user IDs, so the sandbox couldn't write your files
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
[ -f "$QCS/config/opencode/AGENTS.md" ] || "$QCS/bin/write-opencode-config" >/dev/null   # older installs: create the sandbox rules file
mkdir -p "$STATE"/{data,state,cache}
printf '%s\n' "$PROJECT" > "$STATE/path"
# Read-only GitHub access (qwen-stack github): the deploy keys stay on this machine, in an
# ssh-agent that lives only as long as this sandbox. The container gets the agent's socket,
# the public keys, an ssh config with GitHub's pinned host keys, and git URL rewrites.
AGENTS="$QCS/config/opencode/AGENTS.md"; GITHUB=()
if [ -x "$QCS/bin/qwen-github" ] && "$QCS/bin/qwen-github" prepare "$STATE/github"; then
  SOCK="${XDG_RUNTIME_DIR:-/tmp}/qwen-coding-stack-${ID##*-}.agent"
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
RUN=(docker run -it --rm --name "$NAME" --label "qwen-coding-stack.project=$PROJECT" \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  --memory "${SANDBOX_MEMORY:-@@SBMEM@@}" --cpus "${SANDBOX_CPUS:-@@SBCPU@@}" \
  -v "$PROJECT":/workspace \
  -v "$QCS/config/opencode/opencode.json":/home/dev/.config/opencode/opencode.json:ro \
  -v "$AGENTS":/home/dev/.config/opencode/AGENTS.md:ro \
  "${GITHUB[@]}" \
  -v "$STATE/data":/home/dev/.local/share/opencode \
  -v "$STATE/state":/home/dev/.local/state \
  -v "$STATE/cache":/home/dev/.cache \
  -e HISTFILE=/home/dev/.local/state/bash_history \
  -w /workspace \
  qwen-coding-stack-sandbox:latest "${@:2}")
# With an agent to stop afterwards, stay around until the container exits; otherwise hand over.
if [ ${#GITHUB[@]} -gt 0 ]; then "${RUN[@]}"; else exec "${RUN[@]}"; fi
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
#   qwen-stack github [add|check|remove] read-only GitHub access for the sandbox (qwen-stack github help)
set -euo pipefail
export DOCKER_HOST=unix:///var/run/docker.sock   # the system Docker: rootless Docker and Docker Desktop remap user IDs, so the sandbox couldn't write your files
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
  # --load: a docker-container builder otherwise keeps the image in its build cache only.
  local build=(docker build)
  docker buildx version >/dev/null 2>&1 && build=(docker buildx build --load)
  "${build[@]}" "$@" -t "$IMAGE" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" - < "$QCS/sandbox/Dockerfile"
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
  echo "GitHub (read-only):"
  "$QCS/bin/qwen-github" list 2>/dev/null | sed 's/^  //; s/^/  /' || true
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
  github) shift; exec "$QCS/bin/qwen-github" "$@" ;;
  ""|-h|--help|help) sed -n '2,11p' "$0" ;;
  *) sed -n '2,11p' "$0" >&2; exit 1 ;;
esac
SCRIPT

chmod +x "$QCS"/bin/*
  sed -i "s/@@SBMEM@@/$SANDBOX_MEMORY/; s/@@SBCPU@@/$SANDBOX_CPUS/" "$QCS/bin/sandbox"
}
