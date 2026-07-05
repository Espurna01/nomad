#!/bin/bash
# forja_userspace.sh
# Post-reboot userspace setup: packages, configs, interface, sound...
set -euo pipefail

# Anchor to the script's own directory so `source helpers.sh`, .env, and
# utilities/ resolve regardless of the caller's working directory.
cd "$(dirname "$0")" || exit 1

source helpers.sh
enforce_env

if [ "$(id -u)" -eq 0 ]; then
  error "Don't run $0 as root (sudo $0). Run as a normal user; sudo is used per-command."
  exit 1
fi

# ============================================================
# 1. Packages + AUR (Arch User Repository)
# ============================================================
if [ -n "${PACMAN_PACKAGES:-}" ]; then
  info "Installing essential packages from PACMAN_PACKAGES..."
  before=$(pacman -Q | wc -l)
  sudo pacman -Syu --needed --noconfirm ${PACMAN_PACKAGES} || \
	  append_note "Some packages failed to install — check PACMAN_PACKAGES for typos."  
  after=$(pacman -Q | wc -l)
  info "Installed a total of $((after - before)) new package(s)"
else
  info "PACMAN_PACKAGES not set in .env, skipping package install"
fi

if [ -n "${AUR_HELPER:-}" ]; then
  if ! command -v makepkg >/dev/null 2>&1; then
    error "makepkg not found — base-devel not installed or missing from PACMAN_PACKAGES"
    append_note "AUR skipped: makepkg unavailable (add base-devel to PACMAN_PACKAGES)."
  else
    if ! command -v "${AUR_HELPER}" >/dev/null 2>&1; then
      info "Bootstrapping AUR helper: ${AUR_HELPER}"
      tmp_dir="$(mktemp -d)"
      git clone "https://aur.archlinux.org/${AUR_HELPER}.git" "${tmp_dir}"
      ( cd "${tmp_dir}" && makepkg -si --noconfirm )
      rm -rf "${tmp_dir}"
    else
      info "${AUR_HELPER} already installed, skipping bootstrap"
    fi

    if [ -n "${AUR_PACKAGES:-}" ]; then
      info "Installing AUR packages: ${AUR_PACKAGES}"
      "${AUR_HELPER}" -S --needed --noconfirm ${AUR_PACKAGES}
    else
      info "AUR_PACKAGES not set, skipping AUR package installation"
    fi
  fi
else
  info "AUR_HELPER not set in .env, skipping AUR setup"
fi

# ============================================================
# 2. Dotfiles (fetch + merge, then stow into ~/.config)
# ============================================================
if [ -n "${DOTFILES_REPO:-}" ]; then
  DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"

  if [ -d "${DOTFILES_DIR}/.git" ]; then
    # Repo present: fetch (safe) then attempt merge. Clean merges auto-apply;
    # conflicts abort and are deferred for manual resolution.
    info "Dotfiles repo present at ${DOTFILES_DIR}, fetching"
    git -C "${DOTFILES_DIR}" fetch --quiet
    upstream="$(git -C "${DOTFILES_DIR}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -n "${upstream}" ]; then
      behind="$(git -C "${DOTFILES_DIR}" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
      if [ "${behind}" = "0" ]; then
        info "Dotfiles up to date with ${upstream}."
      else
        info "Dotfiles ${behind} commit(s) behind ${upstream}; attempting merge"
        if git -C "${DOTFILES_DIR}" merge --no-edit '@{u}' >/dev/null 2>&1; then
          info "Merge completed cleanly."
        else
          git -C "${DOTFILES_DIR}" merge --abort 2>/dev/null || true
          append_note "Dotfiles merge from ${upstream} has conflicts — NOT merged. Resolve manually: cd ${DOTFILES_DIR} && git merge ${upstream} (fix conflicts, then re-run stow). Symlinks reflect the pre-merge state."
        fi
      fi
    else
      info "No upstream tracking branch set; skipping merge."
    fi
  else
    info "Cloning dotfiles repo ${DOTFILES_REPO} -> ${DOTFILES_DIR}"
    git clone "${DOTFILES_REPO}" "${DOTFILES_DIR}"
  fi

  if [ -n "${STOW_PACKAGES:-}" ]; then
    if ! command -v stow >/dev/null 2>&1; then
      error "stow not found — add 'stow' to PACMAN_PACKAGES in .env"
      append_note "Dotfiles not symlinked: stow not installed."
    else
      mkdir -p "${HOME}/.config"
      info "Stowing packages into ~/.config: ${STOW_PACKAGES}"
      ( cd "${DOTFILES_DIR}" && stow -v -t "${HOME}/.config" ${STOW_PACKAGES} )
    fi
  else
    info "STOW_PACKAGES not set, skipping stow step"
  fi
else
  info "DOTFILES_REPO not set, skipping dotfiles setup"
fi

# ============================================================
# 3. Timezone + NTP + Locale + console keymap
# ============================================================
if [ -n "${TIMEZONE:-}" ]; then
  info "Setting timezone to ${TIMEZONE}"
  sudo timedatectl set-timezone "${TIMEZONE}"
fi

if [ "${ENABLE_NTP:-true}" = "true" ]; then
  info "Enabling NTP time sync"
  sudo timedatectl set-ntp true
else
  info "ENABLE_NTP=false, leaving NTP disabled (clock may drift over time)"
fi

if [ -n "${LOCALE:-}" ]; then
  info "Setting locale to ${LOCALE}"
  sudo localectl set-locale "LANG=${LOCALE}"
fi

# Console keymaps: flatten each source map in utilities/keymaps/ into a
# self-contained, include-free .map.gz under /usr/share/kbd/keymaps/custom/.
# Why flatten: the sd-vconsole initramfs hook embeds only the named map, not
# the base map it `include`s (that base lives on the not-yet-mounted root fs
# at early boot), so an include-based map fails early. loadkeys resolves the
# full include tree; dumpkeys --full-table emits the flattened result.
KEYMAP_SRC="./utilities/keymaps"
KEYMAP_DIR="/usr/share/kbd/keymaps/custom"
if [ -d "${KEYMAP_SRC}" ]; then
  if [ ! -d "${KEYMAP_DIR}" ]; then
    info "Creating ${KEYMAP_DIR} (one-time, needs root) and handing it to $(whoami)"
    sudo mkdir -p "${KEYMAP_DIR}"
    sudo chown "$(id -u):$(id -g)" "${KEYMAP_DIR}"
  fi

  for src in "${KEYMAP_SRC}"/*.map; do
    [ -e "${src}" ] || continue
    name="$(basename "${src}" .map)"
    info "Flattening keymap ${name} (resolving includes) -> ${KEYMAP_DIR}/${name}.map.gz"
    if sudo loadkeys "${src}" >/dev/null 2>&1; then
      sudo dumpkeys --full-table | gzip | sudo tee "${KEYMAP_DIR}/${name}.map.gz" >/dev/null
    else
      append_note "Keymap ${name} failed to load/flatten from ${src} — check its include target exists."
    fi
  done

  # Apply the chosen default: load it live AND persist it to vconsole.conf
  # so systemd-vconsole-setup uses it on every boot.
  if [ -n "${DEFAULT_KEYMAP:-}" ]; then
    info "Setting default console keymap to ${DEFAULT_KEYMAP}"
    sudo loadkeys "${DEFAULT_KEYMAP}" 2>/dev/null || \
      append_note "Failed to load default keymap ${DEFAULT_KEYMAP} — check it exists in ${KEYMAP_DIR}."
    set_key_value "KEYMAP" "${DEFAULT_KEYMAP}" "/etc/vconsole.conf"
  fi

  # Re-embed the flattened map into the initramfs for early boot.
  if command -v mkinitcpio >/dev/null 2>&1; then
    info "Rebuilding initramfs so early-boot keymap matches (mkinitcpio -P)"
    sudo mkinitcpio -P
  fi
fi

# ============================================================
# 4. Graphics: GPU driver + Wayland/Sway + Bluetooth + login
# ============================================================

# --- 4a. GPU driver (auto-detected by vendor) ---
if [ "${SETUP_GPU:-true}" = "true" ]; then
  gpu_line="$(lspci | grep -Ei 'vga|3d|display' || true)"
  info "Detected GPU: ${gpu_line:-none found}"
  if echo "${gpu_line}" | grep -qi nvidia; then
    info "NVIDIA GPU detected — installing nvidia-open + nvidia-utils"
    info "(assumes Turing+; pre-Turing cards need a legacy AUR driver instead)"
    sudo pacman -S --needed --noconfirm nvidia-open nvidia-utils
  elif echo "${gpu_line}" | grep -qiE 'amd|radeon|ati'; then
    info "AMD GPU detected — installing mesa + vulkan-radeon"
    sudo pacman -S --needed --noconfirm mesa vulkan-radeon
  elif echo "${gpu_line}" | grep -qi intel; then
    info "Intel GPU detected — installing mesa + vulkan-intel"
    sudo pacman -S --needed --noconfirm mesa vulkan-intel
  else
    info "GPU vendor not recognized — skipping driver install, set up manually"
  fi
else
  info "SETUP_GPU=false, skipping GPU driver install"
fi

# --- 4b. Wayland / Sway compositor stack ---
if [ "${SETUP_WAYLAND:-true}" = "true" ]; then
  if [ -n "${WAYLAND_PACKAGES:-}" ]; then
    info "Installing Wayland/Sway stack: ${WAYLAND_PACKAGES}"
    sudo pacman -S --needed --noconfirm ${WAYLAND_PACKAGES}
  else
    info "WAYLAND_PACKAGES not set, skipping Wayland stack"
  fi
else
  info "SETUP_WAYLAND=false, skipping Wayland stack"
fi

# --- 4c. Bluetooth ---
if [ "${SETUP_BLUETOOTH:-true}" = "true" ]; then
  info "Installing Bluetooth stack (bluez, bluez-utils) and enabling service"
  sudo pacman -S --needed --noconfirm bluez bluez-utils
  sudo systemctl enable bluetooth.service
else
  info "SETUP_BLUETOOTH=false, skipping Bluetooth"
fi

# --- 4d. Login manager: greetd + regreet
# Deliberately NOT handled here. Auto-starting sway on login is shell- and
# user-specific config and belongs in your dotfiles, not install logic.
# For reference, the bash version (in ~/.bash_profile) is:
#   if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
#     exec sway            # append --unsupported-gpu on NVIDIA
#   fi


# --- 4e. Default shell (optional) ---
# zsh is installed via PACMAN_PACKAGES; make it the login shell if requested.
if [ "${SETUP_ZSH_SHELL:-false}" = "true" ] && command -v zsh >/dev/null 2>&1; then
  if [ "${SHELL:-}" != "$(command -v zsh)" ]; then
    info "Setting default login shell to zsh"
    chsh -s "$(command -v zsh)" || \
      append_note "Could not change login shell to zsh — run 'chsh -s $(command -v zsh)' manually."
  fi
fi

success "Userspace setup complete."
echo
if [ ${#NOTES[@]} -ne 0 ]; then
	warn "The following need manual resolution."
	print_notes
fi
