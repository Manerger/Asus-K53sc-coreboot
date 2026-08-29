/* SPDX-License-Identifier: GPL-2.0-only */

#include <acpi/acpi.h>
#include <bootstate.h>
#include <console/console.h>
#include <device/device.h>
#include <device/pci_def.h>
#include <device/pci_ops.h>
#include <option.h>
#include <drivers/intel/gma/int15.h>
#include <pc80/keyboard.h>

#include "ec.h"

/* NVIDIA's write-once subsystem ID override; back-fills the read-only 0x2c. */
#define K53SC_NV_SUBSYSTEM_ID_OVERRIDE	0x40
/* ASUS 0x1043, board 0x1762 -- the value nvami.inf expects for this machine. */
#define K53SC_DGPU_SUBSYSTEM_ID		0x17621043


static void mainboard_init(struct device *dev)
{
	/*
	 * The IT8572E is already running ASUS EC firmware.
	 * Do not replay the vendor EC register dump: those registers may
	 * control power, charging, thermal policy, fan control and devices.
	 */
	pc_keyboard_init(NO_AUX_DEVICE);

	/*
	 * The EC will not act on the PCH's sleep signals until these are set,
	 * so without this the machine cannot power off or suspend at all.
	 */
	k53sc_ec_arm_power_sequencer();

	/*
	 * The EC leaves ACPI mode across a suspend and the OS does not
	 * repeat the ACPI_ENABLE handshake, so nothing puts it back and
	 * the hotkeys stay dead until a reboot.
	 */
	if (acpi_is_wakeup_s3())
		k53sc_ec_enter_acpi_mode();
}

/*
 * Allow the discrete GeForce GT 520MX to be switched off from firmware.
 *
 * Clearing the PEG10 device here is enough: sandybridge's disable_peg(), which
 * runs later from northbridge_init(), sees the inactive bridge and clears
 * DEVEN_PEG10. The port then disappears from PCI entirely rather than merely
 * being hidden from the OS, so the GPU draws no power.
 *
 * Toggle it from a booted system with:
 *   nvramtool -w dgpu=Disable    (or Enable), then reboot
 */
static void k53sc_configure_dgpu(void)
{
	struct device *peg;

	if (get_uint_option("dgpu", 1))
		return;

	peg = pcidev_on_root(1, 0);
	if (!peg) {
		printk(BIOS_WARNING, "K53SC: PEG10 not found, cannot disable dGPU\n");
		return;
	}

	peg->enabled = 0;
	printk(BIOS_INFO, "K53SC: discrete GPU disabled via CMOS option\n");
}

/*
 * Give the discrete GeForce GT 520MX its PCI subsystem ID.
 *
 * The GPU has no ROM of its own, so nothing sources a subsystem ID for it and
 * config space 0x2c reads 0x00000000. Windows matches display drivers on that
 * ID, and every INF entry for DEV_1051 -- including the ASUS one in nvami.inf,
 * SUBSYS_17621043 -- requires a specific value, so the card matches nothing and
 * the NVIDIA driver fails with Code 43 (CM_PROB_FAILED_POST_START).
 *
 * 0x2c itself is read-only: writes are dropped, both through config space and
 * through the PCI config mirror NVIDIA parts expose at BAR0 + 0x88000. NVIDIA
 * instead provides a write-once override at config offset 0x40 which back-fills
 * 0x2c, and that is how OEMs brand these parts. The factory firmware used it --
 * a DXE driver in the stock image reads offset 0 for 0x105110de and, on a match,
 * writes 0x17621043 to offset 0x40 through EFI_PCI_IO_PROTOCOL.Pci.Write.
 *
 * Verified on the board: 0x2c and 0x40 both read zero, then after writing
 * 0x17621043 to 0x40 both read 0x17621043.
 *
 * The option ROM cannot do this for us. Its init entry deliberately declines to
 * run on an Optimus system: it tests bit 7 of byte 0x48 in the image, then zeroes
 * its own size field and returns without touching the hardware.
 *
 * nouveau does not care either way -- it never looks at the subsystem ID.
 */
static void k53sc_set_dgpu_subsystem_id(void *unused)
{
	struct device *peg, *gpu;

	peg = pcidev_on_root(1, 0);
	if (!peg || !peg->enabled || !peg->downstream)
		return;

	gpu = (struct device *)pcidev_path_behind(peg->downstream, PCI_DEVFN(0, 0));
	if (!gpu || !gpu->enabled)
		return;

	if (pci_read_config32(gpu, PCI_SUBSYSTEM_VENDOR_ID))
		return;

	pci_write_config32(gpu, K53SC_NV_SUBSYSTEM_ID_OVERRIDE,
			   K53SC_DGPU_SUBSYSTEM_ID);

	printk(BIOS_INFO, "K53SC: discrete GPU subsystem ID set to %08x\n",
	       pci_read_config32(gpu, PCI_SUBSYSTEM_VENDOR_ID));
}

BOOT_STATE_INIT_ENTRY(BS_DEV_INIT, BS_ON_EXIT, k53sc_set_dgpu_subsystem_id, NULL);

static void mainboard_enable(struct device *dev)
{
	dev->ops->init = mainboard_init;

	k53sc_configure_dgpu();

	install_intel_vga_int15_handler(
		GMA_INT15_ACTIVE_LFP_INT_LVDS,
		GMA_INT15_PANEL_FIT_DEFAULT,
		GMA_INT15_BOOT_DISPLAY_DEFAULT,
		0);
}

struct chip_operations mainboard_ops = {
	.enable_dev = mainboard_enable,
};
