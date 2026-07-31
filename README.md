# openwrt-tawk

OpenWrt customisation and peripheral bring-up for TAWK coordinator hardware.

Build scripts, device tree overlays, provisioning and bench tooling for getting radios and
security peripherals working on OpenWrt across a range of boards. One repository so the work
accumulates instead of being rediscovered per device.

**This repository contains no TAWK protocol source.** That is a deliberate, enforced boundary —
see [The IP boundary](#the-ip-boundary). It is intended to be publishable without a cleanup pass.

---

## Layout

```
common/                     device-agnostic: provisioning, image finalisation, build container
raspberrypi/
  rpi4/                     Raspberry Pi 4B (bcm2711)
    BRINGUP.md              the bring-up log — read this first
    build-morse-openwrt.sh  build Morse Micro's OpenWrt for this board
    overlays/               device tree overlays
    tools/                  bench diagnostics, compiled on the target
    legacy-stock-kernel/    abandoned stock-kernel/DKMS route, kept for the record
scripts/                    artifact fetch + the IP boundary guard
tawk-artifacts/             EPHEMERAL, gitignored — never committed
```

Add a board as `<vendor>/<model>/`, keeping anything device-agnostic in `common/`.

### Current status

| Board | Peripheral | State |
|---|---|---|
| Raspberry Pi 4B | Morse Micro MM6108 (Wi-Fi HaLow) over SPI, on a Seeed WM1302 Pi HAT | in bring-up — see `raspberrypi/rpi4/BRINGUP.md` |

---

## Quick start (Raspberry Pi 4B + MM6108 over SPI)

```bash
# 1. build Morse Micro's OpenWrt for this board (x86_64 Linux host, ~50 GB, 1-3 h)
./raspberrypi/rpi4/build-morse-openwrt.sh ~/morse-openwrt

# 2. bake in known credentials, guaranteed RJ45+DHCP and an SSH key, BEFORE the image is assembled
SSH_PUBKEY=~/.ssh/id_ed25519.pub HOSTNAME_=tawk-halow-01 \
  ./common/provision-image.sh ~/morse-openwrt

# 3. rebuild (incremental) — finalize-image.sh runs after, binding a SHA-256 to those credentials
cd ~/morse-openwrt && make -j"$(nproc)"
```

Prefer the pinned build container over a modern host distro — it is the one Morse's own CI uses, and
it avoids a class of host-toolchain breakage:

```bash
UID_GID="$(id -u):$(id -g)" SRC=~/morse-openwrt \
  docker compose -f common/docker-compose.morse-openwrt.yml run --rm build
```

`raspberrypi/rpi4/BRINGUP.md` carries the detail, including several traps that each cost an evening.

---

## Related

Protocol-level design and analysis live in a separate repository and are deliberately not duplicated
or summarised here.

## Licence

**Apache-2.0** — full text in [`LICENSE`](LICENSE), attribution in [`NOTICE`](NOTICE), and an SPDX
header on every file.

Chosen for **ecosystem growth**, which is what this repository is for. TAWK is an openly specified
protocol whose value comes from the number of devices that speak it, so anything lowering the barrier
to enabling a new board is aligned with the project. Apache-2.0 lets a vendor engineer contribute a
board configuration without a legal review, carries an express patent grant with defensive
termination, and makes contributions inbound-equal-outbound by default (§5) without a CLA.

**No third-party code is included here.** The scripts *invoke* OpenWrt, the Morse Micro driver and
feed, hostapd and the rest; each stays under its own licence and is fetched from its own upstream at
build time. Two device tree overlays that *were* ports of Morse's GPL-2.0 overlay have been removed
rather than carried — they were failed A/B controls, and `raspberrypi/rpi4/BRINGUP.md` §5 records
every property difference and both results, which is all they were ever for.

## Scope

This repository is **OS and hardware enablement**: OpenWrt configuration, device tree overlays, build
and provisioning scripts, and bench tooling. That is all it is for, and all it should ever contain.

TAWK protocol source and any cryptographic or credential material live in a separate repository and
are never committed here. When a build needs a TAWK binary it is staged into the gitignored
`tawk-artifacts/` by an explicit fetch step and removed afterwards — visible in the build log rather
than an implicit dependency.

Enforced rather than merely stated:

```bash
./scripts/install-hooks.sh   # once per clone — pre-commit scans the tree, pre-push scans history
./scripts/check-no-tawk-ip.sh --rev HEAD
```

Contributors who want stricter local checks can drop additional patterns in `.guard-patterns`
(gitignored, one extended-regex per line); the committed defaults are deliberately generic.

## Contributing

New boards welcome as `<vendor>/<model>/`; keep anything device-agnostic in `common/`. Run
`./scripts/install-hooks.sh` after cloning. Apache-2.0 §5 makes contributions inbound-equal-outbound,
so no CLA is required; `git commit -s` sign-off is appreciated but not mandatory.
