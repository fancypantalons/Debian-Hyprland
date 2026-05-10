#!/usr/bin/env bash
# Convenience wrapper to build the monolithic debian-hyprland .deb.
#
# Steps:
#   1. (Optional) install Build-Depends from debian/control via apt.
#   2. Run dpkg-buildpackage to produce the .deb in ../.
#
# The build is NOT offline-capable: install scripts clone from git, fetch
# crates from crates.io, and run npm install. Run on a host with network.
#
# Usage:
#   ./build-deb.sh                # build the .deb (assumes deps already installed)
#   ./build-deb.sh --install-deps # apt-get install Build-Depends first, then build
#   ./build-deb.sh --clean        # clean build artifacts, then build
#   ./build-deb.sh --no-clean     # skip the pre-build clean (preserves staging
#                                 # tree from a prior failed run); pair with
#                                 # START_MODULE=<name> to resume mid-pipeline.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

INSTALL_DEPS=0
DO_CLEAN=0
NO_CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --install-deps) INSTALL_DEPS=1 ;;
    --clean) DO_CLEAN=1 ;;
    --no-clean) NO_CLEAN=1 ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [ "$DO_CLEAN" -eq 1 ] && [ "$NO_CLEAN" -eq 1 ]; then
  echo "ERROR: --clean and --no-clean are mutually exclusive." >&2
  exit 2
fi

if ! [ -f debian/control ]; then
  echo "ERROR: debian/control not found. Run from the repo root." >&2
  exit 1
fi

if [ "$DO_CLEAN" -eq 1 ]; then
  echo "[build-deb] Cleaning previous build artifacts..."
  fakeroot debian/rules clean || rm -rf build/ Install-Logs/ debian/debian-hyprland/ debian/files debian/.debhelper
fi

if [ "$INSTALL_DEPS" -eq 1 ]; then
  if ! command -v mk-build-deps >/dev/null 2>&1; then
    echo "[build-deb] Installing devscripts (provides mk-build-deps)..."
    sudo apt-get update
    sudo apt-get install -y devscripts equivs
  fi
  echo "[build-deb] Installing Build-Depends from debian/control..."
  sudo mk-build-deps --install --remove --tool='apt-get -y -o Debug::pkgProblemResolver=yes --no-install-recommends' debian/control
fi

# Sanity check: required tools.
for tool in dpkg-buildpackage debhelper fakeroot; do
  if ! command -v "$tool" >/dev/null 2>&1 && ! dpkg -l "$tool" 2>/dev/null | grep -q '^ii'; then
    echo "WARNING: '$tool' not found. Install with: sudo apt-get install dpkg-dev debhelper fakeroot" >&2
  fi
done

DPKG_ARGS=(-us -uc -b -rfakeroot)
if [ "$NO_CLEAN" -eq 1 ]; then
  DPKG_ARGS+=(-nc)
  echo "[build-deb] --no-clean: skipping pre-build clean (preserves staging tree)."
fi
if [ -n "${START_MODULE:-}" ]; then
  echo "[build-deb] START_MODULE=$START_MODULE will be passed through to package-build.sh."
fi

echo "[build-deb] Running dpkg-buildpackage ${DPKG_ARGS[*]}..."
dpkg-buildpackage "${DPKG_ARGS[@]}"

echo "============================================================"
echo "[build-deb] Done. Generated package(s):"
ls -la ../debian-hyprland_*.deb 2>/dev/null || echo "  (no .deb found in parent dir)"
echo "============================================================"
