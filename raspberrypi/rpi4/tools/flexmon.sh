#!/bin/sh
# flexmon.sh — mechanical-stress monitor for a hand-wired MM6108 on the Pi's 40-pin header.
#
# WHAT IT IS FOR. A hand-soldered SPI harness that passes every bench test at rest can still carry
# a cold joint that only opens when the wiring is flexed or the module is twisted — which is the
# failure that reaches the field, because nothing on the bench moves. This loads the SPI bus and
# samples the failure indicators once a second while *you* flex, tug, twist and tap the hardware.
# It names the fault by signature rather than just saying "something broke":
#
#   CHIP-RESET    RESET (GPIO 5 / pin 29) shorting — the chip is being reset under you
#   IRQ-STALL     INT (GPIO 25 / pin 22) opened — no interrupts for a whole second
#   IRQ-STORM     INT shorting/ringing — >10x the measured idle rate
#   SPI-ERROR     bus-level failure in the kernel log (cmd53/cmd63/find_token/HW access)
#   CMD-FAIL      driver command channel errors or corrupted pages — CS/CLK/MISO/MOSI
#   TX-ERROR      \
#   TX-DROP        > data path glitched
#   CARRIER-LOSS  / link dropped outright
#
# WHY IT RUNS DETACHED. The first version of this ran over an interactive SSH session and lost the
# entire run when the link dropped mid-test — the one moment the data mattered most. It now
# `setsid`s itself and appends to $LOG, so the log survives a dropped link and can be read live
# from a second session while the run is still going.
#
# USAGE (on the Pi):
#   setsid ./flexmon.sh >/dev/null 2>&1 &
#   tail -f /tmp/flex.log          # live, from anywhere, even a fresh SSH session
#
# Override the defaults with the environment, e.g.:
#   PEER=192.168.12.170 DUR=180 IFACE=wlh0 setsid ./flexmon.sh >/dev/null 2>&1 &
#
# NOTE the load generator sends UDP to a discard port, so the peer does not have to cooperate —
# but it does need to be an *associated station*, or the frames never reach the radio and the SPI
# bus is not actually loaded. Check `iw dev $IFACE station dump` first.
#
# Result of the 2026-08-01 run on the Heltec HT-HC01P harness: see ../BRINGUP.md §"Mechanical
# validation". Five tests, zero anomalies.

LOG=${LOG:-/tmp/flex.log}
IFACE=${IFACE:-wlh0}
PEER=${PEER:-192.168.12.170}   # an associated HaLow station; UDP discard port
DUR=${DUR:-120}                # seconds of monitoring

: > "$LOG"
dmesg -c >/dev/null 2>&1

# Load the bus for the whole run plus a margin. An intermittent joint is far likelier to show up
# mid-transfer than at idle.
(timeout $((DUR + 5)) sh -c "dd if=/dev/zero bs=1400 2>/dev/null | nc -u $PEER 9" >/dev/null 2>&1) &

irq()  { awk "/Morse SPI IRQ/{print \$2}" /proc/interrupts; }
st()   { cat "/sys/class/net/$IFACE/statistics/$1" 2>/dev/null || echo 0; }
cmdf() { morse_cli -i "$IFACE" stats 2>/dev/null | awk -F: "/Commands failed|Command responses failed|Invalid pages/{gsub(/ /,\"\",\$2); s+=\$2} END{print s+0}"; }

PI=$(irq); PE=$(st tx_errors); PD=$(st tx_dropped); PC=$(st tx_carrier_errors); PF=$(cmdf)

# Measure the idle interrupt rate rather than assuming one — it varies with beacon interval and
# traffic, and a fixed threshold would either miss a stall or cry storm on a busy link.
BASE=$(irq); sleep 2; RATE=$(( ($(irq) - BASE) / 2 )); [ "$RATE" -lt 5 ] && RATE=5
echo "baseline irq/s=$RATE  (storm threshold ${RATE}0)" >> "$LOG"
echo "sec irq/s tx_err tx_drop carrier cmdfail note" >> "$LOG"

for s in $(seq 1 "$DUR"); do
  sleep 1
  CI=$(irq); CE=$(st tx_errors); CD=$(st tx_dropped); CC=$(st tx_carrier_errors)
  D=$((CI - PI)); N=""
  [ "$CE" != "$PE" ] && N="$N TX-ERROR"
  [ "$CD" != "$PD" ] && N="$N TX-DROP"
  [ "$CC" != "$PC" ] && N="$N CARRIER-LOSS"
  [ "$D" -eq 0 ]     && N="$N IRQ-STALL"
  [ "$D" -gt $((RATE * 10)) ] && N="$N IRQ-STORM"
  R=$(dmesg | grep -c "Resetting Morse Chip"); [ "$R" != "0" ] && N="$N CHIP-RESET"
  # NB: anchor on `errno:-` / `ret:-<digit>` and not a bare "timeout" — the driver prints
  # `default_cmd_timeout_ms : 600` in its module-parameter dump, and a loose pattern reports that
  # modparam line as an error on every single reset cycle. It cost a false alarm once already.
  E=$(dmesg | grep -icE "cmd53|cmd63|find_token|Failed to access HW|errno:-|ret:-[0-9]")
  [ "$E" != "0" ] && N="$N SPI-ERROR"
  # The morse_cli call is comparatively expensive, so sample the command channel every 10 s.
  if [ $((s % 10)) -eq 0 ]; then CF=$(cmdf); [ "$CF" != "$PF" ] && N="$N CMD-FAIL"; PF=$CF; fi
  # Print on any anomaly, plus a 10-second heartbeat so a silent log is distinguishable from a dead one.
  if [ -n "$N" ] || [ $((s % 10)) -eq 0 ]; then
    printf "%3d %5d %6d %7d %7d %7s %s\n" "$s" "$D" "$CE" "$CD" "$CC" "${CF:--}" "$N" >> "$LOG"
  fi
  PI=$CI; PE=$CE; PD=$CD; PC=$CC
done

{
  echo; echo "== final SPI counters =="
  morse_cli -i "$IFACE" stats 2>/dev/null | grep -E "Commands failed|Command responses failed|Commands repeated|Commands late|Invalid pages"
  echo; echo "== kernel messages during the run (empty = clean) =="
  dmesg | grep -iE "morse|spi0|cmd53|crc|errno|ret:-" | head -20
  echo; echo "== station =="
  iw dev "$IFACE" station dump 2>/dev/null | grep -E "Station|signal|tx retries|tx failed"
  echo "== DONE =="
} >> "$LOG"
