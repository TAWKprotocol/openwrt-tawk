# openwrt-tawk

OpenWrt customisation and peripheral bring-up for TAWK coordinator hardware.

Build scripts, device tree overlays, provisioning and bench tooling for getting radios and
security peripherals working on OpenWrt across a range of boards. One repository so the work
accumulates instead of being rediscovered per device.

**This repository contains no TAWK protocol source.** That is a deliberate, enforced boundary.
It is intended to be publishable without a cleanup pass.

---

## Layout

```
common/                     device-agnostic: provisioning, image finalisation, build container
raspberrypi/
  rpi4/                     Raspberry Pi 4B (bcm2711)
    README.md               build, flash, first boot — start here
    BRINGUP.md              bring-up log: findings, failures, why
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

## Boards

**Build instructions live with each board, not here** — targets, quirks and flashing steps differ
enough that a single root recipe goes stale the moment a second board is added.

| Board | Peripheral | Status | Start here |
|---|---|---|---|
| Raspberry Pi 4B (bcm2711) | Morse Micro MM6108 Wi-Fi HaLow over SPI, on a Seeed WM1302 Pi HAT | in bring-up | [`raspberrypi/rpi4/README.md`](raspberrypi/rpi4/README.md) — build & flash · [`BRINGUP.md`](raspberrypi/rpi4/BRINGUP.md) — findings |

Adding a board: create `<vendor>/<model>/` with its own `README.md` (how to build and flash) and,
if the bring-up was non-trivial, a `BRINGUP.md` (what was learned, including what failed). Anything
device-agnostic belongs in `common/`.

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
