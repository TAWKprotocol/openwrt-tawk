#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Bind every built image to a SHA-256 and to the credentials baked into it.
#
# Run after `make`. Produces, per image, a manifest recording:
#   image filename + size + SHA-256, the AP SSID and its Wi-Fi key, the root and
#   non-root account passwords, the management IP, and the build provenance.
#
# The point is that a flashed card is otherwise anonymous: once several images
# exist you cannot tell which credentials belong to which card, and a headless
# unit gives you no way to ask it. The checksum labels the build, and doubles as
# a corruption check before flashing. Standard release-engineering practice.
#
# usage:  ./finalize-image.sh [buildroot]        (default ~/morse-openwrt)
#
set -euo pipefail

BUILDROOT="${1:-$HOME/morse-openwrt}"
ENVF="$BUILDROOT/.tawk-credentials.env"

[ -d "$BUILDROOT" ] || { echo "FATAL: no buildroot at $BUILDROOT"; exit 1; }
if [ -f "$ENVF" ]; then
	# shellcheck disable=SC1090
	. "$ENVF"
else
	echo "WARNING: $ENVF missing -- was provision-image.sh run before the build?"
	echo "         Hashes will still be recorded, but without credentials."
fi

TAG="$(git -C "$BUILDROOT" describe --tags --always 2>/dev/null || echo unknown)"
BOARD="$(sed -n 's/^CONFIG_TARGET_DEVICE_.*DEVICE_\(.*\)=y/\1/p' "$BUILDROOT/.config" 2>/dev/null | paste -sd, - || echo unknown)"

mapfile -t IMAGES < <(find "$BUILDROOT/bin/targets" -type f \( -name '*.img.gz' -o -name '*.img' \) 2>/dev/null | sort)
[ "${#IMAGES[@]}" -gt 0 ] || { echo "FATAL: no images under $BUILDROOT/bin/targets -- did the build finish?"; exit 1; }

MANIFEST="$BUILDROOT/tawk-image-manifest.txt"
: > "$MANIFEST"

for img in "${IMAGES[@]}"; do
	sum="$(sha256sum "$img" | awk '{print $1}')"
	size="$(stat -c %s "$img" 2>/dev/null || stat -f %z "$img")"
	base="$(basename "$img")"

	# A .sha256 beside each image, in the format sha256sum -c expects.
	printf '%s  %s\n' "$sum" "$base" > "$img.sha256"

	cat >> "$MANIFEST" <<EOF
================================================================================
image            : $base
sha256           : $sum
size             : $size bytes
built from       : MorseMicro/openwrt $TAG   board: $BOARD
finalized (UTC)  : $(date -u +%Y-%m-%dT%H:%M:%SZ)
--------------------------------------------------------------------------------
hostname/AP SSID : ${TAWK_HOSTNAME:-<unset>}
wifi AP key      : ${TAWK_WIFI_KEY:-<unset>}
root password    : ${TAWK_ROOT_PW:-<unset>}
user / password  : ${TAWK_USER:-<unset>} / ${TAWK_USER_PW:-<unset>}
management IP    : ${TAWK_MGMT_IP:-<unset>}  (static alias; RJ45 also DHCP client)
access           : ssh ${TAWK_USER:-root}@${TAWK_MGMT_IP:-<ip>}
verify before flashing:
    sha256sum -c "$base.sha256"
EOF
done

chmod 0600 "$MANIFEST"

# Fold the hash back into the human-readable credentials file too.
CREDS="$BUILDROOT/tawk-image-credentials.txt"
if [ -f "$CREDS" ] && [ "${#IMAGES[@]}" -ge 1 ]; then
	primary="$(printf '%s\n' "${IMAGES[@]}" | grep -m1 -- '-spi' || echo "${IMAGES[0]}")"
	psum="$(sha256sum "$primary" | awk '{print $1}')"
	sed -i "s|^image sha256       : .*|image sha256       : $psum|" "$CREDS" 2>/dev/null || true
	sed -i "\$a image             : $(basename "$primary")" "$CREDS" 2>/dev/null || true
fi

echo
cat "$MANIFEST"
echo
echo "manifest : $MANIFEST  (0600, contains secrets -- do not commit)"
echo "per-image: <image>.sha256   ->  sha256sum -c to verify before flashing"
