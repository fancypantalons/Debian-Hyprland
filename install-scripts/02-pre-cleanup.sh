#!/bin/bash
# ==================================================
#  KoolDots (2026)
#  Project URL: https://github.com/LinuxBeginnings
#  License: GNU GPLv3
#  SPDX-License-Identifier: GPL-3.0-or-later
# ==================================================
# This script is cleaning up previous manual installation files / directories

# 22 Aug 2024
# Files to be removed from previous install locations.
# Includes legacy /usr/local/bin (older installer versions) and the current
# $INSTALL_PREFIX/bin (set in Global_functions.sh, sourced below).

# Define packages to manually remove (was manually installed previously)
PACKAGES=(
  cliphist
  pypr
  swappy
  waybar
  magick
)

# List of packages installed from Debian-Hyprland repo
uninstall=(
  hyprland
  hyprland-plugins
  hyprland-session
  hyprland-protocols
  hyprland-guiutils
  hyprland-qt-support
  hyprland-qtutils
  hyprutils
  libhyprutils-dev
  libhyprutils0
  hyprlang
  libhyprlang-dev
  libhyprlang0
  hyprgraphics
  libhyprgraphics-dev
  libhyprgraphics0
  hyprcursor
  libhyprcursor-dev
  libhyprcursor0
  hyprwayland-scanner
  hyprtoolkit
  hyprwire
  hyprwire-protocols
  libhyprwire-dev
  libhyprwire0
  aquamarine
  libaquamarine-dev
  libaquamarine0
  hypridle
  hyprlock
  hyprpicker
  hyprpaper
  hyprsunset
  hyprlauncher
  hyprsysteminfo
  hyprpolkitagent
  hyprctl
  hyprpm
  xdg-desktop-portal-hyprland
  libhhyprland-dev
  Hyprland
)

## WARNING: DO NOT EDIT BEYOND THIS LINE IF YOU DON'T KNOW WHAT YOU ARE DOING! ##
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Change the working directory to the parent directory of the script
PARENT_DIR="$SCRIPT_DIR/.."
cd "$PARENT_DIR" || { echo "${ERROR} Failed to change directory to $PARENT_DIR"; exit 1; }

# Source the global functions script
if ! source "$(dirname "$(readlink -f "$0")")/Global_functions.sh"; then
  echo "Failed to source Global_functions.sh"
  exit 1
fi

# Set the name of the log file to include the current date and time
LOG="Install-Logs/install-$(date +%d-%H%M%S)_pre-clean-up.log"

# Cleanup target dirs: legacy /usr/local/bin (older installer versions) and current $INSTALL_PREFIX/bin.
# Deduplicate in case INSTALL_PREFIX is /usr/local.
TARGET_DIRS=("/usr/local/bin")
if [ "$INSTALL_PREFIX/bin" != "/usr/local/bin" ]; then
  TARGET_DIRS+=("$INSTALL_PREFIX/bin")
fi

# Loop through the list of packages across all target dirs
for TARGET_DIR in "${TARGET_DIRS[@]}"; do
  for PKG_NAME in "${PACKAGES[@]}"; do
    FILE_PATH="$TARGET_DIR/$PKG_NAME"
    if [[ -f "$FILE_PATH" ]]; then
      sudo rm "$FILE_PATH"
      echo "Deleted: $FILE_PATH" 2>&1 | tee -a "$LOG"
    else
      echo "File not found: $FILE_PATH" 2>&1 | tee -a "$LOG"
    fi
  done
done


# packages removal installed from Debian-Hyprland repo
overall_failed=0
printf "\n%s - ${SKY_BLUE}Removing some packages${RESET} installed from Debian Hyprland official repo \n" "${NOTE}"
for PKG in "${uninstall[@]}"; do
  uninstall_package "$PKG" 2>&1 | tee -a "$LOG"
  if [ $? -ne 0 ]; then
    overall_failed=1
  fi
done

if [ $overall_failed -ne 0 ]; then
  echo -e "${ERROR} Some packages failed to uninstall. Please check the log."
fi

printf "\n%.0s" {1..1}