#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Bake deterministic, headless-safe provisioning into a Morse OpenWrt image.
#
# Requirements this satisfies:
#   * KNOWN credentials      -- root password and wifi key are chosen (or generated
#                               once and PRINTED), never silently randomised per boot.
#   * GUARANTEED RJ45        -- ethernet is a DHCP client, so plugging it into any
#                               network gets it an address; plus a fixed management
#                               alias so it is still reachable with no DHCP server.
#   * FULLY HEADLESS         -- SSH key installed at build time; no console, no
#                               keyboard, no HDMI, no serial required, ever.
#   * ZERO driver impact     -- see "What this does NOT touch" below.
#
# Everything here is OpenWrt's own `files/` overlay plus uci-defaults. It is pure
# userspace configuration applied on first boot.
#
# What this does NOT touch, by construction:
#   - the morse driver, its module parameters, or /etc/modprobe.d
#   - any device tree, overlay, config.txt or distroconfig.txt
#   - the kernel, or any kmod
#   - radio/PHY settings: channel, country, bandwidth, S1G parameters
# The only wireless key it writes is the pre-shared key UCI value, which
# morse-wireless-defaults would otherwise fill with /dev/urandom output.
#
# usage:
#   ROOT_PW='...' SSH_PUBKEY=~/.ssh/id_ed25519.pub ./provision-image.sh ~/morse-openwrt
#   # then build; the image picks up files/ automatically.
#
set -euo pipefail

BUILDROOT="${1:-$HOME/morse-openwrt}"
HOSTNAME_="${HOSTNAME_:-tawk-halow}"      # also fixes the AP SSID, which derives from it
TAWK_USER="${TAWK_USER:-tawk}"            # non-root operator account
MGMT_IP="${MGMT_IP:-10.42.0.1}"
MGMT_MASK="${MGMT_MASK:-255.255.255.0}"
DATA_LABEL="${DATA_LABEL:-tawkdata}"      # separate persistent data partition, mounted at /data
DATA_MOUNT="${DATA_MOUNT:-/data}"
WIFI_KEY="${WIFI_KEY:-}"
ROOT_PW="${ROOT_PW:-}"
USER_PW="${USER_PW:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

[ -d "$BUILDROOT" ] || { echo "FATAL: no buildroot at $BUILDROOT"; exit 1; }

# Generated once and PRINTED, never silently randomised per boot.
# Charset is strictly A-Za-z0-9 -- no special characters, so the values survive
# shell quoting, QR/label printing, WPA passphrase rules and hand transcription.
genpw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
[ -n "$ROOT_PW"  ] || ROOT_PW="$(genpw 16)"
[ -n "$USER_PW"  ] || USER_PW="$(genpw 16)"
[ -n "$WIFI_KEY" ] || WIFI_KEY="$(genpw 16)"
for v in ROOT_PW USER_PW WIFI_KEY; do
	eval "val=\$$v"
	case "$val" in *[!A-Za-z0-9]*) echo "FATAL: $v must be A-Za-z0-9 only"; exit 1;; esac
done
[ "${#WIFI_KEY}" -ge 8 ] || { echo "FATAL: WPA keys must be >= 8 chars"; exit 1; }

# Pre-hash both passwords so no cleartext lands in the image.
hashpw() {
	if command -v mkpasswd >/dev/null 2>&1; then mkpasswd -m sha512crypt "$1"
	elif command -v openssl >/dev/null 2>&1; then openssl passwd -6 "$1"
	else echo "FATAL: need mkpasswd (whois pkg) or openssl" >&2; exit 1; fi
}
ROOT_HASH="$(hashpw "$ROOT_PW")"
USER_HASH="$(hashpw "$USER_PW")"

FILES="$BUILDROOT/files"
mkdir -p "$FILES/etc/uci-defaults" "$FILES/etc/dropbear"

# --- SSH key: the actual headless access path -------------------------------
if [ -n "$SSH_PUBKEY" ] && [ -f "$SSH_PUBKEY" ]; then
	install -m 0600 "$SSH_PUBKEY" "$FILES/etc/dropbear/authorized_keys"
	echo "installed ssh key: $(cut -d' ' -f3 <"$SSH_PUBKEY" 2>/dev/null || echo '(no comment)')"
else
	echo "WARNING: no SSH_PUBKEY given -- password auth will be the only way in."
fi

# --- First-boot provisioning ------------------------------------------------
# 99- so it sorts AFTER Morse's 95-morse-wireless-defaults and wins.
# uci-defaults scripts are deleted after a successful (exit 0) run.
cat > "$FILES/etc/uci-defaults/99-tawk-provision" <<EOF
#!/bin/sh
# TAWK bench/field provisioning. Userspace + UCI only; touches no driver,
# no device tree and no radio/PHY parameters. See provision-image.sh.

# 1. Deterministic identity. The AP SSID is derived from hostname, so fixing
#    the hostname also makes the SSID predictable instead of MAC-suffixed.
uci -q set system.@system[0].hostname='${HOSTNAME_}'
uci -q set system.@system[0].default_wifi_key='${WIFI_KEY}'
uci -q commit system
echo '${HOSTNAME_}' > /proc/sys/kernel/hostname

# 2. Known key on every AP that morse-wireless-defaults populated. This is the
#    same UCI value it would otherwise have set from /dev/urandom -- we are
#    replacing a random string with a known one, nothing more.
for s in \$(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.key=.*/\1/p"); do
	uci -q set "wireless.\$s.key=${WIFI_KEY}"
done
uci -q commit wireless

# 3. RJ45 must never be ignored. Ethernet takes a DHCP lease so the unit is
#    reachable on whatever it is plugged into, AND carries a fixed management
#    alias so it is reachable with no DHCP server present (direct laptop cable).
uci -q set network.lan.proto='dhcp'
uci -q set network.lan.hostname='${HOSTNAME_}'
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci -q delete network.lan.gateway

uci -q delete network.mgmt
uci -q set network.mgmt='interface'
uci -q set network.mgmt.device="\$(uci -q get network.lan.device || echo br-lan)"
uci -q set network.mgmt.proto='static'
uci -q set network.mgmt.ipaddr='${MGMT_IP}'
uci -q set network.mgmt.netmask='${MGMT_MASK}'
uci -q commit network

# 4. Do NOT serve DHCP. A coordinator plugged into an existing LAN must not
#    become a rogue DHCP server; it is a client plus a static alias.
uci -q set dhcp.lan.ignore='1'
uci -q set dhcp.mgmt='dhcp'
uci -q set dhcp.mgmt.interface='mgmt'
uci -q set dhcp.mgmt.ignore='1'
uci -q commit dhcp

# 5. SSH always up, on all interfaces, key auth preferred.
uci -q set dropbear.@dropbear[0].enable='1'
uci -q set dropbear.@dropbear[0].Interface=''
uci -q set dropbear.@dropbear[0].PasswordAuth='on'
uci -q set dropbear.@dropbear[0].RootPasswordAuth='on'
uci -q commit dropbear
/etc/init.d/dropbear enable 2>/dev/null

# 6. Known root password (pre-hashed; no cleartext on the image).
sed -i 's|^root:[^:]*:|root:${ROOT_HASH}:|' /etc/shadow

# 7. Persistent data partition, kept OUT of the OpenWrt config overlay.
#    Rationale: the overlay is config storage -- small, and wiped by
#    "sysupgrade -n". Protocol state (append-only logs, wrapped key material,
#    telemetry) must not share it: a factory reset would destroy the log, and a
#    growing log would starve config writes. A separate filesystem also survives
#    firmware updates, and is the shared-state partition that A/B rootfs slots
#    require, since it belongs to neither slot.
#    Mounted BY LABEL, because the device path differs across media
#    (mmcblk0p3 vs sda3). Absent partition = mount simply does not happen.
uci -q delete fstab.tawkdata
uci -q set fstab.tawkdata='mount'
uci -q set fstab.tawkdata.target='${DATA_MOUNT}'
uci -q set fstab.tawkdata.label='${DATA_LABEL}'
uci -q set fstab.tawkdata.options='rw,noatime'
uci -q set fstab.tawkdata.enabled='1'
uci -q commit fstab
mkdir -p '${DATA_MOUNT}'
/etc/init.d/fstab enable 2>/dev/null

# 8. Non-root operator account. Written directly rather than via busybox adduser,
#    which is interactive and cannot take a pre-computed hash.
if ! grep -q "^${TAWK_USER}:" /etc/passwd 2>/dev/null; then
	echo '${TAWK_USER}:x:1000:1000:${TAWK_USER}:/home/${TAWK_USER}:/bin/ash' >> /etc/passwd
	echo '${TAWK_USER}:${USER_HASH}:0:0:99999:7:::' >> /etc/shadow
	echo '${TAWK_USER}:x:1000:' >> /etc/group
	mkdir -p '/home/${TAWK_USER}/.ssh'
	[ -f /etc/dropbear/authorized_keys ] && \
		cp /etc/dropbear/authorized_keys '/home/${TAWK_USER}/.ssh/authorized_keys'
	chmod 0700 '/home/${TAWK_USER}/.ssh'
	chmod 0600 '/home/${TAWK_USER}/.ssh/authorized_keys' 2>/dev/null
	chown -R 1000:1000 '/home/${TAWK_USER}'
fi

exit 0
EOF
chmod 0755 "$FILES/etc/uci-defaults/99-tawk-provision"

# --- Boot-partition provisioning: the Raspberry Pi Imager analogue ----------
# Raspberry Pi OS lets Imager set user/password/SSH key/wifi because it ships a
# firstrun hook that reads the FAT boot partition. OpenWrt has no such thing.
# This adds one: the FAT partition is the ONLY partition writable from macOS or
# Windows without ext4/squashfs tooling, so it is the correct place for
# per-device provisioning that needs no image rebuild.
#
# 98- so it runs BEFORE 99- (the baked defaults), letting a card-specific file
# override the build-time values.
cat > "$FILES/etc/uci-defaults/98-tawk-bootcfg" <<'EOF'
#!/bin/sh
# Per-device provisioning from the FAT boot partition. Drop a plain-text
# tawk-provision.conf on the card from any OS; no rebuild, no ext4 tooling.
# Same constraint as the baked layer: userspace/UCI only, no driver or DT.
B=/tmp/.tawkboot
mkdir -p "$B"
mounted=0
if ! CFG=$(ls /boot/tawk-provision.conf 2>/dev/null); then
	for d in /dev/mmcblk0p1 /dev/sda1; do
		[ -b "$d" ] || continue
		mount -t vfat -o ro "$d" "$B" 2>/dev/null && { mounted=1; break; }
	done
	CFG="$B/tawk-provision.conf"
fi
[ -f "$CFG" ] || { [ "$mounted" = 1 ] && umount "$B"; exit 0; }

# Accept only known keys; ignore anything else rather than eval-ing the file.
val() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CFG" | tail -1 | tr -d '\r"'"'"''; }
h=$(val hostname); k=$(val wifi_key); ip=$(val mgmt_ip); nm=$(val mgmt_netmask)
ph=$(val root_password_hash); pk=$(val ssh_authorized_key); proto=$(val lan_proto)

[ -n "$h"  ] && { uci -q set system.@system[0].hostname="$h"; echo "$h" > /proc/sys/kernel/hostname; }
[ -n "$k"  ] && [ ${#k} -ge 8 ] && {
	uci -q set system.@system[0].default_wifi_key="$k"
	for s in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.key=.*/\1/p"); do
		uci -q set "wireless.$s.key=$k"
	done
	uci -q commit wireless
}
[ -n "$ip" ] && uci -q set network.mgmt.ipaddr="$ip"
[ -n "$nm" ] && uci -q set network.mgmt.netmask="$nm"
[ -n "$proto" ] && uci -q set network.lan.proto="$proto"
uci -q commit system; uci -q commit network

[ -n "$ph" ] && sed -i "s|^root:[^:]*:|root:$ph:|" /etc/shadow
[ -n "$pk" ] && { mkdir -p /etc/dropbear; echo "$pk" >> /etc/dropbear/authorized_keys; \
	sort -u /etc/dropbear/authorized_keys -o /etc/dropbear/authorized_keys; \
	chmod 0600 /etc/dropbear/authorized_keys; }

logger -t tawk-bootcfg "applied provisioning from $CFG"
[ "$mounted" = 1 ] && umount "$B"
exit 0
EOF
chmod 0755 "$FILES/etc/uci-defaults/98-tawk-bootcfg"

# Sample the operator can copy onto the FAT partition of any card.
cat > "$BUILDROOT/tawk-provision.conf.sample" <<EOF
# Copy to the card's FAT boot partition as: tawk-provision.conf
# Readable/writable from macOS, Windows or Linux with no special tooling.
# Applied once on first boot, before the image's baked defaults.
hostname            = tawk-halow-01
wifi_key            = ChangeMe12345678
mgmt_ip             = ${MGMT_IP}
mgmt_netmask        = ${MGMT_MASK}
lan_proto           = dhcp
# mkpasswd -m sha512crypt 'yourpassword'   (or: openssl passwd -6 'yourpassword')
root_password_hash  =
ssh_authorized_key  = ssh-ed25519 AAAA... you@host
EOF

# --- Print the credentials; also drop them beside the build -----------------
CREDS="$BUILDROOT/tawk-image-credentials.txt"
cat > "$CREDS" <<EOF
TAWK HaLow image credentials  (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))
hostname / AP SSID : ${HOSTNAME_}
root password      : ${ROOT_PW}
user / password    : ${TAWK_USER} / ${USER_PW}
wifi / AP key      : ${WIFI_KEY}
management IP      : ${MGMT_IP} (static alias; ethernet also takes a DHCP lease)
data partition     : label "${DATA_LABEL}" -> ${DATA_MOUNT} (create it on the card; see below)
ssh                : ssh ${TAWK_USER}@${MGMT_IP}   or   ssh root@${HOSTNAME_}
image sha256       : (pending -- run finalize-image.sh after the build)
EOF
chmod 0600 "$CREDS"

# Machine-readable form so finalize-image.sh can bind these to the image hash.
ENVF="$BUILDROOT/.tawk-credentials.env"
cat > "$ENVF" <<EOF
TAWK_HOSTNAME='${HOSTNAME_}'
TAWK_USER='${TAWK_USER}'
TAWK_USER_PW='${USER_PW}'
TAWK_ROOT_PW='${ROOT_PW}'
TAWK_WIFI_KEY='${WIFI_KEY}'
TAWK_MGMT_IP='${MGMT_IP}'
TAWK_PROVISIONED_UTC='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
EOF
chmod 0600 "$ENVF"

echo
echo "=============================================================="
cat "$CREDS"
echo "=============================================================="
echo "saved to: $CREDS   (gitignored; do not commit)"
echo "files tree: $FILES"
echo "per-device sample: $BUILDROOT/tawk-provision.conf.sample -> copy to the card's FAT partition"
echo
cat <<DATA

Persistent data partition
-------------------------
The image mounts a partition LABELLED "${DATA_LABEL}" at ${DATA_MOUNT}. Create it in
the free space after the OpenWrt partitions once the card is flashed:

    sudo parted /dev/sdX -- mkpart primary ext4 <end-of-last-partition> 100%
    sudo mkfs.ext4 -L ${DATA_LABEL} /dev/sdX3

ext4 is used because the image already carries it. If you would rather have
checksums that detect the silent corruption that motivated the immutable-rootfs
work -- a filesystem that fsck's clean while a file is quietly wrong -- build with
CONFIG_PACKAGE_kmod-fs-btrfs=y and mkfs.btrfs -L ${DATA_LABEL} instead. f2fs
(CONFIG_PACKAGE_kmod-fs-f2fs=y) is the flash-friendlier option if wear matters more.

If the partition is absent the mount is simply skipped; nothing else breaks.
DATA

echo "After the build, run ./finalize-image.sh $BUILDROOT to bind a SHA-256 to these."
echo
echo "Verify it was baked in:"
echo "  grep -r 99-tawk-provision $BUILDROOT/build_dir/target-*/root-*/etc/uci-defaults/ 2>/dev/null"
