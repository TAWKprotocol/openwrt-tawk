# Wi-Fi HaLow on a Raspberry Pi: Wio-WM6108 (MM6108) over SPI

_Bring-up log, 2026-07-29. Host: `tawk-rp4` — Pi 4 Model B Rev 1.5, Ubuntu 26.04 LTS,
kernel **7.0.0-1009-raspi** (aarch64), 4 GB. Relates: `HALOW-PLAN.md` (protocol repo),
`hardware/eval-openwrt-reco0-coordinator-base.md` (protocol repo) §3 (bearer mapping),
`hardware/eval-mt7621-asiarf-routerboards.md` (protocol repo) §3 (the mini-PCIe form-factor trap)._

## Status

| Step | State |
|---|---|
| `morse_driver` `mm6108-2.0.1` builds against **stock kernel 7.0** | ✅ (two fixes needed, §2) |
| Driver + `dot11ah` install, sign, load; deps resolve | ✅ |
| Firmware + BCFs installed to `/lib/firmware/morse` (27 files) | ✅ |
| Pi 4 device tree overlay binds `morse_spi` to `spi0.0`, `spidev0` released | ✅ |
| Driver survives a kernel upgrade (DKMS + overlay hook) | ✅ (§6 — it did not, until fixed) |
| Chip responds on SPI | ❌ blocked — **all software variables eliminated; physical** (§5) |
| `wlanN` S1G interface up / scanning | ⛔ blocked |
| TAWK bearer over HaLow | ⛔ blocked |

**The software side is done and reproducible** (`build-morse-driver.sh`). The blocker is
physical: the MM6108 is not driving any of its pins.

## 1. The hardware path, and why it is not PCIe

```
MM6108 die → Quectel FGH100M-H module → Seeed Wio-WM6108 (mini-PCIe card)
           → Seeed WM1302 Pi HAT (mini-PCIe socket → 40-pin header)
           → Raspberry Pi 4, SPI0 / CS0
```

The MM6108 has **no PCIe host interface** — only SDIO and SPI. The mini-PCIe edge connector
is a *form factor*, and the WM1302 Pi HAT re-maps the 52-pin golden fingers onto the Pi's
40-pin header as **SPI**. This is the same trap documented in
`hardware/eval-mt7621-asiarf-routerboards.md` (protocol repo) §3: a mini-PCIe HaLow card in a real PCIe slot
will never enumerate.

Pin map (independently confirmed against
[beyondlogic's WM6108 OpenWrt notes](https://www.beyondlogic.org/building-openwrt-for-the-seeed-studio-wm6108-802-11ah-halow-radio/)
— note the WM6108 moved several pins versus the older bare MM6108 module):

| Signal | GPIO | Pi header pin | Notes |
|---|---|---|---|
| SPI0 MISO / MOSI / SCLK | 9 / 10 / 11 | 21 / 19 / 23 | native `spi0_pins` |
| SPI CS0 | 8 | 24 | `cs-gpios[0]`, already in the Pi base DT, active low |
| IRQ | **5** | 29 | level-low; was GPIO25 on the old module |
| RESET | **17** | 11 | active low; was GPIO5 |
| WAKE | **23** | 16 | `power-gpios[0]`; was GPIO3 |
| BUSY | **24** | 18 | `power-gpios[1]`; was GPIO7 |

## 2. Building against a stock kernel — the two non-obvious fixes

Morse's reference builds run a **patched** kernel (theirs is named
`6.12.25-v8-16k-morse+`). On a stock Ubuntu raspi kernel two things bite:

**`-Wno-error=cpp`.** `spi.c:1519` has
`#warning "SPI_CONTROLLER_ENABLE_CS_GPIOD macro not defined"`, and the Makefile compiles with
`-Werror`, so it is fatal. **`SPI_CONTROLLER_ENABLE_CS_GPIOD` is not a mainline macro** — it is
supplied by Morse's own kernel patch, and it governs whether the SPI core inverts CS-GPIO
polarity when `SPI_CS_HIGH` is set. Demoting the warning yields a driver that relies on
mainline's polarity handling. That appears to be fine here: the Pi's base DT declares
`cs-gpios = <&gpio 8 1>` (active low) and `/sys/kernel/debug/gpio` confirms CS0 idles
`out hi ACTIVE LOW`, which is correct for a deasserted active-low chip select.

**`CONFIG_MORSE_VENDOR_COMMAND=y`.** It defaults to `n` in `Kconfig`, but `vendor_ie.o` is in the
unconditional object list and references `vendor.o`'s symbols, so a default build dies at modpost
with ~10 undefined `morse_vendor_*` symbols. It is effectively mandatory, not optional.

Also worth knowing:
- The `mmrc-submodule` git submodule uses a **relative** URL and must be initialised explicitly.
- The driver's `compat.h` shims stop at `KERNEL_VERSION(6, 18, 0)`. Kernel 7.0 falls past the last
  guard and still builds and loads clean — so the ceiling is softer than it looks.
- The BCF module parameter is named **`bcf`**, not `board_config_file` (that is only the internal
  variable name). With `bcf` unset the driver resolves the board type from the chip's **OTP** and
  logs it — which is how you confirm the fitted FGH100M variant instead of guessing between
  `bcf_fgh100m{a,ab,h,j}aamd.bin`. Leave it unset on first light.
- Ubuntu's raspi images set `os_prefix=current/`, so overlays go in
  `/boot/firmware/current/overlays/`, not `/boot/firmware/overlays/`.

## 3. Device tree

`mm6108-spi-overlay.dts` — compatible `morse,mm610x-spi` on `&spi0` `reg = <0>`, with
`reset-gpios`, `spi-irq-gpios` and `power-gpios = <wake>, <busy>`, plus a fragment disabling
`spidev0` so it does not hold CS0.

Every GPIO cell flag is **0** on purpose. The driver parses these with `of_get_named_gpio()` and
then drives them through the *legacy* raw-GPIO API (`gpio_request_one`, `gpio_direction_output`),
handling polarity itself; a non-zero flag would make gpiolib invert a line the driver is already
inverting. For the same reason no `interrupts`/`interrupt-parent` property is needed — the driver
calls `gpio_to_irq()` on the GPIO number itself (`IRQF_TRIGGER_LOW`, or falling-edge with
`spi_use_edge_irq=1`).

## 4. The blocker, and how it was isolated

Symptom, identical at **every** SPI clock from 1 to 20 MHz:

```
morse_spi spi0.0: morse_of_probe: Reading gpio pins configuration from device tree
Resetting Morse Chip
morse_spi_find_token failed
morse_spi spi0.0: spi: cmd53_read fn=1 0x00004d20:4 r=0x10050002 b=0xffffffff (ret:-71)
morse_spi spi0.0: morse_chip_cfg_set_and_validate: Failed to access HW (errno:-5)
morse_spi_probe: probe failed (ret:-5)
```

`morse_spi_find_token()` walks the response skipping `0xff`; `b=0xffffffff` means MISO stayed
idle-high for the whole transfer. Bit-for-bit identical results across a 20× clock sweep rule out
timing, noise and marginal signal integrity — those produce *varying* corruption, not a constant.

To separate "card present but miswired" from "card not powered", `gpioprobe.c` reads the card's
**output** lines (IRQ, BUSY) twice — once with the SoC's internal pull-up, once with its
pull-down. A line the card is actively driving holds its level regardless of bias; a floating line
follows the bias. Result:

```
  as-found           IRQ(5): pu=1 pd=0 -> floating   BUSY(24): pu=1 pd=0 -> floating
  RESET=0 WAKE=0     IRQ(5): pu=1 pd=0 -> floating   BUSY(24): pu=1 pd=0 -> floating
  RESET=1 WAKE=0     IRQ(5): pu=1 pd=0 -> floating   BUSY(24): pu=1 pd=0 -> floating
  RESET=1 WAKE=1     IRQ(5): pu=1 pd=0 -> floating   BUSY(24): pu=1 pd=0 -> floating
  after reset pulse  IRQ(5): pu=1 pd=0 -> floating   BUSY(24): pu=1 pd=0 -> floating
```

**All three of the card's output lines — IRQ (5), MISO (9), BUSY (24) — float in every state,
including after a clean reset pulse with WAKE asserted.**

> ⚠ **This evidence is weaker than it first appeared — corrected 2026-07-29 after reading Morse's
> own OpenWrt feed (§5).** Two independent problems with the reading above:
>
> 1. **Two of the four probed pins may be the wrong pins.** Morse's vendor overlay uses
>    `power-gpios = <&gpio 3 0>, <&gpio 7 0>` — wake on **GPIO 3**, busy on **GPIO 7** — where this
>    document (following beyondlogic, which states the WM6108 *moved* these) uses 23 and 24. If the
>    card is really on 3/7, then "BUSY(24) floating" measured a pin the card never drives and proves
>    nothing, and the WAKE we asserted went nowhere. The conclusion then rests only on **IRQ (5)** and
>    **MISO (9)**, which both sources agree on.
> 2. **Even IRQ may be legitimately undriven when idle.** If the MM6108 leaves its interrupt line to
>    a pull-up until it has something to report, "floating" is the expected state of a *healthy*
>    powered chip, not evidence of a dead one.
>
> **And the bias-flip probe cannot settle which pinout is in use on this board.** Both vendor
> candidates are unreadable by this technique:
> - **GPIO 3** (vendor WAKE) is also **I2C1 SDA**, which carries a **fixed ~1.8 kΩ pull-up to 3V3 on
>   the Pi itself**. That swamps the SoC's ~50 kΩ internal pull-down, so the line reads "DRIVEN HIGH"
>   no matter what. Confirmed with **GPIO 2 (I2C1 SCL) as a control** — a pin the card has no
>   connection to — which reads identically. Any "driven" verdict on GPIO 2/3 is the board, not the card.
> - **GPIO 7** (vendor BUSY) is **SPI0 CE1** and stays claimed even after unbinding `spidev0.1`,
>   because `cs-gpios` is held by the SPI *controller*, not the child device. Freeing it needs a
>   device-tree change and a reboot.
>
> So there is currently **no valid reading of wake/busy under either pinout**, and the §4 evidence
> reduces to MISO holding `0xff` through transactions with CS asserted — which is equally consistent
> with a dead card and with the missing `spi-bcm2835` chip-select patch below.
>
> The honest position: **the card being dead is plausible but not established.** The software stack
> it was tested against was also incomplete (§5), so this was never a clean control. Reseat, then
> re-test against Morse's own image — that is the control experiment, not merely a shortcut.

The same probe also cleared two suspects:

- **No GPIO contention from the stacked WWAN HAT.** GPIO 4, 6, 17 and 23 all float too, so nothing
  else is holding the HaLow reset/wake lines. (GPIO 17 is a common PWRKEY/reset pin on Quectel Pi
  HATs, so a collision there was a live theory. It is not happening.)
- **The WWAN HAT is alive**, so this is not a shared-power problem. `/dev/ttyS0` at **115200**
  carries **NMEA** from the modem's GNSS engine (`$GNGLL,,,,,,V` — `V` = invalid, i.e. powered and
  streaming but no fix indoors; `$GNGSA` mode 1, DOP 25.5). An earlier read of this as "both
  add-ons are dead, therefore stack-level power" was **wrong** and is corrected here.

So the two faults are independent, and the HaLow fault is isolated to the card, its seating, or the
WM1302 HAT's routing.

> **Useful side effect: this is an `AbsTime` source.** `hardware/eval-mt7621-asiarf-routerboards.md` (protocol repo) §1
> notes that the AsiaRF AP7621-001's onboard Quectel L70B is a real advantage because the ARM64
> candidate boards have no onboard GNSS. The WWAN HAT's GNSS supplies the same thing here — a
> disciplined wall clock for the optional `AbsTime` in the Field-9 extension map. (`TawkTime`
> remains an unrelated monotonic counter — never derive time semantics from it.)
> To use it, stop the serial getty first: `sudo systemctl mask serial-getty@ttyS0.service`. A getty
> on that port eats the NMEA *and* echoes login prompts at the receiver.

Weak/void evidence, recorded so it is not re-litigated: no `/proc/device-tree/hat*` node and an
empty `i2cdetect -y 1` prove little — HAT ID EEPROMs sit on **i2c-0** (`ID_SD`/`ID_SC`), which
is not exposed here, and the WM1302 HAT may not populate one.

> ⚠ **Do not bias-probe a pin that has an alt-function.** Requesting GPIO 14/15 as GPIO inputs
> pulled them out of ALT0 (UART) and `pinctrl-bcm2835` does **not** restore the previous function on
> release — it killed the GNSS stream until a reboot re-applied the pinmux from the DT. `gpioprobe.c`
> is therefore limited to lines with no competing function. A bias flip is only meaningful on a line
> nothing else owns.

### The decisive evidence: identical hardware works — on a *patched* kernel

Morse Micro's community forum has a user (`salvage4703`) with **exactly this hardware** — Raspberry
Pi + **Seeed WM1302 Pi HAT** + **Seeed WM6108** + **Quectel FGH100MHAAMD**, `bcf_fgh100mhaamd.bin`,
`mm6108.bin` — who **got the driver up**
([thread](https://community.morsemicro.com/t/mm6108-fgh100m-h-wm6108-wm1302-pi-hat-rpi5-over-spi/1104)).

Their kernel: **`6.12.25-v8-16k-morse+`** — a custom build carrying Morse's patches. That is the one
variable this bench has never had, and it is the same gap identified in §5 (the `spi-bcm2835`
chip-select patch plus seven `mac80211` S1G patches).

**So the card is probably fine and the stock kernel is the blocker.** The "card is dead" reading in
§4 should be treated as unlikely, not merely unproven.

Two further things from Morse staff (`ajudge`) in that thread and in
[Build Thread: HaLow for Raspberry Pi OS](https://community.morsemicro.com/t/build-thread-halow-for-raspberry-pi-os/1124):

- **"Have you physically power cycled the device, or just soft booted? … most of our deployments use
  a reset script to toggle the reset line on boot. If that's not run, on warmboots you will see
  these errors."** Every test on this bench has been a **warm** reboot.
- **Use Morse's own OpenWrt fork, not Seeed's.** Their **EKH01 eval kit is a Raspberry Pi 4B** with
  Morse's MMECH06 HAT and ships running that fork. Upstream is
  [`MorseMicro/openwrt`](https://github.com/MorseMicro/openwrt) +
  [`MorseMicro/morse-feed`](https://github.com/MorseMicro/morse-feed) — the Seeed/Wvirgil tree read
  in §5 is a stale downstream copy of exactly this.

**The long reset sequence was tested here and did not help.** A working third-party setup
([`ykhan1999/zero2w_80211ah`](https://github.com/ykhan1999/zero2w_80211ah), MM6108 over SPI on a
Pi Zero 2W) blacklists the driver from autoloading and drives it from a service that does:

```bash
pinctrl set 5 op dl   # reset LOW
sleep 2               #   held 2 full seconds (the driver's internal reset is 80 ms)
pinctrl set 5 pu dh   # release HIGH with pull-up
sleep 4               #   4 s settle
modprobe morse enable_wiphy=0 enable_otp_check=1 country=US \
        bcf=... spi_clock_speed=24000000 slow_clock_mode=0 fw_bin_file=mm6108.bin
# ...and loops until dmesg reports "Driver loaded with kernel module parameters"
```

Replicated on this bench against GPIO 17 (with WAKE asserted first), three attempts: **identical
`cmd53_read b=0xffffffff / -71` every time.** So the reset timing alone is not the missing piece —
which leaves the **cold power cycle** and the **patched kernel** as the untried variables.

> Note their overlay uses `reset-gpios = <&gpio 5 1>` — **flag 1, active-low** — where Morse's own
> vendor overlay uses flag `0`. Another inconsistency in the published examples; and their pinout
> (reset 5, IRQ 25, wake 3, busy 7) is a *hand-wired* Heltec HT-HC01P, chosen to match Morse's
> overlay, not a carrier constraint. It does not transfer to the WM1302 HAT, whose routing is fixed
> in copper.

### 2026-07-31 — the Morse-patched kernel changes nothing. Result matrix.

Running Morse's own OpenWrt (`3.0.2`, `ekh-bcm2711-mm6108`) on the same hardware:

| Kernel | wake/busy pins | chip-select config | Result |
|---|---|---|---|
| stock Ubuntu 7.0 | ours 23 / 24 | base DT, **two** CS, native alt-fn | CMD63 **passes**, `cmd53 b=0xffffffff` → **-71** |
| Morse patched 6.6 | Morse 3 / 7 | vendor: one CS, `GPIO_OUT` | CMD63 **fails** → -61 |
| Morse patched 6.6 | ours 23 / 24 | vendor: one CS, `GPIO_OUT` | CMD63 **fails** → -61 |
| **Morse patched 6.6** | **ours 23 / 24** | **base DT, two CS, native** | CMD63 **passes**, `cmd53 b=0xffffffff` → **-71** |

Two conclusions, and the first retires the reason this migration happened.

- **The kernel patches make no difference.** On the patched kernel, in the best configuration, the
  failure is *byte-identical* to the stock kernel — same `r=0x10050002 b=0xffffffff`, same `-71`.
  §5's inference that "the stock kernel is the blocker, the card is probably fine" is **wrong**. The
  identical-hardware forum report remains true, but whatever differs in that setup is not the kernel.
- **The chip-select configuration decides CMD63, and nothing decides `cmd53`.** Single-CS or
  `GPIO_OUT` chip select ⇒ `-61`. Native two-CS ⇒ CMD63 passes and then the first register read
  returns all-ones. No configuration has ever got past that read.

Getting to a probe on OpenWrt needed three interdependent device tree changes, and partial adoption
fails differently at each step — worth knowing before anyone tries again:

1. `morse-ps` claims **GPIO 7** for Morse's MMECH06 carrier, colliding with the base DT's CS1:
   `pin gpio7 already requested by leds; cannot claim for fe204000.spi` → controller never probes,
   **no SPI devices at all**, driver silent.
2. Narrowing `cs-gpios` alone is insufficient — `pinctrl-0` still references a pin *group* containing
   GPIO 7: `could not request pin 7 from group gpio7`.
3. Redefining that group by label gives it a new phandle, so the base's reference dangles:
   `prop pinctrl-0 index 1 invalid phandle`. `cs-gpios`, the pin group, and `pinctrl-0` are a coupled
   set; all three must agree.

Since `morse-ps` configures the wrong carrier's pins anyway (wake on 7, not 23), **disabling it and
using the base DT's native two-CS setup is the cleanest configuration** — and is what the device now
runs (`mm6108-spi-native.dts`).

**Where that leaves it.** Every software variable identified has now been eliminated: pinout (both
tried), kernel patches (both tried), chip-select config (all three tried), power-enable GPIO 18
(both polarities), reset timing, and de-stacking. The physical evidence from §4 — IRQ, MISO, BUSY and
the vendor BUSY pin all floating in every state — stands unexplained by any of them. The remaining
candidates are the **card itself, its seating, or what the WM1302 HAT actually routes to the
mini-PCIe socket**, which is a carrier designed for the WM1302 LoRa concentrator, not this card.

This matrix is the right thing to send Morse's forum with a support request.

### Controlled experiments, 2026-07-30 (de-stacked: HaLow HAT only)

With the WWAN HAT physically removed, three overlay variants were booted and compared. Speed was
20 MHz throughout (the `spi_clock_speed` modparam caps below any DT `spi-max-frequency`), so clock
is not a variable.

| Overlay | `cs-gpios` | wake/busy | CS pinctrl | Result |
|---|---|---|---|---|
| `mm6108-spi-overlay.dts` (ours) | base DT `<8>,<7>` | 23 / 24 | native | **CMD63 passes**, `cmd53_read b=0xffffffff` → `-71` |
| vendor-faithful (not kept — see below) | `<8>` only | 3 / 7 | vendor `GPIO_OUT` + pulls | CMD63 **fails** → `-61` |
| vendor pinout, native CS (not kept) | `<8>` only | 3 / 7 | native | CMD63 **fails** → `-61` |

**Ours is the best-performing configuration and is the default.** The two losing variants are
recorded here rather than carried as files — they were ports of Morse's GPL-2.0 overlay, and the
table above captures every property difference and both outcomes, which is the whole of their value. Two conclusions:

- **The regression is caused by reducing `cs-gpios` to a single entry**, not by the vendor's
  chip-select pinctrl — overlay C kept native CS and still failed at CMD63. An initial theory that
  the vendor's `brcm,function = <1>` CS presupposed their `spi-bcm2835` patch was **wrong**; the
  variable is the chip-select *count* seen by `spi-bcm2835`, which changes its native-CS handling.
- **The wake/busy pinout ambiguity is resolved as a non-cause.** Dropping `cs-gpios` to one entry
  finally released **GPIO 7** from the SPI controller, making it readable — and it **floats**, exactly
  like GPIO 24. So the card drives *neither* candidate BUSY pin, nor IRQ (5), nor MISO (9). Whichever
  pinout is correct for this carrier, the card is not driving it. (GPIO 3 still reads "driven high"
  but that remains the Pi's I2C pull-up: control pin GPIO 2 reads identically.)

**De-stacking changed nothing** — identical failure with the WWAN HAT removed.

> **Correction: the GNSS is on the WM1302 HAT, not the WWAN modem.** With the WWAN HAT physically
> removed and nothing modem-like on USB, `/dev/ttyS0` still streams NMEA at 115200 (3709 bytes in
> 4 s). The WM1302 Pi HAT carries its **own onboard GPS** — Seeed's page notes it "enhances the
> accuracy of timing and location of the WM1302 module." An earlier attribution of this NMEA to the
> Quectel modem's GNSS engine was wrong.
>
> Two consequences. It removes the last shred of the "WWAN HAT is alive so power is fine" reasoning
> as evidence about *that* HAT — but it substitutes something better: **the HaLow HAT itself is
> demonstrably powered and partly functional**, since its GPS is running. And the `AbsTime` source
> noted below lives on the HaLow carrier, which is convenient for the coordinator story.

### The carrier's own GPIO map (WM1302 Pi HAT)

`seeed-lora/WM1302-doc` gives the HAT's GPIO usage, which completes the mental model: **the HAT
fixes which Pi GPIOs reach which mini-PCIe pins; the card decides what those pins mean.**

| HAT function (LoRa card) | Pi GPIO | What a HaLow card sees there |
|---|---|---|
| SX1302 reset | **17** | MM6108 `reset-gpios` — matches Morse's overlay |
| SX1261 reset | **5** | MM6108 `spi-irq-gpios` — matches Morse's overlay |
| **Power enable** | **18** | gates power to the mini-PCIe socket |

That GPIO 17/5 coincidence is why Morse's overlay uses exactly those numbers, and it is good evidence
the reset/IRQ half of this tree's overlay is right.

**GPIO 18 was tested and is not the answer.** Driven high *and* low, with and without a driver load,
IRQ(5) / MISO(9) / BUSY(24) stayed floating and the chip never answered. So an unasserted
power-enable is ruled out as the cause — **but the pin is still the right place to look with a
meter** (below).

### Physical checks, in priority order

External power to both HATs is already confirmed present, so that is ruled out.

1. **Reseat the WM6108** in the mini-PCIe socket and fit the retention screws — it is a full-size
   mini-PCIe card and can sit proud enough to lose contact on the SPI pins while still mating power.
   **Most likely cause given everything else is cleared.**
2. **De-stack.** Run the HaLow HAT alone, directly on the Pi. Rules out a pass-through header that
   does not carry every signal even though it carries power. (Not a GPIO conflict — that was
   measured and cleared — but a *missing* connection would look exactly like this.)
3. **Confirm the carrier is SPI-wired for HaLow.** The WM1302 concentrator ships in SPI *and* USB
   variants; verify this HAT revision routes MISO/MOSI/SCLK/CS through to the socket and is not
   strapped for the USB variant.
4. **Measure 3V3 at the mini-PCIe socket, card removed.** This is the one measurement that
   separates "unpowered" from "card faulty" without ambiguity, and it can be done while the card is
   out for reseating. Mini-PCIe carries 3.3 V on **pins 2, 24, 39 and 41**; ground on 4, 9, 15, 18,
   21, 26, 35, 40, 50, 52. Probe with the Pi booted and the HAT's external supply connected, and
   re-check with GPIO 18 driven high (`sudo ./holdpin 18 1 &`). No 3V3 at the socket means the HAT or
   its enable path; 3V3 present means the card is the suspect.
5. **Antenna.** Not the cause of a dead SPI bus, but fit the 900 MHz antenna before transmitting.

Separately, for the WWAN HAT's *modem* (as opposed to its GNSS): an earlier reading of "absent from
`lsusb`" as a missing USB jumper was **wrong**. The jumper is fitted — hub port 3 holds a device that
is detected and powered but never answers a control transfer:

```
usb 1-1.3: device descriptor read/64, error -71   (x2)
usb 1-1-port3: attempt power cycle
usb 1-1.3: Device not responding to setup address.
usb 1-1.3: device not accepting address 7, error -71
usb 1-1-port3: unable to enumerate USB device
```

It completes the high-speed chirp, then fails at SET_ADDRESS, so it never yields a VID:PID and
cannot appear in `lsusb`. The kernel tried its own power cycle at t~4.4 s and gave up permanently at
t~5.9 s. That fits a Quectel module whose USB PHY comes up before its firmware (kernel probes at
4 s; these modules need 10-15 s), or one that never received its **PWRKEY pulse** — GNSS runs off
the module's always-on domain, which is why NMEA works while USB does not. Since the kernel's own
power cycle did not help, PWRKEY or boot timing is likelier than power.

Retrying enumeration after the module has booted is the test. Note the Pi 4's **internal** VIA hub
is **ganged, not per-port** (`wHubCharacteristic 0x00e0` — `uhubctl` may still tag it `ppps`), so a
VBUS cycle there hits the XIAO and nRF54L15 too. One `xhci_hcd` behind **PCIe Gen2 x1** serves every
USB-A port: a Pi 4 is one reset domain and one ~4 Gbit/s pipe, which is worth knowing before this
shape becomes the coordinator (see `hardware/eval-mt7621-asiarf-routerboards.md` (protocol repo) §3 on counting USB
ports rather than mini-PCIe slots).

## 5. What Morse's own OpenWrt feed says — and what this build was missing

The Seeed/Wvirgil OpenWrt tree turns out to carry **Morse Micro's own vendor feed**
(`feeds/morse/`, ~50 packages), not a community hack. Reading it shows this hand-built stack was
missing things the vendor treats as required. Recorded because it changes how much the §4 result
can be trusted, and because it retires most of the OpenWrt packaging work item.

**Vendor SPI overlay** (`target/linux/bcm27xx/patches-5.15/991-0003-dt-overlays-morse-add-spi-overlay-fragment.patch`):

| Property | Vendor | This tree | |
|---|---|---|---|
| `compatible` | `morse,mm610x-spi` | same | ✅ |
| `reg` | `<0>` (CE0) | same | ✅ |
| `reset-gpios` | `<&gpio 17 0>` | same | ✅ |
| `spi-irq-gpios` | `<&gpio 5 0>` | same | ✅ |
| `power-gpios` | `<&gpio 3 0>, <&gpio 7 0>` | `<&gpio 23 0>, <&gpio 24 0>` | ❗ **differs** |
| `spi-max-frequency` | `<50000000>` | `<20000000>` | differs |
| `spidev` disabled | `spidev@0` **and** `spidev@1` | only `spidev@0` | ❗ |
| `interrupts` property | none | none | ✅ |
| GPIO cell flags | all `0` | all `0` | ✅ |

The `power-gpios` split is the live question. Beyondlogic states the **WM6108 moved** wake/busy from
GPIO 3/7 to 23/24 relative to the older bare MM6108, and this stale vendor tree plausibly predates
the WM6108. Note the vendor disables `spidev@1` precisely because **GPIO 7 is SPI0 CE1** and they
repurpose it as BUSY — internally consistent with the old pinout. **Determine which pinout this card
actually uses before trusting any liveness result.**

**Kernel patches this build did not have:**

- `999-001-morse-spi-fix-spi-bcm2835-driver-v5.3.patch` — reworks `spi-bcm2835`, notably reverting
  chip-select handling from **GPIO descriptors back to raw GPIO numbers**. That is the same seam as
  the missing `SPI_CONTROLLER_ENABLE_CS_GPIOD` macro in §2: Morse's SPI code expects the older
  raw-GPIO CS behaviour. §2 concluded that demoting the `#warning` was "probably fine because CS
  idles correctly" — that conclusion is **not safe**, and this is a credible alternative root cause
  for the dead bus in §4.
- `991-0002-dt-overlays-morse-add-powersave-and-reset-pin-defini.patch` — the "morse-ps" overlay
  beyondlogic referred to; powersave/reset pin definitions kept separate from the SPI fragment.
- **Seven `mac80211` S1G patches** (`package/kernel/mac80211/patches/subsys/999-00*-morse-*`):
  ECSA for AP and MLME, mesh support, IBSS bridging, NDP block-ack, dynamic-PS recalc. This build
  linked **stock** `mac80211`, so even with a working SPI bus, S1G operation would be degraded or
  broken. **Builds clean ≠ works.**

**What this retires from the eval.** `hardware/eval-openwrt-reco0-coordinator-base.md` (protocol repo) §4.1 listed
"build `morse_driver` as an OpenWrt kmod" as open work. The vendor already ships it, plus
`morse-fw`, `morse-regdb`, `hostapd_s1g`, `morsecli`, `mm-board-config`, and — most valuable —
**`netifd-morse`**, which integrates HaLow into `netifd`/`uci` as an ordinary `wifi-device`
(`lib/netifd/wireless/morse.sh`). That is exactly the control-plane integration §1 predicted came
free with OpenWrt, already written. The remaining work is porting that feed from its kernel-5.15
base onto upstream 25.12.0 / kernel 6.x — a much smaller job than writing it.

Two incidental notes: `morse-firmware-sign` ships a **Morse Micro root signing CA** and an upgrade
hook, which is worth a look if you package your own images; and Morse's own EKH03/EKH04
reference gateways are **MT7628 (ramips MIPS)** — which does not disturb the MIPS verdict in
`hardware/eval-mt7621-asiarf-routerboards.md` (protocol repo) §2.1, since a HaLow gateway runs no PQC.

## 6. A kernel upgrade silently disarmed the radio — and why that matters beyond this bench

Mid-session, `unattended-upgrades` installed **7.0.0-1009-raspi → 7.0.0-1015-raspi**. After the next
reboot the radio was simply gone, with **no error message anywhere**:

- the out-of-tree `morse.ko` was installed under `/lib/modules/7.0.0-1009-raspi/updates/`, so it was
  invisible to the running kernel — `modprobe: Module morse not found`;
- `flash-kernel` **repopulated `/boot/firmware/current/overlays/`** and deleted `mm6108-spi.dtbo`,
  while `config.txt` still said `dtoverlay=mm6108-spi`. A missing overlay is skipped **silently** —
  no boot warning, no dmesg line — so `spi0.0` came back as plain `spidev` and nothing probed.

This is a concrete instance of why out-of-tree kernel modules are a liability worth avoiding on a
device that must come back up unattended. A general-purpose auto-updating distro will silently
de-provision a bearer. Under ADR-006's always-forward guarantee a coordinator that loses its radio
is not a degraded relay, it is an **absent** one — and nothing logged a complaint.

Mitigations applied here (both are the bench-grade fix, not the architectural one):

| Problem | Fix |
|---|---|
| Module vanishes on kernel change | **DKMS** (`dkms.conf`, `AUTOINSTALL="yes"`) rebuilds on every kernel install |
| Overlay deleted by `flash-kernel` | `zz-mm6108-overlay` kernel postinst hook reinstalls it from `/usr/local/share/mm6108/` |

The **architectural** fix is the one the ADR already calls for: an immutable image with the driver
and overlay baked in, A/B slots, and no in-place package-managed kernel churn. Treat DKMS as a
bench affordance, not a product answer — and note this is a second, independent reason the reco0
coordinator wants a built image rather than a general-purpose distro.

## 7. Files

| File | Purpose |
|---|---|
| `build-morse-driver.sh` | Reproducible driver + firmware + overlay install; encodes both kernel-7.0 fixes |
| `overlays/mm6108-spi-overlay.dts` | Pi 4 device tree overlay, `morse,mm610x-spi` on SPI0/CS0 |
| `tools/gpioprobe.c` | Bias-flip liveness probe — distinguishes a dead/unpowered card from a wiring fault |
| `build-morse-openwrt.sh` | Build Morse's OpenWrt for this Pi 4B (§8) — the chosen path |
| `../../common/provision-image.sh` | Headless provisioning: known credentials, guaranteed RJ45+DHCP, SSH key, and a FAT-partition per-device config hook. Userspace/UCI only |
| `../../common/finalize-image.sh` | Post-build: SHA-256 per image, bound to the credentials baked into it |
| `../../common/docker-compose.morse-openwrt.yml` | Wraps the OpenWrt buildworker image Morse's own CI uses (§8) |
| `tools/holdpin.c` | Drive and hold one GPIO at a level until killed (power-enable / JTAG-reset tests) |
| _(two A/B controls, not kept)_ | Both regressed to CMD63 `-61`. They were ports of Morse's GPL-2.0 overlay, so they are **not** carried in this Apache-2.0 repository; the table in §5 records every property difference and both results, which is what the files were for. Reconstruct from Morse's tree if ever needed. |
| `legacy-stock-kernel/dkms.conf` | DKMS recipe; rebuilds the driver on every kernel install (§6) |
| `legacy-stock-kernel/zz-mm6108-overlay` | `/etc/kernel/postinst.d/` hook; reinstalls the overlay after `flash-kernel` (§6) |

## 8. Decision: move to Morse Micro's OpenWrt

**Chosen 2026-07-30 — stop fighting the stock kernel; build Morse's own OpenWrt for this Pi 4B.**
Rationale is §5: identical hardware works on a Morse-patched kernel, the required patches are not
upstream, and Morse's **EKH01 evaluation kit is itself a Raspberry Pi 4B** so their fork already
targets this board. Seeed's own README independently confirms `-b ekh01` is the right board for
their HaLow modules on a Pi.

`build-morse-openwrt.sh` automates it. Run it on an **x86_64 Linux build host** (not the Pi, not
macOS); ~50 GB free, 1–3 hours.

| | |
|---|---|
| Source | [`MorseMicro/openwrt`](https://github.com/MorseMicro/openwrt) tag **3.0.2** — pairs the `mm6108-2.0.1` driver with MM6108 parts (3.1.1 gives MM6108 the older 1.17.8) |
| Board | `./scripts/morse_setup.sh -i -b `**`ekh-bcm2711-mm6108`** |
| Releases | **source tags only — no prebuilt images**, so building is mandatory |

**The board name is the first trap.** Morse reorganised `boards/` to `ekh-<target>-<chip>`, so at
3.0.2 there is **no `ekh01`** — yet `morse_setup.sh`'s own help text still shows
`-b ekh01` and `-b ekh03v4` in its examples. Following the script's own documentation therefore
fails, complaining about a missing `*_hw_diffconfig`. Do **not** graft Seeed's `boards/ekh01/` in to
satisfy it; that is the old layout. The correct board is **`ekh-bcm2711-mm6108`**, whose
`target_diffconfig` is:

```
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_bcm27xx=y
CONFIG_TARGET_bcm27xx_bcm2711=y
CONFIG_TARGET_DEVICE_bcm27xx_bcm2711_DEVICE_morse_mm6108-ekh01-sdio=y
CONFIG_TARGET_DEVICE_bcm27xx_bcm2711_DEVICE_morse_mm6108-ekh01-spi=y
```

Note **`ekh01` survives as the *device* name** even though the board directory was renamed — which is
exactly why the stale examples look plausible. It builds **both SDIO and SPI profiles**; the WM6108
on a WM1302 Pi HAT is SPI, so take the ***-spi*** image.

Boards present at 3.0.2: `ekh-bcm2711-mm6108`, `ekh-bcm2711-mm8108`, `ekh-filogic`, `ekh-mt7621`,
`ekh-mt7622`, `ekh-mt76x8`, `ekh-ath79`, `ekh-ipq806x-generic`, `ekh-mvebu-cortexa9`,
`ekh-armsr_armv7/armv8`, `ekh-malta_*`, `ekh-x86_64`, `halowlink1`, `halowlink2`.

If `morse_setup.sh` aborts with `<file> is not a symlink`, use **`-m`** (minimal): it consumes only
`target_diffconfig`, which is exempt from that check, and extras can be re-added with `-x`.

**Build in Morse's own CI container, not on a modern host.** Their tree ships
`.devcontainer/ci-env/devcontainer.json` pinning
**`ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9`** with `remoteUser: buildbot` — the official
OpenWrt buildworker. Using it removes the whole class of host-toolchain breakage seen on Ubuntu
24.04 (GCC 15 against the golang host build, the dropped `python3-distutils`). There is no Dockerfile
to write; `docker-compose.morse-openwrt.yml` in this directory wraps that image with persistent
`dl/` and ccache mounts. (OpenWrt refuses to build as root — hence the `buildbot` user.)

**`CONFIG_PACKAGE_morsectrl` is a bug in 3.0.2 and a container will not fix it.** A board diffconfig
sets `CONFIG_PACKAGE_morsectrl=y`, but the *pinned* feed (`morse-feed.git^c880dca4`) ships the
package as **`morsecli`**. Because `morse_setup.sh` runs defconfig with
`KCONFIG_WARN_UNKNOWN_SYMBOLS=1 KCONFIG_WERROR=1`, the stale symbol is fatal rather than a warning:

```
.config:302:warning: unknown symbol: PACKAGE_morsectrl
SETUP FAILED: error 2 ... from: KCONFIG_WARN_UNKNOWN_SYMBOLS=1 KCONFIG_WERROR=1 make defconfig
```

Fix before configuring — `build-morse-openwrt.sh` now does this automatically:

```bash
grep -rls CONFIG_PACKAGE_morsectrl boards/ | xargs sed -i 's/^CONFIG_PACKAGE_morsectrl=/CONFIG_PACKAGE_morsecli=/'
```

Three further things that will otherwise cost an evening:

1. **`python3-distutils` does not exist on Ubuntu 24.04+.** Morse's README lists it, but Python
   3.12 removed distutils and the package was dropped. Use `python3-setuptools`; the script detects
   this.
2. **The BCF must be symlinked to `bcf_default.bin`.** The driver falls back to that name, so the
   FGH100M-H file has to be linked to it on the flashed image:
   `cd /lib/firmware/morse && rm -f bcf_default.bin && ln -s bcf_fgh100mhaamd.bin bcf_default.bin`.
3. **EKH01 ships Morse's MMECH06 HAT, not the WM1302 Pi HAT**, so the stock overlay's wake/busy pins
   are wrong for this carrier. Fortunately **OpenWrt on bcm27xx still boots through the Pi bootloader
   with `config.txt` + `overlays/`**, so `mm6108-spi-overlay.dts` from this directory drops in
   unchanged — the same mechanism that already works under Ubuntu.

## 9. First boot on the Morse image

⚠ **Do not plug it into an existing LAN first.** The ekh board config sets
`CONFIG_TARGET_PREINIT_IP="10.42.0.1"` and OpenWrt runs `dnsmasq` on LAN by default, so on a shared
network it becomes a **rogue DHCP server** handing out 10.42.0.x leases. Bring it up
**point-to-point** to a laptop (static `10.42.0.2/24`) or on an isolated switch.

```bash
ssh root@10.42.0.1            # no password on a fresh OpenWrt image — set one immediately
dmesg | grep -i morse
```

Read the result against §4's baseline:

| dmesg | Meaning |
|---|---|
| an OTP board type + firmware/BCF checksums, then an `iw dev` interface | working — go to §10 |
| `cmd53_read … b=0xffffffff (ret:-71)` | same failure as the stock kernel ⇒ **pinout**, not patches. Swap the overlay (below) |
| `failed to init SPI with CMD63 (ret:-61)` | chip not answering at all; recheck seating, then the overlay |

**Expect to need the overlay swap.** The image ships Morse's overlay for their **MMECH06** HAT, not
the Seeed **WM1302**. OpenWrt on bcm27xx still boots through the Pi bootloader, so the boot partition
has `config.txt` and `overlays/` exactly as under Raspberry Pi OS:

```bash
dtc -@ -I dts -O dtb -o mm6108-spi.dtbo mm6108-spi-overlay.dts   # on the build host
# copy mm6108-spi.dtbo into the card's boot partition overlays/, then in config.txt
# replace the morse overlay line with:
#   dtoverlay=mm6108-spi
```

And the BCF, which the driver reaches via a fixed default name:

```bash
ls /lib/firmware/morse/                       # see which FGH100M variants shipped
cd /lib/firmware/morse && rm -f bcf_default.bin
ln -s bcf_fgh100mhaamd.bin bcf_default.bin    # FGH100M-H = the WM6108's module
```

### Card forensics, 2026-07-30 (Morse image, post-first-boot)

Examined the flashed card offline. Three results.

**1. The management AP key is not on the card, and cannot be.** The AP `ekh01-<macsuffix>` is named
from the hostname and its key is generated at first boot:

```sh
default_wifi_key=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)   # morse-wireless-defaults:21
uci set "system.@system[0].default_wifi_key=$default_wifi_key"
```

`/etc/config/{system,network,wireless}` are **absent from the squashfs** — all generated at boot. And
see (2): there is nowhere to persist them. So **the key changes on every boot** and only ever exists
in RAM. Recovering it from the card is impossible by construction; read it from a running device with
`uci get system.@system[0].default_wifi_key`, via HDMI console (fresh OpenWrt has no root password).

**2. There is no `rootfs_data` partition — nothing persists.** The card carries only:

| Part | Size | FS |
|---|---|---|
| `sdc1` | 64 MB | vfat (`boot`) |
| `sdc2` | 300 MB | squashfs (read-only rootfs) |
| — | **14 GiB** | **unallocated** |

With no overlay partition, OpenWrt falls back to a **tmpfs** overlay: every UCI change, the wifi key,
the root password and any HaLow config are lost on reboot. `CONFIG_TARGET_ROOTFS_PARTSIZE=300` matches
the 300 MB rootfs exactly, so the `*_hw_diffconfig` *was* applied and the build was **not** minimal —
which also means `kmod-of-mdio` should be present, so the unreachable Ethernet is more likely an
address/DHCP issue than a missing driver. Fix persistence by claiming the free space:

```bash
sudo parted /dev/sdX mkpart primary ext4 761856s 100%
sudo mkfs.ext4 -L rootfs_data /dev/sdX3      # fstools adopts a partition with this label
```

**3. The SPI configuration in the image is correct.** `config.txt` includes `distroconfig.txt`, which
carries:

```
dtoverlay=morse-ps          # the power/reset-pin overlay beyondlogic said was required
dtparam=spi=on
dtoverlay=mm610x-spi        # NB named mm610x-spi.dtbo, not morse-spi -- easy to miss when grepping
dtoverlay=sysinfo,board-name="morse,mm6108-ekh01-spi",model="MorseMicro MM6108-EKH01 (SPI)"
```

So the SPI path and the power-sequence overlay are both wired up. To substitute the WM1302 pinout,
replace **`dtoverlay=mm610x-spi`** in `distroconfig.txt` with `dtoverlay=mm6108-spi` and drop this
directory's `mm6108-spi.dtbo` into the boot partition's `overlays/`.

## 10. Next, once the card answers

1. Read the OTP-reported board type from `dmesg` and pin `bcf=` accordingly.
2. `iw list` / `iw dev` — confirm the S1G band and that `country=US` took (driver default is `AU`;
   region policy per `HALOW-PLAN.md` (protocol repo) and ADR-026).
3. Build Morse's `hostap` fork (`hostapd_s1g` / `wpa_supplicant_s1g`, same tag) for AP/STA. Note
   `nmcli dev set wlanN managed no` first — NetworkManager will otherwise fight hostapd.
4. Bring up the HaLow bearer as a `Transport` impl over raw `AF_PACKET` **EtherType 0x88B5**, the
   framing already used by `hardware/esp32s3-tawk/halow/` (protocol repo) — so the Pi and the ESP32-S3 nodes
   interoperate on the wire without a translation shim.
5. Expected ceiling: the Morse community reports **~19 Mbps on Pi 4** over SPI versus ~800 kbps on
   a Pi 5 (RP1 SPI bottleneck) — the Pi 4 is the good host here, which is worth remembering before
   anyone "upgrades" the bench.
