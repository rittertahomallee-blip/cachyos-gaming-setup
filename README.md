# CachyOS Gaming Setup

> Repeatable, opinionated setup script for a fresh **CachyOS KDE (BTRFS)** installation. It performs a full update, configures selected drivers and applications, and records manifests, backups and logs so the result can be reviewed and recreated later.
>
> Package repositories, Flathub and the AUR are live sources, so this is not a bit-for-bit immutable build.

![Overview](skript-uebersicht.png)

**Who is it for?** Fresh CachyOS install. Not intended for existing systems with important data without a backup.

---

## Table of Contents

- [What it does](#what-it-does)
- [Automatic Hardware Detection](#automatic-hardware-detection)
- [Requirements](#requirements)
- [Installation & Usage](#installation--usage)
- [What gets installed / removed](#what-gets-installed--removed)
- [Helper commands after installation](#helper-commands-after-installation)
- [Verification](#verification)
- [Notes for GitHub & Legal](#notes-for-github--legal)
- [Troubleshooting](#troubleshooting)
- [Uninstall / Rollback](#uninstall--rollback)
- [Contributing](#contributing)
- [License & Disclaimer](#license--disclaimer)

---

## What it does

The script uses numbered phases and logs every phase to `~/cachyos-logs/`:

1. **System check and confirmation** – Checks Secure Boot, boot space, connectivity and keyrings, then shows a change summary. It refuses to run as `root` and requires confirmation unless `--yes` is supplied.
2. **System update** – Uses a full `pacman -Syu` transaction and aborts on a failed required update.
3. **Kernel and cleanup** – Installs the standard and Bore CachyOS kernels. Existing kernels, Snapper, desktop applications, fonts and services are **kept by default**; each removal needs an explicit option.
4. **Base and helpers** – Enables `multilib`, configures Flathub and installs the documented local helper commands.
5. **Applications** – Installs the selected desktop and gaming applications. AUR-only packages remain optional and use Flatpak fallbacks where available.
6. **Performance profile** – Configures ZRAM, hardware-aware drivers and the balanced or extreme profile. The default is `balanced`; `mitigations=off` requires two explicit flags.
7. **Safe maintenance** – Always records possible orphans, `.pacnew` files, BTRFS state and cache sizes. Cache deletion, Flatpak data cleanup, journal trimming, package-cache cleanup and BTRFS balancing require `--run-maintenance`.
8. **Verification and bootloader** – Checks only applicable hardware/profile-dependent components and generates `~/system-check.sh` for after the reboot.
9. **Final inventory** – Writes Pacman, AUR/foreign and Flatpak manifests plus a run metadata file for later rebuilds and troubleshooting.

**Not included in the public version:** Vencord / Vesktop / MessageLogger. To comply with Discord's Terms of Service, all third-party client modifications have been removed. Additionally, Proton Mail/VPN components were replaced by the universal Thunderbird client to suit everyone's needs. If you want Discord or Proton specific apps, install them natively via Flatpak:
`flatpak install flathub com.discordapp.Discord`
`flatpak install flathub me.proton.Mail`

---

## Automatic Hardware Detection

The script detects hardware at runtime and installs **only** matching drivers (no unnecessary packages):

| Hardware | Detection | What gets installed |
|---|---|---|
| **CPU** | `lscpu` | `intel-ucode` on Intel, `amd-ucode` on AMD |
| **GPU** | `lspci` + `GPU_VENDOR` | **NVIDIA:** `nvidia`/`nvidia-utils`/`nvidia-open-dkms` fallback + Vulkan **· AMD:** `xf86-video-amdgpu` + `vulkan-radeon` **· Intel:** `xf86-video-intel` + `vulkan-intel` **· Unknown:** only `mesa` |
| **Printer** | `lsusb` + `lpstat` + `/dev/usb/lp*` | Only if printer detected: `cups`/`cups-pdf`/`cups-filters`/`gutenprint`/`foomatic`/`ghostscript`, vendor specific `hplip` (HP), `epson-inkjet-printer-escpr` (Epson), `brlaser` (Brother), then `cups.socket` + `avahi-daemon` |
| **Scanner** | `sane-find-scanner` + `lsusb` | `sane` + `simple-scan` only if scanner detected |
| **Bluetooth** | `lsusb`/`lspci`/`rfkill`/`dmesg` | `bluez`/`bluez-utils`/`blueman` + service only if hardware present |
| **WLAN** | `lspci`/`lsusb` | `linux-firmware` + chip specific extras |
| **Sound / Headphones** | always / `lsusb` + `bluetooth` | `sof-firmware` + `alsa-firmware` + `pipewire`/`bluez` – wired and Bluetooth headphones work automatically |
| **Fingerprint** | `lsusb` | `fprintd` only if reader present |
| **Other peripherals** | `lsusb`/`lspci` | Printer, Scanner, BT, WLAN, Webcam, Headphones and more – drivers installed automatically only if hardware is present |

A wide range of peripherals – e.g. printer or headphones – gets its driver automatically if the hardware is detected.

---

## Requirements

- Fresh **CachyOS** with KDE Plasma, BTRFS on `/`, boot partition ideally 2 GB (`/boot` with at least 500 MB free)
- Internet connection
- `sudo` rights (run the script as the normal desktop user; **do not** prefix the whole command with `sudo`)
- Secure Boot **off** in BIOS (otherwise `Invalid signature`)
- Backup if you already have data

Tested on: AMD Ryzen 5 5600X + NVIDIA RTX 3060 Ti, 32 GB, Limine. Also works on Intel/AMD GPUs via detection.

---

## Installation & Usage

```bash
# 1. Download
git clone https://github.com/rittertahomallee-blip/cachyos-gaming-setup.git
cd cachyos-gaming-setup

# 2. Make executable (already +x, just to be safe)
chmod +x cachyos-gaming-setup.sh

# 3. Review the change summary and run the safe default profile
./cachyos-gaming-setup.sh --profile balanced
```

The script asks once for `sudo` and asks for a typed `yes` before it changes the system. For an unattended run, review the options first and pass `--yes` explicitly.

```bash
# Example: explicitly opt in to the legacy, more invasive setup choices
./cachyos-gaming-setup.sh --profile extreme --enable-mitigations-off \
  --remove-snapper --remove-preinstalled-apps --remove-other-kernels \
  --disable-unused-services --enable-firewall --force-brave-extensions \
  --run-maintenance --yes
```

It writes logs and review artifacts to `~/cachyos-logs/`:

- `install_YYYYMMDD_HHMMSS.log` – complete terminal output
- `errors_YYYYMMDD_HHMMSS.log` – unhandled command errors
- `changed-files_*.txt` and `backups_*` – overwritten configuration files and their pre-change copies
- `pacman-explicit_*.txt`, `pacman-foreign_*.txt`, `flatpak_*.txt`, `run_*.txt` – resolved package manifests and run metadata
- maintenance reports for orphaned packages, BTRFS mount state, Flatpak cache size, `.pacnew`/`.pacsave` files and broken symlinks

First run takes about 15–30 minutes depending on internet and packages.

After finish:

```bash
sudo reboot
# choose Bore kernel in boot menu, then
~/system-check.sh
# open Spotify once, log in, close it, then
configure-spicetify
```

---

## What gets installed / removed

**Kept by default:** existing kernels, Snapper/BTRFS rollback tooling, Firefox, preinstalled desktop apps, fonts and services.

**Removal is explicit:** `--remove-snapper` first creates a Snapper `pre` snapshot and only then removes Snapper-related packages with normal dependency checks. `--remove-preinstalled-apps` removes the selected app replacements and Firefox. `--remove-other-kernels` keeps the running kernel and the two CachyOS kernels. `--disable-unused-services` and `--enable-firewall` are separate opt-ins.

**Maintenance is explicit:** The installer records maintenance reports by default. Pass `--run-maintenance` only when you want it to clear browser/thumbnail caches and Trash, prune unused Flatpak data, trim journals, limit the Pacman cache, remove old compressed log archives and optionally balance a sufficiently used BTRFS filesystem.

**Installed (selection):** Brave, Alacritty, Konsole, Fish, Starship, Mission Center, Flameshot, Gimp, VLC, LibreOffice, CopyQ, Spotify, Spicetify, Steam, Heroic, PrismLauncher, Sober (Roblox), optional BedrockOnLinux (AUR), Waydroid, QEMU, Bottles, Lutris, Bauh, Variety and Kvantum. AUR packages can fail independently or fall back to Flatpak; inspect the manifest and verification output.

**Not touched:** System languages (`de`+`en` stay package-managed), man pages, firmware is not deleted.

---

## Helper commands after installation

Located in `~/.local/bin` and immediately in `PATH`:

- `update-arch` – focused `pacman -Syu` + Flatpak + AUR updates and initramfs rebuild; it does **not** reconfigure drivers, repair Flatpak or modify firewall policy
- `clean-arch` – shows orphans, cleans `paccache -rk2`, `journal --vacuum`, never runs `bleachbit` automatically
- `fix-key` – repair keyring
- `update-mirrors` – `cachyos-rate-mirrors` / `reflector`
- `configure-spicetify` – sets up Spicetify for Spotify Flatpak (minimal `filesystem` override, no ad-blocking included – theming only; ad-blocking would violate Spotify ToS)
- `clean-flatpak-caches --yes` – clears only `~/.var/app/*/cache`
- `clean-wine-temp --yes /path/to/prefix` – clears only `.../AppData/Local/Temp` of a *given* prefix
- `clean-shader-cache --yes` – clears Mesa/NVIDIA/DXVK shader caches

---

## Verification

During run: `PASS`/`FAIL` in verify block.

After reboot:

```bash
~/system-check.sh
# expected: Bore kernel active, standard+Bore installed, matching GPU driver,
# CPU mitigations active by default, ZRAM active, fstrim.timer on
```

The integrated verify block runs directly; after reboot use `~/system-check.sh` to validate (watchdog without `nowatchdog` is intentional).

---

## Notes for GitHub & Legal

To avoid problems on GitHub:

- **License:** MIT (see below). Allows fork, use, even commercial, as long as license is included. No copyleft.
- **No Discord ToS violation:** This public version contains **no** Vencord, Vesktop or MessageLogger. Private version stays local.
- **No proprietary redistribution:** The script only downloads packages from official Arch/CachyOS/Flathub/AUR sources. It bundles no binaries.
- **Trademarks:** CachyOS, Brave, Steam, NVIDIA, AMD, Intel are trademarks of their owners. Project is not affiliated.
- **Pinned third-party bootstrap:** Fisher is downloaded from a fixed upstream commit over HTTPS. Third-party Fish plugins are no longer installed or executed automatically.
- **Transparency:** Logs, configuration backups, a changed-file list and resolved package manifests are written per run. No `pacman -Rdd` or blind `--overwrite '*'` is used. Orphans and `.pacnew` are only logged.
- **Privacy:** Script only reads local hardware via `lspci`/`lsusb`/`lscpu`. It sends nothing outward except normal repository, Flatpak, AUR and the pinned Fisher download. No system report is uploaded.

If you make the repo public, do not add `info/cachyos_ALLES_bericht.txt` with serial numbers. Use `inxi -Fz --filter` for bug reports.

---

## Troubleshooting

- **Build fails (`pacman -Syu` error):** `cat ~/cachyos-logs/errors_*.log`, then try `fix-key` and `update-mirrors`. No `--overwrite '*'` in script because it hides conflicts.
- **Bore kernel missing after reboot:** `pacman -Q linux-cachyos-bore`, check log, if needed `sudo pacman -S linux-cachyos-bore linux-cachyos-bore-headers && sudo mkinitcpio -P`
- **Printer not detected:** `lsusb`, then manually `sudo pacman -S cups system-config-printer && sudo systemctl enable --now cups.socket`
- **Spotify Spicetify:** Start Spotify once, log in, close, then `configure-spicetify` (no ad-blocking). Run again after update.
- **Secure Boot error:** Disable Secure Boot in BIOS, then check `sbctl status`.

---

## Uninstall / Rollback

Before overwriting tracked configuration files, the script copies their prior version to the root-readable `~/cachyos-logs/backups_<run-id>/` directory and records it in `changed-files_<run-id>.txt`. `--remove-snapper` creates a Snapper pre-snapshot before it removes anything.

There is no automatic package rollback. The generated manifests let you inspect or reinstall packages; removed packages can be reinstalled with `sudo pacman -S <package>`.

---

## Contributing

Pull requests welcome. Please:

1. `bash -n cachyos-gaming-setup.sh` must pass
2. Do not suppress errors from required package, bootloader or configuration changes
3. Keep hardware detection, no fixed drivers without `lspci` check
4. Preserve the explicit opt-ins for destructive and security-sensitive actions
5. No Vencord/MessageLogger in public version

---

## License & Disclaimer

**MIT License**

Copyright (c) 2026 CachyOS Gaming Setup Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

**Disclaimer:** Use at your own risk. Always create a backup. Authors are not liable for data loss or system damage. Script modifies system files (`/etc/pacman.conf`, `/etc/default/limine` etc.). Understand what it does before running.
