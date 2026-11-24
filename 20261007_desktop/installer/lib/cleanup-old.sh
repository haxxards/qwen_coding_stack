# Pop!_OS: remove what the earlier manual guide created outside the project.

cleanup_old() {
  log "Removing files from the earlier manual setup"
  rm -f "$HOME/Development/qwen/qwen-server" "$HOME/bin/sandbox"
  rmdir "$HOME/Development/qwen" "$HOME/bin" 2>/dev/null || true
  rm -rf "$HOME/llm-sandbox" "$HOME/.venvs/hf"
  rmdir "$HOME/.venvs" "$HOME/models" 2>/dev/null || true
  docker volume rm opencode-data >/dev/null 2>&1 || true
  docker image rm llm-sandbox:latest >/dev/null 2>&1 || true
  if [ -d "$HOME/Development/llama.cpp" ]; then
    info "Left in place: $HOME/Development/llama.cpp (remove with: rm -rf $HOME/Development/llama.cpp)"
  fi
  info "Done."
}
