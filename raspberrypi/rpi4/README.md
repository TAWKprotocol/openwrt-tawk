# Raspberry Pi 4B — Morse Micro MM6108 (Wi-Fi HaLow) over SPI

Board target: **`ekh-bcm2711-mm6108`** · OpenWrt source: **`MorseMicro/openwrt`** tag `3.0.2`

| | |
|---|---|
| Host | Raspberry Pi 4 Model B (bcm2711) |
| Radio | Morse Micro MM6108 — Seeed **Wio-WM6108** mini-PCIe card (Quectel FGH100M-H) |
| Carrier | Seeed **WM1302 Pi HAT** (mini-PCIe socket → 40-pin header) |
| Interface | **SPI0 / CE0** — *not* PCIe; the mini-PCIe edge is a form factor only |

Findings, failures and the reasoning behind the choices are in **[`BRINGUP.md`](BRINGUP.md)**. Read it
before changing anything — it records several traps that each cost an evening.

---

## Build

Four steps, and **the order matters**: `files/` is consumed when the rootfs is assembled, so
provisioning must happen *before* the image is built.

```bash
# 1. fetch, configure and build. First run only: x86_64 Linux host, ~50 GB, 1-3 h.
./build-morse-openwrt.sh ~/morse-openwrt

# 2. bake in credentials, RJ45+DHCP, an SSH key and the data-partition mount.
#    Prints the credentials; writes files/ into the buildroot.
SSH_PUBKEY=~/.ssh/id_ed25519.pub HOSTNAME_=tawk-halow-01 \
  ../../common/provision-image.sh ~/morse-openwrt

# 3. re-assemble the image so files/ is included. Incremental — minutes, not hours.
cd ~/morse-openwrt && make -j"$(nproc)"

# 4. bind a SHA-256 to the credentials baked into each image.
#    A SEPARATE STEP: a bare `make` does not run it; only build-morse-openwrt.sh calls it.
../../common/finalize-image.sh ~/morse-openwrt
```

Prefer the pinned build container over a modern host distro — it is the one Morse's own CI uses, and
it avoids a class of host-toolchain breakage (GCC 15 vs the golang host build, the dropped
`python3-distutils`):

```bash
UID_GID="$(id -u):$(id -g)" SRC=~/morse-openwrt \
  docker compose -f ../../common/docker-compose.morse-openwrt.yml run --rm build
```

### Where the outputs go

The buildroot **root**, not `bin/targets/` — which is the obvious place to look and the wrong one:

| Path | Contents |
|---|---|
| `~/morse-openwrt/tawk-image-credentials.txt` | human-readable credentials + image SHA-256 |
| `~/morse-openwrt/tawk-image-manifest.txt` | per-image manifest: hash, size, build, credentials |
| `~/morse-openwrt/bin/targets/bcm27xx/bcm2711/*.img.gz` | the images |
| `…/*.img.gz.sha256` | `sha256sum -c` files, beside each image |

The target builds **two** device profiles. Take the ***`-spi-`*** image — `-sdio-` is a different
carrier.

---

## Flash and first boot

```bash
sha256sum -c openwrt-morse-*-spi-squashfs-sysupgrade.img.gz.sha256   # verify before writing
```

After flashing, optionally add the persistent data partition in the free space. It is mounted by
label, so it is picked up automatically and skipped harmlessly if absent:

```bash
sudo parted /dev/sdX -- mkpart primary ext4 <end-of-last-partition> 100%
sudo mkfs.ext4 -L tawkdata /dev/sdX3
```

> ⚠ **Do not plug it into an existing LAN for first boot.** Bring it up point-to-point to a laptop
> (static `10.42.0.2/24`) or on an isolated switch. Provisioning disables the DHCP *server*, but
> verify that on your build before trusting it on a shared network.

Then, in order:

```sh
ssh tawk@10.42.0.1              # or root@ — credentials are in tawk-image-credentials.txt
mount | grep overlay            # 1. does config survive a reboot?
dmesg | grep -i morse           # 2. did the MM6108 enumerate?
iw dev                          # 3. is there an S1G interface?
```

Read `dmesg` against the baseline in [`BRINGUP.md`](BRINGUP.md) §4:

| Output | Meaning |
|---|---|
| OTP board type + firmware/BCF checksums, new interface | working |
| `cmd53_read … b=0xffffffff (ret:-71)` | chip not answering — see BRINGUP §5 on the pinout |
| `failed to init SPI with CMD63 (ret:-61)` | chip not answering at all — seating, then overlay |

### If the pinout needs swapping

The image ships Morse's overlay for their **MMECH06** HAT, not the Seeed **WM1302**. OpenWrt on
bcm27xx still boots through the Pi bootloader, so `config.txt` and `overlays/` work exactly as under
Raspberry Pi OS:

```bash
dtc -@ -I dts -O dtb -o mm6108-spi.dtbo overlays/mm6108-spi-overlay.dts
# copy into the boot partition's overlays/, then in distroconfig.txt replace
#   dtoverlay=mm610x-spi     with     dtoverlay=mm6108-spi
```

Do this **only** if the first boot shows `-71`. Changing it pre-emptively means changing two
variables at once, which is what made the earlier diagnosis take so long.

## Files

| File | Purpose |
|---|---|
| `build-morse-openwrt.sh` | build Morse's OpenWrt for this board; handles the `morsectrl` bug and board rename |
| `overlays/mm6108-spi-overlay.dts` | WM1302 HAT pinout — reset 17, IRQ 5, wake 23, busy 24 |
| `tools/gpioprobe.c` | bias-flip liveness probe — tells a dead card from a wiring fault |
| `tools/holdpin.c` | hold one GPIO at a level (power-enable / reset tests) |
| `legacy-stock-kernel/` | the abandoned stock-kernel + DKMS route, kept for the record |
