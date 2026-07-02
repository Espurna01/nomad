#!/bin/bash
# forja_userspace.sh
# Post-reboot userspace setup: packages, configs, interface, sound...
set -euo pipefail

source helpers.sh

enforce_env

if [ -n PACMAN_PACKAGES ]; then
	pacman -Syu --no-confirm
