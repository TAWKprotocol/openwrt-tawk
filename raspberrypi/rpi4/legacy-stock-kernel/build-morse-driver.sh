#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build + install the Morse Micro driver, firmware and BCFs for a Wio-WM6108
# (Quectel FGH100M-H = MM6108) on a Seeed WM1302 Pi HAT, on a Raspberry Pi
# running a *stock* Ubuntu raspi kernel.
#
# Verified 2026-07-29 on: Pi 4 Model B Rev 1.5, Ubuntu 26.04 LTS,
#                         kernel 7.0.0-1009-raspi (aarch64), gcc 15.2.0
#                         morse_driver / morse-firmware tag mm6108-2.0.1
#
# Two things are needed to build against a stock kernel, both non-obvious:
#
#  1. -Wno-error=cpp
#     spi.c has `#warning "SPI_CONTROLLER_ENABLE_CS_GPIOD macro not defined"`,
#     and the Makefile compiles with -Werror, so that warning is fatal.
#     SPI_CONTROLLER_ENABLE_CS_GPIOD is NOT a mainline macro -- it comes from
#     Morse's own kernel patch (which is why their reference builds run a kernel
#     named e.g. 6.12.25-v8-16k-morse+). It controls whether the SPI core inverts
#     CS-GPIO polarity on SPI_CS_HIGH. Demoting the warning builds a driver that
#     relies on mainline's polarity handling instead; the Pi's base DT already
#     declares cs-gpios = <&gpio 8 1> (active low) and CS idles high correctly.
#
#  2. CONFIG_MORSE_VENDOR_COMMAND=y
#     It defaults to n in Kconfig, but vendor_ie.o is compiled unconditionally
#     and references symbols from vendor.o, so a default build fails at modpost
#     with ~10 undefined `morse_vendor_*` symbols. It is effectively mandatory.
#
# The driver's compat.h shims stop at KERNEL_VERSION(6, 18, 0); 7.0 lands past
# the last guard and still builds and loads clean.
#
set -euo pipefail

TAG="${TAG:-mm6108-2.0.1}"
WORK="${WORK:-$HOME/halow}"
KSRC="/lib/modules/$(uname -r)/build"

echo "== prerequisites =="
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
	build-essential "linux-headers-$(uname -r)" device-tree-compiler git gpiod i2c-tools

[ -d "$KSRC" ] || { echo "FATAL: no kernel headers at $KSRC"; exit 1; }

mkdir -p "$WORK"; cd "$WORK"
for r in morse_driver morse-firmware hostap; do
	[ -d "$r" ] || git clone -q "https://github.com/MorseMicro/$r.git"
done

echo "== driver ($TAG) =="
cd "$WORK/morse_driver"
git fetch -q --tags && git checkout -q "$TAG"
# mmrc-submodule uses a relative URL; it must be initialised or the build fails.
git submodule update --init --recursive

make -j"$(nproc)" \
	KCFLAGS="-Wno-error=cpp" \
	MORSE_TRACE_PATH="$(pwd)" \
	KERNEL_SRC="$KSRC" \
	CONFIG_WLAN_VENDOR_MORSE=m \
	CONFIG_MORSE_SPI=y \
	CONFIG_MORSE_SDIO=y \
	CONFIG_MORSE_USER_ACCESS=y \
	CONFIG_MORSE_VENDOR_COMMAND=y \
	CONFIG_MORSE_DEBUGFS=y \
	CONFIG_MORSE_MONITOR=y \
	CONFIG_MORSE_COUNTRY='"US"'

# Install through DKMS rather than `make modules_install`. A plain install lands in
# /lib/modules/<running-kernel>/updates and DISAPPEARS the moment the kernel changes --
# an unattended 7.0.0-1009 -> 7.0.0-1015 upgrade silently disarmed the radio exactly
# this way mid-bring-up (BRINGUP.md §5). DKMS AUTOINSTALL rebuilds on kernel install.
SRCDIR="/usr/src/morse-${TAG}"
HERE="$(dirname "$(readlink -f "$0")")"
sudo rm -rf "$SRCDIR"
sudo mkdir -p "$SRCDIR"
sudo cp -a "$WORK/morse_driver/." "$SRCDIR/"   # includes the initialised mmrc submodule
sudo rm -rf "$SRCDIR/.git"
sudo cp "$HERE/dkms.conf" "$SRCDIR/dkms.conf"
sudo sed -i "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${TAG}\"/" "$SRCDIR/dkms.conf"

sudo dkms remove "morse/${TAG}" --all >/dev/null 2>&1 || true
sudo dkms add -m morse -v "$TAG"
sudo dkms build -m morse -v "$TAG"
sudo dkms install -m morse -v "$TAG" --force
sudo depmod -a || true
sudo dkms status

echo "== firmware + BCFs -> /lib/firmware/morse =="
cd "$WORK/morse-firmware"
git fetch -q --tags && git checkout -q "$TAG"
sudo make install

echo "== module parameters =="
# The BCF parameter is named 'bcf' (not board_config_file, which is just the
# internal variable). Left unset here on purpose: with no bcf= the driver
# resolves the board type from the chip's OTP and logs which module is fitted,
# which is how you confirm the FGH100M variant rather than guessing. Once
# confirmed, pin it -- for the WM6108 that is bcf_fgh100mhaamd.bin.
sudo tee /etc/modprobe.d/morse.conf >/dev/null <<'EOF'
# Wio-WM6108 (Quectel FGH100M-H = MM6108) on Seeed WM1302 Pi HAT, SPI0/CS0.
# country: North America per hardware/HALOW-PLAN.md (driver default is AU).
# spi_clock_speed: 20 MHz is the Morse community's reported operating point.
options morse spi_clock_speed=20000000 country=US
# options morse spi_clock_speed=20000000 country=US bcf=bcf_fgh100mhaamd.bin
EOF

echo "== device tree overlay =="
# Keep the master copy somewhere flash-kernel will not touch, compile it there, and
# install a kernel postinst hook to re-copy it -- flash-kernel repopulates
# /boot/firmware/current/overlays/ on every kernel install and will otherwise delete
# it, leaving config.txt pointing at a missing overlay that the firmware skips
# SILENTLY (BRINGUP.md §5).
sudo mkdir -p /usr/local/share/mm6108
sudo cp "$HERE/../overlays/mm6108-spi-overlay.dts" /usr/local/share/mm6108/
sudo dtc -@ -I dts -O dtb \
	-o /usr/local/share/mm6108/mm6108-spi.dtbo \
	/usr/local/share/mm6108/mm6108-spi-overlay.dts
sudo install -m 0755 "$HERE/zz-mm6108-overlay" /etc/kernel/postinst.d/zz-mm6108-overlay
sudo /etc/kernel/postinst.d/zz-mm6108-overlay
sudo cp --update=none /boot/firmware/config.txt /boot/firmware/config.txt.pre-halow || true
grep -q '^dtoverlay=mm6108-spi' /boot/firmware/config.txt || \
	sudo sed -i 's/^dtparam=spi=on$/dtparam=spi=on\ndtoverlay=mm6108-spi/' /boot/firmware/config.txt

echo
echo "Done. Reboot to apply the overlay, then:"
echo "  sudo dmesg | grep -i morse"
echo "Expect a new wlanN interface. If you instead see"
echo "  cmd53_read ... b=0xffffffff (ret:-71)"
echo "the card is not answering at all -- run ./gpioprobe to tell a dead/unpowered"
echo "card apart from a wiring or polarity problem before touching software."
