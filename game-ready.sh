#!/usr/bin/env bash
# game-ready.sh — make a Manjaro/Arch box game-ready, with GE-Proton COMPILED FROM SOURCE.
#
# Run as your NORMAL user (not root). It uses sudo only for the privileged steps
# (pacman, multilib, drivers, sysctl, services, fstab); yay/makepkg/podman run as you.
#
# What it does:
#   - enables [multilib]
#   - full system update (skip with --no-update)
#   - SCANS every GPU + the CPU on ANY machine, works out the latest right driver
#     for each, checks what's already installed, then installs/compiles the gaps:
#       * NVIDIA  -> open kernel modules (nvidia-open-dkms) on Turing+; proprietary on
#                   Maxwell/Pascal/Volta; legacy 470xx/390xx on Kepler/Fermi; +nvidia-prime on hybrids
#       * Intel Arc (A/B-series) -> vulkan-intel + media + compute runtime (+ ReBAR note)
#       * AMD / older Intel -> open mesa (RADV/ANV); --mesa-git compiles bleeding-edge
#       * VM / unknown GPU  -> mesa + lavapipe (vulkan-swrast) software fallback
#       * CPU microcode (intel-ucode / amd-ucode) + linux-firmware
#       * plus Xorg server + input/randr and the 32-bit/Vulkan userspace
#   - installs DRIVE-CONTROL drivers + tools (ntfs3/ntfs-3g, exfat, vfat, btrfs, xfs, f2fs,
#     udf, udisks2, nvme-cli, smartmontools, hdparm, gptfdisk, parted)
#   - installs the gaming stack (Steam, Lutris, Wine-staging, GameMode, MangoHud,
#     Gamescope, VKD3D, vulkan tools, etc.)
#   - bootstraps yay from source if missing, then installs AUR helpers
#     (protontricks, SteamTinkerLaunch, dxvk-bin, vkd3d-proton-bin, protonup-qt)
#   - installs desktop utilities (Thunar, GParted, GIMP, Geany, Zed, nano, Mousepad, …)
#   - sets up Bluetooth + Xbox (xpadneo/xone) and PlayStation (kernel hid) controllers
#   - installs the lib32 (32-bit) audio pipeline so old/32-bit games get sound
#   - installs Heroic (Epic/GOG/Amazon) + Bottles (Wine prefix manager)
#   - installs earlyoom so a RAM-hungry game can't hard-freeze the whole box
#   - sets up MangoHud (one-command on/off via 'mangohud-toggle') and vkBasalt
#   - builds gxvk (3Dfx Glide -> Vulkan) and installs its Glide DLLs for old Glide games
#   - builds d7vk and installs ddraw.dll (DirectDraw / Direct3D 1-7 -> Vulkan) for
#     old-school DirectX 6/7 games (DX8-11 come from DXVK, DX12 from vkd3d-proton)
#   - installs cnc-ddraw + dgVoodoo2 (extra legacy DDraw/Glide/D3D1-8 wrappers),
#     dxvk-nvapi (DLSS/Reflex on NVIDIA), and OBS + obs-vkcapture for recording
#   - installs hex editors (ghex, ImHex, hexedit, radare2) for patching old game code
#     so it runs on modern CPUs, plus a protection watcher: back up the patched file,
#     lock it immutable where the fs allows, and auto-revert it if anything changes
#   - COMPILES the latest GE-Proton from GloriousEggroll's source tree via the
#     official rootless-podman container build (make redist) and installs it into
#     Steam's compatibilitytools.d
#   - applies gaming sysctl/ulimit/CPU-governor tuning
#   - interactive /etc/fstab wizard built from `lsblk -f`: picks your extra drives,
#     writes UUID-based entries with sane per-filesystem options, and FIXES OWNERSHIP
#     so you actually have read/write access (chown for ext/xfs/btrfs/f2fs,
#     uid/gid/umask mount options for FAT/exFAT/NTFS)
#
# Runs fully verbose: pacman -v, git --progress, live build output (makepkg/yay stream by default).
#
# Flags:
#   --no-update      skip the full system upgrade
#   --skip-ge        do everything EXCEPT the GE-Proton source build
#   --skip-gxvk      don't build the gxvk Glide->Vulkan DLLs
#   --gxvk-only      ONLY build + install gxvk's Glide DLLs, then exit
#   --skip-d7vk      don't build the d7vk ddraw (DirectX 1-7) DLL
#   --d7vk-only      ONLY build + install d7vk's ddraw.dll, then exit
#   --gxvk-uninstall remove gxvk's Glide DLLs from the target prefix/game dir
#   --prefix DIR     Wine prefix for gxvk install (default: $WINEPREFIX or ~/.wine)
#   --game-dir DIR   install gxvk's DLLs next to a game's .exe instead of a prefix
#   --ge-only        ONLY compile+install GE-Proton (assumes stack already present)
#   --fstab          ONLY run the interactive lsblk -> /etc/fstab drive setup
#   --skip-fstab     don't offer the fstab drive setup at the end
#   --skip-launchers don't install Heroic + Bottles
#   --skip-audio     don't install the lib32 audio pipeline
#   --skip-overlays  don't install/configure MangoHud toggle + vkBasalt
#   --mesa-git       AMD/Intel: compile bleeding-edge Mesa (RADV/ANV) from the AUR
#   --skip-dgvoodoo  don't download dgVoodoo2 (proprietary DDraw/Glide/D3D1-8 wrapper)
#   --skip-patch-tools  don't install the hex editors / file-protection watcher
#   --protect FILE   back up a (hex-patched) game file, lock it, auto-revert any change
#   --unprotect FILE stop protecting FILE (unlock + forget it; backup is kept)
#   --protect-restore FILE   restore FILE from its protected backup now
#   --protect-status list protected files, their state, and backup paths
#   --backup-path DIR  where protected backups are stored (used with --protect)
#   --build-dir DIR  where to clone+build GE-Proton (default: ~/ge-proton-build)
#   --clean-build    delete the heavy build tree after a successful GE install
#   --yes            don't prompt before the long GE build
#   -h | --help      this help

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# config / state
# ─────────────────────────────────────────────────────────────────────────────
DO_UPDATE=1
DO_GE=1
DO_FSTAB=1
DO_GXVK=1
DO_D7VK=1
DO_LAUNCHERS=1
DO_AUDIO32=1
DO_OVERLAYS=1
DO_MESA_GIT=0
DO_DGVOODOO=1
DGVOODOO_BASE="http://dege.freeweb.hu"
GXVK_ONLY=0
D7VK_ONLY=0
GXVK_UNINSTALL=0
GXVK_PREFIX=""
GXVK_GAME_DIR=""
GE_ONLY=0
FSTAB_ONLY=0
CLEAN_BUILD=0
ASSUME_YES=0
BUILD_DIR="$HOME/ge-proton-build"
# game-file patching + protection
DO_PATCHTOOLS=1
PROTECT_FILE=""; UNPROTECT_FILE=""; RESTORE_FILE=""; PROTECT_STATUS=0; BACKUP_PATH=""
GR_DIR="$HOME/.local/share/game-ready"
GR_MANIFEST="$GR_DIR/protected.tsv"
GR_BACKUPS_DEFAULT="$GR_DIR/backups"
GE_FAILED=0
GE_TAG=""
SUDO_KEEPALIVE_PID=""
LOG="$HOME/game-ready-$(date +%Y%m%d-%H%M%S).log"
PACMAN_V=(-v)          # full verbose pacman transactions

GE_REPO_URL="https://github.com/GloriousEggroll/proton-ge-custom.git"   # US-hosted
GE_MIN_FREE_GB=30                                                       # per-fs headroom

# ─────────────────────────────────────────────────────────────────────────────
# logging
# ─────────────────────────────────────────────────────────────────────────────
c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_red=$'\e[31m'; c_grn=$'\e[32m'
c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_cyn=$'\e[36m'
_ts(){ date +%H:%M:%S; }
info(){ printf '%s %b==>%b %s\n' "$(_ts)" "$c_cyn" "$c_reset" "$*" | tee -a "$LOG" >&2; }
ok(){   printf '%s %b[ok]%b %s\n'   "$(_ts)" "$c_grn" "$c_reset" "$*" | tee -a "$LOG" >&2; }
warn(){ printf '%s %b[warn]%b %s\n' "$(_ts)" "$c_ylw" "$c_reset" "$*" | tee -a "$LOG" >&2; }
err(){  printf '%s %b[err]%b %s\n'  "$(_ts)" "$c_red" "$c_reset" "$*" | tee -a "$LOG" >&2; }
hdr(){  printf '\n%b%b── %s%b\n' "$c_bold" "$c_blu" "$*" "$c_reset" | tee -a "$LOG" >&2; }
die(){ err "$*"; exit 1; }

usage(){ awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
# args
# ─────────────────────────────────────────────────────────────────────────────
parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-update)   DO_UPDATE=0 ;;
      --skip-ge)     DO_GE=0 ;;
      --ge-only)     GE_ONLY=1 ;;
      --fstab)       FSTAB_ONLY=1 ;;
      --skip-fstab)  DO_FSTAB=0 ;;
      --skip-launchers) DO_LAUNCHERS=0 ;;
      --skip-audio)     DO_AUDIO32=0 ;;
      --skip-overlays)  DO_OVERLAYS=0 ;;
      --mesa-git)       DO_MESA_GIT=1 ;;
      --skip-dgvoodoo)  DO_DGVOODOO=0 ;;
      --skip-gxvk)   DO_GXVK=0 ;;
      --gxvk-only)      GXVK_ONLY=1 ;;
      --skip-d7vk)      DO_D7VK=0 ;;
      --d7vk-only)      D7VK_ONLY=1 ;;
      --gxvk-uninstall) GXVK_UNINSTALL=1 ;;
      --prefix)         shift; GXVK_PREFIX="${1:?--prefix needs a path}" ;;
      --game-dir)       shift; GXVK_GAME_DIR="${1:?--game-dir needs a path}" ;;
      --skip-patch-tools) DO_PATCHTOOLS=0 ;;
      --protect)         shift; PROTECT_FILE="${1:?--protect needs a file}" ;;
      --unprotect)       shift; UNPROTECT_FILE="${1:?--unprotect needs a file}" ;;
      --protect-restore) shift; RESTORE_FILE="${1:?--protect-restore needs a file}" ;;
      --protect-status)  PROTECT_STATUS=1 ;;
      --backup-path)     shift; BACKUP_PATH="${1:?--backup-path needs a dir}" ;;
      --clean-build) CLEAN_BUILD=1 ;;
      --yes|-y)      ASSUME_YES=1 ;;
      --build-dir)   shift; [[ $# -gt 0 ]] || die "--build-dir needs a path"; BUILD_DIR="$1" ;;
      -h|--help)     usage ;;
      *)             die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

confirm(){ (( ASSUME_YES )) && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
ask_yn(){ local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }   # always asks, ignores --yes

# ─────────────────────────────────────────────────────────────────────────────
# preflight + sudo
# ─────────────────────────────────────────────────────────────────────────────
hard_checks(){
  [[ $EUID -ne 0 ]] || die "run as your normal user, NOT root (makepkg/podman refuse root). Don't launch this with sudo."
  command -v pacman &>/dev/null || die "pacman not found — this is for Arch/Manjaro."
  command -v sudo   &>/dev/null || die "sudo is required."
  info "logging to $LOG"
}

prime_sudo(){
  info "priming sudo (you'll be asked once)"
  sudo -v || die "sudo authentication failed"
  ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'rc=$?; [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; exit $rc' EXIT INT TERM
}

ensure_tool(){ command -v "$1" &>/dev/null || sudo pacman -S --needed --noconfirm "$2" &>/dev/null || warn "could not install $2"; }

# install wanted packages: already-installed skipped, real repo names batched
# through pacman, and anything not found in a repo auto-routed to yay (AUR) so a
# single AUR-only name can't abort the whole pacman transaction. never aborts.
pac_install(){
  local want=("$@") repo=() aur=() p
  for p in "${want[@]}"; do
    pacman -Qq "$p" &>/dev/null && continue
    if pacman -Si "$p" &>/dev/null; then repo+=("$p"); else aur+=("$p"); fi
  done
  if ((${#repo[@]})); then
    info "pacman: ${repo[*]}"
    sudo pacman "${PACMAN_V[@]}" -S --needed --noconfirm "${repo[@]}" || warn "pacman batch failed: ${repo[*]}"
  fi
  if ((${#aur[@]})); then
    if command -v yay &>/dev/null; then aur_install "${aur[@]}"
    else warn "not in repos and yay not yet available: ${aur[*]}"; fi
  fi
  ((${#repo[@]}+${#aur[@]})) || ok "already present: ${want[*]}"
}

aur_install(){
  info "yay (repo+AUR): $*"
  yay -S --needed --noconfirm --answerdiff=None --answerclean=None --removemake "$@" \
    || warn "some AUR packages failed: $*"
}

# ─────────────────────────────────────────────────────────────────────────────
# multilib
# ─────────────────────────────────────────────────────────────────────────────
enable_multilib(){
  hdr "Multilib repository"
  if pacman-conf --repo-list 2>/dev/null | grep -qx multilib; then
    ok "multilib already enabled"; return
  fi
  if grep -qE '^[[:space:]]*#[[:space:]]*\[multilib\]' /etc/pacman.conf; then
    info "uncommenting [multilib] in /etc/pacman.conf"
    sudo sed -i '/^[[:space:]]*#[[:space:]]*\[multilib\]/{s/^[[:space:]]*#[[:space:]]*//; n; s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
  elif ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
    info "appending [multilib] to /etc/pacman.conf"
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
  fi
  sudo pacman "${PACMAN_V[@]}" -Syy || warn "database refresh failed"
  ok "multilib enabled"
}

# ─────────────────────────────────────────────────────────────────────────────
# system update
# ─────────────────────────────────────────────────────────────────────────────
system_update(){
  hdr "System update"
  sudo pacman "${PACMAN_V[@]}" -Syu --noconfirm --ignore libcap,lib32-libcap || warn "full upgrade reported issues — continuing"
}

# ─────────────────────────────────────────────────────────────────────────────
# GPU detection
# ─────────────────────────────────────────────────────────────────────────────
HAS_NVIDIA=0; HAS_AMD=0; HAS_INTEL=0; HAS_INTEL_ARC=0; HAS_GENERIC=0; NVIDIA_GEN=open
CPU_VENDOR=""
# NVIDIA driver package for the detected generation (DKMS = compiled on install)
nvidia_pkg(){
  case "$NVIDIA_GEN" in
    open)         echo nvidia-open-dkms ;;
    proprietary)  echo nvidia-dkms ;;
    kepler)       echo nvidia-470xx-dkms ;;
    fermi)        echo nvidia-390xx-dkms ;;
    *)            echo nvidia-dkms ;;
  esac
}

# installed / available version helpers (available falls back to the AUR via yay)
pkg_inst_ver(){ pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }
pkg_avail_ver(){
  local v; v="$(pacman -Si "$1" 2>/dev/null | awk -F': +' '/^Version/{print $2; exit}')"
  [[ -z "$v" ]] && command -v yay &>/dev/null && v="$(yay -Si "$1" 2>/dev/null | awk -F': +' '/^Version/{print $2; exit}')"
  printf '%s' "$v"
}
# report + decide: prints "pkg  installed -> available  [ACTION]"
report_pkg(){
  local pkg="$1" inst avail
  inst="$(pkg_inst_ver "$pkg")"; avail="$(pkg_avail_ver "$pkg")"
  if   [[ -z "$inst" ]];                      then printf '   %-26s (not installed) -> %-14s [WILL INSTALL]\n' "$pkg" "${avail:-?}"
  elif [[ -n "$avail" && "$inst" != "$avail" ]]; then printf '   %-26s %-14s -> %-14s [UPDATE]\n' "$pkg" "$inst" "$avail"
  else printf '   %-26s %-14s [up-to-date]\n' "$pkg" "$inst"; fi
}

detect_gpu(){
  hdr "System scan — GPU(s) + CPU"
  ensure_tool lspci pciutils

  # CPU vendor (for microcode)
  if   grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then CPU_VENDOR=intel
  elif grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then CPU_VENDOR=amd; fi
  info "CPU: $(LC_ALL=C lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}' || echo unknown) [${CPU_VENDOR:-?}]"

  local vga; vga="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display' || true)"
  info "GPU(s) detected:"; printf '%s\n' "$vga" | sed 's/^/   /' | tee -a "$LOG" >&2
  grep -qi 'nvidia'          <<<"$vga" && HAS_NVIDIA=1
  grep -qiE 'amd|ati|radeon' <<<"$vga" && HAS_AMD=1
  grep -qi 'intel'           <<<"$vga" && HAS_INTEL=1
  # virtual / unknown GPUs (VMs, basic display) -> software Vulkan fallback
  grep -qiE 'virtio|qxl|cirrus|bochs|vmware|innotek|microsoft (corporation )?basic|red hat' <<<"$vga" && HAS_GENERIC=1

  # Intel Arc / discrete Intel (Alchemist A-series, Battlemage B-series)
  if grep -qiE 'intel.*(arc|dg2|alchemist|battlemage|a3[0-9]0|a5[0-9]0|a7[0-9]0|b5[0-9]0|b7[0-9]0)' <<<"$vga"; then
    HAS_INTEL_ARC=1
  fi

  # NVIDIA codename -> branch. Open modules (nvidia-open-dkms, current default)
  # support Turing+ ONLY; Maxwell/Pascal/Volta -> proprietary; older -> legacy.
  if (( HAS_NVIDIA )); then
    local code pfx
    code="$(grep -i nvidia <<<"$vga" | grep -oE '\b[A-Z]{2}[0-9]{3}\b' | head -1)"
    pfx="${code:0:2}"
    case "$pfx" in
      GF)              NVIDIA_GEN=fermi ;;
      GK)              NVIDIA_GEN=kepler ;;
      GM|GP|GV)        NVIDIA_GEN=proprietary ;;
      TU|GA|AD|GH|GB)  NVIDIA_GEN=open ;;
      *)               NVIDIA_GEN=open ;;
    esac
    info "NVIDIA chip ${code:-unknown} -> $NVIDIA_GEN branch"
  fi

  (( HAS_NVIDIA+HAS_AMD+HAS_INTEL )) || { HAS_GENERIC=1; warn "no known GPU vendor matched — using mesa + software Vulkan (lavapipe)."; }

  # ---- driver plan (what the latest correct driver is, per device) -----------
  info "Driver plan (latest correct driver for each device):"
  (( HAS_NVIDIA )) && info "   NVIDIA : $(nvidia_pkg)  (DKMS — compiled against your kernel)$([[ $NVIDIA_GEN == open ]] && echo '  [open kernel modules]')"
  if (( HAS_AMD )); then
    if (( DO_MESA_GIT )); then info "   AMD    : mesa-git + lib32-mesa-git  (RADV, COMPILED from source)"
    else info "   AMD    : vulkan-radeon (RADV) — latest stable mesa"; fi
  fi
  if (( HAS_INTEL )); then
    if (( DO_MESA_GIT )); then info "   Intel  : mesa-git + lib32-mesa-git  (ANV, COMPILED)$([[ $HAS_INTEL_ARC == 1 ]] && echo ' + Arc runtime')"
    else info "   Intel  : vulkan-intel (ANV)$([[ $HAS_INTEL_ARC == 1 ]] && echo ' + intel-compute-runtime + vpl-gpu-rt (Arc)')"; fi
  fi
  (( HAS_GENERIC )) && info "   Generic: mesa + vulkan-swrast (lavapipe software Vulkan)"
}

# ─────────────────────────────────────────────────────────────────────────────
# GPU userspace (32-bit + Vulkan); does NOT touch kernel modules
# ─────────────────────────────────────────────────────────────────────────────
install_microcode(){
  hdr "CPU microcode"
  case "$CPU_VENDOR" in
    intel) pac_install intel-ucode ;;
    amd)   pac_install amd-ucode ;;
    *)     warn "unknown CPU vendor — skipping microcode."; return ;;
  esac
  # make sure the bootloader actually loads it
  if   command -v update-grub &>/dev/null;            then sudo update-grub 2>/dev/null || true
  elif [[ -f /boot/grub/grub.cfg ]];                  then sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
  elif command -v bootctl &>/dev/null && [[ -d /boot/loader ]]; then warn "systemd-boot: ensure your entry has 'initrd /${CPU_VENDOR}-ucode.img' before the main initramfs."
  fi
  ok "${CPU_VENDOR}-ucode ensured (loads on next boot)."
}

install_gpu_userspace(){
  hdr "GPU userspace (32-bit + Vulkan)"
  local pkgs=( vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools mesa-utils linux-firmware )

  if (( DO_MESA_GIT )) && (( HAS_AMD || HAS_INTEL || HAS_GENERIC )); then
    warn "compiling Mesa-git (bleeding-edge RADV/ANV) from the AUR — replaces repo mesa, long build."
    aur_install mesa-git lib32-mesa-git            # provides the vulkan ICDs too
  else
    pkgs+=( mesa lib32-mesa )
    (( HAS_AMD ))     && pkgs+=( vulkan-radeon lib32-vulkan-radeon )
    (( HAS_INTEL ))   && pkgs+=( vulkan-intel lib32-vulkan-intel )
    (( HAS_GENERIC )) && pkgs+=( vulkan-swrast )   # lavapipe software Vulkan (VMs / unknown GPUs)
  fi

  # layer/media/compute packages are independent of the mesa vs mesa-git choice
  (( HAS_AMD ))       && pkgs+=( vulkan-mesa-layers lib32-vulkan-mesa-layers libva-mesa-driver lib32-libva-mesa-driver )
  (( HAS_INTEL ))     && pkgs+=( intel-media-driver vulkan-mesa-layers lib32-vulkan-mesa-layers )
  (( HAS_INTEL_ARC )) && pkgs+=( intel-compute-runtime vpl-gpu-rt )
  (( HAS_NVIDIA ))    && pkgs+=( nvidia-utils lib32-nvidia-utils opencl-nvidia lib32-opencl-nvidia nvidia-settings )

  pac_install "${pkgs[@]}"

  # report what the Vulkan/driver packages ended up at
  info "driver package status:"
  (( HAS_NVIDIA )) && { report_pkg "$(nvidia_pkg)"; report_pkg nvidia-utils; }
  if (( DO_MESA_GIT )); then
    report_pkg mesa-git
  else
    report_pkg mesa
    (( HAS_AMD ))   && report_pkg vulkan-radeon
    (( HAS_INTEL )) && report_pkg vulkan-intel
    (( HAS_GENERIC )) && report_pkg vulkan-swrast
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# screen / display drivers (Xorg + GPU kernel module)
# ─────────────────────────────────────────────────────────────────────────────
# install matching kernel headers for every installed kernel (needed by DKMS modules)
install_kernel_headers(){
  local k
  for k in $(pacman -Qq 2>/dev/null | grep -E '^linux[0-9]*$'); do pac_install "${k}-headers"; done
}

# install the right NVIDIA driver for the detected generation (open modules on
# Turing+, proprietary on Maxwell/Pascal/Volta, legacy 470xx/390xx on older).
# DKMS packages so it works on any kernel / any Arch-based distro.
install_nvidia_driver(){
  install_kernel_headers
  case "$NVIDIA_GEN" in
    fermi)
      warn "Fermi NVIDIA (GF): legacy 390xx branch from the AUR (open modules N/A)."
      aur_install nvidia-390xx-dkms nvidia-390xx-utils lib32-nvidia-390xx-utils ;;
    kepler)
      warn "Kepler NVIDIA (GK): legacy 470xx branch from the AUR (open modules N/A)."
      aur_install nvidia-470xx-dkms nvidia-470xx-utils lib32-nvidia-470xx-utils ;;
    open)
      info "installing NVIDIA OPEN kernel modules (nvidia-open-dkms) — latest, recommended for Turing+"
      pac_install nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings ;;
    proprietary|*)
      info "installing NVIDIA proprietary module (nvidia-dkms) — required for Maxwell/Pascal/Volta"
      pac_install nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings ;;
  esac
  # hybrid laptop (NVIDIA + iGPU): prime-run offload helper
  (( HAS_INTEL || HAS_AMD )) && pac_install nvidia-prime
  # DLSS / Reflex (NVAPI) under Proton/Wine — GE-Proton bundles this, system copy helps Lutris
  aur_install dxvk-nvapi lib32-dxvk-nvapi
  warn "reboot required for the NVIDIA kernel module to load."
}

install_display_drivers(){
  hdr "Screen / display drivers"
  pac_install xorg-server xorg-xinit xorg-xrandr xf86-input-libinput libva-utils

  # NVIDIA: install the right module ourselves so the OPEN-module choice is
  # guaranteed on any distro (not left to mhwd, which would pull the proprietary
  # kernel-bound module). mhwd still handles AMD/Intel + hybrid X config.
  if (( HAS_NVIDIA )); then
    if command -v mhwd &>/dev/null && mhwd -li 2>/dev/null | grep -q 'video-nvidia'; then
      warn "a proprietary mhwd NVIDIA config is already installed; to switch to open modules first run: sudo mhwd -r pci video-nvidia"
    fi
    install_nvidia_driver
  elif command -v mhwd &>/dev/null; then
    info "mhwd: auto-installing open GPU drivers (AMD/Intel)"
    sudo mhwd -a pci nonfree 0300 || warn "mhwd auto-install reported an issue (non-fatal)"
  fi

  # Post-check / per-vendor notes
  if (( HAS_NVIDIA )); then
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
      ok "NVIDIA active ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1))"
    else
      warn "NVIDIA module installed via DKMS; it loads after a reboot. If 'nvidia-smi' still fails, check 'dkms status'."
    fi
    (( HAS_INTEL || HAS_AMD )) && info "hybrid laptop: run games on the NVIDIA GPU with  prime-run <cmd>  (Steam: prime-run %command%)."
  fi
  (( HAS_INTEL_ARC )) && warn "Intel Arc: needs kernel >= 6.2 (Alchemist) / a current kernel (Battlemage) and Resizable BAR (ReBAR/SAM) enabled in BIOS, or performance will be poor."
  (( HAS_AMD ))   && ok "AMD: open amdgpu/RADV mesa stack is the correct driver (installed)."
  (( HAS_INTEL && ! HAS_INTEL_ARC )) && ok "Intel iGPU: open i915/ANV mesa stack is the correct driver (installed)."
}

# ─────────────────────────────────────────────────────────────────────────────
# drive-control drivers + disk tools
# ─────────────────────────────────────────────────────────────────────────────
install_storage_drivers(){
  hdr "Drive-control drivers & disk tools"
  # filesystem userspace (ntfs-3g covers NTFS write where ntfs3 isn't used), plus
  # exfat/vfat/btrfs/xfs/f2fs/udf, the mount daemon, and SMART/NVMe/partition tools.
  pac_install \
    ntfs-3g exfatprogs dosfstools e2fsprogs btrfs-progs xfsprogs f2fs-tools udftools \
    udisks2 gvfs gvfs-mtp \
    nvme-cli smartmontools hdparm gptfdisk parted
}

# ─────────────────────────────────────────────────────────────────────────────
# core gaming stack (audio stack deliberately left untouched)
# ─────────────────────────────────────────────────────────────────────────────
install_core_packages(){
  hdr "Core gaming stack"
  pac_install \
    steam steam-native-runtime lutris \
    wine-staging winetricks wine-gecko wine-mono \
    vkd3d lib32-vkd3d \
    gamemode lib32-gamemode gamescope mangohud lib32-mangohud goverlay \
    cpupower nvtop lm_sensors earlyoom
}

# ─────────────────────────────────────────────────────────────────────────────
# yay + AUR
# ─────────────────────────────────────────────────────────────────────────────
ensure_yay(){
  hdr "yay (AUR helper)"
  if command -v yay &>/dev/null; then ok "yay present: $(yay --version 2>/dev/null | head -1)"; return; fi
  # Manjaro ships yay in its own repos — use that (no build, no sudo-timeout)
  if pacman -Si yay &>/dev/null; then
    info "installing yay from repo"
    if sudo pacman "${PACMAN_V[@]}" -S --needed --noconfirm yay && command -v yay &>/dev/null; then
      ok "yay installed (repo)"; return
    fi
    warn "repo yay install failed — falling back to a source build"
  fi
  info "installing git + base-devel"
  sudo pacman "${PACMAN_V[@]}" -S --needed --noconfirm git base-devel || die "could not install git/base-devel"
  local tmp; tmp="$(mktemp -d)"
  info "cloning + building yay-bin"
  git clone --verbose --progress https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" || die "git clone yay-bin failed"
  # build as user, then install with a freshly-primed sudo so the password prompt
  # can't time out mid-build the way 'makepkg -si' does when you step away
  sudo -v || die "sudo expired — re-run the script"
  ( cd "$tmp/yay-bin" && makepkg -sf --noconfirm ) || die "makepkg yay-bin build failed"
  sudo -v
  sudo pacman -U --noconfirm "$tmp"/yay-bin/*.pkg.tar.* || die "installing built yay-bin failed"
  rm -rf "$tmp"
  command -v yay &>/dev/null && ok "yay installed (source)" || die "yay still missing after build"
}

install_aur_packages(){
  hdr "AUR helpers"
  aur_install protontricks steamtinkerlaunch dxvk-bin vkd3d-proton-bin protonup-qt
  if command -v steamtinkerlaunch &>/dev/null; then
    steamtinkerlaunch compat add &>/dev/null || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# desktop apps & utilities
# ─────────────────────────────────────────────────────────────────────────────
install_desktop_apps(){
  hdr "Desktop apps & utilities"
  # Thunar + mounting/thumbnails/archive companions, editors, image + partition tools.
  # 'zed' auto-routes to the AUR if it isn't in a repo on your mirror.
  pac_install \
    thunar thunar-volman thunar-archive-plugin tumbler xarchiver \
    gparted gimp \
    geany geany-plugins zed nano mousepad
}

# ─────────────────────────────────────────────────────────────────────────────
# Bluetooth + game controllers (Xbox / PlayStation)
# ─────────────────────────────────────────────────────────────────────────────
install_controller_support(){
  hdr "Bluetooth + game controllers"
  pac_install bluez bluez-utils

  # power the adapter on at boot + start it now
  [[ -f /etc/bluetooth/main.conf ]] && sudo sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf 2>/dev/null || true
  sudo systemctl enable --now bluetooth.service 2>/dev/null || warn "bluetooth.service didn't start now (starts on boot)"

  # kernel headers for the DKMS drivers, one package per installed kernel
  local k
  for k in $(pacman -Qq 2>/dev/null | grep -E '^linux[0-9]*$'); do pac_install "${k}-headers"; done

  # Xbox One/Series: xpadneo = Bluetooth (rumble, battery, correct mapping); xone = wireless dongle
  aur_install xpadneo-dkms xone-dkms game-devices-udev
  # Xbox controllers won't pair over BT on Linux unless ERTM is disabled — the known fix
  echo 'options bluetooth disable_ertm=1' | sudo tee /etc/modprobe.d/disable-ertm.conf >/dev/null

  # PlayStation DS4/DualSense pair over BT via the in-kernel hid-sony / hid-playstation
  # drivers (nothing to install); dualsensectl adds LED/battery control for DualSense
  aur_install dualsensectl

  ok "Bluetooth on — pair with 'bluetoothctl' (scan on / pair <MAC> / connect <MAC>)."
  ok "Xbox: hold the pair button till it flashes.  PlayStation: hold PS + Share/Create till the bar flashes."
}

# ─────────────────────────────────────────────────────────────────────────────
# GE-Proton — compile from source (official rootless-podman build)
# ─────────────────────────────────────────────────────────────────────────────
ensure_rootless_podman(){
  pac_install podman fuse-overlayfs slirp4netns git
  local u; u="$(id -un)"
  if ! grep -q "^${u}:" /etc/subuid 2>/dev/null || ! grep -q "^${u}:" /etc/subgid 2>/dev/null; then
    info "configuring subuid/subgid for rootless podman"
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$u" || warn "usermod subuid/subgid failed"
    podman system migrate 2>/dev/null || true
  fi
  if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -d "${XDG_RUNTIME_DIR:-/nonexistent}" ]]; then
    if [[ -d "/run/user/$(id -u)" ]]; then export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    else export XDG_RUNTIME_DIR="$(mktemp -d)"; fi
    info "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
  fi
}

check_free_gb(){ df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

install_ge_tarball(){
  local tgz="$1" tag="$2" installed=0 d
  local dests=( "$HOME/.local/share/Steam/compatibilitytools.d" )
  [[ -d "$HOME/.steam/root" ]] && dests+=( "$HOME/.steam/root/compatibilitytools.d" )
  for d in "${dests[@]}"; do
    mkdir -p "$d" || { warn "could not create $d"; continue; }
    rm -rf "${d:?}/${tag:?}" 2>/dev/null || true
    info "installing $tag -> $d"
    if tar -xf "$tgz" -C "$d"; then installed=1; else warn "extract to $d failed"; fi
  done
  cp -f "$tgz" "$HOME/" 2>/dev/null || true
  if (( installed )); then
    ok "GE-Proton $tag installed. Tarball copy: $HOME/$(basename "$tgz")"
    (( CLEAN_BUILD )) && { info "removing build tree"; rm -rf "$BUILD_DIR/proton-ge-custom/build"; }
    return 0
  fi
  err "could not install the GE-Proton tarball"; return 1
}

build_ge_proton(){
  hdr "GE-Proton — compile from source"
  if ! confirm "Compile the latest GE-Proton from source now? (several GB download + ~1–3h build)"; then
    warn "skipping GE-Proton build (per prompt). Re-run later with --ge-only --yes."
    return 0
  fi

  ensure_rootless_podman
  mkdir -p "$BUILD_DIR" || { err "cannot create $BUILD_DIR"; return 1; }

  local bfree hfree
  bfree="$(check_free_gb "$BUILD_DIR")"; hfree="$(check_free_gb "$HOME")"
  info "free space — build dir: ${bfree:-?}G, home: ${hfree:-?}G (need ~${GE_MIN_FREE_GB}G each)"
  if [[ -n "$bfree" && "$bfree" -lt "$GE_MIN_FREE_GB" ]]; then
    err "not enough free space in $BUILD_DIR (${bfree}G < ${GE_MIN_FREE_GB}G). Use --build-dir on a bigger disk, then --ge-only."; return 1
  fi
  if [[ -n "$hfree" && "$hfree" -lt "$GE_MIN_FREE_GB" ]]; then
    err "not enough free space in \$HOME (${hfree}G < ${GE_MIN_FREE_GB}G) — podman stores images under ~/.local/share/containers."; return 1
  fi

  local repo="$BUILD_DIR/proton-ge-custom"
  if [[ -d "$repo/.git" ]]; then
    info "updating existing checkout"
    git -C "$repo" fetch --tags --force --prune --progress || warn "git fetch failed"
  else
    info "cloning proton-ge-custom with submodules (large)"
    git clone --recurse-submodules --verbose --progress "$GE_REPO_URL" "$repo" || { err "clone failed"; return 1; }
  fi

  GE_TAG="$(git -C "$repo" tag -l 'GE-Proton*' | sort -V | tail -1)"
  [[ -n "$GE_TAG" ]] || { err "could not determine latest GE-Proton tag"; return 1; }
  info "building $GE_TAG"

  git -C "$repo" checkout -f "$GE_TAG"                          || { err "checkout $GE_TAG failed"; return 1; }
  git -C "$repo" submodule update --init --recursive --progress || { err "submodule update failed"; return 1; }

  info "applying Valve/staging prep patches"
  ( cd "$repo" && ./patches/protonprep-valve-staging.sh ) || { err "protonprep-valve-staging.sh failed"; return 1; }

  rm -rf "$repo/build"; mkdir -p "$repo/build"
  info "configuring (container-engine=podman)"
  ( cd "$repo/build" && ../configure.sh --container-engine=podman ) || { err "configure.sh failed"; return 1; }

  info "make redist — first run pulls the Proton SDK image and compiles everything. Grab a coffee (or three)."
  ( cd "$repo/build" && make redist ) || { err "make redist failed — see $LOG and $repo/build"; return 1; }

  local tgz
  tgz="$(find "$repo/build" -maxdepth 3 -type f -name 'GE-Proton*.tar.*' 2>/dev/null | sort -V | tail -1)"
  [[ -n "$tgz" ]] || { err "build finished but no GE-Proton tarball found under $repo/build"; return 1; }

  install_ge_tarball "$tgz" "$GE_TAG"
}

# ─────────────────────────────────────────────────────────────────────────────
# gxvk — 3Dfx Glide -> Vulkan (DXVK frontend) for old Glide games
# ─────────────────────────────────────────────────────────────────────────────
_gxvk_resolve_target(){
  GXVK_TGT=""; GXVK_TGT_DESC=""; GXVK_PFX=""
  if [[ -n "$GXVK_GAME_DIR" ]]; then
    GXVK_TGT="$GXVK_GAME_DIR"; GXVK_TGT_DESC="game dir $GXVK_GAME_DIR"; return
  fi
  GXVK_PFX="${GXVK_PREFIX:-${WINEPREFIX:-$HOME/.wine}}"
  if   [[ -d "$GXVK_PFX/drive_c/windows/syswow64" ]]; then GXVK_TGT="$GXVK_PFX/drive_c/windows/syswow64"; GXVK_TGT_DESC="$GXVK_PFX (syswow64)"
  elif [[ -d "$GXVK_PFX/drive_c/windows/system32" ]]; then GXVK_TGT="$GXVK_PFX/drive_c/windows/system32"; GXVK_TGT_DESC="$GXVK_PFX (system32)"; fi
}

gxvk_uninstall(){
  hdr "gxvk uninstall"
  local d f removed=0 dirs
  _gxvk_resolve_target
  if [[ -n "$GXVK_GAME_DIR" ]]; then dirs=("$GXVK_GAME_DIR")
  else dirs=("$GXVK_PFX/drive_c/windows/syswow64" "$GXVK_PFX/drive_c/windows/system32"); fi
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in glide.dll glide2x.dll glide3x.dll; do
      [[ -f "$d/$f" ]] || continue
      rm -f "$d/$f" && { removed=1; info "removed $d/$f"; }
      [[ -f "$d/$f.gxvk-bak" ]] && mv "$d/$f.gxvk-bak" "$d/$f" && info "restored original $f"
    done
  done
  (( removed )) && ok "gxvk DLLs removed." || warn "no gxvk DLLs found to remove."
}

build_install_gxvk(){
  hdr "gxvk (3Dfx Glide -> Vulkan)"
  pac_install meson ninja mingw-w64-gcc glslang git
  if ! command -v i686-w64-mingw32-g++ &>/dev/null \
     || ! command -v i686-w64-mingw32-windres &>/dev/null \
     || { ! command -v glslang &>/dev/null && ! command -v glslangValidator &>/dev/null; }; then
    warn "gxvk build tools missing (mingw-w64-gcc / glslang) — skipping gxvk."
    return 0
  fi

  local root src build ver stage pfx tgt n f
  local -A dll
  root="$(mktemp -d /tmp/gxvk-build.XXXXXX)"
  src="$root/gxvk"
  info "cloning gxvk + submodules (GitHub)"
  if ! git clone --recursive https://github.com/CkNoSFeRaTU/gxvk.git "$src" >>"$LOG" 2>&1; then
    warn "gxvk clone failed (network?) — skipping."; rm -rf "$root"; return 0
  fi
  ver="$(cat "$src/RELEASE" 2>/dev/null || echo unknown)"

  # upstream glide3x DLL links glide2x_extra_dep instead of glide3x_extra_dep
  awk '
  /shared_library\(dxvk_name_prefix\+.glide3x./ { g=1 }
  g && /glide2x_extra_dep, glide_common_dep/ { sub(/glide2x_extra_dep/, "glide3x_extra_dep"); g=0 }
  { print }
  ' "$src/src/glide/meson.build" > "$src/src/glide/meson.build.new" \
    && mv "$src/src/glide/meson.build.new" "$src/src/glide/meson.build"

  build="$root/build32"
  info "building gxvk $ver (32-bit Glide DLLs)"
  if ! ( cd "$src" && meson setup --cross-file "$src/build-win32.txt" --buildtype release \
         -Db_ndebug=if-release -Dbuild_id=false "$build" >>"$LOG" 2>&1 ) \
     || ! ninja -C "$build" >>"$LOG" 2>&1; then
    warn "gxvk build failed — see $LOG. Skipping."; rm -rf "$root"; return 0
  fi

  while IFS= read -r f; do dll["$(basename "$f")"]="$f"; done < <(find "$build" -type f -name 'glide*.dll')
  for n in glide.dll glide2x.dll glide3x.dll; do
    [[ -n "${dll[$n]:-}" ]] || { warn "gxvk: $n not produced — skipping install."; rm -rf "$root"; return 0; }
    i686-w64-mingw32-strip "${dll[$n]}" 2>/dev/null || true
  done

  stage="$HOME/.local/share/gxvk/x32"
  mkdir -p "$stage"
  for n in glide.dll glide2x.dll glide3x.dll; do cp -f "${dll[$n]}" "$stage/$n"; done
  ok "gxvk $ver DLLs staged in $stage"

  _gxvk_resolve_target
  # init an empty prefix (unless targeting a game dir) when Wine is available
  if [[ -z "$GXVK_TGT" && -z "$GXVK_GAME_DIR" ]] \
     && { command -v wine &>/dev/null || command -v wineboot &>/dev/null; }; then
    info "initialising Wine prefix $GXVK_PFX"
    mkdir -p "$GXVK_PFX"
    WINEPREFIX="$GXVK_PFX" WINEDLLOVERRIDES="mscoree=d;mshtml=d" wineboot -u >/dev/null 2>&1 \
      || WINEPREFIX="$GXVK_PFX" WINEDLLOVERRIDES="mscoree=d;mshtml=d" wine wineboot -u >/dev/null 2>&1 || true
    WINEPREFIX="$GXVK_PFX" wineserver -w 2>/dev/null || true
    _gxvk_resolve_target
  fi
  if [[ -n "$GXVK_TGT" ]]; then
    mkdir -p "$GXVK_TGT"
    for n in glide.dll glide2x.dll glide3x.dll; do
      [[ -f "$GXVK_TGT/$n" && ! -f "$GXVK_TGT/$n.gxvk-bak" ]] && cp -f "$GXVK_TGT/$n" "$GXVK_TGT/$n.gxvk-bak"
      cp -f "$stage/$n" "$GXVK_TGT/$n"
    done
    ok "gxvk installed into ${GXVK_TGT_DESC:-$GXVK_TGT} — no DLL overrides needed."
  else
    info "no Wine prefix/target; copy the DLLs from $stage into a game folder or a prefix's syswow64 when needed."
  fi
  rm -rf "$root"
}

# ─────────────────────────────────────────────────────────────────────────────
# d7vk — DirectDraw / Direct3D 1-7 -> Vulkan (old-school DirectX 6/7). DXVK fork
# that adds ddraw.dll; DX8-11 already come from DXVK, DX12 from vkd3d-proton.
# ─────────────────────────────────────────────────────────────────────────────
build_install_d7vk(){
  hdr "d7vk (DirectDraw / Direct3D 1-7 -> Vulkan)"
  pac_install meson ninja mingw-w64-gcc glslang git
  if ! command -v i686-w64-mingw32-g++ &>/dev/null \
     || ! command -v i686-w64-mingw32-windres &>/dev/null \
     || { ! command -v glslang &>/dev/null && ! command -v glslangValidator &>/dev/null; }; then
    warn "d7vk build tools missing (mingw-w64-gcc / glslang) — skipping d7vk."
    return 0
  fi

  local root src build ver stage f
  root="$(mktemp -d /tmp/d7vk-build.XXXXXX)"; src="$root/d7vk"
  info "cloning d7vk + submodules (GitHub)"
  if ! git clone --recursive https://github.com/WinterSnowfall/d7vk.git "$src" >>"$LOG" 2>&1; then
    warn "d7vk clone failed (network?) — skipping."; rm -rf "$root"; return 0
  fi
  ver="$(cat "$src/RELEASE" 2>/dev/null || echo unknown)"

  build="$root/build32"
  info "building d7vk $ver (32-bit)"
  if ! ( cd "$src" && meson setup --cross-file "$src/build-win32.txt" --buildtype release \
         -Db_ndebug=if-release -Dbuild_id=false "$build" >>"$LOG" 2>&1 ) \
     || ! ninja -C "$build" >>"$LOG" 2>&1; then
    warn "d7vk build failed — see $LOG. Skipping."; rm -rf "$root"; return 0
  fi

  local dll; dll="$(find "$build" -type f -name 'ddraw.dll' | head -1)"
  [[ -n "$dll" ]] || { warn "d7vk: ddraw.dll not produced — skipping install."; rm -rf "$root"; return 0; }
  i686-w64-mingw32-strip "$dll" 2>/dev/null || true

  stage="$HOME/.local/share/d7vk/x32"; mkdir -p "$stage"
  cp -f "$dll" "$stage/ddraw.dll"
  ok "d7vk $ver ddraw.dll staged in $stage"

  # install into the resolved Wine prefix (or game dir); init an empty prefix first
  _gxvk_resolve_target
  if [[ -z "$GXVK_TGT" && -z "$GXVK_GAME_DIR" ]] \
     && { command -v wine &>/dev/null || command -v wineboot &>/dev/null; }; then
    info "initialising Wine prefix $GXVK_PFX"
    mkdir -p "$GXVK_PFX"
    WINEPREFIX="$GXVK_PFX" WINEDLLOVERRIDES="mscoree=d;mshtml=d" wineboot -u >/dev/null 2>&1 \
      || WINEPREFIX="$GXVK_PFX" WINEDLLOVERRIDES="mscoree=d;mshtml=d" wine wineboot -u >/dev/null 2>&1 || true
    WINEPREFIX="$GXVK_PFX" wineserver -w 2>/dev/null || true
    _gxvk_resolve_target
  fi

  if [[ -n "$GXVK_TGT" ]]; then
    mkdir -p "$GXVK_TGT"
    [[ -f "$GXVK_TGT/ddraw.dll" && ! -f "$GXVK_TGT/ddraw.dll.d7vk-bak" ]] && cp -f "$GXVK_TGT/ddraw.dll" "$GXVK_TGT/ddraw.dll.d7vk-bak"
    cp -f "$stage/ddraw.dll" "$GXVK_TGT/ddraw.dll"
    # unlike Glide, Wine HAS a builtin ddraw, so force the native (d7vk) one:
    if [[ -z "$GXVK_GAME_DIR" ]] && command -v wine &>/dev/null; then
      WINEPREFIX="$GXVK_PFX" wine reg add 'HKCU\Software\Wine\DllOverrides' /v ddraw /d native,builtin /f >/dev/null 2>&1 \
        && ok "set ddraw=native,builtin override in $GXVK_PFX" \
        || warn "couldn't set the ddraw override automatically — add  WINEDLLOVERRIDES=\"ddraw=n,b\"  to the game's launch options."
    else
      info "game-dir install: add  WINEDLLOVERRIDES=\"ddraw=n,b\"  to the launch options so Wine uses d7vk's ddraw."
    fi
    ok "d7vk installed into ${GXVK_TGT_DESC:-$GXVK_TGT}."
  else
    info "no Wine prefix/target; copy ddraw.dll from $stage into a game folder (and set WINEDLLOVERRIDES=ddraw=n,b) when needed."
  fi
  rm -rf "$root"
}

# ─────────────────────────────────────────────────────────────────────────────
# hex editors + game-file protection (back up a hex-patched exe, keep it enforced)
# ─────────────────────────────────────────────────────────────────────────────
install_game_patch_tools(){
  hdr "Hex editors + file-protection watcher"
  # GUI + CLI hex editors for patching old game code (e.g. CPU-speed / opcode fixes),
  # plus radare2 for deeper patching/analysis and inotify-tools for the watcher.
  pac_install ghex hexedit radare2 inotify-tools
  aur_install imhex
  command -v xxd &>/dev/null || info "CLI 'xxd' ships with vim if you want it."
  setup_protect_subsystem
  ok "hex editors: ghex, ImHex, hexedit, radare2 (+ xxd via vim)."
  info "Protect a patched file:  $0 --protect /path/to/game.exe [--backup-path DIR]"
  info "Status / restore / stop: $0 --protect-status | --protect-restore FILE | --unprotect FILE"
}

# writes the watcher script + a ROOT systemd service that continuously reverts any
# protected file back to its backup (and re-applies the immutable lock).
setup_protect_subsystem(){
  mkdir -p "$GR_DIR" "${BACKUP_PATH:-$GR_BACKUPS_DEFAULT}"
  touch "$GR_MANIFEST"
  cat > "$GR_DIR/protect-watch.sh" <<'WEOF'
#!/usr/bin/env bash
# game-ready protected-file watcher. Arg 1 = manifest path (tab: file backup sha256 method date)
MAN="${1:?manifest path required}"
while true; do
  if [[ -s "$MAN" ]]; then
    while IFS=$'\t' read -r f bak sum method date; do
      [[ -n "$f" && -n "$bak" && -f "$bak" ]] || continue
      if [[ ! -e "$f" ]]; then
        cp -f "$bak" "$f" 2>/dev/null && logger -t game-ready "restored missing $f"
        [[ "$method" == *immutable* ]] && chattr +i "$f" 2>/dev/null
        continue
      fi
      cur="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
      if [[ -n "$sum" && "$cur" != "$sum" ]]; then
        chattr -i "$f" 2>/dev/null
        cp -f "$bak" "$f" 2>/dev/null && logger -t game-ready "reverted $f to protected copy"
        [[ "$method" == *immutable* ]] && chattr +i "$f" 2>/dev/null
      fi
    done < "$MAN"
  fi
  sleep "${GR_POLL:-10}"
done
WEOF
  chmod +x "$GR_DIR/protect-watch.sh"

  sudo tee /etc/systemd/system/game-ready-protect.service >/dev/null <<SEOF
[Unit]
Description=game-ready protected game-file watcher
After=local-fs.target

[Service]
Type=simple
ExecStart=/bin/bash $GR_DIR/protect-watch.sh $GR_MANIFEST
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SEOF
  sudo systemctl daemon-reload 2>/dev/null || true
  sudo systemctl enable --now game-ready-protect.service 2>/dev/null \
    && ok "protection watcher active (reverts any protected file within ~10s)." \
    || warn "couldn't enable the protection watcher service."
}

# native filesystems where chattr +i (immutable) works
_fs_supports_immutable(){ case "$1" in ext2/ext3|ext4|xfs|btrfs|f2fs|jfs|reiserfs) return 0;; *) return 1;; esac; }

protect_file(){
  local src="$1" f bak dir sum fs method
  f="$(readlink -f -- "$src" 2>/dev/null)"
  [[ -n "$f" && -f "$f" ]] || die "not a file: $src"
  setup_protect_subsystem

  dir="${BACKUP_PATH:-$GR_BACKUPS_DEFAULT}"
  # interactive: offer to choose the backup dir if not given
  if [[ -z "$BACKUP_PATH" && -t 0 ]]; then
    read -r -p "backup location [$dir]: " ans; [[ -n "$ans" ]] && dir="$ans"
  fi
  mkdir -p "$dir" || die "cannot create backup dir: $dir"

  bak="$dir/$(basename "$f").$(printf '%s' "$f" | sha256sum | cut -c1-8).bak"
  cp -f --preserve=mode,timestamps "$f" "$bak" || die "backup failed"
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  fs="$(stat -f -c %T "$f" 2>/dev/null)"

  method="watcher"
  if _fs_supports_immutable "$fs"; then
    if sudo chattr +i "$f" 2>/dev/null; then method="immutable+watcher"; ok "locked immutable (chattr +i) on $fs"
    else warn "chattr +i failed — relying on the watcher to auto-revert."; fi
  else
    info "filesystem '$fs' has no immutable flag — the watcher will auto-revert instead."
  fi

  # replace any existing manifest row for this file, then append
  if [[ -s "$GR_MANIFEST" ]]; then
    awk -F'\t' -v k="$f" '$1!=k' "$GR_MANIFEST" > "$GR_MANIFEST.tmp" && mv "$GR_MANIFEST.tmp" "$GR_MANIFEST"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$bak" "$sum" "$method" "$(date -Is)" >> "$GR_MANIFEST"
  sudo systemctl restart game-ready-protect.service 2>/dev/null || true

  hdr "Protection pointer"
  printf '   protected : %s\n'                                   "$f"      | tee -a "$LOG" >&2
  printf '   restores\xe2\x86\x92 : %s   (good copy stays here / returns here)\n' "$f" | tee -a "$LOG" >&2
  printf '   backup    : %s\n'                                   "$bak"    | tee -a "$LOG" >&2
  printf '   method    : %s\n'                                   "$method" | tee -a "$LOG" >&2
  printf '   sha256    : %s\n'                                   "$sum"    | tee -a "$LOG" >&2
  ok "protected. Different backup location any time: --backup-path DIR then re-run --protect."
}

protect_status(){
  hdr "Protected game files"
  [[ -s "$GR_MANIFEST" ]] || { info "nothing protected yet. Use: $0 --protect <file>"; return 0; }
  command -v systemctl &>/dev/null && info "watcher service: $(systemctl is-active game-ready-protect.service 2>/dev/null || echo unknown)"
  local f bak sum method date state lock cur attr
  printf '   %-44s %-9s %-10s %s\n' "PROTECTED FILE" "STATE" "LOCK" "BACKUP" | tee -a "$LOG" >&2
  while IFS=$'\t' read -r f bak sum method date; do
    [[ -n "$f" ]] || continue
    if [[ ! -e "$f" ]]; then state="MISSING"
    else cur="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"; [[ "$cur" == "$sum" ]] && state="OK" || state="DRIFTED"; fi
    attr="$(lsattr -d "$f" 2>/dev/null | awk '{print $1}')"; [[ "$attr" == *i* ]] && lock="immutable" || lock="watch-only"
    printf '   %-44s %-9s %-10s %s\n' "$f" "$state" "$lock" "$bak" | tee -a "$LOG" >&2
  done < "$GR_MANIFEST"
}

protect_restore(){
  local src="$1" f bak sum method date row
  f="$(readlink -f -- "$src" 2>/dev/null)"
  [[ -s "$GR_MANIFEST" ]] || die "nothing is protected."
  row="$(awk -F'\t' -v k="$f" '$1==k{print; exit}' "$GR_MANIFEST")"
  [[ -n "$row" ]] || die "not protected: $f"
  IFS=$'\t' read -r f bak sum method date <<<"$row"
  [[ -f "$bak" ]] || die "backup missing: $bak"
  sudo chattr -i "$f" 2>/dev/null
  cp -f "$bak" "$f" || die "restore failed"
  [[ "$method" == *immutable* ]] && sudo chattr +i "$f" 2>/dev/null
  ok "restored $f from $bak"
}

unprotect_file(){
  local src="$1" f
  f="$(readlink -f -- "$src" 2>/dev/null)"
  [[ -s "$GR_MANIFEST" ]] || { warn "nothing is protected."; return 0; }
  sudo chattr -i "$f" 2>/dev/null
  awk -F'\t' -v k="$f" '$1!=k' "$GR_MANIFEST" > "$GR_MANIFEST.tmp" && mv "$GR_MANIFEST.tmp" "$GR_MANIFEST"
  sudo systemctl restart game-ready-protect.service 2>/dev/null || true
  ok "unprotected $f (backup kept; it will no longer be auto-reverted)."
}

# ─────────────────────────────────────────────────────────────────────────────
# fstab wizard (from lsblk -f) + ownership fix
# ─────────────────────────────────────────────────────────────────────────────
sanitize(){ printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_\{2,\}/_/g; s/^_//; s/_$//'; }

is_native_fs(){ case "$1" in ext2|ext3|ext4|xfs|btrfs|f2fs|jfs|reiserfs|nilfs2) return 0;; *) return 1;; esac; }

# echo "type|opts|passno" for a given on-disk fstype
fstab_spec(){
  local fs="$1" uid gid; uid="$(id -u)"; gid="$(id -g)"
  case "$fs" in
    ntfs|ntfs3) printf 'ntfs3|defaults,nofail,uid=%s,gid=%s,umask=022,windows_names,x-systemd.automount|0' "$uid" "$gid" ;;
    exfat)      printf 'exfat|defaults,nofail,uid=%s,gid=%s,umask=022,x-systemd.automount|0' "$uid" "$gid" ;;
    vfat|fat)   printf 'vfat|defaults,nofail,uid=%s,gid=%s,umask=022,x-systemd.automount|0' "$uid" "$gid" ;;
    btrfs)      printf 'btrfs|defaults,nofail,compress=zstd,x-systemd.automount|2' ;;
    ext2|ext3|ext4|xfs|f2fs|jfs|reiserfs|nilfs2) printf '%s|defaults,nofail,x-systemd.automount|2' "$fs" ;;
    *)          printf '%s|defaults,nofail,x-systemd.automount|0' "$fs" ;;
  esac
}

fstab_wizard(){
  hdr "fstab drive setup (from lsblk -f)"
  if [[ ! -t 0 ]]; then
    warn "no TTY — skipping interactive fstab setup. Run 'bash $0 --fstab' in a terminal to use it."
    return 0
  fi
  ensure_tool lsblk util-linux

  info "current block devices:"
  lsblk -f -o NAME,FSTYPE,LABEL,SIZE,UUID,MOUNTPOINTS 2>/dev/null | sed 's/^/   /' | tee -a "$LOG" >&2

  # gather candidate filesystems: has fstype + uuid, not swap, not already in fstab,
  # not a live system mount. NAME/FSTYPE have no spaces, so this split is safe.
  local -a cands=()
  local n fs dev uuid label mp
  while read -r n fs; do
    [[ -n "$fs" ]] || continue
    [[ "$fs" == swap ]] && continue
    dev="/dev/$n"
    uuid="$(lsblk -no UUID "$dev" 2>/dev/null | head -1 | tr -d '[:space:]')"
    [[ -n "$uuid" ]] || continue
    mp="$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | head -1)"
    label="$(lsblk -no LABEL "$dev" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')"
    grep -qiE "UUID=${uuid}([[:space:]]|/|$)" /etc/fstab 2>/dev/null && continue
    grep -qE "(^|[[:space:]])${dev}([[:space:]]|$)" /etc/fstab 2>/dev/null && continue
    case "$mp" in /|/boot|/boot/efi|/efi|/home|"[SWAP]") continue ;; esac
    cands+=("${dev}|${fs}|${uuid}|${label}|${mp}")
  done < <(lsblk -rno NAME,FSTYPE 2>/dev/null)

  if ((${#cands[@]}==0)); then
    ok "no unconfigured drives found — everything with a filesystem is already in fstab or system-mounted."
    return 0
  fi

  local -a lines=() dirs=() nativemnts=()
  local c type opts passno defmp mpsel ans
  for c in "${cands[@]}"; do
    IFS='|' read -r dev fs uuid label mp <<<"$c"
    printf '\n  %s  fstype=%s  label=%s  uuid=%s %s\n' \
      "$dev" "$fs" "${label:-–}" "$uuid" "${mp:+(mounted now at $mp)}" | tee -a "$LOG" >&2
    ask_yn "  Add $dev to /etc/fstab?" || continue
    if [[ -n "$label" ]]; then defmp="/mnt/$(sanitize "$label")"; else defmp="/mnt/${fs}_${uuid:0:8}"; fi
    read -r -p "  mount point [$defmp]: " mpsel; mpsel="${mpsel:-$defmp}"
    IFS='|' read -r type opts passno <<<"$(fstab_spec "$fs")"
    lines+=("UUID=${uuid}  ${mpsel}  ${type}  ${opts}  0  ${passno}")
    dirs+=("$mpsel")
    is_native_fs "$fs" && nativemnts+=("$mpsel")
  done

  ((${#lines[@]})) || { warn "nothing selected — /etc/fstab unchanged."; return 0; }

  info "proposed /etc/fstab additions:"
  printf '   %s\n' "${lines[@]}" | tee -a "$LOG" >&2
  ask_yn "Write these to /etc/fstab (a timestamped backup is made first)?" \
    || { warn "aborted — /etc/fstab unchanged."; return 0; }

  local bak="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
  sudo cp /etc/fstab "$bak" && ok "backed up /etc/fstab -> $bak"
  local d
  for d in "${dirs[@]}"; do sudo mkdir -p "$d" || warn "mkdir $d failed"; done
  { printf '\n# added by game-ready.sh %s\n' "$(date)"; printf '%s\n' "${lines[@]}"; } \
    | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload 2>/dev/null || true

  info "mounting (mount -a; nofail means a missing drive won't block boot)"
  sudo mount -a && ok "mount -a clean" || warn "mount -a reported an issue — check entries; restore with: sudo cp $bak /etc/fstab"

  # ownership: FAT/exFAT/NTFS already own via uid/gid/umask mount opts; native fs
  # (ext2/3/4, xfs, btrfs, f2fs…) store ownership on disk, so chown them to you.
  if ((${#nativemnts[@]})); then
    hdr "Drive ownership (native filesystems)"
    local m uname gname; uname="$(id -un)"; gname="$(id -gn)"
    for m in "${nativemnts[@]}"; do
      sudo ls -A "$m" >/dev/null 2>&1 || true      # trigger automount if needed
      if mountpoint -q "$m"; then
        info "chown ${uname}:${gname} $m (top level)"
        sudo chown "${uname}:${gname}" "$m" || warn "chown $m failed"
        sudo chmod u+rwX "$m" 2>/dev/null || true
        if ask_yn "  Recursively chown ALL existing files on $m to ${uname}? (slow on big/shared drives)"; then
          info "chown -R ${uname}:${gname} $m"
          sudo chown -R "${uname}:${gname}" "$m" || warn "recursive chown $m failed"
        fi
        ok "$m is writable by you."
      else
        warn "$m is not mounted yet (automount on first access) — ownership will be applied once you can't; re-run 'bash $0 --fstab' if needed."
      fi
    done
  fi
  info "FAT/exFAT/NTFS drives get your ownership via uid/gid/umask mount options (no chown needed)."
}

# ─────────────────────────────────────────────────────────────────────────────
# lib32 (32-bit) audio pipeline — so 32-bit / old games get sound
# ─────────────────────────────────────────────────────────────────────────────
install_lib32_audio(){
  hdr "lib32 audio pipeline"
  # 32-bit client libs for whatever server is running (PipeWire default on Manjaro;
  # these are the compat/client libs games link against, not a server reconfigure).
  pac_install lib32-libpulse lib32-alsa-plugins lib32-alsa-lib lib32-openal
  if pacman -Qq pipewire &>/dev/null; then
    pac_install lib32-pipewire
    pacman -Qq pipewire-jack &>/dev/null && pac_install lib32-pipewire-jack
  fi
  ok "32-bit audio libs installed (old/32-bit games will have sound)."
}

# ─────────────────────────────────────────────────────────────────────────────
# game launchers beyond Steam: Heroic (Epic/GOG/Amazon) + Bottles
# ─────────────────────────────────────────────────────────────────────────────
install_launchers(){
  hdr "Game launchers (Heroic + Bottles)"
  # Bottles is in the Arch 'extra' repo on most mirrors; Heroic is AUR (-bin = prebuilt).
  pac_install bottles
  aur_install heroic-games-launcher-bin
  ok "Heroic + Bottles installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# overlays: MangoHud (dead-simple on/off) + vkBasalt (post-process FX)
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# extra legacy-DirectX wrappers: cnc-ddraw (open, 2D DDraw) + dgVoodoo2 (proprietary,
# DDraw/Glide/D3D1-8). Both are per-game drop-ins, staged for you to copy as needed.
# ─────────────────────────────────────────────────────────────────────────────
install_legacy_wrappers(){
  hdr "Legacy-DirectX wrappers (cnc-ddraw + dgVoodoo2)"

  # --- cnc-ddraw (AUR) : best for old 2D DirectDraw games (C&C, AoE, etc.) -----
  aur_install cnc-ddraw
  local cncdll stage_cnc="$HOME/.local/share/cnc-ddraw"
  cncdll="$(pacman -Ql cnc-ddraw 2>/dev/null | awk '/\/ddraw\.dll$/{print $2; exit}')"
  if [[ -n "$cncdll" && -f "$cncdll" ]]; then
    mkdir -p "$stage_cnc"; cp -f "$cncdll" "$stage_cnc/ddraw.dll"
    local cncini; cncini="$(pacman -Ql cnc-ddraw 2>/dev/null | awk '/\/ddraw\.ini$/{print $2; exit}')"
    [[ -n "$cncini" && -f "$cncini" ]] && cp -f "$cncini" "$stage_cnc/ddraw.ini"
    ok "cnc-ddraw staged in $stage_cnc (copy ddraw.dll next to a 2D DDraw game's .exe; set ddraw=n,b)."
  else
    info "cnc-ddraw installed; its ddraw.dll lives under /usr/share — copy it next to a game as needed."
  fi

  # --- dgVoodoo2 (proprietary) : DDraw/Glide/Direct3D 1-8 -> D3D11/12 ----------
  if (( DO_DGVOODOO )); then
    install_dgvoodoo
  else
    info "dgVoodoo2 skipped (--skip-dgvoodoo)."
  fi
}

# downloads the latest dgVoodoo2 from the official site (Hungary; not a .ru host)
# and stages its 32/64-bit DLLs. Non-fatal — warns + prints the link on any failure.
install_dgvoodoo(){
  ensure_tool curl curl; ensure_tool unzip unzip
  local stage="$HOME/.local/share/dgvoodoo2" tmp zipurl zipfile
  mkdir -p "$stage"; tmp="$(mktemp -d)"
  info "finding the latest dgVoodoo2 release on $DGVOODOO_BASE"
  # scrape the index and pick the href with the highest numeric version, ignoring
  # any path prefix (so a '/'-prefixed link can't sort ahead of a bare filename)
  local href v bestv=-1
  while read -r href; do
    v="$(grep -oE '[0-9]+' <<<"${href##*dgVoodoo2}" | head -1)"
    [[ -n "$v" ]] || continue
    if (( 10#$v > bestv )); then bestv=$((10#$v)); zipurl="$href"; fi
  done < <(curl -fsSL "$DGVOODOO_BASE/" 2>/dev/null | grep -oiE '[A-Za-z0-9_/.-]*dgVoodoo2[._-][0-9]+\.zip')
  if [[ -n "${zipurl:-}" ]]; then
    [[ "$zipurl" == http* ]] || zipurl="$DGVOODOO_BASE/${zipurl#/}"
    info "downloading $zipurl"
    if curl -fsSL -o "$tmp/dgv.zip" "$zipurl" && unzip -oq "$tmp/dgv.zip" -d "$tmp/dgv"; then
      # keep the MS (DDraw/D3D) + 3Dfx (Glide) DLL sets + the config/control panel
      cp -rf "$tmp/dgv/MS"   "$stage/" 2>/dev/null
      cp -rf "$tmp/dgv/3Dfx" "$stage/" 2>/dev/null
      find "$tmp/dgv" -maxdepth 1 \( -iname 'dgVoodoo*.conf' -o -iname 'dgVoodooCpl.exe' \) -exec cp -f {} "$stage/" \; 2>/dev/null
      ok "dgVoodoo2 staged in $stage (MS/x86 = DDraw/D3D1-8, 3Dfx/x86 = Glide)."
      info "per game: copy the needed DLLs from $stage/MS/x86 next to the .exe and set them to native (WINEDLLOVERRIDES)."
    else
      warn "dgVoodoo2 download/extract failed — grab it manually from $DGVOODOO_BASE and unzip into $stage"
    fi
  else
    warn "couldn't find the dgVoodoo2 zip on $DGVOODOO_BASE — download it manually and unzip into $stage"
  fi
  rm -rf "$tmp"
}

setup_overlays(){
  hdr "Overlays: MangoHud + vkBasalt"
  pac_install mangohud lib32-mangohud goverlay obs-studio
  aur_install vkbasalt lib32-vkbasalt obs-vkcapture lib32-obs-vkcapture

  local cfg="$HOME/.config"
  mkdir -p "$cfg/MangoHud" "$cfg/vkBasalt" "$cfg/environment.d" "$HOME/.local/bin"

  # MangoHud default config — only written if absent (don't clobber your tweaks).
  if [[ ! -f "$cfg/MangoHud/MangoHud.conf" ]]; then
    cat > "$cfg/MangoHud/MangoHud.conf" <<'MHCONF'
# game-ready.sh default MangoHud config — edit freely, or use GOverlay (GUI).
legacy_layout=0
gpu_stats
gpu_temp
gpu_core_clock
cpu_stats
cpu_temp
ram
vram
fps
frametime=1
frame_timing=1
resolution
gpu_name
engine_version
vulkan_driver
# live toggle the overlay in-game:
toggle_hud=Shift_R+F12
toggle_logging=Shift_L+F2
MHCONF
    ok "wrote $cfg/MangoHud/MangoHud.conf"
  fi

  # vkBasalt default config — CAS sharpening, off until you press Home (or set ENABLE_VKBASALT=1).
  if [[ ! -f "$cfg/vkBasalt/vkBasalt.conf" ]]; then
    cat > "$cfg/vkBasalt/vkBasalt.conf" <<'VKCONF'
# game-ready.sh default vkBasalt config. Toggle in-game with the Home key.
effects = cas
casSharpness = 0.4
toggleKey = Home
enableOnLaunch = False
VKCONF
    ok "wrote $cfg/vkBasalt/vkBasalt.conf"
  fi

  # ---- mangohud-toggle : flip the global overlay on/off in one command --------
  cat > "$HOME/.local/bin/mangohud-toggle" <<'TOGGLE'
#!/usr/bin/env bash
# Turn the MangoHud overlay on or off GLOBALLY (all Vulkan games, next launch).
# In-game you can also toggle live with Shift_R+F12.
f="$HOME/.config/environment.d/90-mangohud.conf"
mkdir -p "$(dirname "$f")"
if grep -qs '^MANGOHUD=1' "$f" 2>/dev/null; then
  rm -f "$f"
  echo "MangoHud: OFF globally (relaunch games). Per-game: prefix with 'mangohud'."
else
  printf 'MANGOHUD=1
MANGOHUD_DLSYM=1
' > "$f"
  echo "MangoHud: ON globally (relaunch games). Live toggle in-game: Shift_R+F12."
fi
TOGGLE
  chmod +x "$HOME/.local/bin/mangohud-toggle"

  # ---- vkbasalt-toggle : flip post-processing on/off in one command -----------
  cat > "$HOME/.local/bin/vkbasalt-toggle" <<'TOGGLE'
#!/usr/bin/env bash
# Turn vkBasalt post-processing on or off GLOBALLY (next launch).
# In-game you can also toggle live with the Home key.
f="$HOME/.config/environment.d/91-vkbasalt.conf"
mkdir -p "$(dirname "$f")"
if grep -qs '^ENABLE_VKBASALT=1' "$f" 2>/dev/null; then
  rm -f "$f"; echo "vkBasalt: OFF globally (relaunch games)."
else
  echo 'ENABLE_VKBASALT=1' > "$f"; echo "vkBasalt: ON globally (relaunch games). Live toggle in-game: Home."
fi
TOGGLE
  chmod +x "$HOME/.local/bin/vkbasalt-toggle"

  case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) warn "add ~/.local/bin to PATH to call mangohud-toggle directly." ;; esac
  ok "overlays ready."
  info "MangoHud:  'mangohud-toggle' = global on/off   |  Shift_R+F12 = live in-game  |  Steam launch opt: mangohud %command%"
  info "vkBasalt:  'vkbasalt-toggle' = global on/off    |  Home = live in-game"
  command -v obs-gamecapture &>/dev/null && info "OBS capture: launch a game with  obs-gamecapture %command%  then add a \"Game Capture (Vulkan/GL)\" source in OBS."
}

# ─────────────────────────────────────────────────────────────────────────────
# performance tuning
# ─────────────────────────────────────────────────────────────────────────────
apply_performance_tuning(){
  hdr "Performance tuning"

  if command -v cpupower &>/dev/null; then
    info "CPU governor -> performance"
    sudo sed -i "s/^#\?governor=.*/governor='performance'/" /etc/default/cpupower 2>/dev/null || true
    grep -q "^governor='performance'" /etc/default/cpupower 2>/dev/null \
      || echo "governor='performance'" | sudo tee -a /etc/default/cpupower >/dev/null
    sudo systemctl enable --now cpupower.service 2>/dev/null || warn "cpupower.service enable failed"
  fi

  info "sysctl vm.max_map_count (esync/large-address games)"
  printf 'vm.max_map_count=2147483642\n' | sudo tee /etc/sysctl.d/99-gaming.conf >/dev/null
  sudo sysctl --system &>/dev/null || true

  info "raising open-file limits (esync/fsync)"
  printf '*    soft    nofile    1048576\n*    hard    nofile    1048576\n' \
    | sudo tee /etc/security/limits.d/99-gaming.conf >/dev/null
  sudo mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
  printf '[Manager]\nDefaultLimitNOFILE=1048576\n' | sudo tee /etc/systemd/system.conf.d/99-gaming.conf >/dev/null
  printf '[Manager]\nDefaultLimitNOFILE=1048576\n' | sudo tee /etc/systemd/user.conf.d/99-gaming.conf   >/dev/null

  if getent group gamemode &>/dev/null; then
    sudo gpasswd -a "$(id -un)" gamemode &>/dev/null || true
  fi

  if pacman -Qq earlyoom &>/dev/null; then
    sudo systemctl enable --now earlyoom.service 2>/dev/null || warn "earlyoom.service enable failed"
    ok "earlyoom active — prevents a RAM-exhausting game from hard-freezing the box."
  fi

  ok "tuning applied (reboot to pick up governor + nofile limits)"
}

# ─────────────────────────────────────────────────────────────────────────────
# summary
# ─────────────────────────────────────────────────────────────────────────────
summary(){
  hdr "Summary"
  info "installed GPU drivers:"
  (( HAS_NVIDIA )) && pacman -Q "$(nvidia_pkg)" nvidia-utils 2>/dev/null | sed 's/^/   /'
  (( DO_MESA_GIT )) && pacman -Q mesa-git 2>/dev/null | sed 's/^/   /' || pacman -Q mesa 2>/dev/null | sed 's/^/   /'
  (( HAS_AMD && ! DO_MESA_GIT )) && pacman -Q vulkan-radeon 2>/dev/null | sed 's/^/   /'
  (( HAS_INTEL && ! DO_MESA_GIT )) && pacman -Q vulkan-intel 2>/dev/null | sed 's/^/   /'
  { [[ "$CPU_VENDOR" == intel ]] && pacman -Q intel-ucode 2>/dev/null | sed 's/^/   /'; } || { [[ "$CPU_VENDOR" == amd ]] && pacman -Q amd-ucode 2>/dev/null | sed 's/^/   /'; }
  if command -v vulkaninfo &>/dev/null; then
    info "active Vulkan devices:"
    vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|apiVersion' | sed 's/^/   /' | tee -a "$LOG" >&2 || true
  fi
  ok "steam:     $(command -v steam       || echo 'MISSING')"
  ok "lutris:    $(command -v lutris      || echo 'MISSING')"
  ok "gamemode:  $(command -v gamemoderun || echo 'MISSING')"
  ok "mangohud:  $(command -v mangohud    || echo 'MISSING')"
  ok "yay:       $(command -v yay         || echo 'MISSING')"

  info "GE-Proton versions found:"
  ls -1 "$HOME/.local/share/Steam/compatibilitytools.d" "$HOME/.steam/root/compatibilitytools.d" 2>/dev/null \
    | grep -E 'GE-Proton' | sort -u | sed 's/^/   /' || echo "   (none)"

  (( GE_FAILED )) && err "GE-Proton source build did NOT complete — see $LOG"

  cat >&2 <<EOF

Next:
  1. Reboot (applies CPU governor, open-file limits, and any new GPU kernel module).
  2. Steam -> Settings -> Compatibility -> tick "Enable Steam Play for all other titles",
     set the Proton version to ${GE_TAG:-GE-Proton}. Per game: right-click -> Properties -> Compatibility.
  3. Launch options for overlay + GameMode:  gamemoderun mangohud %command%

Log: $LOG
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────
main(){
  parse_args "$@"
  hard_checks
  if (( GXVK_UNINSTALL )); then
    gxvk_uninstall
    exit 0
  fi
  prime_sudo

  [[ -n "$PROTECT_FILE" ]]   && { protect_file "$PROTECT_FILE"; exit 0; }
  [[ -n "$UNPROTECT_FILE" ]] && { unprotect_file "$UNPROTECT_FILE"; exit 0; }
  [[ -n "$RESTORE_FILE" ]]   && { protect_restore "$RESTORE_FILE"; exit 0; }
  (( PROTECT_STATUS ))       && { protect_status; exit 0; }

  if (( FSTAB_ONLY )); then
    fstab_wizard
    exit 0
  fi

  if (( GE_ONLY )); then
    build_ge_proton || GE_FAILED=1
    summary
    exit $GE_FAILED
  fi

  if (( GXVK_ONLY )); then
    build_install_gxvk
    exit 0
  fi

  if (( D7VK_ONLY )); then
    build_install_d7vk
    exit 0
  fi

  enable_multilib
  (( DO_UPDATE )) && system_update
  detect_gpu
  install_microcode
  install_gpu_userspace
  install_display_drivers
  install_storage_drivers
  install_core_packages
  ensure_yay
  install_aur_packages
  install_desktop_apps
  install_controller_support
  (( DO_AUDIO32 )) && install_lib32_audio
  (( DO_LAUNCHERS )) && install_launchers
  (( DO_OVERLAYS )) && setup_overlays
  (( DO_PATCHTOOLS )) && install_game_patch_tools
  apply_performance_tuning
  (( DO_GXVK )) && build_install_gxvk
  (( DO_D7VK )) && build_install_d7vk
  install_legacy_wrappers
  (( DO_GE )) && { build_ge_proton || GE_FAILED=1; }
  (( DO_FSTAB )) && fstab_wizard
  summary
  exit $GE_FAILED
}

main "$@"
