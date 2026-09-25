#!/usr/bin/env bash
# ==============================================================================
# CachyOS Gaming Setup
# Inspiriert von: Arch Wiki, CachyOS, pacman-contrib + bewährten Desktop-Setups
# Target: CachyOS KDE on BTRFS | fresh installation
# What it does: reproducible gaming setup, curated app selection, safe maintenance
# ==============================================================================
set -Euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# This script deliberately runs as the desktop user. Individual privileged commands
# use sudo so user configuration, AUR builds and group membership target that user.
if (( EUID == 0 )); then
  printf '%s\n' 'Do not run this script with sudo. Run ./cachyos-gaming-setup.sh as your desktop user; it asks for sudo when needed.' >&2
  exit 2
fi

PROFILE="balanced"
AUTO_CONFIRM=false
REMOVE_SNAPPER=false
REMOVE_PREINSTALLED_APPS=false
REMOVE_OTHER_KERNELS=false
DISABLE_UNUSED_SERVICES=false
ENABLE_FIREWALL=false
FORCE_BRAVE_EXTENSIONS=false
RUN_MAINTENANCE=false
ENABLE_MITIGATIONS_OFF=false
BOOTLOADER="not-configured"
BOOTLOADER_CONFIG=""

usage() {
  cat <<'EOF'
Usage: ./cachyos-gaming-setup.sh [options]

Profiles:
  --profile balanced              Default. Keeps CPU security mitigations enabled.
  --profile extreme               Enables the high-performance tuning set, but still
                                  keeps mitigations enabled unless explicitly opted in.

Explicit opt-ins for destructive or security-sensitive actions:
  --enable-mitigations-off        Add mitigations=off (requires --profile extreme).
  --remove-snapper                Create a Snapper pre-snapshot, then remove Snapper.
  --remove-preinstalled-apps      Remove the listed replacement apps and Firefox.
  --remove-other-kernels          Remove non-CachyOS kernels except the running one.
  --disable-unused-services       Disable Baloo, Tracker, ModemManager and lvm2-monitor.
  --enable-firewall               Configure and enable UFW LAN rules (never over SSH).
  --force-brave-extensions        Apply the curated Brave extension force-install policy.
  --run-maintenance               Run cache, journal and package-cache cleanup in phase 6.

Other:
  --yes                           Accept the change summary without an interactive prompt.
  -h, --help                      Show this help and exit.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { printf '%s\n' '--profile needs balanced or extreme.' >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --enable-mitigations-off) ENABLE_MITIGATIONS_OFF=true; shift ;;
    --remove-snapper) REMOVE_SNAPPER=true; shift ;;
    --remove-preinstalled-apps) REMOVE_PREINSTALLED_APPS=true; shift ;;
    --remove-other-kernels) REMOVE_OTHER_KERNELS=true; shift ;;
    --disable-unused-services) DISABLE_UNUSED_SERVICES=true; shift ;;
    --enable-firewall) ENABLE_FIREWALL=true; shift ;;
    --force-brave-extensions) FORCE_BRAVE_EXTENSIONS=true; shift ;;
    --run-maintenance) RUN_MAINTENANCE=true; shift ;;
    --yes) AUTO_CONFIRM=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PROFILE" in
  balanced|extreme) ;;
  *) printf 'Unknown profile: %s (use balanced or extreme).\n' "$PROFILE" >&2; exit 2 ;;
esac
if [[ "$ENABLE_MITIGATIONS_OFF" == "true" && "$PROFILE" != "extreme" ]]; then
  printf '%s\n' '--enable-mitigations-off requires --profile extreme.' >&2
  exit 2
fi

# One run = one full log plus a separate error log.
LOG_DIR="$HOME/cachyos-logs"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/install_${RUN_ID}.log"
ERROR_LOG="$LOG_DIR/errors_${RUN_ID}.log"
CHANGED_FILES="$LOG_DIR/changed-files_${RUN_ID}.txt"
BACKUP_DIR="$LOG_DIR/backups_${RUN_ID}"
LOG="$LOG_FILE"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE" "$ERROR_LOG" "$CHANGED_FILES"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" "$ERROR_LOG" >&2)

log_time(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ echo -e "${GREEN}[✓ $(log_time)]${NC} $1"; }
info(){ echo -e "${CYAN}[→ $(log_time)]${NC} $1"; }
warn(){ echo -e "${YELLOW}[! $(log_time)]${NC} $1"; }
fail(){ echo -e "${RED}[✖ $(log_time)]${NC} $1"; }
# Optional bundles are retried package-by-package if one package is unavailable.
# This avoids losing an entire desktop feature because a single optional package
# was renamed or missing from a repository.
install_pacman_optional() {
  local feature="$1" package failed=0
  shift
  if sudo pacman -S --needed --noconfirm "$@"; then
    log "$feature installed"
    return 0
  fi
  warn "$feature bundle failed; retrying its packages individually."
  for package in "$@"; do
    if ! sudo pacman -S --needed --noconfirm "$package"; then
      warn "$feature: could not install optional package $package"
      failed=1
    fi
  done
  return "$failed"
}
step(){ echo -e "\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${MAGENTA}  $1${NC}\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Preserve each changed configuration once. Backups are root-readable only because
# some files below can contain system-specific configuration.
declare -A BACKED_UP=()
backup_file() {
  local source="$1" destination
  [[ -e "$source" || -L "$source" ]] || return 0
  [[ -n "${BACKED_UP[$source]:-}" ]] && return 0
  destination="$BACKUP_DIR${source}"
  if ! sudo install -d -m 700 -- "$(dirname "$destination")" || ! sudo cp -a -- "$source" "$destination"; then
    fail "Could not back up $source; refusing to overwrite it."
    exit 1
  fi
  BACKED_UP[$source]=1
  printf '%s -> %s\n' "$source" "$destination" | sudo tee -a "$CHANGED_FILES" >/dev/null
  log "Backup created: $source"
}

ERROR_COUNT=0
on_error(){
  local status="$1" line="$2" command="$3" quoted_command
  ERROR_COUNT=$((ERROR_COUNT + 1))
  printf -v quoted_command '%q' "$command"
  printf '[ERROR %s] line %s: command %s failed (status %s)\n' "$(log_time)" "$line" "$quoted_command" "$status" >> "$ERROR_LOG"
  warn "Line $line failed (status $status) – details: $ERROR_LOG"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

confirm_plan() {
  step "CHANGE SUMMARY"
  info "Profile: $PROFILE (mitigations remain enabled by default)"
  [[ "$ENABLE_MITIGATIONS_OFF" == "true" ]] && warn "EXTREME: mitigations=off will be added to the detected bootloader."
  [[ "$REMOVE_SNAPPER" == "true" ]] && warn "Snapper will be removed only after a new pre-snapshot succeeds."
  [[ "$REMOVE_PREINSTALLED_APPS" == "true" ]] && warn "Selected preinstalled applications and Firefox will be removed."
  [[ "$REMOVE_OTHER_KERNELS" == "true" ]] && warn "Non-CachyOS kernels will be removed, except the running kernel."
  [[ "$DISABLE_UNUSED_SERVICES" == "true" ]] && warn "Selected desktop services will be disabled."
  [[ "$ENABLE_FIREWALL" == "true" ]] && warn "UFW LAN rules will be configured and UFW enabled, unless this is an SSH session."
  [[ "$FORCE_BRAVE_EXTENSIONS" == "true" ]] && warn "The curated Brave extension policy will force-install extensions."
  [[ "$RUN_MAINTENANCE" == "true" ]] && warn "Caches, unused Flatpak data, journal entries and old package-cache versions will be removed."
  info "The script updates the system, installs the documented applications, and writes logs to $LOG_DIR."
  if [[ "$AUTO_CONFIRM" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      fail "Non-interactive use requires --yes after reviewing the options."
      exit 2
    fi
    local answer
    read -r -p 'Type yes to continue: ' answer
    if [[ "$answer" != "yes" ]]; then
      info "No changes were made."
      exit 0
    fi
  fi
}

# Gaming profile is intentionally not the security-sensitive kernel-parameter opt-in.
GAMING_EXTREME=false
[[ "$PROFILE" == "extreme" ]] && GAMING_EXTREME=true
# GPU detection for hardware-specific drivers (NVIDIA only on NVIDIA)
GPU_VENDOR="unknown"
if lspci 2>/dev/null | grep -qi "nvidia"; then GPU_VENDOR="nvidia"
elif lspci 2>/dev/null | grep -qiE "amd.*vga|amd.*graphics|Radeon"; then GPU_VENDOR="amd"
elif lspci 2>/dev/null | grep -qi "intel.*graphics"; then GPU_VENDOR="intel"
fi
log "GPU: $GPU_VENDOR | profile: $PROFILE | mitigations-off: $ENABLE_MITIGATIONS_OFF"

echo -e "${BLUE}Full log: $LOG_FILE${NC}"
echo -e "${RED}Errors only:       $ERROR_LOG${NC}\n"
if ! sudo -v; then
  fail "Sudo authorization failed – aborting without changes."
  exit 1
fi
confirm_plan
backup_file /etc/pacman.conf

# Removing BTRFS snapshots is never implicit. A fresh pre-snapshot is mandatory
# for the explicit --remove-snapper option.
if [[ "$REMOVE_SNAPPER" == "true" ]]; then
  if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" != "btrfs" ]] || ! command -v snapper >/dev/null 2>&1; then
    fail "--remove-snapper requires BTRFS and an installed Snapper client."
    exit 1
  fi
  if ! sudo snapper list-configs | awk 'NR > 1 && $1 == "root" { found=1 } END { exit !found }' || \
     ! sudo snapper -c root create --type pre --description "Before CachyOS Gaming Setup ${RUN_ID}"; then
    fail "Could not create a Snapper pre-snapshot; Snapper will not be removed."
    exit 1
  fi
  log "Snapper pre-snapshot created before requested removal"
fi

# ---------- 0. SYSTEMPRÜFUNG ----------
step "0/8 SYSTEM CHECK - check requirements and system status"
info "Secure Boot check (must be OFF, otherwise Invalid signature)"
sbctl status 2>/dev/null | grep -q "Secure Boot.*Enabled" && warn "Secure Boot ON! Disable in BIOS" || log "Secure Boot off - good"
info "Boot partition check (Windows 100MB too small -> 2GB needed)"
df -h /boot | tail -1 | awk '{print "Boot:", $2, "total", $4, "frei"}'
df /boot | awk 'NR==2{if($4<500000) exit 1}' || warn "Boot low! 2GB recommended"
if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" != "btrfs" ]]; then
  fail "This setup targets BTRFS on /. Refusing to apply the BTRFS-oriented profile on another root filesystem."
  exit 1
fi
log "BTRFS root filesystem confirmed"
info "BTRFS Kernel 6.15 Bug Check (warning only, no abort on request)"
if uname -r | grep -q "6\.15"; then
  warn "6.15 BTRFS Bug! Log-tree corruption possible — no abort on request, only warning"
  info "If issues: sudo pacman -S linux-lts linux-lts-headers && sudo mkinitcpio -P && reboot into LTS"
fi
log "Kernel $(uname -r) ok"
if curl --fail --silent --show-error --connect-timeout 10 --head https://archlinux.org/ >/dev/null 2>&1 || ping -c1 -W3 archlinux.org &>/dev/null; then
  log "Internet reachable"
else
  fail "No internet connection – aborting to avoid incomplete setup."
  exit 1
fi
info "Configure pacman (parallel, color, verbose)"
set_pacman_option() {
  local key="$1" value="$2"
  if grep -qE "^#?${key}" /etc/pacman.conf; then
    sudo sed -Ei "s|^#?${key}.*|${value}|" /etc/pacman.conf
  else
    printf '%s\n' "$value" | sudo tee -a /etc/pacman.conf >/dev/null
  fi
}
if ! set_pacman_option "ParallelDownloads" "ParallelDownloads = 5" || \
   ! set_pacman_option "Color" "Color" || \
   ! set_pacman_option "VerbosePkgLists" "VerbosePkgLists"; then
  fail "Could not configure /etc/pacman.conf; see $ERROR_LOG."
  exit 1
fi
if ! grep -qxF "ILoveCandy" /etc/pacman.conf && ! printf '%s\n' "ILoveCandy" | sudo tee -a /etc/pacman.conf >/dev/null; then
  fail "Could not add ILoveCandy to /etc/pacman.conf."
  exit 1
fi
info "Refresh keyrings with a full system transaction"
if ! sudo pacman -Syu --needed --noconfirm archlinux-keyring cachyos-keyring; then
  fail "Keyring refresh failed; aborting before further package changes."
  exit 1
fi
if ! sudo pacman-key --populate archlinux cachyos; then
  warn "pacman-key population failed; investigate before retrying."
fi
if command -v cachyos-rate-mirrors >/dev/null 2>&1 && ! sudo cachyos-rate-mirrors; then
  warn "Mirror rating failed; keeping the existing mirror configuration."
fi
if ! sudo chmod 644 /etc/pacman.d/mirrorlist /etc/pacman.d/cachyos-mirrorlist; then
  warn "Could not adjust mirror-list permissions; continuing with existing permissions."
fi
log "Pre-flight done"

# ---------- 1. UPDATE ----------
# Auf Arch/CachyOS muss das vollständige Update vor Installationen/Entfernungen laufen.
step "1/8 SYSTEM UPDATE - full update, abort safely on error"
if sudo pacman -Syu --noconfirm; then
  log "System update done"
else
  fail "System update failed – no automatic --overwrite='*'. Check $ERROR_LOG and rerun after fixing."
  exit 1
fi

# ---------- 1.5 BEREINIGUNG - bewusst ersetzte Apps und Kernel ----------
step "1.5/8 CLEANUP - standard+Bore, remove replaced apps"
info "Kernel: install standard + Bore from CachyOS repos"
if ! sudo pacman -S --needed --noconfirm linux-cachyos linux-cachyos-headers linux-cachyos-bore linux-cachyos-bore-headers; then
  fail "Required CachyOS kernels could not be installed; aborting before cleanup."
  exit 1
fi

# AUR packages are optional. Never pretend an unavailable helper succeeded, and
# never build as root (the script already refuses root execution).
AUR=""
build_paru() {
  local build_dir
  build_dir="$(mktemp -d "${TMPDIR:-/tmp}/paru.XXXXXX")" || return 1
  if git clone --depth 1 https://aur.archlinux.org/paru.git "$build_dir/paru" && \
     (cd "$build_dir/paru" && makepkg -si --noconfirm); then
    rm -rf -- "$build_dir"
    command -v paru >/dev/null 2>&1
  else
    rm -rf -- "$build_dir"
    return 1
  fi
}
if command -v paru >/dev/null 2>&1; then
  AUR="paru"
elif command -v yay >/dev/null 2>&1; then
  AUR="yay"
elif sudo pacman -S --needed --noconfirm yay && command -v yay >/dev/null 2>&1; then
  AUR="yay"
elif build_paru; then
  AUR="paru"
else
  warn "No AUR helper is available. AUR-only applications will be skipped or use documented Flatpak fallbacks."
fi
aur_install() {
  if [[ -z "$AUR" ]]; then
    warn "AUR install skipped (no paru/yay): $*"
    return 127
  fi
  "$AUR" -S --needed --noconfirm "$@"
}
[[ -n "$AUR" ]] && log "AUR helper available: $AUR"

# Kernel removal is destructive and therefore requires an explicit opt-in.
if [[ "$REMOVE_OTHER_KERNELS" == "true" ]]; then
  RUNNING_KERNEL_PKG="$(pacman -Qqo "/usr/lib/modules/$(uname -r)" 2>/dev/null | head -n1 || true)"
  mapfile -t KERNEL_PACKAGES < <(pacman -Qq 2>/dev/null | grep -E '^linux-(cachyos|zen|lts|hardened|rt|xanmod)(-|$)' || true)
  for k in "${KERNEL_PACKAGES[@]}"; do
    case "$k" in
      linux-cachyos|linux-cachyos-headers|linux-cachyos-bore|linux-cachyos-bore-headers) continue ;;
    esac
    if [[ -n "$RUNNING_KERNEL_PKG" && "$k" == "$RUNNING_KERNEL_PKG" ]]; then
      warn "Keeping currently running kernel: $k"
    elif sudo pacman -Rns --noconfirm "$k"; then
      log "Removed requested non-CachyOS kernel: $k"
    else
      warn "Kernel $k was not removed (dependency or protection)."
    fi
  done
else
  info "Other installed kernels are kept (use --remove-other-kernels to opt in)."
fi

if [[ "$REMOVE_PREINSTALLED_APPS" == "true" ]]; then
  info "Remove selected preinstalled apps with normal dependency checks"
  REMOVED_PACKAGES=(
    yakuake spectacle kmail kontact akonadi akregator korganizer
    elisa dragon haruna amarok juk discover octopi flatseal btop neofetch
    htop ksysguard plasma-systemmonitor khelpcenter konqueror kmahjongg kpat knetattach
  )
  for pkg in "${REMOVED_PACKAGES[@]}"; do
    if pacman -Qq "$pkg" &>/dev/null && ! sudo pacman -Rns --noconfirm "$pkg"; then
      warn "Keeping $pkg because it is still required."
    fi
  done
  flatpak uninstall -y org.mozilla.firefox org.kde.kate || warn "One or more optional Flatpak replacements were not removed."
else
  info "Preinstalled applications are kept (use --remove-preinstalled-apps to opt in)."
fi
if [[ "$REMOVE_SNAPPER" == "true" ]]; then
  sudo systemctl disable --now snapper-cleanup.timer snapper-timeline.timer limine-snapper-sync.service || warn "Some Snapper units were already inactive or unavailable."
  if ! sudo pacman -Rns --noconfirm snapper cachyos-snapper-support limine-snapper-sync snap-pac snap-pac-grub btrfs-assistant; then
    warn "Snapper or related packages were retained because a dependency prevented removal."
  fi
else
  info "Snapper and BTRFS rollback tooling are kept (use --remove-snapper to opt in)."
fi

# Paketdateien nicht manuell aus /usr/share/locale löschen: Ein Update ist kein Reparatur-Mechanismus.
info "Language packs stay package-managed (de+en fully available)"
if [[ "$REMOVE_PREINSTALLED_APPS" == "true" ]]; then
  sudo pacman -Rns --noconfirm gnu-free-fonts || warn "gnu-free-fonts was retained because a dependency requires it."
else
  info "Preinstalled fonts are kept (part of --remove-preinstalled-apps cleanup)."
fi

if [[ "$DISABLE_UNUSED_SERVICES" == "true" ]]; then
  info "Disable explicitly selected desktop services"
  balooctl disable || true; balooctl6 disable || true; balooctl purge || true; balooctl6 purge || true; balooctl suspend || true
  systemctl --user mask baloo_file.service tracker-miner-fs.service tracker-miner-rss.service tracker-extract.service tracker-miner-fs-3.service tracker-extract-3.service || true
  kwriteconfig5 --file baloofilerc --group "Basic Settings" --key "Indexing-Enabled" false || true
  sudo systemctl disable --now ModemManager lvm2-monitor || warn "One or more selected services could not be disabled."
else
  info "Desktop services are left unchanged (use --disable-unused-services to opt in)."
fi

# ---------- 2. BASIS ----------
step "2/8 BASE - Multilib, Flatpak"
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  if ! printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null; then
    fail "Could not enable multilib; aborting."
    exit 1
  fi
  # Neue Repository-Konfiguration immer mit einem vollständigen Update übernehmen, nie nur -Sy.
  if ! sudo pacman -Syu --noconfirm; then
    fail "Update nach Aktivierung von multilib fehlgeschlagen – Abbruch."
    exit 1
  fi
fi
if ! sudo pacman -S --needed --noconfirm base-devel git flatpak pacman-contrib acl python pciutils; then
  fail "Required base packages could not be installed; aborting."
  exit 1
fi
if ! sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
  warn "Flathub could not be configured; Flatpak app installs may be skipped."
fi
# Sichere Komfort-Befehle: keine Paketlöschung oder BleachBit-Aktion ohne Prüfung.
mkdir -p "$HOME/.local/bin" "$HOME/.config/fish/conf.d"
# Preserve generated helpers and shell configuration before replacing them.
for helper in update-arch clean-arch fix-key update-mirrors configure-spicetify clean-flatpak-caches clean-wine-temp; do
  backup_file "$HOME/.local/bin/$helper"
done
backup_file "$HOME/.bashrc"
backup_file "$HOME/.config/fish/conf.d/cachyos-local-tools.fish"

cat <<'EOF' > "$HOME/.local/bin/update-arch"
#!/usr/bin/env bash
# Deliberately limited to updates. Driver installation, firewall policy and repair
# operations belong to the reviewed setup run, not to a recurring update command.
set -Euo pipefail
if ! sudo pacman -Syu --noconfirm; then
  printf '%s\n' 'Pacman update failed; Flatpak and AUR updates were not started.' >&2
  exit 1
fi
if command -v flatpak >/dev/null 2>&1 && ! flatpak update -y; then
  printf '%s\n' 'Flatpak update failed; continue by reviewing the output above.' >&2
fi
if command -v paru >/dev/null 2>&1; then
  paru -Syu --noconfirm || printf '%s\n' 'Paru update failed; review the AUR build output.' >&2
elif command -v yay >/dev/null 2>&1; then
  yay -Syu --noconfirm || printf '%s\n' 'Yay update failed; review the AUR build output.' >&2
else
  printf '%s\n' 'No AUR helper found; AUR updates skipped.'
fi
if command -v mkinitcpio >/dev/null 2>&1; then
  sudo mkinitcpio -P || printf '%s\n' 'Initramfs rebuild failed; do not reboot until this is resolved.' >&2
fi
if command -v limine-mkinitcpio >/dev/null 2>&1; then
  sudo limine-mkinitcpio || printf '%s\n' 'Limine entry regeneration failed; review its output.' >&2
fi
EOF
cat <<'EOF' > "$HOME/.local/bin/clean-arch"
#!/usr/bin/env bash
set -u
sudo paccache -rk2
flatpak uninstall --unused -y || true
sudo journalctl --vacuum-time=3d || true
sudo journalctl --vacuum-size=100M || true
orphans="$(pacman -Qdtq 2>/dev/null || true)"
if [[ -n "$orphans" ]]; then
  printf '%s\n%s\n' 'Mögliche Waisen – nur anzeigen, nicht automatisch entfernen:' "$orphans"
  printf '%s\n' 'Nach Prüfung optional: sudo pacman -Rns <paketname>'
else
  printf '%s\n' 'Keine Pacman-Waisen gefunden.'
fi
printf '%s\n' 'BleachBit wird nicht automatisch ausgeführt. Erst: bleachbit --preview <cleaner>'
EOF
cat <<'EOF' > "$HOME/.local/bin/fix-key"
#!/usr/bin/env bash
set -u
if ! sudo pacman -Syu --needed --noconfirm archlinux-keyring cachyos-keyring; then
  printf '%s\n' 'Keyring-Update fehlgeschlagen.' >&2
  exit 1
fi
sudo pacman-key --populate archlinux cachyos
EOF
cat <<'EOF' > "$HOME/.local/bin/update-mirrors"
#!/usr/bin/env bash
set -u
if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
  sudo cachyos-rate-mirrors
elif command -v reflector >/dev/null 2>&1; then
  sudo reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist
else
  printf '%s\n' 'Kein Mirror-Tool installiert (cachyos-rate-mirrors / reflector).'
fi
EOF
cat <<'EOF' > "$HOME/.local/bin/configure-spicetify"
#!/usr/bin/env bash
# Konfiguriert Spicetify für das Spotify-Flatpak mit minimalen, gezielten Rechten.
set -u
SPOTIFY_APP_ID="com.spotify.Client"
if ! command -v spicetify >/dev/null 2>&1; then
  printf '%s\n' 'Spicetify ist nicht installiert.' >&2
  exit 1
fi
if ! flatpak info "$SPOTIFY_APP_ID" >/dev/null 2>&1; then
  printf '%s\n' 'Spotify Flatpak ist nicht installiert.' >&2
  exit 1
fi
spotify_root="$(flatpak info --show-location "$SPOTIFY_APP_ID" 2>/dev/null || true)"
spotify_path=""
for candidate in "$spotify_root/files/extra/share/spotify" "$spotify_root/files/share/spotify"; do
  if [[ -d "$candidate" ]]; then
    spotify_path="$candidate"
    break
  fi
done
if [[ -z "$spotify_path" ]]; then
  printf '%s\n' 'Spotify-Ressourcen wurden nicht gefunden; prüfe: flatpak info --show-location com.spotify.Client' >&2
  exit 1
fi
prefs_path=""
for candidate in \
  "$HOME/.var/app/com.spotify.Client/config/spotify/prefs" \
  "$HOME/.config/spotify/prefs"; do
  if [[ -f "$candidate" ]]; then
    prefs_path="$candidate"
    break
  fi
done
if [[ -z "$prefs_path" ]]; then
  printf '%s\n' 'Starte Spotify einmal, melde dich an, schließe es und führe danach configure-spicetify erneut aus.' >&2
  exit 2
fi
# Keine --filesystem=host-os Freigabe: nur die konkreten Spotify-Ressourcen werden beschreibbar gemacht.
if [[ "$spotify_root" == /var/lib/flatpak/* ]]; then
  if ! command -v setfacl >/dev/null 2>&1; then
    printf '%s\n' 'setfacl fehlt; installiere zuerst das Paket acl.' >&2
    exit 1
  fi
  sudo setfacl -m "u:$(id -un):rwx" "$spotify_path" || exit 1
  sudo setfacl -R -m "u:$(id -un):rwX" "$spotify_path/Apps" || exit 1
else
  chmod u+rwX "$spotify_path" || exit 1
  chmod -R u+rwX "$spotify_path/Apps" || exit 1
fi
if ! spicetify config spotify_path "$spotify_path" || ! spicetify config prefs_path "$prefs_path"; then
  printf '%s\n' 'Spicetify-Pfade konnten nicht gespeichert werden.' >&2
  exit 1
fi
# Marketplace/CustomApps brauchen nur Lesezugriff auf die gezielten Spicetify-Ordner, nie host-os.
spicetify_config_file="$(spicetify -c 2>/dev/null || true)"
if [[ -z "$spicetify_config_file" || ! -f "$spicetify_config_file" ]]; then
  printf '%s\n' 'Spicetify-Konfigurationsdatei wurde nicht gefunden.' >&2
  exit 1
fi
spicetify_config_dir="$(dirname "$spicetify_config_file")"
for folder in CustomApps Extensions; do
  mkdir -p "$spicetify_config_dir/$folder"
  flatpak override --user --filesystem="$spicetify_config_dir/$folder:ro" "$SPOTIFY_APP_ID" || {
    printf 'Flatpak-Freigabe für %s konnte nicht gesetzt werden.\n' "$folder" >&2
    exit 1
  }
done
if ! spicetify backup apply; then
  printf '%s\n' 'Spicetify konnte nicht angewendet werden.' >&2
  exit 1
fi
printf '%s\n' 'Spicetify wurde für Spotify eingerichtet. Nach einem Spotify-Update bei Bedarf erneut ausführen.'
EOF
cat <<'EOF' > "$HOME/.local/bin/clean-flatpak-caches"
#!/usr/bin/env bash
# Entfernt ausschließlich Inhalte aus den standardisierten Flatpak-XDG-Cache-Ordnern.
# Ohne --yes wird nur die belegte Größe angezeigt.
set -Euo pipefail
cache_root="$HOME/.var/app"
declare -a cache_dirs=()
if [[ -d "$cache_root" && ! -L "$cache_root" ]]; then
  while IFS= read -r -d '' cache_dir; do
    cache_dirs+=("$cache_dir")
  done < <(find "$cache_root" -mindepth 2 -maxdepth 2 -type d -name cache -print0 2>/dev/null)
fi
if (( ${#cache_dirs[@]} == 0 )); then
  printf '%s\n' 'Keine Flatpak-App-Caches gefunden.'
  exit 0
fi
printf '%s\n' 'Gefundene Flatpak-App-Caches (config/ und data/ bleiben unangetastet):'
printf '  %q\n' "${cache_dirs[@]}"
du -sch -- "${cache_dirs[@]}" 2>/dev/null || true
if [[ "${1:-}" != "--yes" || $# -ne 1 ]]; then
  printf '%s\n' 'Vorschau beendet. Zum gezielten Leeren ausführen: clean-flatpak-caches --yes'
  exit 0
fi
for cache_dir in "${cache_dirs[@]}"; do
  find "$cache_dir" -mindepth 1 -xdev -depth -delete
done
printf '%s\n' 'Flatpak-App-Caches geleert. Einstellungen und Nutzerdaten wurden nicht gelöscht.'
EOF
cat <<'EOF' > "$HOME/.local/bin/clean-wine-temp"
#!/usr/bin/env bash
# Leert nur Temp-Inhalte eines explizit angegebenen Wine-/Proton-Prefixes; nie Shadercache oder den Prefix selbst.
set -Euo pipefail
if [[ $# -ne 2 || "$1" != "--yes" ]]; then
  printf '%s\n' 'Verwendung: clean-wine-temp --yes /absoluter/pfad/zum/prefix' >&2
  printf '%s\n' 'Beispiel Steam: clean-wine-temp --yes ~/.local/share/Steam/steamapps/compatdata/APPID/pfx' >&2
  exit 2
fi
prefix="$(realpath -e -- "$2" 2>/dev/null || true)"
if [[ -z "$prefix" || ! -f "$prefix/system.reg" || ! -d "$prefix/drive_c/users" ]]; then
  printf '%s\n' 'Kein gültiger Wine-/Proton-Prefix (system.reg und drive_c/users erforderlich).' >&2
  exit 2
fi
for process in wineserver wine wine64 wine-preloader wine64-preloader steam steamwebhelper lutris bottles; do
  if pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1; then
    printf 'Abbruch: %s läuft noch. Schließe Steam, Wine, Lutris und Bottles zuerst.\n' "$process" >&2
    exit 1
  fi
done
declare -a temp_dirs=()
while IFS= read -r -d '' temp_dir; do
  temp_dirs+=("$temp_dir")
done < <(find "$prefix/drive_c/users" -xdev -type d -path '*/AppData/Local/Temp' -print0 2>/dev/null)
if (( ${#temp_dirs[@]} == 0 )); then
  printf '%s\n' 'Keine Windows-Temp-Ordner in diesem Prefix gefunden.'
  exit 0
fi
printf '%s\n' 'Folgende Temp-Ordner werden geleert (nur deren Inhalte; Prefix und Shadercache bleiben außerhalb davon):'
printf '  %q\n' "${temp_dirs[@]}"
du -sch -- "${temp_dirs[@]}" 2>/dev/null || true
for temp_dir in "${temp_dirs[@]}"; do
  find "$temp_dir" -mindepth 1 -xdev -depth -delete
done
printf '%s\n' 'Windows-Temp-Inhalte dieses Prefixes wurden geleert.'
EOF
chmod +x "$HOME/.local/bin/update-arch" "$HOME/.local/bin/clean-arch" "$HOME/.local/bin/fix-key" "$HOME/.local/bin/update-mirrors" "$HOME/.local/bin/configure-spicetify" "$HOME/.local/bin/clean-flatpak-caches" "$HOME/.local/bin/clean-wine-temp"
# Den neuen Pfad sofort im aktuellen Skriptprozess verfügbar machen und dauerhaft für Bash/Fish speichern.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# ~/.local/bin für Bash und Fish dauerhaft verfügbar machen, ohne Bash-Syntax in Fish zu schreiben.
if ! grep -Fqx 'export PATH="$HOME/.local/bin:$PATH" # CachyOS local tools' "$HOME/.bashrc" 2>/dev/null; then
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH" # CachyOS local tools' >> "$HOME/.bashrc"
fi
cat <<'EOF' > "$HOME/.config/fish/conf.d/cachyos-local-tools.fish"
if not contains -- "$HOME/.local/bin" $PATH
    set -gx PATH "$HOME/.local/bin" $PATH
end
EOF
log "Base+helper commands: update-arch, clean-arch, fix-key, update-mirrors, configure-spicetify, clean-flatpak-caches, clean-wine-temp"

# Firewall policy is a network-security decision. It is opt-in and never applied
# from a detected SSH session, where a missing custom rule could lock the user out.
if [[ "$ENABLE_FIREWALL" == "true" ]]; then
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn "UFW was not changed because this is an SSH session. Configure the required SSH rule manually first."
  elif ! command -v ufw >/dev/null 2>&1 && ! sudo pacman -S --needed --noconfirm ufw; then
    warn "--enable-firewall was requested, but UFW could not be installed."
  elif ! command -v ufw >/dev/null 2>&1; then
    warn "UFW installation completed without making the command available; no rules were changed."
  elif ! sudo ufw default deny incoming || ! sudo ufw default allow outgoing || \
       ! sudo ufw allow 22000/tcp || ! sudo ufw allow 21027/udp || \
       ! sudo ufw allow 1714:1764/tcp || ! sudo ufw allow 1714:1764/udp || \
       ! sudo ufw allow 5353/udp || ! sudo ufw allow 5355/tcp || \
       ! sudo ufw allow 5355/udp || ! sudo ufw allow 7680/tcp || \
       ! sudo ufw allow 1900/udp || ! sudo ufw --force enable; then
    warn "UFW setup did not finish. Review 'sudo ufw status numbered' before relying on it."
  else
    log "UFW enabled with requested Syncthing/KDE Connect/mDNS/LAN rules"
  fi
else
  info "UFW is left unchanged (use --enable-firewall to opt in)."
fi

# ---------- 3. AUSGEWÄHLTE ANWENDUNGEN ----------
step "3/8 APPLICATIONS - install selected programs"

info "Browser: install Brave"
if [[ "$REMOVE_PREINSTALLED_APPS" == "true" ]]; then
  pkill firefox || true
  sudo pacman -Rns --noconfirm firefox firefox-i18n-de || warn "Firefox packages were retained because a dependency requires them."
  flatpak uninstall -y org.mozilla.firefox || warn "Firefox Flatpak was not installed or could not be removed."
else
  info "Firefox is kept (use --remove-preinstalled-apps to opt in to replacement)."
fi
if ! sudo pacman -S --needed --noconfirm brave-browser && ! aur_install brave-bin; then
  warn "Brave could not be installed from the CachyOS repositories or AUR."
fi
backup_file /etc/brave/policies/managed/brave-settings.json
if ! sudo install -d -m 755 /etc/brave/policies/managed || ! sudo tee /etc/brave/policies/managed/brave-settings.json >/dev/null <<'EOF'
{
  "BraveRewardsDisabled": true,
  "BraveWalletDisabled": true,
  "BraveVPNDisabled": true,
  "BraveNewsDisabled": true,
  "BraveAIChatEnabled": false,
  "BraveTalkDisabled": true
}
EOF
then
  warn "Brave settings policy could not be written."
fi
if [[ "$FORCE_BRAVE_EXTENSIONS" == "true" ]]; then
  backup_file /etc/brave/policies/managed/extensions.json
  if ! sudo tee /etc/brave/policies/managed/extensions.json >/dev/null <<'EOF'
{"ExtensionInstallForcelist":["eimadpbcbfnmbkopoojfekhnkhdbieeh;https://clients2.google.com/service/update2/crx","mnjggcdmjocbbbhaepdhchncahnbgone;https://clients2.google.com/service/update2/crx","gebbhagfogifgggkldgodflihgfeippi;https://clients2.google.com/service/update2/crx","cjpalhdlnbpafiamejdnhcphjbkeiagm;https://clients2.google.com/service/update2/crx","hdokiejnpimakedhajhdlcegeplioahd;https://clients2.google.com/service/update2/crx","ponfpcnoehjfmfllpaingbgckeeldkh;https://clients2.google.com/service/update2/crx","alhmbbnlcggfcjjfihglopfopcbigmil;https://clients2.google.com/service/update2/crx"]}
EOF
  then
    warn "Brave extension policy could not be written."
  fi
else
  info "Brave extensions are not force-installed (use --force-brave-extensions to opt in)."
fi

# WhatsApp PWA wird manuell installiert — kein force-install mehr (auf Wunsch)
info "Terminal: Alacritty + Konsole + Fish + pinned Fisher bootstrap + Starship (keep both terminals)"
# btop/neofetch/fastfetch wurden oben ausschließlich mit normaler Abhängigkeitsprüfung behandelt – nie mit -Rdd.
install_pacman_optional "Terminal tools" alacritty konsole fish starship || true
log "Keep both terminals: Alacritty + Konsole"
# Fisher is pinned to a reviewed commit. Plugins are not executed automatically;
# users can inspect and install them later with Fisher if they want them.
FISHER_COMMIT="791da644d33d392216f6b1a9b5fc1e470db6d7f2"
if command -v fish >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/fish/functions"
  backup_file "$HOME/.config/fish/functions/fisher.fish"
  if curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      "https://raw.githubusercontent.com/jorgebucaran/fisher/${FISHER_COMMIT}/functions/fisher.fish" \
      -o "$HOME/.config/fish/functions/fisher.fish"; then
    log "Pinned Fisher bootstrap installed (${FISHER_COMMIT:0:12}); no third-party Fish plugins were auto-installed"
  else
    warn "Pinned Fisher bootstrap could not be downloaded"
  fi
else
  warn "Fish is unavailable – Fisher bootstrap skipped"
fi
# Kein Conky Widget mehr — stattdessen bester Taskmanager (Mission Center wie Windows)
flatpak install -y flathub io.missioncenter.MissionCenter || install_pacman_optional "Plasma System Monitor fallback" plasma-systemmonitor || true
log "Taskmanager Mission Center installiert (Fallback plasma-systemmonitor)"
install_pacman_optional "Catfish" catfish || true
mkdir -p "$HOME/.config/fish"
backup_file "$HOME/.config/starship.toml"
backup_file "$HOME/.config/fish/config.fish"
starship preset nerd-font-symbols -o "$HOME/.config/starship.toml" 2>/dev/null || true
grep -q "starship init fish" "$HOME/.config/fish/config.fish" 2>/dev/null || echo 'starship init fish | source' >> "$HOME/.config/fish/config.fish"

info "Apps: Flameshot (Spectacle removed), Gimp+Gwenview, VLC+ffmpeg, Ark+p7zip/unrar/unzip/lrzip, LibreOffice, CopyQ + Kate"
if [[ "$REMOVE_PREINSTALLED_APPS" == "true" ]]; then
  sudo pacman -Rns --noconfirm spectacle || warn "Spectacle was retained because a dependency requires it."
fi
install_pacman_optional "Desktop media and document applications" flameshot gimp gwenview vlc vlc-plugins-all ffmpeg ark p7zip unrar unzip lrzip dolphin dolphin-plugins okular kate || true
# Keine Windows-Aliase mehr — alle Aliase entfernt auf Wunsch (clean)
# (früher hier: notepad->kate, snippingtool->flameshot, roblox->sober etc. — jetzt entfernt)
install_pacman_optional "LibreOffice" libreoffice-fresh libreoffice-fresh-de || aur_install libreoffice-fresh || true
install_pacman_optional "Desktop utilities" copyq bleachbit fwupd openrgb lm_sensors || true
aur_install stacer-bin || flatpak install -y flathub io.github.stacer || true

info "Comm: Discord/Vesktop skipped (public version without Vencord), WhatsApp as Brave App, Spotify+Spicetify, LastPass"
# Public version: No Vencord/Vesktop and no MessageLogger (ToS-safe). For Discord: flatpak install flathub com.discordapp.Discord
# Vesktop/Vencord removed in public version – no plugin setup
# Public version: No Vencord/MessageLogger configuration
# WhatsApp as Brave App (PWA) instead of Flatpak — so WAIncognito (browser addon) works 🟢📱
flatpak install -y flathub com.spotify.Client || true
# WhatsApp Web wird manuell eingerichtet — kein Auto-Install mehr (auf Wunsch)
log "WhatsApp manually via brave://apps (if not working: brave --app=https://web.whatsapp.com)"
if ! aur_install spicetify-cli; then
  warn "Spicetify konnte nicht installiert werden (ohne AdBlock, reines Theming)"
fi
mkdir -p ~/.config/spicetify
info "Spicetify: Spotify once open/log in, close, then run configure-spicetify (no ad-blocking, theming only)"
# Standard Mail Client fuer alle (statt Proton) – Thunderbird, bei Bedarf Proton separat: flatpak install flathub me.proton.Mail
if ! flatpak install -y flathub org.mozilla.Thunderbird; then
  install_pacman_optional "Thunderbird" thunderbird || true
fi
# Proton Mail & VPN entfernt – bei Bedarf manuell: flatpak install flathub me.proton.Mail / com.protonvpn.www

info "Sync/Remote: KDEConnect Syncthing RustDesk Sunshine WaydroidStore"
install_pacman_optional "KDE Connect and Syncthing" kdeconnect syncthing || true
systemctl --user enable --now syncthing || true
aur_install rustdesk-bin sunshine-bin || flatpak install -y flathub com.rustdesk.RustDesk || true

info "Gaming: Steam, Heroic, Prism, Sober, BedrockOnLinux, Waydroid, QEMU, Bottles, Lutris and tools"
install_pacman_optional "Steam" steam || true
aur_install heroic-games-launcher-bin || flatpak install -y flathub com.heroicgameslauncher.hgl || true
if ! install_pacman_optional "Prism Launcher" prism-launcher; then
  aur_install prism-launcher-bin || flatpak install -y flathub org.prismlauncher.PrismLauncher || true
fi
# Older JDKs can be absent from a repository, so each remains independently optional.
for jdk in jdk8-openjdk jdk11-openjdk jdk17-openjdk jdk21-openjdk jdk-openjdk; do
  install_pacman_optional "Optional JDK" "$jdk" || true
done
flatpak install -y flathub org.vinegarhq.Sober || true
# BedrockOnLinux lädt mit deinem Microsoft-Konto die Windows-/GDK-Ausgabe von Minecraft Bedrock.
# Bewusst kein mcpelauncher-Fallback: mcpelauncher nutzt die Android-Ausgabe und wäre etwas anderes.
if ! aur_install bedrock-on-linux-bin; then
  warn "BedrockOnLinux konnte nicht installiert werden – die Android-Version wird nicht ersatzweise installiert"
fi
if ! install_pacman_optional "Waydroid prerequisites" waydroid lzip; then
  aur_install waydroid || warn "Waydroid konnte nicht installiert werden"
fi
# Binder nur dann beim Boot laden, wenn der aktuelle Kernel das Modul tatsächlich bereitstellt.
if modinfo binder_linux &>/dev/null; then
  backup_file /etc/modules-load.d/waydroid-binder.conf
  backup_file /etc/modprobe.d/waydroid-binder.conf
  sudo install -d -m 755 /etc/modules-load.d /etc/modprobe.d
  printf '%s\n' 'binder_linux' | sudo tee /etc/modules-load.d/waydroid-binder.conf >/dev/null
  if modinfo -F parm binder_linux 2>/dev/null | grep -q '^devices:'; then
    printf '%s\n' 'options binder_linux devices=binder,hwbinder,vndbinder' | sudo tee /etc/modprobe.d/waydroid-binder.conf >/dev/null
  fi
  if sudo modprobe binder_linux; then
    log "Waydroid Binder-Modul geladen und für den Boot vorgemerkt"
  else
    warn "binder_linux konnte nicht geladen werden – Waydroid-Log nach dem Start prüfen"
  fi
else
  info "binder_linux ist kein ladbares Modul; keine erzwungene modules-load-Konfiguration erstellt"
fi
if ! aur_install libhoudini; then
  warn "libhoudini wurde nicht installiert – kein externes Root-Skript wird automatisch ausgeführt"
fi
sudo waydroid init -s GAPPS -f 2>/dev/null || warn "Waydroid-Initialisierung fehlgeschlagen"
sudo systemctl enable --now waydroid-container 2>/dev/null || warn "waydroid-container konnte nicht gestartet werden"
install_pacman_optional "Virtualization stack" qemu-full virt-manager virt-viewer libvirt edk2-ovmf || install_pacman_optional "Virtualization fallback" qemu virt-manager libvirt || true
sudo systemctl enable --now libvirtd 2>/dev/null || true; sudo usermod -aG libvirt,kvm,qemu "$USER" 2>/dev/null || true
aur_install protonup-qt steamtinkerlaunch umu-launcher || flatpak install -y flathub net.davidotek.pupgui2 || true
install_pacman_optional "Gaming and container tools" bottles lutris winetricks protontricks mangohud lib32-mangohud vkbasalt lib32-vkbasalt gamescope gamemode lib32-gamemode obs-studio distrobox podman || aur_install bottles lutris || flatpak install -y flathub com.usebottles.bottles || true
aur_install debtap alien || true
command -v debtap &>/dev/null && sudo debtap -u >/dev/null 2>&1 &
install_pacman_optional "Developer and media tools" git github-cli handbrake || true

info "GUI/Theme: Bauh (Flatseal removed), Variety, Kvantum, keep Plymouth"
aur_install bauh || true
aur_install variety || true
install_pacman_optional "Theme prerequisites" kvantum plymouth || true
aur_install plymouth-theme-cachyos || true
sudo plymouth-set-default-theme -R cachyos || true
log "Selected applications installed"

# ---------- 4. LEISTUNGS-TWEAKS ----------
step "4/8 PERFORMANCE TWEAKS - apply desired gaming settings"
# Der Bore-Kernel wurde bereits vor dem Kernel-Cleanup in Phase 1.5 installiert und dort geschützt.
if pacman -Q linux-cachyos-bore &>/dev/null; then
  log "Bore kernel already installed"
else
  warn "Bore kernel missing – check log before rebooting"
fi
# Automatic hardware detection for public GitHub script
if lscpu 2>/dev/null | grep -qi "GenuineIntel"; then
  install_pacman_optional "Intel microcode" intel-ucode || true
elif lscpu 2>/dev/null | grep -qi "AuthenticAMD"; then
  install_pacman_optional "AMD microcode" amd-ucode || true
fi
install_pacman_optional "Performance tooling" zram-generator ananicy-cpp cachyos-ananicy-rules scx-scheds cpupower earlyoom || true
sudo systemctl enable --now ananicy-cpp earlyoom 2>/dev/null || true
# Hardware-dependent GPU drivers install directly (for GitHub users with different hardware)
if [[ "$GPU_VENDOR" == "nvidia" ]]; then
  log "NVIDIA detected ($GPU_VENDOR) – installing NVIDIA drivers automatically"
  sudo pacman -S --needed --noconfirm nvidia nvidia-utils lib32-nvidia-utils nvidia-settings opencl-nvidia lib32-opencl-nvidia libva-nvidia-driver || sudo pacman -S --needed --noconfirm nvidia-open-dkms || true
elif [[ "$GPU_VENDOR" == "amd" ]]; then
  log "AMD detected – installing AMD drivers automatically"
  install_pacman_optional "AMD graphics driver" xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon || true
elif [[ "$GPU_VENDOR" == "intel" ]]; then
  log "Intel detected – installing Intel drivers automatically"
  install_pacman_optional "Intel graphics driver" xf86-video-intel vulkan-intel lib32-vulkan-intel || true
else
  log "GPU unknown – installing generic Mesa drivers"
fi
# Ananicy CGroups Fix (Report: cpu controller not available) - Fallback auf nice only wenn cgroup fehlt
if ! grep -q "cpu" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  backup_file /etc/ananicy.d/00-cgroup-fix.conf
  sudo install -d -m 755 /etc/ananicy.d
  printf '%s\n' "apply_cgroup=false" | sudo tee -a /etc/ananicy.d/00-cgroup-fix.conf >/dev/null || warn "Could not write the Ananicy cgroup fallback."
fi

# === AUTOMATISCHE DRUCKER ERKENNUNG – nur wenn Hardware vorhanden (hohe Qualitaet) ===
# Base CUPS always available, but drivers only if printer is detected
if lsusb 2>/dev/null | grep -qiE "printer|hewlett|hp|canon|epson|brother|lexmark|kyocera|ricoh|oki" || lpstat -p 2>/dev/null | grep -q printer || ls /dev/usb/lp* 2>/dev/null | grep -q lp; then
  log "Printer detected – installing printer support automatically"
  install_pacman_optional "Printer base support" cups cups-pdf cups-filters system-config-printer || true
  install_pacman_optional "Printer driver database" gutenprint foomatic-db foomatic-db-engine foomatic-db-nonfree || true
  install_pacman_optional "Printer rendering support" ghostscript gsfonts || true
  # Hersteller-spezifisch nur wenn passende Hardware gefunden
  if lsusb 2>/dev/null | grep -qiE "hewlett|hp"; then install_pacman_optional "HP printer driver" hplip || true; fi
  if lsusb 2>/dev/null | grep -qi "epson"; then install_pacman_optional "Epson printer driver" epson-inkjet-printer-escpr || true; fi
  if lsusb 2>/dev/null | grep -qi "canon"; then install_pacman_optional "Canon printer driver" cnijfilter2 || true; fi
  if lsusb 2>/dev/null | grep -qi "brother"; then install_pacman_optional "Brother printer driver" brlaser || true; fi
  sudo systemctl enable --now cups.service cups.socket 2>/dev/null || true
  sudo systemctl enable --now avahi-daemon 2>/dev/null || true
else
  log "No printer detected – printer support skipped (if needed: sudo pacman -S cups system-config-printer)"
  # CUPS nicht automatisch starten wenn kein Drucker vorhanden – spart RAM
fi

# === AUTOMATISCHER SCANNER SUPPORT ===
if lsusb 2>/dev/null | grep -qiE "scanner|hewlett|canon|epson|brother|fujitsu" || sane-find-scanner 2>/dev/null | grep -qi "found"; then
  log "Scanner detected – installing scanner support"
  install_pacman_optional "Scanner support" sane sane-airscan simple-scan || true
fi

# === AUTOMATISCHER BLUETOOTH SUPPORT ===
if lsusb 2>/dev/null | grep -qi bluetooth || lspci 2>/dev/null | grep -qi bluetooth || rfkill list 2>/dev/null | grep -qi bluetooth || dmesg 2>/dev/null | grep -qi bluetooth; then
  log "Bluetooth hardware detected – installing Bluetooth stack"
  install_pacman_optional "Bluetooth support" bluez bluez-utils blueman || true
  sudo systemctl enable --now bluetooth.service 2>/dev/null || true
else
  log "No Bluetooth detected – skipped"
fi

# === AUTOMATISCHER WLAN FIRMWARE ===
if lspci 2>/dev/null | grep -qiE "network|wireless|wlan|wifi" || lsusb 2>/dev/null | grep -qiE "wireless|wlan|wifi|realtek.*802|mediatek.*wireless|intel.*wireless"; then
  log "WLAN hardware detected – installing WLAN firmware"
  install_pacman_optional "WLAN firmware" linux-firmware-whence linux-firmware || true
  # Zusaetzliche Firmware fuer haeufige Chips
  if lspci 2>/dev/null | grep -qi "realtek"; then install_pacman_optional "Realtek WLAN firmware" rtl88xxau-aircrack-dkms-firmware || true; fi
fi

# === AUTOMATISCHER SOUND FIRMWARE ===
install_pacman_optional "Sound firmware and PipeWire" sof-firmware alsa-firmware pipewire pipewire-pulse pipewire-alsa || true  # Headphones (wired + Bluetooth) work automatically via sound firmware + pipewire/bluez

# === AUTOMATISCHER WEBCAM / FINGERPRINT (optional, nur wenn vorhanden) ===
if lsusb 2>/dev/null | grep -qiE "webcam|camera|chicony|logitech.*camera"; then
  log "Webcam erkannt – Treiber bereits im Kernel (uvcvideo)"
fi
if lsusb 2>/dev/null | grep -qiE "fingerprint|validity|synaptics.*fp"; then
  log "Fingerprint Reader erkannt – installiere fprint"
  install_pacman_optional "Fingerprint support" fprintd || true
fi
# CPU: use EPP on amd-pstate-epp (Ryzen 5600X etc.), don't force governor when EPP is available (avoids power-profiles-daemon error)
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference ]]; then
  log "AMD EPP detected (amd-pstate-epp) – using EPP, leaving governor to system daemon"
  # Enable boost safely
  echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
  for p in /sys/devices/system/cpu/cpufreq/policy*/boost; do echo 1 | sudo tee "$p" 2>/dev/null || true; done
  for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo balance_performance | sudo tee "$f" 2>/dev/null || echo power | sudo tee "$f" 2>/dev/null || true; done
  log "AMD EPP set to balance_performance (Gamemode will boost to performance when needed)"
else
  # Fallback for systems without EPP: use schedutil
  backup_file /etc/default/cpupower
  printf '%s\n' 'governor="schedutil"' | sudo tee /etc/default/cpupower >/dev/null || warn "Could not configure cpupower defaults."
  sudo systemctl enable --now cpupower || warn "cpupower could not be enabled."
  sudo cpupower frequency-set -g schedutil 2>/dev/null || sudo cpupower frequency-set -g powersave 2>/dev/null || true
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo schedutil | sudo tee "$f" 2>/dev/null || echo powersave | sudo tee "$f" 2>/dev/null || true; done
  log "CPU governor set to schedutil (no EPP available)"
fi
# Do not mask power-profiles-daemon when EPP is present – it manages EPP correctly
backup_file /etc/systemd/zram-generator.conf
if ! sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
EOF
then
  warn "Could not write the ZRAM configuration."
fi
if [[ "$GAMING_EXTREME" == "true" ]]; then SPLIT="kernel.split_lock_mitigate=0"; else SPLIT="# split_lock disabled outside the extreme profile"; fi
backup_file /etc/sysctl.d/99-gaming-max.conf
if ! sudo tee /etc/sysctl.d/99-gaming-max.conf >/dev/null <<EOF
vm.max_map_count=2147483642
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
$SPLIT
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=2097152
vm.nr_hugepages=0
EOF
then
  warn "Could not write the gaming sysctl configuration."
fi
sudo sysctl --system || warn "Could not apply all sysctl settings."
sudo sysctl -w vm.swappiness=10 || true
printf '%s\n' 10 | sudo tee /proc/sys/vm/swappiness >/dev/null || true
sudo sysctl -w vm.vfs_cache_pressure=50 || true
# Watchdog etc. außerhalb von GAMING_EXTREME
# Watchdog bleibt an (auf Wunsch nicht geblacklistet) — sicherer bei Freeze
log "Watchdog stays active (no blacklist on request)"
# Coredumps bleiben an (auf Wunsch nicht deaktiviert) — Debug Infos bei Crash verfügbar
log "Coredumps stay active (no disable on request)"
# Shader-Cache clean Helper — kein Limit, aber sauber löschbar 🧹🎮
backup_file "$HOME/.local/bin/clean-shader-cache"
cat <<'EOF' > "$HOME/.local/bin/clean-shader-cache"
#!/usr/bin/env bash
set -uo pipefail
echo "Shader-Caches die geleert werden:"
du -sch -- "$HOME/.cache/mesa_shader_cache" "$HOME/.cache/nvidia" "$HOME/.cache/radv_builtin_shaders" "$HOME/.nv" "$HOME/.cache/dxvk" 2>/dev/null || true
if [[ "${1:-}" != "--yes" ]]; then echo "Vorschau — mit --yes wirklich löschen: clean-shader-cache --yes"; exit 0; fi
rm -rf -- "$HOME/.cache/mesa_shader_cache" "$HOME/.cache/nvidia" "$HOME/.cache/radv_builtin_shaders" "$HOME/.nv" "$HOME/.cache/dxvk" 2>/dev/null || true
echo "Shader-Caches geleert — beim nächsten Spielstart werden sie neu aufgebaut (kurz mehr Ruckler)"
EOF
chmod +x "$HOME/.local/bin/clean-shader-cache"
log "Shader-Cache Helper erstellt: clean-shader-cache"
printf '%s\n' madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null || true
backup_file /etc/tmpfiles.d/thp.conf
if ! sudo tee /etc/tmpfiles.d/thp.conf >/dev/null <<'EOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag - - - - madvise
EOF
then
  warn "Could not write the THP tmpfiles configuration."
fi
# amd_pstate is not forced through modprobe.d; the kernel default remains in control.
if [[ "$GAMING_EXTREME" == "true" ]]; then
  backup_file /etc/security/limits.d/99-gaming.conf
  if ! sudo tee /etc/security/limits.d/99-gaming.conf >/dev/null <<EOF
# Restricted to the invoking desktop user; no global unlimited memlock policy.
$USER soft nice -10
$USER hard nice -10
EOF
  then
    warn "Could not write the extreme-profile PAM limits configuration."
  fi
fi
if [[ "$GPU_VENDOR" == "nvidia" && "$GAMING_EXTREME" == "true" ]]; then
  backup_file /etc/X11/xorg.conf.d/20-nvidia.conf
  if ! sudo install -d -m 755 /etc/X11/xorg.conf.d || ! sudo tee /etc/X11/xorg.conf.d/20-nvidia.conf >/dev/null <<'EOF'
Section "Device"
    Identifier "NVIDIA Card"
    Driver "nvidia"
    Option "TripleBuffer" "off"
    Option "Coolbits" "28"
EndSection
EOF
  then
    warn "Could not write the NVIDIA extreme-profile configuration."
  fi
elif [[ "$GPU_VENDOR" == "nvidia" ]]; then
  info "NVIDIA Coolbits are not configured in the balanced profile."
fi
mkdir -p "$HOME/.config/gamemode"
backup_file "$HOME/.config/gamemode/gamemode.ini"
printf '%s\n' '[general]' 'renice=10' 'desiredgov=performance' > "$HOME/.config/gamemode/gamemode.ini"

detect_bootloader() {
  BOOTLOADER="unknown"
  BOOTLOADER_CONFIG=""
  if [[ -f /etc/default/limine ]]; then
    BOOTLOADER="limine"; BOOTLOADER_CONFIG="/etc/default/limine"
  elif [[ -f /etc/sdboot-manage.conf ]]; then
    BOOTLOADER="systemd-boot"; BOOTLOADER_CONFIG="/etc/sdboot-manage.conf"
  elif [[ -f /etc/default/grub ]]; then
    BOOTLOADER="grub"; BOOTLOADER_CONFIG="/etc/default/grub"
  elif [[ -f /boot/refind_linux.conf ]]; then
    BOOTLOADER="refind"; BOOTLOADER_CONFIG="/boot/refind_linux.conf"
  elif [[ -f /etc/kernel/cmdline ]]; then
    BOOTLOADER="kernel-install"; BOOTLOADER_CONFIG="/etc/kernel/cmdline"
  fi
}
detect_bootloader
log "Bootloader detected: $BOOTLOADER${BOOTLOADER_CONFIG:+ ($BOOTLOADER_CONFIG)}"

# Disabling CPU mitigations needs two independent choices: the extreme profile and
# --enable-mitigations-off. It is never implied by the default profile.
if [[ "$ENABLE_MITIGATIONS_OFF" == "true" ]]; then
  if [[ -z "$BOOTLOADER_CONFIG" ]]; then
    warn "No supported bootloader was detected; mitigations=off was not written."
  else
    backup_file "$BOOTLOADER_CONFIG"
    case "$BOOTLOADER" in
      limine)
        if sudo grep -qE '^[[:space:]]*KERNEL_CMDLINE\[.*\]=' "$BOOTLOADER_CONFIG"; then
          sudo sed -Ei '/^[[:space:]]*KERNEL_CMDLINE\[.*\]=/ { s/[[:space:]]*mitigations=off//g; s/"$/ mitigations=off"/; }' "$BOOTLOADER_CONFIG" || warn "Limine configuration could not be changed."
        else
          printf '%s\n' 'KERNEL_CMDLINE[default]+=" mitigations=off"' | sudo tee -a "$BOOTLOADER_CONFIG" >/dev/null || warn "Limine kernel parameter could not be added."
        fi
        ;;
      systemd-boot)
        if sudo grep -qE '^[[:space:]]*LINUX_OPTIONS=' "$BOOTLOADER_CONFIG"; then
          sudo sed -Ei '/^[[:space:]]*LINUX_OPTIONS=/ { s/[[:space:]]*mitigations=off//g; s/"$/ mitigations=off"/; }' "$BOOTLOADER_CONFIG" || warn "systemd-boot configuration could not be changed."
        else
          printf '%s\n' 'LINUX_OPTIONS="mitigations=off"' | sudo tee -a "$BOOTLOADER_CONFIG" >/dev/null || warn "systemd-boot kernel parameter could not be added."
        fi
        if [[ -d /etc/kernel ]]; then
          backup_file /etc/kernel/cmdline
          sudo install -d -m 755 /etc/kernel
          sudo grep -qw mitigations=off /etc/kernel/cmdline 2>/dev/null || printf '%s\n' mitigations=off | sudo tee -a /etc/kernel/cmdline >/dev/null
        fi
        ;;
      grub)
        if sudo grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$BOOTLOADER_CONFIG"; then
          sudo sed -Ei '/^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/ { s/[[:space:]]*mitigations=off//g; s/"$/ mitigations=off"/; }' "$BOOTLOADER_CONFIG" || warn "GRUB configuration could not be changed."
        else
          printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="mitigations=off"' | sudo tee -a "$BOOTLOADER_CONFIG" >/dev/null || warn "GRUB kernel parameter could not be added."
        fi
        ;;
      refind)
        if sudo grep -qE '^[[:space:]]*"Boot using default options"' "$BOOTLOADER_CONFIG"; then
          sudo sed -Ei '/^[[:space:]]*"Boot using default options"/ { s/[[:space:]]*mitigations=off//g; s/"$/ mitigations=off"/; }' "$BOOTLOADER_CONFIG" || warn "rEFInd configuration could not be changed."
        else
          warn "rEFInd default option line not found; no incomplete boot option was written."
        fi
        ;;
      kernel-install)
        sudo grep -qw mitigations=off "$BOOTLOADER_CONFIG" || printf '%s\n' mitigations=off | sudo tee -a "$BOOTLOADER_CONFIG" >/dev/null || warn "kernel-install parameter could not be added."
        ;;
    esac
  fi
else
  log "CPU security mitigations stay enabled (use --profile extreme --enable-mitigations-off to opt in)."
fi
log "Watchdog stays active; no nowatchdog parameter is added"
log "Tweaks applied for profile: $PROFILE"

# ---------- 5. PACCACHE HOOK (sicherer Cache-Erhalt bei jedem Update) ----------
step "5/8 PACCACHE HOOK - skipped (no hook on request)"
info "Paccache hook not created on request (no -rk2)"
# DISABLED on request
# sudo mkdir -p /etc/pacman.d/hooks (disabled – Hook auf Wunsch nicht erstellt)
log "Hook skipped (on request)"
# DISABLED

# ---------- 6. SICHERE WARTUNG - Caches, Runtimes und Logs ohne Systemdateien zu beschädigen ----------
step "6/8 SAFE MAINTENANCE - free space, protect rollback and data"
info "Before: Packages=$(pacman -Qq | wc -l) Explizit=$(pacman -Qqe | wc -l) Cache=$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1) Orphans=$(pacman -Qtdq 2>/dev/null | wc -l)"
# BleachBit kann je nach Cleaner Logins, Sprache oder Nutzerdaten betreffen: niemals blind/root ausführen.
info "BleachBit wird nicht automatisch ausgeführt – erst Vorschau prüfen: bleachbit --preview <cleaner>"
# Keine extern nachgeladenen Skripte mit deinem Benutzerkonto ausführen.

# Destructive maintenance is deliberately opt-in. A fresh install usually has no
# meaningful caches, while an existing user may intentionally retain downloads,
# Trash contents, app data or package rollback versions.
if [[ "$RUN_MAINTENANCE" == "true" ]]; then
  info "Run requested maintenance cleanup"
  rm -rf -- "$HOME/.thumbnails/"* "$HOME/.cache/thumbnails/"* "$HOME/.local/share/Trash/"* \
    "$HOME/.cache/mozilla/"* "$HOME/.cache/chromium/"* "$HOME/.cache/google-chrome/"* || warn "Some user cache entries could not be removed."
  sudo systemd-tmpfiles --clean || warn "systemd-tmpfiles cleanup was incomplete."
else
  info "User caches, Trash, package cache and journal history are kept (use --run-maintenance to opt in)."
fi

# Orphans are a review item, never an automatic removal.
ORPHANS_FILE="$LOG_DIR/orphans_${RUN_ID}.txt"
orphans="$(pacman -Qdtq 2>/dev/null || true)"
if [[ -n "$orphans" ]]; then
  printf '%s\n' "$orphans" | tee "$ORPHANS_FILE"
  warn "Possible orphans listed in $ORPHANS_FILE – review before running pacman -Rns."
else
  : > "$ORPHANS_FILE"
  log "No Pacman orphans found"
fi
BROKEN_LINKS_FILE="$LOG_DIR/broken-symlinks_${RUN_ID}.txt"
find "$HOME" -type l ! -exec test -e {} \; -print 2>/dev/null > "$BROKEN_LINKS_FILE" || true
if [[ -s "$BROKEN_LINKS_FILE" ]]; then
  warn "Broken links were only recorded: $BROKEN_LINKS_FILE"
else
  rm -f "$BROKEN_LINKS_FILE"
fi

FLATPAK_CACHE_REPORT="$LOG_DIR/flatpak-caches_${RUN_ID}.txt"
: > "$FLATPAK_CACHE_REPORT"
if [[ -d "$HOME/.var/app" && ! -L "$HOME/.var/app" ]]; then
  while IFS= read -r -d '' cache_dir; do
    du -sh -- "$cache_dir" >> "$FLATPAK_CACHE_REPORT" 2>/dev/null || printf 'unreadable: %q\n' "$cache_dir" >> "$FLATPAK_CACHE_REPORT"
  done < <(find "$HOME/.var/app" -mindepth 2 -maxdepth 2 -type d -name cache -print0 2>/dev/null)
fi
if [[ -s "$FLATPAK_CACHE_REPORT" ]]; then
  info "Flatpak app caches recorded in $FLATPAK_CACHE_REPORT (optional: clean-flatpak-caches --yes)"
else
  rm -f "$FLATPAK_CACHE_REPORT"
  log "No remaining Flatpak app caches found"
fi
info "Steam shader cache and Wine/Proton prefixes are kept (optional: clean-wine-temp --yes <prefix>)"

if [[ "$RUN_MAINTENANCE" == "true" ]]; then
  flatpak uninstall --unused --delete-data -y || warn "Unused Flatpak cleanup was incomplete."
  sudo paccache -rk2 || warn "Pacman cache cleanup was incomplete."
  sudo journalctl --rotate || true
  sudo journalctl --vacuum-time=3d || true
  sudo journalctl --vacuum-size=100M || true
  sudo coredumpctl --vacuum-time=3d || true
  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -r || warn "User font-cache rebuild was incomplete."
    sudo fc-cache -r -s || warn "System font-cache rebuild was incomplete."
  fi
  sudo rm -f /etc/pacman.d/gnupg/*.log || true
  sudo find /var/log -type f \( -name "*.old" -o -name "*.gz" \) -delete || warn "Some legacy log files could not be removed."
  rm -rf -- "$HOME/.cache/icon-cache/"* "$HOME/.local/share/baloo/"* || true
else
  info "Flatpak data, Pacman cache, journals and old log archives are only reported; no maintenance cleanup ran."
fi
info "Documentation, language files and firmware stay package-consistent"

# BTRFS mount state is always reported. Trim timer is safe and enabled by default;
# an online balance is an explicit maintenance operation.
BTRFS_MOUNTS_FILE="$LOG_DIR/btrfs-mounts_${RUN_ID}.txt"
findmnt -rn -t btrfs -o TARGET,SOURCE,OPTIONS | tee "$BTRFS_MOUNTS_FILE"
ROOT_BTRFS_OPTIONS="$(findmnt -n -o OPTIONS / 2>/dev/null || true)"
case ",$ROOT_BTRFS_OPTIONS," in
  *,noatime,*) log "BTRFS root: noatime enabled" ;;
  *) info "BTRFS root: noatime is not set – review $BTRFS_MOUNTS_FILE deliberately" ;;
esac
case ",$ROOT_BTRFS_OPTIONS," in
  *compress=zstd*) log "BTRFS root: Zstd compression enabled" ;;
  *) info "BTRFS root: no Zstd compression detected – fstab is left unchanged" ;;
esac
sudo systemctl enable --now fstrim.timer || warn "fstrim.timer could not be enabled"
if [[ "$RUN_MAINTENANCE" == "true" ]] && [[ $(df / | awk 'NR==2{print $5}' | tr -d '%') -gt 10 ]]; then
  info "Run requested BTRFS balance for lightly used chunks"
  sudo btrfs balance start -dusage=50 -musage=50 / || warn "BTRFS balance was not completed – inspect its output."
elif [[ "$RUN_MAINTENANCE" != "true" ]]; then
  info "BTRFS balance skipped (use --run-maintenance to opt in)."
else
  info "BTRFS balance skipped on a lightly used root filesystem (<10%)."
fi
if [[ "$RUN_MAINTENANCE" == "true" ]]; then
  rm -rf -- "$HOME/.npm/_cacache/"* "$HOME/.yarn/cache/"* "$HOME/.node-gyp/"* "$HOME/.cache/electron/"* || true
  sudo fstrim -av || warn "Manual fstrim was incomplete; the timer remains enabled."
fi
# .pacnew/.pacsave nur protokollieren, nie automatisch löschen.
PACNEW_FILE="$LOG_DIR/pacnew_${RUN_ID}.txt"
info "Prüfe auf .pacnew/.pacsave-Dateien"
find /etc -regextype posix-extended -regex '.+\.pac(new|save)' -print 2>/dev/null > "$PACNEW_FILE" || true
if [[ -s "$PACNEW_FILE" ]]; then
  warn ".pacnew/.pacsave gefunden – manuell prüfen: sudo pacdiff -o"
  cat "$PACNEW_FILE"
else
  log "Keine .pacnew/.pacsave-Dateien"
  rm -f "$PACNEW_FILE"
fi
info "After: Packages=$(pacman -Qq | wc -l) Explizit=$(pacman -Qqe | wc -l) Orphans=$(pacman -Qtdq 2>/dev/null | wc -l)"
info "Nachher Disk: $(df -h / | tail -1 | awk '{print $3"/"$2" used, "$4" free"}' 2>/dev/null) RAM Boot: $(free -h | awk '/Mem:/{print $3"/"$2}' 2>/dev/null)"
log "Maintenance reports completed; cleanup only ran when --run-maintenance was requested"

# ---------- 7. VERIFY INTEGRIERT - Alles in einem Skript ----------
step "7/8 VERIFY - check if everything succeeded (all in ONE script)"
PASS=0; FAIL=0
check(){
  local label="$1"
  shift
  if "$@" &>/dev/null; then
    echo -e "${GREEN}[✓]${NC} $label"
    PASS=$((PASS+1))
  else
    echo -e "${RED}[✖]${NC} $label"
    FAIL=$((FAIL+1))
  fi
}
# vesktop_plugin_config_valid entfernt – oeffentliche Version ohne Vencord

check "Brave" bash -c 'command -v brave-browser >/dev/null || command -v brave >/dev/null'
check "Alacritty" command -v alacritty
check "Mission Center (Taskmanager)" bash -c 'flatpak info io.missioncenter.MissionCenter >/dev/null 2>&1 || command -v missioncenter >/dev/null || pacman -Q plasma-systemmonitor >/dev/null 2>&1'
check "Konsole behalten" command -v konsole
check "Flameshot" command -v flameshot
check "Gimp" command -v gimp
# check "Vesktop-Plugin-Konfiguration" entfernt – oeffentliche Version
# Proton Mail check removed – optional, not everyone wants it
# Proton VPN check removed – optional
check "Bore Kernel" pacman -Q linux-cachyos-bore
if [[ "$GPU_VENDOR" == "nvidia" ]]; then
  check "NVIDIA driver" bash -c 'pacman -Q nvidia-utils >/dev/null 2>&1 && { nvidia-smi >/dev/null 2>&1 || lsmod 2>/dev/null | grep -q nvidia || pacman -Q nvidia-open-dkms >/dev/null 2>&1 || pacman -Q nvidia-dkms >/dev/null 2>&1 || ls /usr/lib/modules/*/extramodules/*nvidia* >/dev/null 2>&1; }'
else
  info "NVIDIA driver check skipped (detected GPU: $GPU_VENDOR)"
fi
if [[ "$ENABLE_MITIGATIONS_OFF" == "true" && -n "$BOOTLOADER_CONFIG" ]]; then
  check "mitigations=off configured ($BOOTLOADER)" grep -qw mitigations=off "$BOOTLOADER_CONFIG"
else
  info "CPU security mitigations remain enabled by selected profile."
fi
check "ZRAM" test -f /etc/systemd/zram-generator.conf
check "Gamemode" command -v gamemoded
check "Spicetify helper" test -x "$HOME/.local/bin/configure-spicetify"
if command -v bleachbit >/dev/null 2>&1 && { pacman -Q stacer-bin >/dev/null 2>&1 || pacman -Q stacer >/dev/null 2>&1; }; then
  check "BleachBit + Stacer" true
else
  info "BleachBit/Stacer are optional; no verification failure recorded."
fi
if [[ -n "$AUR" ]]; then
  check "AUR helper ($AUR)" command -v "$AUR"
else
  info "AUR helper unavailable; AUR-only applications were optional."
fi
if command -v bedrock-on-linux >/dev/null 2>&1 || pacman -Q bedrock-on-linux-bin >/dev/null 2>&1; then
  check "Minecraft Bedrock for Windows" true
else
  info "BedrockOnLinux is optional and was not installed."
fi
# Paccache Hook auf Wunsch entfernt -> nur Info, kein FAIL
if [[ -f /etc/pacman.d/hooks/pacclean.hook ]]; then check "Paccache Hook (pacclean.hook)" bash -c 'test -f /etc/pacman.d/hooks/pacclean.hook'; else info "Paccache hook not created on request (no -rk2)"; fi
if modinfo binder_linux &>/dev/null; then
  check "Waydroid Binder-Autoload" grep -qx binder_linux /etc/modules-load.d/waydroid-binder.conf
else
  info "Waydroid Binder: kein ladbares binder_linux-Modul – keine Autoload-Datei erwartet"
fi
if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null)" == "btrfs" ]]; then
  check "SSD-Trim Timer" systemctl is-enabled fstrim.timer
fi
echo -e "Verify: ${GREEN}$PASS OK${NC} / ${RED}$FAIL FAIL${NC}"
log "Verify done"

# Einen echten Check für nach dem Reboot erzeugen (die frühere Abschlussmeldung verwies auf eine nicht vorhandene Datei).
backup_file "$HOME/system-check.sh"
cat <<'EOF' > "$HOME/system-check.sh"
#!/usr/bin/env bash
set -uo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
check(){
  local label="$1"
  shift
  if "$@" &>/dev/null; then
    echo -e "${GREEN}[✓]${NC} $label"
    PASS=$((PASS+1))
  else
    echo -e "${RED}[✖]${NC} $label"
    FAIL=$((FAIL+1))
  fi
}
check "Bore-Kernel läuft" bash -c 'uname -r | grep -q -- "bore"'
check "Standard-Kernel installiert" pacman -Q linux-cachyos
check "Bore-Kernel installiert" pacman -Q linux-cachyos-bore
if lspci 2>/dev/null | grep -qi nvidia; then
  check "NVIDIA Treiber" bash -c 'pacman -Q nvidia-utils >/dev/null 2>&1 && { nvidia-smi >/dev/null 2>&1 || lsmod 2>/dev/null | grep -q nvidia || pacman -Q nvidia-open-dkms >/dev/null 2>&1; }'
else
  echo -e "\033[0;36m[i] NVIDIA-Treiberprüfung übersprungen (keine NVIDIA-GPU erkannt).\033[0m"
fi
if grep -qw mitigations=off /proc/cmdline; then
  echo -e "\033[1;33m[!] mitigations=off ist aktiv.\033[0m"
else
  echo -e "\033[0;36m[i] CPU-Sicherheitsmitigations bleiben aktiv.\033[0m"
fi
check "ZRAM aktiv" bash -c 'swapon --show=NAME 2>/dev/null | grep -q zram'
check "Mission Center" bash -c 'flatpak info io.missioncenter.MissionCenter >/dev/null 2>&1 || pacman -Q plasma-systemmonitor >/dev/null 2>&1'
check "Alacritty" command -v alacritty
check "Konsole behalten" command -v konsole
check "Spicetify-Helfer" test -x "$HOME/.local/bin/configure-spicetify"
check "Brave" bash -c 'command -v brave-browser >/dev/null || command -v brave >/dev/null'
if modinfo binder_linux &>/dev/null; then
  check "Waydroid Binder-Autoload" grep -qx binder_linux /etc/modules-load.d/waydroid-binder.conf
fi
if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null)" == "btrfs" ]]; then
  check "SSD-Trim Timer" systemctl is-enabled fstrim.timer
  if ! findmnt -n -o OPTIONS / 2>/dev/null | grep -qw noatime; then
    echo -e "\033[1;33m[!] BTRFS ohne noatime — erhöht SSD-Schreiblast\033[0m"
  fi
fi
if command -v paru >/dev/null || command -v yay >/dev/null; then
  check "AUR Helper (paru/yay)" true
else
  echo -e "\033[0;36m[i] Kein AUR-Helper: AUR-Komponenten sind optional.\033[0m"
fi
echo -e "\033[0;36m[i] Kein Paccache-Hook wurde eingerichtet.\033[0m"
check "Bootloader configuration" bash -c 'test -f /etc/default/limine || test -f /etc/sdboot-manage.conf || test -f /etc/default/grub || test -f /boot/refind_linux.conf || test -f /etc/kernel/cmdline'
if command -v bedrock-on-linux >/dev/null 2>&1 || pacman -Q bedrock-on-linux-bin >/dev/null 2>&1; then
  check "Minecraft Bedrock für Windows" true
else
  echo -e "\033[0;36m[i] BedrockOnLinux ist optional und nicht installiert.\033[0m"
fi
echo -e "\nErgebnis: ${GREEN}$PASS OK${NC} / ${RED}$FAIL FAIL${NC}"
exit "$FAIL"
EOF
chmod +x "$HOME/system-check.sh"
log "Post-reboot check created: $HOME/system-check.sh"

# ---------- 8. BOOTLOADER AKTUALISIEREN + REBOOT ----------
step "8/8 BOOTLOADER - apply kernel params for $BOOTLOADER"
case "$BOOTLOADER" in
  limine)
    if command -v limine-mkinitcpio &>/dev/null; then
      sudo limine-mkinitcpio || warn "Limine-Einträge konnten nicht neu erzeugt werden"
    else
      warn "limine-mkinitcpio fehlt – $BOOTLOADER_CONFIG manuell anwenden"
    fi
    ;;
  systemd-boot)
    if command -v sdboot-manage &>/dev/null; then
      sudo sdboot-manage gen || warn "systemd-boot-Einträge konnten nicht neu erzeugt werden"
    else
      warn "sdboot-manage fehlt – $BOOTLOADER_CONFIG manuell anwenden"
    fi
    if command -v bootctl &>/dev/null; then
      sudo bootctl update || warn "bootctl update fehlgeschlagen"
    fi
    ;;
  grub)
    if command -v grub-mkconfig &>/dev/null; then
      sudo grub-mkconfig -o /boot/grub/grub.cfg || warn "GRUB-Konfiguration konnte nicht neu erzeugt werden"
    else
      warn "grub-mkconfig fehlt – $BOOTLOADER_CONFIG manuell anwenden"
    fi
    ;;
  refind)
    log "rEFInd übernimmt Änderungen an $BOOTLOADER_CONFIG direkt; kein Rebuild nötig"
    ;;
  kernel-install)
    if command -v mkinitcpio &>/dev/null; then
      sudo mkinitcpio -P || warn "kernel-install/mkinitcpio konnte nicht neu erzeugt werden"
    else
      warn "Kein mkinitcpio gefunden – $BOOTLOADER_CONFIG manuell anwenden"
    fi
    ;;
  *)
    warn "Bootloader unbekannt – keine blind geratenen Rebuild-Befehle ausgeführt"
    ;;
esac

# ---------- 9/9 FINAL UPDATE - nochmal ALLES am Schluss ----------
step "9/9 FINAL UPDATE - only Flatpak + initramfs (no second pacman -Syu, phase 1 already covers everything)"
flatpak update -y || true
# Only rebuild initramfs if drivers/kernel changed – no repeated pacman -Syu (rarely new packages same day)
sudo mkinitcpio -P || true
if command -v limine-mkinitcpio >/dev/null 2>&1; then sudo limine-mkinitcpio || true; fi
log "Final update done — everything up to date ✅"

# Record exactly what this mutable package ecosystem resolved today. These manifests
# make later rebuilds and troubleshooting substantially more reproducible.
PACMAN_MANIFEST="$LOG_DIR/pacman-explicit_${RUN_ID}.txt"
PACMAN_FOREIGN_MANIFEST="$LOG_DIR/pacman-foreign_${RUN_ID}.txt"
FLATPAK_MANIFEST="$LOG_DIR/flatpak_${RUN_ID}.txt"
RUN_METADATA="$LOG_DIR/run_${RUN_ID}.txt"
pacman -Qqe > "$PACMAN_MANIFEST" || warn "Could not write the explicit Pacman manifest."
pacman -Qm > "$PACMAN_FOREIGN_MANIFEST" || warn "Could not write the foreign/AUR Pacman manifest."
flatpak list --app --columns=application,branch,origin > "$FLATPAK_MANIFEST" || warn "Could not write the Flatpak manifest."
{
  printf 'run_id=%s\nprofile=%s\n' "$RUN_ID" "$PROFILE"
  printf 'mitigations_off=%s\nremove_snapper=%s\nremove_preinstalled_apps=%s\n' "$ENABLE_MITIGATIONS_OFF" "$REMOVE_SNAPPER" "$REMOVE_PREINSTALLED_APPS"
  sha256sum "$0" 2>/dev/null || true
} > "$RUN_METADATA"
if (( ERROR_COUNT > 0 )); then
  warn "Setup reached completion with $ERROR_COUNT logged command error(s). Review $ERROR_LOG and the verification output."
else
  log "No unhandled command errors were recorded."
fi

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Setup completed — review verification before rebooting.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Full log: ${CYAN}$LOG_FILE${NC}"
echo -e "Error log:       ${CYAN}$ERROR_LOG${NC}"
echo -e "Manifest:        ${CYAN}$PACMAN_MANIFEST${NC} (Flatpak: ${CYAN}$FLATPAK_MANIFEST${NC})"
echo -e "Changes/backups: ${CYAN}$CHANGED_FILES${NC} / ${CYAN}$BACKUP_DIR${NC}"
echo -e "1. ${YELLOW}sudo reboot${NC} -> choose Bore kernel in boot menu"
echo -e "2. Afterwards: ${CYAN}~/system-check.sh${NC}"
echo -e "3. Open Spotify once/log in, close, then: ${CYAN}configure-spicetify${NC}"
if command -v bedrock-on-linux >/dev/null 2>&1; then
  echo -e "4. Minecraft Bedrock for Windows: ${CYAN}bedrock-on-linux${NC} start and log in with Microsoft account"
else
  echo -e "4. ${YELLOW}BedrockOnLinux was not installed – check AUR error in log.${NC}"
fi
echo -e "5. Check if needed: ${CYAN}$ORPHANS_FILE${NC}, ${CYAN}$PACNEW_FILE${NC}, ${CYAN}${BTRFS_MOUNTS_FILE:-}${NC} und ${CYAN}${FLATPAK_CACHE_REPORT:-}${NC}"
echo -e "Helper commands: ${CYAN}update-arch  clean-arch  fix-key  update-mirrors  configure-spicetify  clean-flatpak-caches  clean-wine-temp${NC}"
