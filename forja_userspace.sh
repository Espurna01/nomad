#!/bin/bash
# forja_userspace.sh
# Post-reboot userspace setup: packages, configs, interface, sound...
set -euo pipefail

source helpers.sh

enforce_env

[ $(id -u) -eq 0 ] && error "Don't run $0 as root (sudo $0). Run as normal user." && exit

# Package installation and AUR (Arch User Repo)
if [ -n "${PACMAN_PACKAGES:-}" ]; then
	info "Installing essential packages from PACMAN_PACKAGES..."
	before=$(pacman -Q | wc -l)
	sudo pacman -Syu $PACMAN_PACKAGES
	after=$(pacman -Q | wc -l)
	info "Installed a total of $((after - before))"
else 
	info "PACMAN_PACKAGES not set in .env, skipping package install"
fi

if [ -n "${AUR_HELPER:-}" ]; then
	if ! command -v makepkg >/dev/null 2>&1; then
		error "makepkg not found, base-devel package wasn't installed correctly or not on PACMAN_PACKAGES"
	elif ! command -v ${AUR_HELPER} >/dev/null 2>&1; then
		info "Bootstraping AUR helper: ${AUR_HELPER}"
		tmp_dir="$(mktemp -d)"
		git clone "https://aur.archlinux.org/${AUR_HELPER}.git "${tmp_dir}"
		( cd "${tmp_dir} && makepkg
	fi

else 
	info "AUR_HELPER not set in .env, skipping package install"
fi

if [
