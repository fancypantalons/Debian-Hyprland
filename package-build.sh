#!/usr/bin/env bash
# Orchestrator for the Debian-package build.
#
# Invokes the build-and-install install-scripts in dependency order with
# INSTALL_PREFIX and DESTDIR set so everything lands in the staging tree
# instead of the live filesystem. Called from debian/rules.
#
# Skips:
#   - Apt-dep installers (00-dependencies.sh, 01-hypr-pkgs.sh) — handled by Build-Depends.
#   - Cleanup/post-install (02-pre-cleanup.sh, 03-Final-Check.sh).
#   - Theming/config/system-tweak scripts (fonts, dotfiles*, gtk_themes,
#     sddm*, bluetooth, nvidia*, rog, thunar*, InputGroup, zsh*).
#
# Build sources are cloned into $SRC_ROOT (defaults to ./build/src) at build time.
# This requires network access — the build is not offline-capable.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Sanity: required env from debian/rules.
: "${INSTALL_PREFIX:=/usr}"
: "${DESTDIR:?DESTDIR must be set (debian/rules sets this)}"
export INSTALL_PREFIX DESTDIR

# Create the staging root and standard subdirs so install -D operations succeed.
mkdir -p "$DESTDIR$INSTALL_PREFIX/bin" \
         "$DESTDIR$INSTALL_PREFIX/lib" \
         "$DESTDIR$INSTALL_PREFIX/include" \
         "$DESTDIR$INSTALL_PREFIX/share"

mkdir -p Install-Logs

# Build order mirrors install.sh's main flow. hyprwire-protocols.sh is invoked
# transitively by hyprtavern.sh when needed, so it's not listed here.
MODULES=(
  hyprutils
  hyprlang
  hyprcursor
  hyprwayland-scanner
  hyprgraphics
  aquamarine
  hyprland-qt-support
  hyprtoolkit
  hyprland-guiutils
  hyprland-protocols
  wayland-protocols-src
  xkbcommon
  hyprwire
  hyprland
  hyprpolkitagent
  wallust
  swww
  rofi-wayland
  hyprlock
  hypridle
  hyprpaper
  hyprpicker
  hyprshutdown
  hyprpwcenter
  hyprtavern
  hyprsunset
  hyprlauncher
  hyprsysteminfo
  xdph
  ags
  quickshell
)

run_module() {
  local mod="$1"
  local script="install-scripts/${mod}.sh"
  if [ ! -x "$script" ]; then
    echo "ERROR: $script not found or not executable" >&2
    return 1
  fi
  echo "============================================================"
  echo "[package-build] $mod"
  echo "============================================================"
  bash "$script"
}

# Optional resume: START_MODULE=<name> drops everything in MODULES before <name>.
# Useful when a build failed partway and the staging tree is intact — combine with
# `dpkg-buildpackage -nc` (or `./build-deb.sh --no-clean`) so debian/rules clean
# doesn't wipe the previously-built artifacts.
if [ -n "${START_MODULE:-}" ]; then
  found=0
  filtered=()
  for mod in "${MODULES[@]}"; do
    if [ "$found" -eq 0 ] && [ "$mod" != "$START_MODULE" ]; then
      continue
    fi
    found=1
    filtered+=("$mod")
  done
  if [ "$found" -eq 0 ]; then
    echo "ERROR: START_MODULE='$START_MODULE' is not in the MODULES list." >&2
    exit 2
  fi
  MODULES=("${filtered[@]}")
  echo "[package-build] Resuming from '$START_MODULE' (${#MODULES[@]} modules to run)."
fi

for mod in "${MODULES[@]}"; do
  if ! run_module "$mod"; then
    echo "============================================================" >&2
    echo "[package-build] FAILED: $mod — aborting build." >&2
    echo "[package-build] Fix the failing module and re-run ./build-deb.sh" >&2
    echo "============================================================" >&2
    exit 1
  fi
done

# Strip build-time-only artifacts that collide with system packages.
# These are needed during the build (later modules consume XMLs, headers,
# and CMake config files) but must not ship in the .deb because they
# overlap files owned by other Debian packages — `dpkg -i` would refuse
# the install otherwise.
echo "[package-build] Stripping build-time-only artifacts from staging..."
strip_paths=(
  # Owned by libglaze-dev
  "$DESTDIR$INSTALL_PREFIX/include/glaze"
  "$DESTDIR$INSTALL_PREFIX/share/glaze"
  # Owned by the system wayland-protocols package
  "$DESTDIR$INSTALL_PREFIX/include/wayland-protocols"
  "$DESTDIR$INSTALL_PREFIX/share/wayland-protocols"
  "$DESTDIR$INSTALL_PREFIX/share/pkgconfig/wayland-protocols.pc"
  # Owned by libxkbcommon-dev / libxkbcommon-x11-dev / libxkbregistry-dev
  "$DESTDIR$INSTALL_PREFIX/include/xkbcommon"
)
for p in "${strip_paths[@]}"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    echo "  rm -rf $p"
    rm -rf "$p"
  fi
done

# Global_functions.sh's stage_pkgconfig_for_destdir generates rewritten copies
# of every staged .pc into $BUILD_ROOT/staged-pkgconfig/, with prefix= pointing
# at $DESTDIR. Those rewrites are never re-deleted, so a .pc whose source path
# we just stripped (e.g. wayland-protocols.pc) stays in the rewrite cache and
# pkg-config still finds it on the next module build — pointing at directories
# that no longer exist. Wipe the cache so the next build regenerates from the
# current (stripped) DESTDIR.
if [ -d "${BUILD_ROOT:-build}/staged-pkgconfig" ]; then
  echo "  rm -rf ${BUILD_ROOT:-build}/staged-pkgconfig"
  rm -rf "${BUILD_ROOT:-build}/staged-pkgconfig"
fi

echo "============================================================"
echo "[package-build] All ${#MODULES[@]} modules built and staged successfully."
echo "[package-build] Staged into: $DESTDIR"
echo "============================================================"
