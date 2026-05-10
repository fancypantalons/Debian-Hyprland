#!/bin/bash
# ==================================================
#  KoolDots (2026)
#  Project URL: https://github.com/LinuxBeginnings
#  License: GNU GPLv3
#  SPDX-License-Identifier: GPL-3.0-or-later
# ==================================================
# 💫 https://github.com/LinuxBeginnings 💫 #
# Global Functions for Scripts #

set -e

# Set some colors for output messages (be resilient in non-interactive shells)
if tput sgr0 >/dev/null 2>&1; then
  OK="$(tput setaf 2)[OK]$(tput sgr0)"
  ERROR="$(tput setaf 1)[ERROR]$(tput sgr0)"
  NOTE="$(tput setaf 3)[NOTE]$(tput sgr0)"
  INFO="$(tput setaf 4)[INFO]$(tput sgr0)"
  WARN="$(tput setaf 1)[WARN]$(tput sgr0)"
  CAT="$(tput setaf 6)[ACTION]$(tput sgr0)"
  MAGENTA="$(tput setaf 5)"
  ORANGE="$(tput setaf 214)"
  WARNING="$(tput setaf 1)"
  YELLOW="$(tput setaf 3)"
  GREEN="$(tput setaf 2)"
  BLUE="$(tput setaf 4)"
  SKY_BLUE="$(tput setaf 6)"
  RESET="$(tput sgr0)"
else
  OK="[OK]"; ERROR="[ERROR]"; NOTE="[NOTE]"; INFO="[INFO]"; WARN="[WARN]"; CAT="[ACTION]"
  MAGENTA=""; ORANGE=""; WARNING=""; YELLOW=""; GREEN=""; BLUE=""; SKY_BLUE=""; RESET=""
fi

# Create Directory for Install Logs
if [ ! -d Install-Logs ]; then
    mkdir Install-Logs
fi

# Shared build output root (override with BUILD_ROOT env)
BUILD_ROOT="${BUILD_ROOT:-$PWD/build}"
mkdir -p "$BUILD_ROOT"
SRC_ROOT="${SRC_ROOT:-$BUILD_ROOT/src}"
mkdir -p "$SRC_ROOT"

# Install prefix for built components. Defaults to /usr (Debian-package layout).
# Override with INSTALL_PREFIX env var (e.g. /usr/local for a local /usr/local install).
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr}"

# Staging directory for packaging. Empty = install directly to live filesystem (default).
# When set (e.g. by debian/rules), installs go to "$DESTDIR$INSTALL_PREFIX/..." with no sudo.
DESTDIR="${DESTDIR:-}"

# Helper: emit the sudo prefix for install commands.
# When DESTDIR is empty we install into the live filesystem and need sudo;
# when DESTDIR is set we are staging into a build dir owned by the current user.
install_sudo() {
  if [ -z "$DESTDIR" ]; then echo "sudo"; else echo ""; fi
}

# Helper: emit "DESTDIR=... " for a build-system install command, or empty.
install_destdir_env() {
  if [ -n "$DESTDIR" ]; then echo "DESTDIR=$DESTDIR"; else echo ""; fi
}

# Detect Debian multi-arch triplet (e.g. x86_64-linux-gnu). On Debian, CMake's
# GNUInstallDirs places libs and .pc files under lib/<triplet>/ when
# CMAKE_INSTALL_PREFIX=/usr, so we need this in path layering.
DEB_HOST_MULTIARCH="${DEB_HOST_MULTIARCH:-$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)}"
export DEB_HOST_MULTIARCH

# Make components built earlier in this run discoverable to later builds.
# Layered: staging tree first (for packaging builds), then runtime prefix
# (for live installs and system fallback). Each layer covers both the
# multi-arch lib path and the plain lib path.
export PKG_CONFIG_PATH="\
$DESTDIR$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH/pkgconfig:\
$DESTDIR$INSTALL_PREFIX/lib/pkgconfig:\
$DESTDIR$INSTALL_PREFIX/share/pkgconfig:\
$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH/pkgconfig:\
$INSTALL_PREFIX/lib/pkgconfig:\
$INSTALL_PREFIX/share/pkgconfig:\
${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$DESTDIR$INSTALL_PREFIX:$INSTALL_PREFIX:${CMAKE_PREFIX_PATH:-}"
export PATH="$DESTDIR$INSTALL_PREFIX/bin:$INSTALL_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="\
$DESTDIR$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH:\
$DESTDIR$INSTALL_PREFIX/lib:\
$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH:\
$INSTALL_PREFIX/lib:\
${LD_LIBRARY_PATH:-}"

# CPATH and LIBRARY_PATH augment the compiler's default include/library
# search. Some upstream CMakeLists (e.g. hyprland-qt-support) link bare-name
# targets like `hyprlang` instead of `PkgConfig::hyprlang`, so include dirs
# from pkg_check_modules don't propagate. In a live install this works
# because /usr/include is in gcc's default path; we need the staging tree
# treated the same way.
#
# IMPORTANT: do NOT add $INSTALL_PREFIX/include to CPATH. Listing /usr/include
# in CPATH puts it ahead of /usr/include/c++/<ver>/ in the search order, which
# breaks `#include_next <stdlib.h>` from <cstdlib>. CPATH is for the staging
# tree only; gcc's built-in default already finds /usr/include in the right
# position. (LIBRARY_PATH doesn't have the same issue — the linker has no
# `#include_next` analogue.)
export CPATH="\
$DESTDIR$INSTALL_PREFIX/include:\
${CPATH:-}"
export LIBRARY_PATH="\
$DESTDIR$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH:\
$DESTDIR$INSTALL_PREFIX/lib:\
${LIBRARY_PATH:-}"

# When building module B against staged module A's shared lib, the linker
# must also resolve A's NEEDED entries (indirect deps). Without this,
# the linker falls through to /usr/lib/$multiarch/ and may pick up a
# previously-installed older version of one of our own components,
# producing soname/ABI mismatches. -Wl,-rpath-link tells the linker to
# search the staging tree FIRST for indirect deps. This is link-time only;
# nothing gets baked into the final binary's rpath.
if [ -n "$DESTDIR" ]; then
  export LDFLAGS="\
-Wl,-rpath-link=$DESTDIR$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH \
-Wl,-rpath-link=$DESTDIR$INSTALL_PREFIX/lib \
-L$DESTDIR$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH \
-L$DESTDIR$INSTALL_PREFIX/lib \
${LDFLAGS:-}"
fi

# DESTDIR + pkg-config reconciliation:
# Staged .pc files have `prefix=$INSTALL_PREFIX` (e.g. /usr) baked in, but
# the actual files live at $DESTDIR$INSTALL_PREFIX. So `pkg-config --cflags`
# returns `-I/usr/include` which doesn't exist during a packaging build.
# Solution: write a parallel set of .pc files into $BUILD_ROOT/staged-pkgconfig/
# with `prefix=` rewritten to the staging path, and prepend that dir to
# PKG_CONFIG_PATH. The originals (which ship in the .deb) remain unmodified.
# Some Debian -dev packages don't ship .pc files, but CMake's pkg_check_modules
# requires them. Synthesize minimal .pc files for those system libraries so
# the build can discover them. These are created in the global staged-pkgconfig
# directory so they're available to all modules.
synthesize_system_pc_files() {
  local pc_dir="${BUILD_ROOT}/staged-pkgconfig"
  mkdir -p "$pc_dir"

  # libpci-dev: ships headers + libpci.a/.so but no .pc file
  if [ ! -f "$pc_dir/libpci.pc" ]; then
    cat >"$pc_dir/libpci.pc" <<'EOPC'
prefix=/usr
exec_prefix=${prefix}
libdir=${prefix}/lib/${DEB_HOST_MULTIARCH}
includedir=${prefix}/include

Name: libpci
Description: PCI Utilities library
Version: 3.15.0
Libs: -L${libdir} -lpci
Cflags: -I${includedir}
EOPC
  fi
}
synthesize_system_pc_files

stage_pkgconfig_for_destdir() {
  [ -n "$DESTDIR" ] || return 0
  local STAGED_PC_DIR="${BUILD_ROOT}/staged-pkgconfig"
  mkdir -p "$STAGED_PC_DIR"
  local pc_dir pc out
  for pc_dir in \
    "$DESTDIR$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH/pkgconfig" \
    "$DESTDIR$INSTALL_PREFIX/lib/pkgconfig" \
    "$DESTDIR$INSTALL_PREFIX/share/pkgconfig"
  do
    [ -d "$pc_dir" ] || continue
    for pc in "$pc_dir"/*.pc; do
      [ -f "$pc" ] || continue
      out="$STAGED_PC_DIR/$(basename "$pc")"
      if [ ! -f "$out" ] || [ "$pc" -nt "$out" ]; then
        # Rewrite every assignment line (^name=...) whose value starts with
        # $INSTALL_PREFIX (followed by '/' or end-of-line). Some upstreams use
        # ${prefix}-relative includedir/libdir; others hardcode absolute paths.
        # This handles both: any `name=$INSTALL_PREFIX[...]` line gets DESTDIR
        # prepended; lines like `name=${prefix}/include` are left alone.
        sed -E "s|^([A-Za-z_][A-Za-z0-9_]*)=$INSTALL_PREFIX(/\|$)|\1=$DESTDIR$INSTALL_PREFIX\2|" "$pc" > "$out"
      fi
    done
  done
  case ":$PKG_CONFIG_PATH:" in
    *":$STAGED_PC_DIR:"*) ;;
    *) export PKG_CONFIG_PATH="$STAGED_PC_DIR:$PKG_CONFIG_PATH" ;;
  esac
}
# FindPkgConfig.cmake's _pkg_find_libs accumulates every -L flag from every
# .pc file into one _search_paths list. System .pc files (wayland-client,
# egl, etc.) contribute -L/usr/lib/x86_64-linux-gnu first, so find_library's
# NO_DEFAULT_PATH search finds old system-installed copies of our own staged
# libs (e.g. libhyprutils.so.10 in /usr/lib vs libhyprutils.so.12 in staging)
# before ever reaching the staging tree.
#
# Fix: create shadow copies of system .pc files with -L flags stripped.
# The linker already searches /usr/lib/<multiarch> by default, so removing
# -L${libdir} from system .pc files is safe. Place these shadows before the
# system paths in PKG_CONFIG_PATH so pkg-config finds them first.
shadow_system_pkgconfig_for_destdir() {
  [ -n "$DESTDIR" ] || return 0
  local shadow_dir="${BUILD_ROOT}/shadow-system-pkgconfig"
  mkdir -p "$shadow_dir"
  local pc_dir pc out name

  for pc_dir in \
    "$INSTALL_PREFIX/lib/$DEB_HOST_MULTIARCH/pkgconfig" \
    "$INSTALL_PREFIX/lib/pkgconfig" \
    "$INSTALL_PREFIX/share/pkgconfig"
  do
    [ -d "$pc_dir" ] || continue
    for pc in "$pc_dir"/*.pc; do
      [ -f "$pc" ] || continue
      name="$(basename "$pc")"
      out="$shadow_dir/$name"
      [ -f "$out" ] && continue
      sed 's/ -L[^ ]*//g' "$pc" > "$out"
    done
  done

  case ":$PKG_CONFIG_PATH:" in
    *":$shadow_dir:"*) ;;
    *) export PKG_CONFIG_PATH="$shadow_dir:$PKG_CONFIG_PATH" ;;
  esac
}
shadow_system_pkgconfig_for_destdir

stage_pkgconfig_for_destdir

# Show progress function
show_progress() {
    local pid=$1
    local package_name=$2
    local spin_chars=("●○○○○○○○○○" "○●○○○○○○○○" "○○●○○○○○○○" "○○○●○○○○○○" "○○○○●○○○○" \
                      "○○○○○●○○○○" "○○○○○○●○○○" "○○○○○○○●○○" "○○○○○○○○●○" "○○○○○○○○○●") 
    local i=0

    tput civis 
    printf "\r${INFO} Installing ${YELLOW}%s${RESET} ..." "$package_name"

    while ps -p $pid &> /dev/null; do
        printf "\r${INFO} Installing ${YELLOW}%s${RESET} %s" "$package_name" "${spin_chars[i]}"
        i=$(( (i + 1) % 10 ))  
        sleep 0.3  
    done

    printf "\r${INFO} Installing ${YELLOW}%s${RESET} ... Done!%-20s \n\n" "$package_name" ""
    tput cnorm  
}


# Function for installing packages with a progress bar
install_package() { 
  if [ -n "$DESTDIR" ]; then
    echo -e "${INFO} Skipping apt install of ${MAGENTA}$1${RESET} (DESTDIR build; handled by Build-Depends)."
    return 0
  fi
  if dpkg -l | grep -q -w "$1" ; then
    echo -e "${INFO} ${MAGENTA}$1${RESET} is already installed. Skipping..."
  else 
    (
      stdbuf -oL sudo apt install -y "$1" 2>&1
    ) >> "$LOG" 2>&1 &
    PID=$!
    show_progress $PID "$1" 
    
    # Double check if the package successfully installed
    if dpkg -l | grep -q -w "$1"; then
        echo -e "\e[1A\e[K${OK} Package ${YELLOW}$1${RESET} has been successfully installed!"
    else
        echo -e "\e[1A\e[K${ERROR} ${YELLOW}$1${RESET} failed to install. Please check the install.log. You may need to install it manually. Sorry, I have tried :("
    fi
  fi
}
# Function for installing packages from a target release (e.g., backports)
install_package_target() {
  local pkg="$1"
  local target="$2"
  if dpkg -l | grep -q -w "$pkg" ; then
    echo -e "${INFO} ${MAGENTA}$pkg${RESET} is already installed. Skipping..."
  else
    (
      stdbuf -oL sudo apt install -y -t "$target" "$pkg" 2>&1
    ) >> "$LOG" 2>&1 &
    PID=$!
    show_progress $PID "$pkg"

    # Double check if the package successfully installed
    if dpkg -l | grep -q -w "$pkg"; then
      echo -e "\e[1A\e[K${OK} Package ${YELLOW}$pkg${RESET} has been successfully installed!"
    else
      echo -e "\e[1A\e[K${ERROR} ${YELLOW}$pkg${RESET} failed to install. Please check the install.log. You may need to install it manually. Sorry, I have tried :("
    fi
  fi
}

# Function for build depencies with a progress bar
build_dep() {
  if [ -n "$DESTDIR" ]; then
    echo -e "${INFO} Skipping apt build-dep for ${MAGENTA}$1${RESET} (DESTDIR build; handled by Build-Depends)."
    return 0
  fi
  echo -e "${INFO} building dependencies for ${MAGENTA}$1${RESET} "
    (
      stdbuf -oL sudo apt build-dep -y "$1" 2>&1
    ) >> "$LOG" 2>&1 &
    PID=$!
    show_progress $PID "$1"
}

# Function for cargo install with a progress bar
cargo_install() { 
  echo -e "${INFO} installing ${MAGENTA}$1${RESET} using cargo..."
    (
      stdbuf -oL cargo install "$1" 2>&1
    ) >> "$LOG" 2>&1 &
    PID=$!
    show_progress $PID "$1" 
}

# Function for re-installing packages with a progress bar
re_install_package() {
    if [ -n "$DESTDIR" ]; then
        echo -e "${INFO} Skipping apt reinstall of ${MAGENTA}$1${RESET} (DESTDIR build; handled by Build-Depends)."
        return 0
    fi
    (
        stdbuf -oL sudo apt install --reinstall -y "$1" 2>&1
    ) >> "$LOG" 2>&1 &
    
    PID=$!
    show_progress $PID "$1" 
    
    if dpkg -l | grep -q -w "$1"; then
        echo -e "\e[1A\e[K${OK} Package ${YELLOW}$1${RESET} has been successfully re-installed!"
    else
        # Package not found, reinstallation failed
        echo -e "${ERROR} ${YELLOW}$1${RESET} failed to re-install. Please check the install.log. You may need to install it manually. Sorry, I have tried :("
    fi
}

# Function for removing packages
uninstall_package() {
  local pkg="$1"

  # Checking if package is installed
  if sudo dpkg -l | grep -q -w "^ii  $1" ; then
    echo -e "${NOTE} removing $pkg ..."
    sudo apt autoremove -y "$1" >> "$LOG" 2>&1 | grep -v "error: target not found"
    
    if ! dpkg -l | grep -q -w "^ii  $1" ; then
      echo -e "\e[1A\e[K${OK} ${MAGENTA}$1${RESET} removed."
    else
      echo -e "\e[1A\e[K${ERROR} $pkg Removal failed. No actions required."
      return 1
    fi
  else
    echo -e "${INFO} Package $pkg not installed, skipping."
  fi
  return 0
}