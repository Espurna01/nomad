#!/bin/bash
# forja_bootstrap.sh
# one-file Arch bootstrap: partitions, base install, system config
# following arch wiki, assuming:
#   - ethernet connection
#   - uefi system
set -euo pipefail

info()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
success() { printf "\033[1;32m[SUCCESS]\033[0m %s\n" "$*"; }

# verify bootmode
if [ ! -f /sys/firmware/efi/fw_platform_size ]; then
  error "Bootmode legacy BIOS/CSM, not UEFI. Exiting..."
  exit 1
fi

info "UEFI bootmode: $(cat /sys/firmware/efi/fw_platform_size)-bit"

# enforce use of .env
if [ ! -f .env ]; then
  error ".env not found in working direcotry. Copy template_.env to .env and set your values." >&2
  exit 2
fi
source .env

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

# 1.8 update system clock
info "Enabling NTP time sync"
timedatectl set-ntp true

# 1.9 partition disks
# resolve target
if [ -z "${DISK:-}" ] || [ ! -b "${DISK:-}" ]; then
  [ -n "${DISK:-}" ] && error "DISK='${DISK}' is not a block device."
  info "Available disks:"
  echo
  lsblk -dno NAME,SIZE,TYPE,TRAN,MODEL | awk '$3=="disk"' # filters column 3 (type) by "disk"
  echo

  names=() i=1
  while read -r name; do
    names+=("$name")
    printf "  %d) /dev/%s\n" "$i" "$name"
    i=$((i+1))
  done < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

  [ "${#names[@]}" -gt 0 ] || { error "No disks found. Aborting."; exit 3; }
  echo
  while true; do
    read -rp "Type the number of the disk to install Arch to: " choice
    # if choice is a number in range break
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ]; then
      break
    fi
    error "Invalid selection. Enter a number between 1 and ${#names[@]}."
  done
  DISK="/dev/${names[$((choice-1))]}"
fi
info "Target disk: $DISK"

# partition prefix if nvme
case "$DISK" in
  *[0-9]) P="${DISK}p" ;;
  *) P="${DISK}p" ;;
esac

BOOT_SIZE="${BOOT_SIZE:-1G}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

read -rp "Boot size in GB (default $BOOT_SIZE): " boot_in
if [[ "$swap_in" =~ ^[1-9][0-9]*$ ]]; then
  BOOT_GB=$boot_in
else
  BOOT_GB=$BOOT_SIZE
fi

read -rp "Swap size in GB (default $SWAP_SIZE): " swap_in
if [[ "$swap_in" =~ ^[1-9][0-9]*$ ]]; then
  SWAP_GB=$swap_in
else
  SWAP_GB=$default_swap
fi
info "Layout: efi=${BOOT_GB}, swap=${SWAP_GB}, root=remainder"

error "CAREFUL! following will erase everything on selected disk: '$DISK'"
lsblk lsblk -dno NAME,SIZE,TYPE,TRAN,MODEL "$DISK"
read -rp "Type the disk path '$DISK' to confirm: " confirm
if [ "$confirm" != "$DISK" ]; then
   error "Confirmation mismatch. Aborting."
   exit 6
fi

# wipe and start partitioning
wipefs --all "$DISK"
sfdisk --delete "$DISK" 2>/dev/null || true
sfdisk -X gpt "$DISK" <<EOF
size=${BOOT_GB}G,   type=uefi, name=EFI
size=${SWAP_GB}G,   type=swap, name=swap
                    type=linux, name=root
EOF
info "Formated 3 partitions, confirm if everything is correct"
sfdisk -V $DISK
read -rp "Press ENTER to continue or exit with Ctrl-C" _

# Format filesystem
info "Formatting partitions"
mkfs.fat -F32 "${P}1"
mkswap        "${P}2"
mkfs.ext4 -F  "${P}3"

# mount filesystem
info "Mounting filesystem"
mount "${P}3" /mnt
mount --mkdir "${P}1" /mnt/boot
swapon "${P}2"

# installing basic packages
info "Installing base system (pacstrap), this might take a while..."
pacstrap -K /mnt \
  base linux linux-firmware \
  grub efibootmanager \
  networkmanager \
  sof-firmware base-devel

# fstab
info "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# persistent console keymap file (copied ISO-side from the repo)
if [ -n "${PERS_KEYS:-}" ] && [ -n "${KEYMAP_DIR:-}" ]; then
  info "Copying keymap ${PERS_KEYS} -> /mnt${KEYMAP_DIR}"
  mkdir -p "/mnt${KEYMAP_DIR}"
  cp "$PERS_KEYS" "/mnt${KEYMAP_DIR}/"
fi

# collect interactive identity on the ISO (real tty, before chroot)
if [ -z "${HOSTNAME:-}" ]; then
  read -rp "Hostname: " HOSTNAME
fi
if [ -z "${USERNAME:-}" ]; then
  read -rp "Username (blank to skip user creation): " USERNAME
fi
if [ -z "${ROOT_PASSWORD:-}" ]; then
  read -rsp "Root password: " ROOT_PASSWORD; echo
  read -rsp "Confirm: " confirm; echo
  [ "$ROOT_PASSWORD" = "$confirm" ] || { error "Passwords don't match."; exit 1; }
fi
if [ -n "${USERNAME:-}" ] && [ -z "${USER_PASSWORD:-}" ]; then
  read -rsp "Password for ${USERNAME}: " USER_PASSWORD; echo
  read -rsp "Confirm: " confirm; echo
  [ "$USER_PASSWORD" = "$confirm" ] || { error "Passwords don't match."; exit 1; }
fi

# chroot: non-secret system config (unquoted heredoc expands $vars)
info "Entering chroot to configure the installed system"
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
# 3.3 Time
if [ -n "${TIMEZONE:-}" ]; then
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  hwclock --systohc
fi
# 3.4 Localization
if [ -n "${LOCALE:-}" ]; then
  sed -i "s/^#\\s*\\(${LOCALE}\\)/\\1/" /etc/locale.gen
  locale-gen
  echo "LANG=${LOCALE}" > /etc/locale.conf
fi
if [ -n "${KEYMAP_WRITE:-}" ]; then
  echo "KEYMAP=${KEYMAP_WRITE}" > /etc/vconsole.conf
fi
# 3.5 Network (enable only — cannot start in chroot)
echo "${HOSTNAME}" > /etc/hostname
systemctl enable NetworkManager
# 3.6 Initramfs
mkinitcpio -P
# 3.8 Boot loader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT

# secrets + user: separate arch-chroot calls, no heredoc expansion
# root password
echo "root:${ROOT_PASSWORD}" | arch-chroot /mnt chpasswd

# user creation + password + sudo
if [ -n "${USERNAME:-}" ]; then
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
  echo "${USERNAME}:${USER_PASSWORD}" | arch-chroot /mnt chpasswd
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers
fi

# === reboot ===
success "Base install complete."
info "Unmount and reboot:  umount -R /mnt && reboot"
