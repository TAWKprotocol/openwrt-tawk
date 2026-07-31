#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build Morse Micro's OpenWrt for a Raspberry Pi 4B carrying a Seeed WM6108 HaLow
# card, and prepare the WM1302 Pi HAT device tree overlay for it.
#
# Why this and not the stock-kernel route: morse_driver needs kernel patches that a
# stock kernel does not have -- a spi-bcm2835 chip-select patch plus seven mac80211
# S1G patches (BRINGUP.md §5). Building against a stock kernel compiles cleanly and
# still fails at the first SPI register read. A forum user with *identical* hardware
# (Pi + WM1302 HAT + WM6108 + FGH100MHAAMD) got the driver up only on a
# Morse-patched kernel.
#
# Why Morse's fork and not Seeed's: Morse staff explicitly steer users to their own
# tree; the Seeed/Wvirgil fork is a stale whole-tree copy that cannot rebase.
# Morse's EKH01 evaluation kit *is* a Raspberry Pi 4B, so their tree already targets
# this board. Note EKH01 survives as the *device* name
# (DEVICE_morse_mm6108-ekh01-spi) even though the board-config directory was renamed;
# that mismatch is what makes "-b ekh01" look plausible when it no longer exists.
#
# RUN THIS ON AN x86_64 LINUX BUILD HOST, not on the Pi and not on macOS.
# Needs ~50 GB free and takes 1-3 hours.
#
# Host toolchain trouble (GCC 15 vs the golang host build, the dropped
# python3-distutils) is best avoided by building in the container Morse's own CI
# uses rather than on a modern distro -- see docker-compose.morse-openwrt.yml,
# which pins ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 straight from their
# .devcontainer. Run this script inside that container and the apt step below is
# a no-op.
#
set -euo pipefail

REPO="${REPO:-https://github.com/MorseMicro/openwrt.git}"
# 3.0.2 pairs the mm6108-2.0.1 driver with MM6108 parts (3.1.1 pairs MM6108 with the
# older 1.17.8 and reserves 2.0.0 for MM8108). For a WM6108, 3.0.2 is the one.
TAG="${TAG:-3.0.2}"
# Boards were reorganised to ekh-<target>-<chip>. At 3.0.2 there is NO "ekh01" --
# despite morse_setup.sh's own help text still showing "-b ekh01" and "-b ekh03v4"
# in its examples (stale docs; this is what makes the obvious first guess fail with
# a missing *_hw_diffconfig). The Pi 4 + MM6108 board is:
BOARD="${BOARD:-ekh-bcm2711-mm6108}"
SRC="${SRC:-$HOME/morse-openwrt}"

echo "== build dependencies =="
sudo apt-get update
# Morse's README lists python3-distutils, which does NOT exist on Ubuntu 24.04+
# (Python 3.12 removed distutils). python3-setuptools supplies the shim instead.
DISTUTILS_PKG="python3-setuptools"
apt-cache show python3-distutils >/dev/null 2>&1 && DISTUTILS_PKG="python3-distutils"
sudo apt-get install -y \
	build-essential clang flex g++ gawk gcc-multilib git gettext \
	libncurses-dev libssl-dev "$DISTUTILS_PKG" rsync unzip zlib1g-dev swig \
	file wget which time python3

echo "== free space check (OpenWrt wants ~50 GB) =="
df -h "$(dirname "$SRC")" | tail -1

echo "== source ($TAG) =="
[ -d "$SRC/.git" ] || git clone "$REPO" "$SRC"
cd "$SRC"
git fetch --tags
git checkout "$TAG"

# --- Known bug in Morse's 3.0.2 board configs -------------------------------
# A board diffconfig sets CONFIG_PACKAGE_morsectrl=y, but the *pinned* morse-feed
# (feeds.conf.default: morse-feed.git^c880dca4) ships that package as `morsecli`.
# morse_setup.sh runs `make defconfig` with KCONFIG_WARN_UNKNOWN_SYMBOLS=1 and
# KCONFIG_WERROR=1, so a stale symbol is FATAL rather than a warning:
#     .config:302:warning: unknown symbol: PACKAGE_morsectrl
#     SETUP FAILED: error 2 ... from: make defconfig
# This is a config bug, not a host-environment one -- it reproduces identically
# inside a build container. Rename it before assembling .config.
if grep -rqs 'CONFIG_PACKAGE_morsectrl' boards/; then
	echo "== patching stale CONFIG_PACKAGE_morsectrl -> morsecli =="
	grep -rls 'CONFIG_PACKAGE_morsectrl' boards/ | tee /dev/stderr \
		| xargs sed -i 's/^CONFIG_PACKAGE_morsectrl=/CONFIG_PACKAGE_morsecli=/'
fi

echo "== available boards in this tree =="
ls -1 boards/ | grep -v '^common' | sed 's/^/  /'
[ -d "boards/$BOARD" ] || { echo "FATAL: boards/$BOARD not present in tag $TAG"; exit 1; }

echo "== configure for $BOARD =="
# -i updates/installs feeds; -b assembles .config from boards/<board>/*_diffconfig.
# Add -E to fetch a prebuilt toolchain instead of building one (much faster).
# If it aborts with "<file> is not a symlink", fall back to -m: minimal mode uses
# only target_diffconfig, which is exempt from that check, and extras can be added
# back individually with -x.
./scripts/morse_setup.sh -i -b "$BOARD" \
  || { echo "retrying in minimal mode"; ./scripts/morse_setup.sh -i -m -b "$BOARD"; }

echo "== build =="
make -j"$(nproc)" || {
	echo
	echo "Build failed. Re-run serially with full output to find the real error:"
	echo "  cd $SRC && make -j1 V=sc 2>&1 | tee build.log"
	exit 1
}

echo
echo "== bind images to SHA-256 + credentials =="
HERE_DIR="$(dirname "$(readlink -f "$0")")"
FINALIZE="$HERE_DIR/../../common/finalize-image.sh"
[ -x "$FINALIZE" ] && "$FINALIZE" "$SRC" || \
	echo "  (finalize-image.sh not run; images will be unlabelled)"

echo "== images =="
# The target builds BOTH device profiles:
#   morse_mm6108-ekh01-sdio  and  morse_mm6108-ekh01-spi
# The WM6108 on a WM1302 Pi HAT is SPI -- take the *-spi* image.
find bin/targets \( -name '*.img.gz' -o -name '*.img' \) | sed 's/^/  /'
cat <<'NEXT'

Next steps
----------
1. Flash the bcm2711 sysupgrade/factory image to the SD card.

2. Point the driver at the right board config. The driver falls back to a default
   BCF name, so the correct file must be linked to it. For the WM6108's Quectel
   FGH100M-H:

       ssh root@10.42.0.1
       cd /lib/firmware/morse
       rm -f bcf_default.bin
       ln -s bcf_fgh100mhaamd.bin bcf_default.bin

   (Seeed's downstream tree uses its own bcf_mf16858_fgh100mh_v6.3.0.bin for the
   same module -- check which names ship in /lib/firmware/morse and pick the
   FGH100M-H one. Leaving `bcf=` unset lets the driver report the OTP board type,
   which is the honest way to confirm the variant.)

3. Fix the pinout. EKH01 ships Morse's own MMECH06 HAT, NOT the Seeed WM1302 Pi
   HAT, so the stock overlay's wake/busy pins will be wrong for this carrier.
   OpenWrt on bcm27xx still boots through the Pi bootloader with config.txt and
   overlays, so mm6108-spi-overlay.dts from this directory drops straight in:

       # on the build host, then copy to the SD card's boot partition:
       dtc -@ -I dts -O dtb -o mm6108-spi.dtbo overlays/mm6108-spi-overlay.dts
       # boot partition: place mm6108-spi.dtbo in overlays/ and set in config.txt:
       #   dtoverlay=mm6108-spi

   That overlay uses reset=17, irq=5, wake=23, busy=24 -- the WM1302 HAT routing
   per beyondlogic. See BRINGUP.md §5 for why the vendor tree's 3/7 does not apply.

4. Check it came up:

       dmesg | grep -i morse        # expect an OTP board type and no CMD63/-71
       iw dev                       # expect a new S1G-capable interface

NEXT
