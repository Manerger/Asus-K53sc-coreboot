/* SPDX-License-Identifier: GPL-2.0-only */

#include <arch/io.h>
#include <stdint.h>

#include "ec.h"

#define K53SC_EC_STATUS		0x258	/* ECIC in the stock DSDT */
#define K53SC_EC_DATA		0x257	/* ECID in the stock DSDT */

#define K53SC_EC_OBF		(1 << 0)
#define K53SC_EC_IBF		(1 << 1)

/* Stock polls the status port using an I/O read to 0xed as the delay. */
#define K53SC_IO_DELAY_PORT	0xed

/* Bound every poll, so an unresponsive EC cannot stall SMM indefinitely.
 * Stock uses the same limit.
 */
#define K53SC_EC_TIMEOUT	0x10000

#define K53SC_EC_UNLOCK		0xff
#define K53SC_EC_CMD_ACPI	0xca
#define K53SC_EC_CMD_WRITE	0x95
#define K53SC_EC_CMD_RAM_WRITE	0x81

#define K53SC_EC_ACPI_ENTER	0x16
#define K53SC_EC_ACPI_EXIT	0x17

#define K53SC_EC_IDX_TJMAX	0x1a

/*
 * EC RAM bytes that gate the EC's own power sequencing.
 *
 * The IT8572E is this board's power sequencer: it receives SLP_S3#/SLP_S5#
 * from the PCH (PM_SUSB# on pin 107, PM_SUSC# on pin 21) and owns the VR
 * enables (CPU_VRON on pin 76, VSUS_ON_R on pin 86). Nothing else can drop
 * the rails.
 *
 * Under coreboot the EC leaves these two bytes in a state where it ignores
 * the sleep signals entirely, so an OS poweroff asserts SLP_S3#/S4#/S5#
 * correctly and the rails simply stay up: the machine halts with the fan at
 * full and never powers down. Stock leaves them as below and powers off.
 *
 * Verified on a logic analyser: with these values written, PM_PWROK follows
 * the sleep assertion after ~13 ms (12.9 ms entering S5, 12.0 ms entering
 * S3); without them it never drops at all, in captures 25 s long.
 *
 * Semantics, from the stock EC firmware in the BIOS flash at 0x200000:
 *   0x4f0 bit0  disables the EC host watchdog        (test at 0x6d30)
 *         bit1  opens the shutdown gate              (test at 0x7f84)
 *         bit2  when set, aborts the power-button handler (test at 0x67b6)
 *   0x4f3 bit1  master shutdown gate                 (tests at 0x7f8b, 0x6d45)
 *
 * Note 0x03 is self-consistent: it opens the shutdown path and disables the
 * watchdog together, so arming the gate does not expose the EC's watchdog
 * shutdown (reason code 0xa3).
 */
#define K53SC_EC_RAM_MODE	0x4f0
#define K53SC_EC_RAM_GATE	0x4f3

#define K53SC_EC_MODE_STOCK	0x03
#define K53SC_EC_GATE_STOCK	0x02

/* Discard any stale output the EC left behind. */
static void k53sc_ec_drain(void)
{
	unsigned int i;

	for (i = 0; i < K53SC_EC_TIMEOUT; i++) {
		if (!(inb(K53SC_EC_STATUS) & K53SC_EC_OBF))
			return;
		(void)inb(K53SC_EC_DATA);
		outb(0, K53SC_IO_DELAY_PORT);
	}
}

static void k53sc_ec_wait_ibf(void)
{
	unsigned int i;

	for (i = 0; i < K53SC_EC_TIMEOUT; i++) {
		if (!(inb(K53SC_EC_STATUS) & K53SC_EC_IBF))
			return;
		outb(0, K53SC_IO_DELAY_PORT);
	}
}

static void k53sc_ec_put(uint16_t port, uint8_t val)
{
	k53sc_ec_wait_ibf();
	outb(val, port);
}

/*
 * Tell the EC the host has entered or left ACPI mode.
 *
 * Stock's AcpiModeEnable module registers software SMI handlers for the FADT
 * ACPI_ENABLE/ACPI_DISABLE values and, after the usual PM register work, walks
 * a list of registered callbacks. ECSMI registers into that list, and its
 * callbacks call the ECProtocol SMM interface (GUID
 * ac44520d-0169-4966-b743-4f6ceaf2598e, installed at 0x140001ef0 with size
 * 0x130) at entries +0x40 and +0x48. Those two entries are these sequences:
 *
 *   +0x40  drain; 0xff -> 0x258; 0xca -> 0x258; 0x16 -> 0x257
 *   +0x48  drain; 0xff -> 0x258; 0xca -> 0x258; 0x17 -> 0x257
 *
 * coreboot's southbridge_smi_apmc() handles the same two APMC values by
 * setting and clearing SCI_EN and never touches the EC, so without this the
 * EC is never told the host has entered ACPI mode: Fn hotkeys produce only
 * plain AT scancodes, nothing reaches the ACPI/WMI path and the GPE 0x1B
 * counter does not move on a key press.
 */
static void k53sc_ec_acpi_mode(uint8_t mode)
{
	k53sc_ec_drain();
	k53sc_ec_put(K53SC_EC_STATUS, K53SC_EC_UNLOCK);
	k53sc_ec_put(K53SC_EC_STATUS, K53SC_EC_CMD_ACPI);
	k53sc_ec_put(K53SC_EC_DATA, mode);
	k53sc_ec_wait_ibf();
}

void k53sc_ec_enter_acpi_mode(void)
{
	k53sc_ec_acpi_mode(K53SC_EC_ACPI_ENTER);
}

void k53sc_ec_exit_acpi_mode(void)
{
	k53sc_ec_acpi_mode(K53SC_EC_ACPI_EXIT);
}

void k53sc_ec_program_tjmax(uint8_t tjmax)
{
	if (!tjmax)
		return;

	k53sc_ec_put(K53SC_EC_STATUS, K53SC_EC_UNLOCK);
	k53sc_ec_put(K53SC_EC_STATUS, K53SC_EC_CMD_WRITE);
	k53sc_ec_put(K53SC_EC_DATA, K53SC_EC_IDX_TJMAX);
	k53sc_ec_put(K53SC_EC_DATA, tjmax);
	k53sc_ec_wait_ibf();
}

/*
 * Write one byte of EC RAM using the 0x81 primitive.
 *
 * This is the write counterpart of the 0x80 read that ECProtocol.efi uses,
 * and takes a 16-bit address:
 *
 *   drain; 0xff -> 0x258; 0x81 -> 0x258; addr_hi -> 0x257; addr_lo -> 0x257;
 *   val -> 0x257
 */
static void k53sc_ec_ram_write(uint16_t addr, uint8_t val)
{
	k53sc_ec_drain();
	k53sc_ec_put(K53SC_EC_STATUS, K53SC_EC_UNLOCK);
	k53sc_ec_put(K53SC_EC_STATUS, K53SC_EC_CMD_RAM_WRITE);
	k53sc_ec_put(K53SC_EC_DATA, addr >> 8);
	k53sc_ec_put(K53SC_EC_DATA, addr & 0xff);
	k53sc_ec_put(K53SC_EC_DATA, val);
	k53sc_ec_wait_ibf();
}

void k53sc_ec_arm_power_sequencer(void)
{
	k53sc_ec_ram_write(K53SC_EC_RAM_MODE, K53SC_EC_MODE_STOCK);
	k53sc_ec_ram_write(K53SC_EC_RAM_GATE, K53SC_EC_GATE_STOCK);
}
