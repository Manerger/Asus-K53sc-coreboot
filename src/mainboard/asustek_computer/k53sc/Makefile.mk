## SPDX-License-Identifier: GPL-2.0-only

bootblock-y += early_init.c
bootblock-y += ec.c
bootblock-y += gpio.c
romstage-y += early_init.c
romstage-y += ec.c
romstage-y += gpio.c
ramstage-y += ec.c
ramstage-$(CONFIG_MAINBOARD_USE_LIBGFXINIT) += gma-mainboard.ads
smm-y += ec.c
smm-y += smihandler.c
