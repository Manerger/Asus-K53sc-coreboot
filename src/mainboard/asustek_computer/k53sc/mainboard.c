/* SPDX-License-Identifier: GPL-2.0-only */

#include <acpi/acpi.h>
#include <device/device.h>
#include <drivers/intel/gma/int15.h>
#include <pc80/keyboard.h>

#include "ec.h"


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

static void mainboard_enable(struct device *dev)
{
	dev->ops->init = mainboard_init;

	install_intel_vga_int15_handler(
		GMA_INT15_ACTIVE_LFP_INT_LVDS,
		GMA_INT15_PANEL_FIT_DEFAULT,
		GMA_INT15_BOOT_DISPLAY_DEFAULT,
		0);
}

struct chip_operations mainboard_ops = {
	.enable_dev = mainboard_enable,
};
