// SPDX-License-Identifier: Apache-2.0
/*
 * gpioprobe — is the MM6108 on the WM1302 Pi HAT actually alive?
 *
 * The morse driver reads 0xffffffff on MISO at every SPI clock speed, which means
 * nothing drove the line. That has two very different causes: the card is present
 * and talking but MISO isn't routed, or the card has no power / isn't seated.
 *
 * This tells them apart electrically, in software. Read a line twice — once with
 * the SoC's internal pull-up, once with its pull-down:
 *
 *   value follows bias  -> line is floating   -> nothing is driving it
 *   value ignores bias  -> line is driven     -> something is alive on it
 *
 * Two passes:
 *   1. survey  — every line either the HaLow card or a stacked HAT could drive,
 *                to catch both a dead card and contention from a neighbour.
 *   2. sweep   — drive RESET/WAKE through their states and re-read the card's
 *                outputs, to see whether releasing reset changes anything.
 *
 * !! Never add a pin that has a non-GPIO alt-function (UART, I2C, PCM...). !!
 * Requesting a line through /dev/gpiochip* reconfigures its pinmux, and
 * pinctrl-bcm2835 does NOT restore the previous function on release. Probing
 * GPIO 14/15 during bring-up silently killed the WWAN HAT's GNSS NMEA stream
 * until a reboot re-applied the pinmux from the device tree. A bias flip is only
 * meaningful on a line nothing else owns.
 *
 * Build: gcc -O2 -o gpioprobe gpioprobe.c        Run: sudo ./gpioprobe
 * Unload the driver first (sudo modprobe -r morse) or the lines read as BUSY.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/gpio.h>

#define IRQ_LINE   5   /* MM6108 -> host, active low  */
#define MISO_LINE  9   /* MM6108 -> host (SPI0 MISO)  */
#define RESET_LINE 17  /* host -> MM6108, active low  */
#define WAKE_LINE  23  /* host -> MM6108              */
#define BUSY_LINE  24  /* MM6108 -> host              */

static int chipfd = -1;

/* Request `n` lines with `flags`; returns a line-request fd or -1. */
static int req(const unsigned *offs, unsigned n, uint64_t flags, const char *tag)
{
	struct gpio_v2_line_request r;
	memset(&r, 0, sizeof r);
	for (unsigned i = 0; i < n; i++)
		r.offsets[i] = offs[i];
	r.num_lines = n;
	r.config.flags = flags;
	snprintf(r.consumer, sizeof r.consumer, "%s", tag);
	if (ioctl(chipfd, GPIO_V2_GET_LINE_IOCTL, &r) < 0)
		return -1;
	return r.fd;
}

/* Read one line under a given bias. Returns 0/1, or -1 if it could not be read. */
static int read1(unsigned off, uint64_t bias)
{
	struct gpio_v2_line_values v;
	int fd = req(&off, 1, GPIO_V2_LINE_FLAG_INPUT | bias, "gpioprobe");
	if (fd < 0)
		return -1;
	memset(&v, 0, sizeof v);
	v.mask = 1;
	usleep(30000); /* let the bias settle on whatever capacitance is present */
	if (ioctl(fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &v) < 0) {
		close(fd);
		return -1;
	}
	close(fd);
	return !!(v.bits & 1);
}

/* Drive RESET and WAKE; caller keeps the returned fd open to hold the levels. */
static int drive(int reset, int wake)
{
	const unsigned offs[2] = { RESET_LINE, WAKE_LINE };
	struct gpio_v2_line_values v;
	int fd = req(offs, 2, GPIO_V2_LINE_FLAG_OUTPUT, "gpioprobe-out");
	if (fd < 0) {
		fprintf(stderr, "  cannot drive reset/wake: %s\n", strerror(errno));
		return -1;
	}
	memset(&v, 0, sizeof v);
	v.mask = 0x3;
	v.bits = (reset ? 1 : 0) | (wake ? 2 : 0);
	if (ioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &v) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void sweep_row(const char *state)
{
	int iu = read1(IRQ_LINE,  GPIO_V2_LINE_FLAG_BIAS_PULL_UP);
	int id = read1(IRQ_LINE,  GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN);
	int bu = read1(BUSY_LINE, GPIO_V2_LINE_FLAG_BIAS_PULL_UP);
	int bd = read1(BUSY_LINE, GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN);

	if (iu < 0 || id < 0 || bu < 0 || bd < 0) {
		printf("  %-22s (lines busy — unload the morse driver first)\n", state);
		return;
	}
	printf("  %-22s IRQ(5): pu=%d pd=%d -> %-8s   BUSY(24): pu=%d pd=%d -> %s\n",
	       state, iu, id, (iu == id) ? "DRIVEN" : "floating",
	       bu, bd, (bu == bd) ? "DRIVEN" : "floating");
}

int main(void)
{
	static const struct { unsigned n; const char *what; } survey[] = {
		{ IRQ_LINE,   "IRQ    (HaLow -> host)" },
		{ MISO_LINE,  "MISO   (HaLow -> host)" },
		{ RESET_LINE, "RESET  (host -> HaLow)" },
		{ WAKE_LINE,  "WAKE   (host -> HaLow)" },
		{ BUSY_LINE,  "BUSY   (HaLow -> host)" },
		{ 4,          "GPIO4  (common HAT PWRKEY)" },
		{ 6,          "GPIO6  (common HAT ctrl)" },
	};
	int fd;

	chipfd = open("/dev/gpiochip0", O_RDONLY);
	if (chipfd < 0) {
		fprintf(stderr, "open /dev/gpiochip0: %s\n", strerror(errno));
		return 1;
	}

	printf("MM6108 liveness probe — pull-up vs pull-down\n");
	printf("  a line something drives ignores the bias; a floating line follows it\n\n");

	printf("== survey: is anything driving any of these? ==\n");
	printf("line  %-28s pu pd  verdict\n", "signal");
	for (unsigned i = 0; i < sizeof survey / sizeof survey[0]; i++) {
		int u = read1(survey[i].n, GPIO_V2_LINE_FLAG_BIAS_PULL_UP);
		int d = read1(survey[i].n, GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN);

		if (u < 0 || d < 0) {
			printf("%-5u %-28s -- --  BUSY (claimed by a driver)\n",
			       survey[i].n, survey[i].what);
			continue;
		}
		printf("%-5u %-28s %d  %d   %s\n", survey[i].n, survey[i].what, u, d,
		       (u == d) ? (u ? "DRIVEN HIGH" : "DRIVEN LOW")
				: "floating (nothing driving)");
	}

	printf("\n== sweep: does the card react to reset/wake? ==\n");
	sweep_row("as-found");

	fd = drive(0, 0);                        /* reset asserted */
	if (fd >= 0) { usleep(150000); sweep_row("RESET=0 WAKE=0"); close(fd); }

	fd = drive(1, 0);                        /* reset released */
	if (fd >= 0) { usleep(150000); sweep_row("RESET=1 WAKE=0"); close(fd); }

	fd = drive(1, 1);                        /* released + awake */
	if (fd >= 0) { usleep(300000); sweep_row("RESET=1 WAKE=1"); close(fd); }

	fd = drive(0, 1);                        /* a real reset pulse */
	if (fd >= 0) { usleep(100000); close(fd); }
	fd = drive(1, 1);
	if (fd >= 0) { usleep(500000); sweep_row("after reset pulse"); close(fd); }

	printf("\nIf every card output floats in every state, the MM6108 is driving nothing:\n"
	       "that is power, seating or carrier routing — not driver or device tree.\n");

	close(chipfd);
	return 0;
}
