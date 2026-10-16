# WiVRn installer for CachyOS / Arch

Scripts that automate the CachyOS parts of [chaosmaou/wivrn-guide](https://github.com/chaosmaou/wivrn-guide) for wireless PCVR on standalone headsets (Quest 2/3/3S/Pro, Pico Neo 4, Vive Focus 3, Vive XR Elite) using [WiVRn](https://github.com/WiVRn/WiVRn).

> Not affiliated with the guide or with WiVRn. Read the guide first, especially its requirements section (wired gigabit to your router, WiFi 5/6 or newer, kernel 6.15+).

## Quick start

One command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/wivrn-cachyos-install.sh) --configure
```

Anything after the URL is passed to the installer (for example `--wayvr` or `--dry-run`). Use `bash <(...)` rather than `curl ... | bash`, because a pipe breaks the confirmation prompts and the AUR PKGBUILD review.

Prefer to read the script first? Download it, check it and then run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/<user>/<repo>/main/wivrn-cachyos-install.sh
less wivrn-cachyos-install.sh
bash wivrn-cachyos-install.sh --dry-run     # see what it would do
bash wivrn-cachyos-install.sh --configure   # install and write the WiVRn config
```

Or clone the repo:

```bash
git clone https://github.com/<user>/<repo>.git
cd <repo>
chmod +x wivrn-cachyos-install.sh wivrn-cachyos-uninstall.sh
```

Run it as your normal user, not root. It uses `sudo` when needed.

## What the installer does

- Checks the kernel (6.15+ for ntsync) and detects your GPU vendor (NVIDIA, AMD or Intel)
- Installs `wivrn-dashboard`, `xrizer` and `lact` via paru, plus `pavucontrol`, `avahi` and diagnostic tools
- Enables `lactd` and `avahi-daemon`, and loads and persists the `ntsync` module
- Opens the WiVRn ports (9757 tcp/udp and mDNS) in firewalld or ufw, for private LAN ranges only
- With `--configure`, writes encoder, codec and the xrizer path to `~/.config/wivrn/config.json` (existing config is backed up)
- Prints the Steam launch options for your install and runs a diagnostics check

### Options

| Option | Effect |
| --- | --- |
| `--configure` | Write `~/.config/wivrn/config.json` |
| `--encoder nvenc\|vaapi\|vulkan` | Override the encoder (default: nvenc on NVIDIA, vaapi on AMD/Intel) |
| `--codec h265\|h264\|av1` | Codec (default `h265`; try `av1` on Quest 3/3S with AMD 9000+ or RTX 40+) |
| `--wayvr` | Also install WayVR and fcitx5 |
| `--proton` | Also install `proton-cachyos-slr` |
| `--no-lact` | Skip LACT (the VR power profile only matters on AMD) |
| `--no-firewall` | Don't touch firewalld/ufw |
| `--fw-any` | Open ports to any source instead of private LAN ranges |
| `--check` | Run diagnostics only, change nothing |
| `--dry-run` | Print what would be done |
| `-y`, `--yes` | Skip the script's own confirmations |

## Not automated

- The LACT profile (VR power profile, auto-switch rule on `wivrn-server`)
- Installing the WiVRn app on the headset and entering the pairing PIN
- Selecting WiVRn as the audio input and output device
- Adding the Steam launch options to your games (the installer prints them)

## Security note

AUR packages are built from user-submitted PKGBUILDs, and malicious ones have been reported. The installer always shows the PKGBUILD review in paru and never skips it, even with `-y`. Read what you are about to build.

## Uninstall

```bash
./wivrn-cachyos-uninstall.sh --dry-run
./wivrn-cachyos-uninstall.sh
```

Removes the installed packages, the ntsync boot config and the firewall rules. It leaves Steam, avahi, pavucontrol and your WiVRn config in place unless you pass `--remove-config` or `--disable-avahi`.

## Disclaimer

Provided as is, without warranty. It was syntax-checked and linted but has had limited testing across hardware. Run `--dry-run` first and keep a backup of anything you care about.

---

*Note: this project is vibe coded. The scripts were written with AI assistance, not hand-audited line by line, so read them before you run them and use `--dry-run` first.*
