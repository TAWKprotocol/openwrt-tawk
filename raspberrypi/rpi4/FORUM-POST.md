<!-- SPDX-License-Identifier: Apache-2.0 -->
# Draft for community.morsemicro.com

_Ready to paste. Relevant threads: the WM1302-Pi-HAT/WM6108-over-SPI one (`salvage4703` has this exact
hardware and is stuck at the same symptom), and "Build Thread: HaLow for Raspberry Pi OS"._

---

**Title:** Solved: WM1302 Pi HAT + Wio-WM6108 never answers on SPI — hand-wired HT-HC01P works on the same kernel/driver/firmware

---

Posting this because I lost several days to it and I think at least one other person here is stuck at
the same place.

## TL;DR

The **Seeed WM1302 Pi HAT** was the fault, not the card, the kernel, the pinout, or the driver
configuration. An MM6108 hand-wired straight to the Pi's 40-pin header came up on the first boot,
using the *same* kernel, driver, firmware and BCF that had never once produced a response through the
HAT.

If you are seeing `cmd53_read ... b=0xffffffff (ret:-71)` with a mini-PCIe HaLow card in a WM1302 Pi
HAT, I would test the module directly on the header before spending time on software.

## Setup

- Raspberry Pi 4B
- `MorseMicro/openwrt` tag **3.0.2**, board `ekh-bcm2711-mm6108`, driver `mm6108-2.0.1`
- Firmware `mm6108.bin`, BCF `bcf_fgh100mhaamd.bin`
- Failing: Seeed **Wio-WM6108** (Quectel FGH100M-H) in a Seeed **WM1302 Pi HAT**
- Working: Heltec **HT-HC01P** hand-wired to the header

## Symptom

```
morse_spi spi0.0: morse_of_probe: Reading gpio pins configuration from device tree
Resetting Morse Chip
morse_spi_find_token failed
morse_spi spi0.0: spi: cmd53_read fn=1 0x00004d20:4 r=0x10050002 b=0xffffffff (ret:-71)
morse_spi spi0.0: morse_chip_cfg_set_and_validate: Failed to access HW (errno:-5)
```

`b=0xffffffff` is MISO idle-high for the whole transfer — the chip never drove the line.

## What I eliminated against the HAT

Every one of these gave either the `-71` above or `-61` at CMD63. None ever got further.

| Kernel | wake/busy pins | chip-select config | Result |
|---|---|---|---|
| stock Ubuntu 7.0 | 23 / 24 | base DT, two CS, native | CMD63 ok → **-71** |
| Morse-patched 6.6 | 3 / 7 | one CS, `GPIO_OUT` | **-61** |
| Morse-patched 6.6 | 23 / 24 | one CS, `GPIO_OUT` | **-61** |
| Morse-patched 6.6 | 23 / 24 | base DT, two CS, native | CMD63 ok → **-71** |

Also tried and ruled out: the exact module parameters from a known-working setup
(`enable_wiphy=0 enable_otp_check=1 slow_clock_mode=0 spi_clock_speed=24000000 debug_mask=2`); GPIO 18
(the WM1302 HAT's documented power-enable) driven both high and low; a 2-second reset-low / 4-second
settle sequence before `modprobe`; SPI clocks swept 1–20 MHz (bit-identical results, which rules out
timing); and removing all other HATs.

A GPIO bias test (read each line with the SoC's internal pull-up, then pull-down — a driven line
ignores the bias, a floating line follows it) showed **IRQ, MISO, BUSY and the vendor BUSY pin all
floating in every state**, including after a clean reset pulse with WAKE asserted. The chip was
driving nothing.

Notably, the **Morse-patched kernel made no difference at all** — the failure was byte-for-byte
identical to the stock kernel, same `r=0x10050002 b=0xffffffff`. That surprised me, since the patched
kernel was the main reason I moved to your OpenWrt fork.

## The fix

Wire the module directly, per the pin map used in `ykhan1999/zero2w_80211ah`:

| MM6108 | Pi GPIO | Header pin |
|---|---|---|
| 3V3 / GND | — | 1 / 6 |
| CS | 8 | 24 |
| MISO / MOSI / CLK | 9 / 10 / 11 | 21 / 19 / 23 |
| RESET | 5 | 29 |
| WAKE | 3 | 5 |
| BUSY | 7 | 26 |
| INT | 25 | 22 |

Result on first boot:

```
morse_io: Device node '/dev/morse_io' created successfully
morse_spi spi0.0: Loaded firmware from morse/mm6108.bin, size 468304, crc32 0xbe7b5c8f
morse_spi spi0.0: Loaded BCF from morse/bcf_default.bin, size 1298, crc32 0xf72450a7
morse_spi spi0.0: Driver loaded with kernel module parameters
```

A second Heltec HaLow device in STA mode then associated, 924 MHz / 8 MHz, MCS 2 @ 9.8 Mbit/s.

## Four things that cost me time, in case they help someone

**1. `morse-ps` collides with SPI CS1.** It claims GPIO 7 for the MMECH06 carrier, and the Pi's base
DT wants GPIO 7 as SPI CS1. The loser is the SPI controller:

```
pinctrl-bcm2835 fe200000.gpio: pin gpio7 already requested by leds; cannot claim for fe204000.spi
spi-bcm2835 fe204000.spi: Error applying setting, reverse things back
```

The controller then never probes, **no SPI devices are created at all**, and the morse driver prints
only its registration lines — which looks nothing like a wiring problem. If you are not using
Morse's own carrier, disable `dtoverlay=morse-ps`.

**2. `cs-gpios`, the chip-select pin group, and `pinctrl-0` are a coupled set.** Adopting them
piecemeal fails differently at each step, and none of the errors point at the real cause:

- reduce `cs-gpios` alone → still `could not request pin 7 from group gpio7`, because `pinctrl-0`
  references a *group* containing GPIO 7
- redefine the group by label → `prop pinctrl-0 index 1 invalid phandle`, because the new node gets a
  new phandle and the base's reference dangles
- all three consistent → works

**3. `iw` reports nonsense frequencies for S1G.** It shows `channel 161 (5805 MHz), width: 160 MHz`
because stock `iw`/hostapd map S1G through 5 GHz operating classes. `morse_cli -i wlh0 channel` gives
the truth (924 MHz). I saw someone else on here chase this.

**4. The interface is `wlh0`, not `wlan0`.** `morse_cli -i wlan0` returns
`Invalid wiphy or interface index`, which reads like a driver failure when it is just the wrong name.

## Open question

Is the Wio-WM6108 card itself fine and simply mis-carried, or is the card bad too? I will test it in
the same hand-wired harness and follow up. If anyone has the WM1302 Pi HAT schematic, or has actually
verified that it routes SPI to the mini-PCIe pins a WM6108 uses, I would like to hear it — Seeed
state the WM6108 "can be inserted into" the WM1302 Pi HAT, and my results suggest that needs a
qualifier.

Thanks to `@ajudge` for the Raspberry Pi OS build thread and to `ykhan1999` for publishing a known-good
pin map — having one reference configuration that definitely worked is what made it possible to
isolate this.
