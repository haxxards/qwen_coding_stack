# Phase 1: system-level setup (needs sudo; may need a reboot afterwards).

phase1() {
  local here=$1
  log "Phase 1: system packages, NVIDIA driver, CUDA toolkit, Docker"
  install_self "$here"
  [ "$PROFILE" = debian-laptop ] && enable_debian_components
  apt_install build-essential cmake git curl wget pciutils iproute2 \
    libcurl4-openssl-dev python3 python3-venv ca-certificates
  case "$PROFILE" in
    popos-desktop) pop_driver_and_cuda ;;
    debian-laptop) debian_driver_and_cuda; apt_install power-profiles-daemon ;;
  esac
  docker_setup
}

install_self() {
  local here=$1
  mkdir -p "$QCS/installer"
  if [ "$(readlink -f "$here")" != "$(readlink -f "$QCS/installer")" ]; then
    cp -a "$here"/. "$QCS/installer/"
    info "Copied installer to $QCS/installer (run it from there from now on)."
  fi
}

enable_debian_components() {
  log "Enabling contrib / non-free / non-free-firmware"
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sudo perl -i -pe 'if (/^Components:/) { for my $c (qw(contrib non-free non-free-firmware)) { s/$/ $c/ unless /\s\Q$c\E(\s|$)/ } }' \
      /etc/apt/sources.list.d/debian.sources
  fi
  if [ -f /etc/apt/sources.list ]; then
    sudo perl -i -pe 'if (/^deb(-src)?\s/ && /\smain(\s|$)/) { for my $c (qw(contrib non-free non-free-firmware)) { s/$/ $c/ unless /\s\Q$c\E(\s|$)/ } }' \
      /etc/apt/sources.list
  fi
}

add_cuda_keyring() {
  local repo=$1
  if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
    wget -qO "$QCS/cache/cuda-keyring.deb" \
      "https://developer.download.nvidia.com/compute/cuda/repos/${repo}/x86_64/cuda-keyring_1.1-1_all.deb"
    sudo dpkg -i "$QCS/cache/cuda-keyring.deb"
    APT_UPDATED=   # fetch the new repo's package list before the next install
  fi
}

pop_driver_and_cuda() {
  log "NVIDIA driver (System76 package) and CUDA toolkit"
  apt_install system76-driver-nvidia
  add_cuda_keyring ubuntu2404
  sudo tee /etc/apt/preferences.d/nvidia-cuda-toolkit-only >/dev/null <<'PIN'
# Only use NVIDIA's repo for packages nothing else provides (the CUDA toolkit).
# Pop!_OS keeps control of the driver.
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 100
PIN
  resolve_cuda_ver
  ensure_toolkit
}

debian_driver_and_cuda() {
  log "NVIDIA open driver and CUDA toolkit (NVIDIA repo)"
  add_cuda_keyring "debian${VERSION_ID}"
  apt_install nvidia-open
  resolve_cuda_ver
  ensure_toolkit
  secure_boot_key
}

# Debian + Secure Boot: the DKMS-built module is signed with a local key that
# must be enrolled once (you'll set a one-time password, then confirm it at the
# blue "MOK management" screen on the next boot).
secure_boot_key() {
  command -v mokutil >/dev/null || apt_install mokutil
  mokutil --sb-state 2>/dev/null | grep -q enabled || return 0
  local key=/var/lib/dkms/mok.pub
  [ -f "$key" ] || { warn "Secure Boot is on but $key wasn't found; see the guide's troubleshooting."; return 0; }
  if mokutil --test-key "$key" 2>&1 | grep -q "already enrolled"; then
    info "Secure Boot key already enrolled."
  elif mokutil --list-new 2>/dev/null | grep -q .; then
    info "Secure Boot key enrollment already pending; complete it at the next boot."
  else
    log "Secure Boot: enroll the driver signing key (choose a one-time password)"
    sudo mokutil --import "$key"
    touch "$QCS/cache/.mok-pending"
  fi
}

docker_setup() {
  log "Docker"
  apt_install docker.io
  systemctl is-enabled --quiet docker && systemctl is-active --quiet docker || sudo systemctl enable --now docker
  if ! getent group docker | grep -qw "$USER"; then
    sudo usermod -aG docker "$USER"
    info "Added $USER to the docker group (takes effect after reboot/re-login)."
  fi
}

reboot_needed() {
  REBOOT_REASONS=()
  nvidia-smi >/dev/null 2>&1 || REBOOT_REASONS+=("the NVIDIA driver isn't loaded yet")
  if [ "$PROFILE" = popos-desktop ] && nvidia-smi >/dev/null 2>&1 \
     && ! grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
    REBOOT_REASONS+=("the open kernel module isn't loaded yet")
  fi
  id -nG | grep -qw docker || REBOOT_REASONS+=("the docker group isn't active in this session")
  [ -f /var/run/reboot-required ] && REBOOT_REASONS+=("the system reports a reboot is required")
  [ -f "$QCS/cache/.mok-pending" ] && REBOOT_REASONS+=("Secure Boot key enrollment is pending") && rm -f "$QCS/cache/.mok-pending"
  [ "${#REBOOT_REASONS[@]}" -gt 0 ]
}

offer_reboot() {
  log "Phase 1 complete. A reboot is needed because:"
  for r in "${REBOOT_REASONS[@]}"; do info "- $r"; done
  info ""
  info "After rebooting, continue with:"
  info "  $QCS/installer/install.sh"
  if [ "$PROFILE" = debian-laptop ] && mokutil --list-new 2>/dev/null | grep -q .; then
    info ""
    info "At boot you'll see a blue MOK screen: Enroll MOK -> Continue -> Yes -> enter the password you chose."
  fi
  if [ "${AUTO_REBOOT:-no}" = yes ]; then
    info ""; info "Rebooting in 15 seconds (Ctrl+C to cancel)..."
    sleep 15; sudo systemctl reboot
  else
    read -r -p "Reboot now? [y/N] " ans </dev/tty || true
    case "$ans" in [yY]*) sudo systemctl reboot ;; *) info "OK — reboot when ready, then re-run the installer." ;; esac
  fi
}
