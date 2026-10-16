#!/usr/bin/env bash
#
# wivrn-cachyos-install.sh
# Automates the CachyOS / Arch parts of https://github.com/chaosmaou/wivrn-guide
#
#   - checks kernel (>= 6.15 for ntsync), GPU vendor, paru
#   - installs lact, wivrn-dashboard, xrizer (AUR packages are PKGBUILD-reviewed)
#   - enables lactd + avahi, loads/persists the ntsync module
#   - opens the WiVRn ports (9757 tcp/udp + mDNS) for firewalld / ufw, LAN only
#   - optionally writes ~/.config/wivrn/config.json (encoder, codec, xrizer path)
#   - optionally installs WayVR, proton-cachyos-slr
#   - prints the Steam launch options for your install
#
# Usage: ./wivrn-cachyos-install.sh [options]      (see --help)

set -Eeuo pipefail

# ----------------------------------------------------------------- helpers
if [[ -t 1 ]]; then
  C_B=$'\033[1;34m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
  C_B=; C_G=; C_Y=; C_R=; C_0=
fi
log()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

DRY_RUN=0; YES=0; DO_CONFIG=0; DO_WAYVR=0; DO_PROTON=0
NO_FIREWALL=0; NO_LACT=0; FW_ANY=0; CHECK_ONLY=0
ENCODER=""; CODEC="h265"
GPU="unknown"
XRIZER_PATH=""

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
Usage: wivrn-cachyos-install.sh [options]

  --configure        write ~/.config/wivrn/config.json (encoder, codec, xrizer path); backs up first
  --encoder ENC      nvenc | vaapi | vulkan   (default: nvenc on NVIDIA, vaapi on AMD/Intel)
  --codec CODEC      h265 | h264 | av1        (default: h265; try av1 on Quest 3/3S with AMD 9000+ / RTX 40+)
  --wayvr            also install WayVR (desktop overlay) + fcitx5 for its virtual keyboard
  --proton           also install proton-cachyos-slr
  --no-lact          skip LACT (use this on NVIDIA if you don't want it)
  --no-firewall      don't touch firewalld/ufw
  --fw-any           open WiVRn ports to any source instead of private LAN ranges only
  --check            only run the diagnostics, change nothing
  --dry-run          print what would be done
  -y, --yes          don't ask for confirmation (AUR PKGBUILD review is NEVER skipped)
  -h, --help
EOF
}

while (($#)); do
  case "$1" in
    --configure) DO_CONFIG=1 ;;
    --encoder)   ENCODER="${2:?--encoder needs a value}"; shift ;;
    --codec)     CODEC="${2:?--codec needs a value}"; shift ;;
    --wayvr)     DO_WAYVR=1 ;;
    --proton)    DO_PROTON=1 ;;
    --no-lact)   NO_LACT=1 ;;
    --no-firewall) NO_FIREWALL=1 ;;
    --fw-any)    FW_ANY=1 ;;
    --check)     CHECK_ONLY=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -y|--yes)    YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
  shift
done

case "$ENCODER" in ""|nvenc|vaapi|vulkan) ;; *) die "Invalid --encoder: $ENCODER" ;; esac
case "$CODEC" in h265|h264|av1) ;; *) die "Invalid --codec: $CODEC" ;; esac

# ----------------------------------------------------------------- checks
kernel_ok() {
  local cur
  cur=$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
  [[ "$(printf '%s\n6.15\n' "$cur" | sort -V | head -n1)" == "6.15" ]]
}

detect_gpu() {
  local info
  info=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)
  if   grep -qi nvidia <<<"$info";             then GPU=nvidia
  elif grep -Eqi 'amd|ati|radeon' <<<"$info";  then GPU=amd
  elif grep -qi intel <<<"$info";              then GPU=intel
  else GPU=unknown; fi
}

preflight() {
  ((EUID != 0)) || die "Run as your normal user, not root (paru refuses to build as root; the script uses sudo where needed)."
  [[ -r /etc/os-release ]] || die "Can't read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "arch" || "${ID:-}" == "cachyos" || "${ID_LIKE:-}" == *arch* ]] \
    || die "This script is for Arch-based systems (CachyOS). Detected: ${PRETTY_NAME:-unknown}"
  command -v sudo >/dev/null || die "sudo is required"
  command -v pacman >/dev/null || die "pacman not found"

  if kernel_ok; then ok "Kernel $(uname -r) is >= 6.15 (ntsync OK)"
  else warn "Kernel $(uname -r) is older than 6.15. ntsync needs 6.15+; update your kernel (e.g. linux-cachyos) first."; fi

  detect_gpu
  log "Detected GPU vendor: $GPU"
  if [[ -z "$ENCODER" ]]; then
    case "$GPU" in
      nvidia) ENCODER=nvenc ;;
      amd|intel) ENCODER=vaapi ;;
      *) ENCODER="" ;;
    esac
  fi
  [[ "$GPU" == nvidia ]] && ((NO_LACT == 0)) && log "NVIDIA detected: LACT's VR power profile only matters on AMD (use --no-lact to skip it)."

  if ((CHECK_ONLY == 0)); then
    ((DRY_RUN)) || sudo -v
  fi
}

# ----------------------------------------------------------------- packages
ensure_paru() {
  command -v paru >/dev/null && return
  log "paru not found, installing from the CachyOS repo"
  run sudo pacman -S --needed --noconfirm paru
  ((DRY_RUN)) || command -v paru >/dev/null || die "Could not install paru"
}

paru_install() {
  # Always review PKGBUILDs. The guide's author was hit by malware from an AUR package,
  # so this script never passes --skipreview / --noconfirm to paru.
  local review=()
  if paru --help 2>&1 | grep -q -- '--review'; then
    review=(--review)
  elif grep -Esq '^\s*SkipReview' /etc/paru.conf "$HOME/.config/paru/paru.conf" 2>/dev/null; then
    warn "paru.conf has SkipReview enabled and this paru lacks --review. Remove SkipReview or review PKGBUILDs manually!"
  fi
  run paru -S --needed "${review[@]}" "$@"
}

first_available() {
  local p
  for p in "$@"; do
    if paru -Si "$p" >/dev/null 2>&1; then echo "$p"; return 0; fi
  done
  return 1
}

install_packages() {
  ensure_paru

  log "Installing base tooling (pacman)"
  run sudo pacman -S --needed --noconfirm pavucontrol avahi libva-utils vulkan-tools pciutils

  if ! pacman -Qq steam >/dev/null 2>&1; then
    warn "Steam is not installed (the guide requires a working Steam)."
    confirm "Install steam now?" && run sudo pacman -S --needed steam
  fi

  local aur=(wivrn-dashboard xrizer)
  if ((NO_LACT == 0)); then aur+=(lact); fi
  log "Installing: ${aur[*]}  (you will be shown the PKGBUILDs, read them!)"
  paru_install "${aur[@]}"

  if ((DO_PROTON)); then
    log "Installing proton-cachyos-slr"
    run sudo pacman -S --needed proton-cachyos-slr
  fi

  if ((DO_WAYVR)); then
    local pkg
    if pkg=$(first_available wayvr wayvr-bin wlx-overlay-s-git wlx-overlay-s); then
      log "Installing WayVR package: $pkg"
      paru_install "$pkg" fcitx5 fcitx5-qt fcitx5-gtk
    else
      warn "No WayVR package found via paru. Get the release from https://github.com/wlx-team/wayvr/releases"
    fi
  fi
}

# ----------------------------------------------------------------- system setup
setup_services() {
  log "Enabling avahi (mDNS discovery for the headset)"
  run sudo systemctl enable --now avahi-daemon.service

  if ((NO_LACT == 0)); then
    log "Enabling LACT daemon"
    run sudo systemctl enable --now lactd.service
  fi
}

setup_ntsync() {
  if [[ -e /dev/ntsync ]]; then ok "/dev/ntsync already present"; return; fi
  if modinfo ntsync >/dev/null 2>&1; then
    log "Loading ntsync module and enabling it at boot"
    run sudo modprobe ntsync
    if ((DRY_RUN)); then
      echo "    [dry-run] echo ntsync > /etc/modules-load.d/ntsync.conf"
    else
      echo ntsync | sudo tee /etc/modules-load.d/ntsync.conf >/dev/null
    fi
  else
    warn "ntsync module not available for this kernel. Install/boot a kernel >= 6.15 (linux-cachyos)."
  fi
}

setup_firewall() {
  ((NO_FIREWALL)) && { log "Skipping firewall"; return; }
  local nets=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16) net proto

  if systemctl is-active --quiet firewalld; then
    log "Configuring firewalld"
    if ((FW_ANY)); then
      run sudo firewall-cmd --permanent --add-port=9757/tcp --add-port=9757/udp
      run sudo firewall-cmd --permanent --add-service=mdns
    else
      for net in "${nets[@]}"; do
        for proto in tcp udp; do
          run sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$net port port=9757 protocol=$proto accept"
        done
        run sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$net port port=5353 protocol=udp accept"
      done
    fi
    run sudo firewall-cmd --reload
  elif command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "Configuring ufw"
    if ((FW_ANY)); then
      run sudo ufw allow 9757/tcp
      run sudo ufw allow 9757/udp
      run sudo ufw allow 5353/udp
    else
      for net in "${nets[@]}"; do
        run sudo ufw allow from "$net" to any port 9757 proto tcp
        run sudo ufw allow from "$net" to any port 9757 proto udp
        run sudo ufw allow from "$net" to any port 5353 proto udp
      done
    fi
  else
    log "No active firewalld/ufw found, nothing to open"
  fi
}

# ----------------------------------------------------------------- WiVRn config
detect_xrizer() {
  local so
  so=$(pacman -Qlq xrizer 2>/dev/null | grep -E '/bin/linux64/vrclient\.so$' | head -n1 || true)
  if [[ -z "$so" ]]; then
    so=$(find /usr /opt -path '*xrizer*' -name vrclient.so 2>/dev/null | head -n1 || true)
  fi
  [[ -n "$so" ]] && XRIZER_PATH="${so%/bin/linux64/vrclient.so}"
  if [[ -n "$XRIZER_PATH" ]]; then ok "xrizer found at $XRIZER_PATH"
  else warn "Could not locate xrizer's vrclient.so; set the OpenVR compat path manually in the WiVRn dashboard."; fi
}

write_wivrn_config() {
  ((DO_CONFIG)) || return 0
  command -v python3 >/dev/null || { warn "python3 missing, skipping config"; return 0; }
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/wivrn" cfg
  cfg="$dir/config.json"
  log "Writing $cfg (encoder=${ENCODER:-unchanged}, codec=$CODEC)"
  if ((DRY_RUN)); then echo "    [dry-run] merge encoder/codec/openvr-compat-path into $cfg"; return 0; fi
  mkdir -p "$dir"
  [[ -f "$cfg" ]] && cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)"
  python3 - "$cfg" "$ENCODER" "$CODEC" "$XRIZER_PATH" <<'PY'
import json, sys
path, enc, codec, xr = sys.argv[1:5]
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
if enc:
    cfg["encoders"] = [{"encoder": enc, "codec": codec,
                        "width": 1.0, "height": 1.0, "offset_x": 0.0, "offset_y": 0.0}]
if xr:
    cfg["openvr-compat-path"] = xr
with open(path, "w") as f:
    json.dump(cfg, f, indent=4)
    f.write("\n")
PY
  ok "Config written (a timestamped .bak copy of any previous config was kept)"
}

# ----------------------------------------------------------------- diagnostics
doctor() {
  log "Diagnostics"
  kernel_ok && ok "kernel >= 6.15" || warn "kernel < 6.15"
  [[ -e /dev/ntsync ]] && ok "/dev/ntsync present (verify per game with: lsof /dev/ntsync)" || warn "/dev/ntsync missing"
  command -v wivrn-server >/dev/null && ok "wivrn-server installed" || warn "wivrn-server not found"
  command -v wivrn-dashboard >/dev/null && ok "wivrn-dashboard installed" || warn "wivrn-dashboard not found"
  systemctl is-active --quiet avahi-daemon && ok "avahi-daemon running" || warn "avahi-daemon not running"
  if ((NO_LACT == 0)); then
    systemctl is-active --quiet lactd && ok "lactd running" || warn "lactd not running"
  fi
  if compgen -G '/usr/share/openxr/1/*wivrn*' >/dev/null; then ok "WiVRn OpenXR runtime manifest present"
  else warn "No WiVRn OpenXR manifest in /usr/share/openxr/1/ (the dashboard may set it per-user)"; fi
  if [[ "$ENCODER" == vaapi ]] && command -v vainfo >/dev/null; then
    if vainfo 2>/dev/null | grep -q 'VAEntrypointEncSlice'; then ok "VA-API hardware encode available"
    else warn "vainfo shows no VA-API encode entrypoint; try the vulkan encoder"; fi
  fi
  pacman -Qq steam >/dev/null 2>&1 && ok "Steam installed" || warn "Steam not installed"
}

summary() {
  local rw=""
  [[ -n "$XRIZER_PATH" ]] && rw=" PRESSURE_VESSEL_FILESYSTEMS_RW=$XRIZER_PATH"
  cat <<EOF

${C_G}Done.${C_0} Manual steps that can't be scripted safely:

 1. Steam launch options for VR games (native Steam). Double-check against the
    "launch parameters" shown on the WiVRn dashboard main page:

      PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1${rw} %command%

    Half-Life: Alyx / VTOL VR need the extras from the guide's "Games Tested" section.
    Proton: Valve Proton 11+, GE-Proton, or proton-cachyos all ship ntsync.

 2. Open WiVRn Dashboard, click through the wizard, keep "Running" and "Pairing" on.
    The dashboard must stay open or the server stops.
$( [[ "$ENCODER" == "" ]] && echo "    Pick encoder/codec in Settings (NVIDIA: nvenc, AMD: vaapi/vulkan; Quest 2 -> H265)." )

 3. Headset: install WiVRn from the Quest store, connect, enter the PIN from the dashboard.
    Quest 3/3S: AV1 on AMD 9000+ / RTX 40+, otherwise H265. Cap refresh at 90 Hz.

 4. AMD only, LACT: open LACT, enable overdrive (reboot), create a "WiVRn" profile with
    Performance Level = Manual and Power Profile Mode = VR, then Edit Rules ->
    process "wivrn-server", and tick "Switch automatically".

 5. Audio: while connected, pick WiVRn as default output/input (pavucontrol is installed).
$( ((DO_WAYVR)) && echo " 6. WayVR: in KDE System Settings -> Keyboard -> Virtual Keyboard choose Fcitx 5,
    then select WayVR as the autostart application in the WiVRn dashboard settings." )

Re-run diagnostics any time with: $0 --check
EOF
}

# ----------------------------------------------------------------- main
main() {
  preflight
  if ((CHECK_ONLY)); then doctor; exit 0; fi

  warn "AUR packages are built from user-submitted PKGBUILDs. Read each one when paru shows it."
  confirm "Proceed with installation?" || die "Aborted."

  install_packages
  setup_services
  setup_ntsync
  setup_firewall
  detect_xrizer
  write_wivrn_config
  doctor
  summary
}

main "$@"