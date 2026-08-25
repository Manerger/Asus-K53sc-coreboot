/* SPDX-License-Identifier: GPL-2.0-only */

#include <bootblock_common.h>
#include <cpu/intel/model_206ax/model_206ax.h>
#include <cpu/x86/msr.h>
#include <device/pci_ops.h>
#include <southbridge/intel/bd82x6x/pch.h>
#include <southbridge/intel/common/lpc_def.h>

#include "ec.h"

void bootblock_mainboard_early_init(void)
{
	msr_t msr;

	pci_write_config16(PCI_DEV(0, 0x1f, 0), 0x82, 0x1c0f);
	pci_write_config16(PCI_DEV(0, 0x1f, 0), 0x80, 0x0000);

	/*
	 * Generic decode range 3 routes 0x250-0x25f to LPC. Ramstage programs
	 * this from the devicetree, but the EC configuration pair at
	 * 0x257/0x258 has to be reachable this early, so set it here too. The
	 * value matches devicetree "gen3_dec".
	 */
	pci_write_config32(PCI_DEV(0, 0x1f, 0), LPC_GEN3_DEC, 0x002c0251);

	/*
	 * Stock's ITEPEI module hands the CPU's thermal control
	 * temperature to the EC on every boot, before anything else
	 * touches it.
	 */
	msr = rdmsr(MSR_TEMPERATURE_TARGET);
	k53sc_ec_program_tjmax((msr.lo >> 16) & 0xff);
}
