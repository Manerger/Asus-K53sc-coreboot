/* SPDX-License-Identifier: GPL-2.0-only */

#ifndef MAINBOARD_ASUSTEK_COMPUTER_K53SC_EC_H
#define MAINBOARD_ASUSTEK_COMPUTER_K53SC_EC_H

#include <stdint.h>

/*
 * Access to the IT8572E's configuration index/data pair on LPC.
 *
 * This is not the ACPI EC interface at 0x62/0x66 that the OS driver owns; it
 * is the pair the stock firmware uses from PEI and SMM, at 0x257/0x258, and
 * it stays usable while the OS is running. Every command and operand issued
 * here is transcribed from a stock module rather than invented.
 *
 * The generic decode range that routes 0x250-0x25f to LPC is programmed in
 * bootblock_mainboard_early_init(), so these are usable from bootblock
 * onwards.
 */

/* Tell the EC the host has entered or left ACPI mode.
 *
 * Until it is told, the EC delivers no ACPI events at all: hotkeys produce
 * only plain AT scancodes and the GPE never fires. Stock issues this from its
 * ACPI_ENABLE/ACPI_DISABLE software SMI handler, by way of the ECProtocol SMM
 * interface (GUID ac44520d-0169-4966-b743-4f6ceaf2598e) entries +0x40/+0x48.
 *
 * Must be issued from firmware, not userspace: the kernel's ACPI EC driver
 * owns the same controller and racing with it desynchronises the EC.
 */
void k53sc_ec_enter_acpi_mode(void);
void k53sc_ec_exit_acpi_mode(void);

/* Hand the CPU's thermal control temperature to the EC, as stock's ITEPEI
 * module does on every boot. Note this does not by itself change the EC's
 * thermal trip points; see the board notes.
 */
void k53sc_ec_program_tjmax(uint8_t tjmax);

/* Put the EC's power sequencer into the state stock leaves it in, so that it
 * acts on SLP_S3#/SLP_S5# and actually drops the rails. Without this an OS
 * poweroff or suspend halts the machine with the rails still up. See ec.c for
 * the byte semantics and how they were established.
 */
void k53sc_ec_arm_power_sequencer(void);

#endif /* MAINBOARD_ASUSTEK_COMPUTER_K53SC_EC_H */
