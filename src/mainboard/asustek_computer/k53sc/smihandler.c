/* SPDX-License-Identifier: GPL-2.0-only */

#include <console/console.h>
#include <cpu/x86/smm.h>

#include "ec.h"

/*
 * K53SC GPI1 SMI experiment.
 *
 * The stock ASUS firmware enables an alternate-GPI SMI on GPI1
 * (ALT_GP_SMI_EN = 0x0002) and services it from SMM. coreboot configures the
 * same pin identically (GPIO_MODE_GPIO / GPIO_DIR_INPUT / GPIO_INVERT in
 * gpio.c) but never enables the SMI and supplies no handler, so the common
 * handler falls through to the weak default.
 *
 * GPI1 is the only remaining event-routing difference between stock and
 * coreboot on this board: GPI3 is SATA hot-plug (stock _L13) and GPE 6 is the
 * Intel graphics SCI (stock _L06), both ordinary features.
 *
 * This handler deliberately only reports. It issues no EC command and writes
 * no EC register, so a behavioral change can be attributed to enabling the SMI
 * alone rather than to any speculative EC access. The common handler has
 * already cleared ALT_GP_SMI_STS before calling us.
 */

#define K53SC_GPI_EC	1

void mainboard_smi_gpi(u32 gpi_sts)
{
	if (gpi_sts & (1 << K53SC_GPI_EC))
		printk(BIOS_DEBUG, "K53SC SMI: GPI1 asserted\n");

	if (gpi_sts & ~(1 << K53SC_GPI_EC))
		printk(BIOS_DEBUG, "K53SC SMI: unexpected GPI status 0x%08x\n",
		       gpi_sts);
}

/*
 * Put the EC into ACPI mode when the OS enables ACPI, as stock does.
 *
 * coreboot's southbridge_smi_apmc() handles ACPI_ENABLE/ACPI_DISABLE by
 * setting and clearing SCI_EN and never touches the EC. See ec.c for the
 * sequences and where they come from.
 */
int mainboard_smi_apmc(u8 data)
{
	switch (data) {
	case APM_CNT_ACPI_ENABLE:
		printk(BIOS_DEBUG, "K53SC SMI: EC to ACPI mode\n");
		k53sc_ec_enter_acpi_mode();
		break;
	case APM_CNT_ACPI_DISABLE:
		printk(BIOS_DEBUG, "K53SC SMI: EC out of ACPI mode\n");
		k53sc_ec_exit_acpi_mode();
		break;
	}

	return 0;
}
