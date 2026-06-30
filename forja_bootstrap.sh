#!/bin/bash
# forja_bootstrap.sh
# a one file script that sets up partitions, user and other bootstrap configurations
set -euo pipefail

info()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
success() { printf "\033[1;32m[SUCCESS]\033[0m %s\n" "$*"; }

if [ ! -f .env ]; then
  error ".env not found in working direcotry. Copy template_.env to .env and set your values." >&2
  exit 1
fi
source .env

: "${KEYMAP_DIR:?error: KEYMAP_DIR not set in .env}"
: "${KEYMAP_WRITE:?error: KEYMAP_WRITE not set in .env}"
: "${PERS_KEYS:?error: PERS_KEYS not set in .env}"
: "${USER:?error: USER not set in .env}"

# idempotent set key value on configuration file
set_key_value() { # pls don't use | as key/value
  local key="$1" value="$2" file="$3"
  local line="${key}=${value}"
  if grep -q "^\s*${key}\s*=" "$file" 2>/dev/null; then
    sed -i "s|^\s*${key}\s*=.*|${line}|" "$file"
  else
    echo "${line}" >> "$file"
  fi
}

info "Adding KEYMAP configuration from $PERS_KEYS to $KEYMAP_DIR"
mkdir -p "$KEYMAP_DIR"
cp "$PERS_KEYS" "$KEYMAP_DIR"
set_key_value KEYMAP "$KEYMAP_WRITE" /etc/vconsole.conf
info "Restarting systemd-vconsole service for the changes to take effect"
systemctl restart systemd-vconsole-setup.service
success "Successfully configured /etc/vconsole.conf"


if [ ! -f /sys/firmware/efi/fw_platform_size ]; then
  error "Bootmode legacy BIOS or CSM, not UEFI. Exiting..."
  exit 2
fi

t=$(cat /sys/firmware/efi/fw_platform_size)
info "UEFI bootmode: $t"




