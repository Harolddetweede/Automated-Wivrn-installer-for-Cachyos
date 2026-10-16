#!/usr/bin/env bash
#
# wivrn-cachyos-uninstall.sh
# Reverts what wivrn-cachyos-install.sh set up on CachyOS / Arch.
#
# Removes: wivrn-dashboard, xrizer, lact (+ wayvr / proton-cachyos-slr if present),
#          the ntsync boot config, and the firewall rules the installer added.
# Keeps:   steam, pavucontrol, avahi, libva-utils, vulkan-tools, pciutils, your WiVRn
#          config (unless --remove-config) and avahi (unless --disable-avahi).

set -Eeuo pipefail

if [[ -t 1 ]]; then
  C_B=$'\033[1;34m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
  C_B=; C_G=; C_Y=; C_R=; C_0=
fi
log()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

DRY_RUN=0; YES=0; REMOVE_CONFIG=0; DISABLE_AVAHI=0; KEEP_FIREWALL=0; KEEP_PROTON=0

run() {
  if ((DRY_RUN)); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}

confirm() {
  ((YES)) && return 0
  local ans; read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

usage() {
  cat <<'EOF'
Usage: wivrn-cachyos-uninstall.sh [options]

  --remove-config    also delete ~/.config/wivrn (and its backups) and /etc/lact
  --disable-avahi    also stop and disable avahi-daemon (it may be used by other things)
  --keep-proton      don't remove proton-cachyos-slr
  --keep-firewall    don't touch firewalld/ufw rules
  --dry-run          print what would be done
  -y, --yes          don't ask for confirmation
  -h, --help
EOF
}

while (($#)); do
  case "$1" in
    --remove-config) REMOVE_CONFIG=1 ;;
    --disable-avahi) DISABLE_AVAHI=1 ;;
    --keep-proton)   KEEP_PROTON=1 ;;
    --keep-firewall) KEEP_FIREWALL=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    -y|--yes)        YES=1 ;;
    -h|--help)       usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
  shift
done

((EUID != 0)) || die "Run as your normal user, not root (the script uses sudo where needed)."
command -v sudo >/dev/null || die "sudo is required"
command -v pacman >/dev/null || die "pacman not found"

# ----------------------------------------------------------------- packages
remove_packages() {
  local candidates=(wivrn-dashboard wivrn-server xrizer lact wayvr wayvr-bin wlx-overlay-s wlx-overlay-s-git)
  ((KEEP_PROTON)) || candidates+=(proton-cachyos-slr)

  local installed=() p
  for p in "${candidates[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 && installed+=("$p")
  done

  if ((${#installed[@]} == 0)); then
    log "None of the installer's packages are installed"
    return
  fi

  log "Packages to remove: ${installed[*]}"
  # Stop services first so nothing holds the files.
  if pacman -Qq lact >/dev/null 2>&1; then
    run sudo systemctl disable --now lactd.service || true
  fi
  # -Rns also removes dependencies that nothing else needs; pacman shows the full list and asks.
  run sudo pacman -Rns "${installed[@]}"
}

# ----------------------------------------------------------------- system config
remove_ntsync_conf() {
  local f=/etc/modules-load.d/ntsync.conf
  [[ -f "$f" ]] || return 0
  if [[ "$(tr -d '[:space:]' < "$f")" == "ntsync" ]]; then
    log "Removing $f (the module stays loaded until reboot; Proton keeps working with it)"
    run sudo rm -f "$f"
  else
    warn "$f has custom content, leaving it alone"
  fi
}

remove_firewall() {
  ((KEEP_FIREWALL)) && { log "Keeping firewall rules"; return; }
  local nets=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16) net proto

  if systemctl is-active --quiet firewalld; then
    log "Removing WiVRn rules from firewalld"
    for net in "${nets[@]}"; do
      for proto in tcp udp; do
        run sudo firewall-cmd --permanent --remove-rich-rule="rule family=ipv4 source address=$net port port=9757 protocol=$proto accept" || true
      done
      run sudo firewall-cmd --permanent --remove-rich-rule="rule family=ipv4 source address=$net port port=5353 protocol=udp accept" || true
    done
    # Rules from the installer's --fw-any mode.
    run sudo firewall-cmd --permanent --remove-port=9757/tcp || true
    run sudo firewall-cmd --permanent --remove-port=9757/udp || true
    run sudo firewall-cmd --permanent --remove-service=mdns || true
    run sudo firewall-cmd --reload
  elif command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "Removing WiVRn rules from ufw"
    for net in "${nets[@]}"; do
      run sudo ufw delete allow from "$net" to any port 9757 proto tcp || true
      run sudo ufw delete allow from "$net" to any port 9757 proto udp || true
      run sudo ufw delete allow from "$net" to any port 5353 proto udp || true
    done
    # Rules from the installer's --fw-any mode.
    run sudo ufw delete allow 9757/tcp || true
    run sudo ufw delete allow 9757/udp || true
    run sudo ufw delete allow 5353/udp || true
  else
    log "No active firewalld/ufw found, nothing to remove"
  fi
}

disable_avahi() {
  ((DISABLE_AVAHI)) || return 0
  log "Disabling avahi-daemon"
  run sudo systemctl disable --now avahi-daemon.service || true
}

remove_config() {
  ((REMOVE_CONFIG)) || return 0
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/wivrn"
  if [[ -d "$dir" ]]; then
    log "Removing $dir"
    run rm -rf -- "$dir"
  fi
  if [[ -d /etc/lact ]]; then
    log "Removing /etc/lact"
    run sudo rm -rf -- /etc/lact
  fi
}

# ----------------------------------------------------------------- main
main() {
  warn "This will remove WiVRn, xrizer, LACT and related config added by the installer."
  confirm "Proceed?" || die "Aborted."
  ((DRY_RUN)) || sudo -v

  remove_packages
  remove_ntsync_conf
  remove_firewall
  disable_avahi
  remove_config

  ok "Done."
  cat <<EOF

Left in place on purpose:
  - steam, pavucontrol, avahi, libva-utils, vulkan-tools, pciutils (remove with pacman -Rns if you want)
  - Steam launch options you added to games (remove them in each game's Properties)
  - Your WiVRn config in ~/.config/wivrn (use --remove-config to delete it)
  - The AMD overdrive/ppfeaturemask setting LACT may have added to your bootloader config
EOF
}

main "$@"