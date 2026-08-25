/* SPDX-License-Identifier: GPL-2.0-only */

Device (EC0)
{
	Name (_HID, EISAID ("PNP0C09"))
	Name (_UID, 0)
	Name (_GPE, 0x1B)

	Name (_CRS, ResourceTemplate ()
	{
		IO (Decode16,
			0x0062,
			0x0062,
			0x00,
			0x01
		)

		IO (Decode16,
			0x0066,
			0x0066,
			0x00,
			0x01
		)
	})

	Name (REGC, Zero)

	Method (_REG, 2, NotSerialized)
	{
		If (Arg0 == 0x03)
		{
			REGC = Arg1
		}
	}

	Method (ECAV, 0, NotSerialized)
	{
		Return (REGC)
	}

	/*
	 * Deliberately no ERAM register fields or _Qxx methods yet.
	 * Those will be reconstructed from observed ASUS behavior.
	 */
	OperationRegion (ERAM, EmbeddedControl, 0x00, 0xFF)

	/*
	 * ASUS indexed battery/thermal window.
	 *
	 * The stock firmware declares the same index/data pair at 0x25a/0x25b.
	 * LPC generic decode range 3 (devicetree "gen3_dec" = 0x002c0251, base
	 * 0x250 / mask 0x2c) routes 0x250-0x25f to LPC, so this is reachable.
	 *
	 * This is SystemIO rather than EmbeddedControl, so it does not depend
	 * on the OS embedded-controller driver being loaded.
	 *
	 * Field offsets and semantics were confirmed on hardware by sampling
	 * across an AC unplug/replug cycle.
	 */
	OperationRegion (BRAM, SystemIO, 0x025A, 0x02)
	Field (BRAM, ByteAcc, Lock, Preserve)
	{
		BRAI,	8,
		BRAD,	8
	}

	IndexField (BRAI, BRAD, ByteAcc, NoLock, Preserve)
	{
		Offset (0x90),
		EPWS,	8,	/* bit0: AC present, bit1: battery present */
		EB0S,	8,	/* bit0: discharging, bit1: charging, bit4: present */
		Offset (0x98),
		ECPU,	8,	/* CPU temperature, degrees C */
		ECRT,	8,	/* critical trip point, degrees C */
		Offset (0xA0),
		B0VL,	16,	/* present voltage, mV */
		B0RC,	16,	/* remaining capacity, mAh */
		B0FC,	16,	/* last full charge capacity, mAh */
		B0MD,	16,
		B0ST,	16,
		B0CC,	16,	/* present rate, signed mA (negative = discharging) */
		B0DC,	16,	/* design capacity, mAh */
		B0DV,	16	/* design voltage, mV */
	}

	Device (BAT0)
	{
		Name (_HID, EisaId ("PNP0C0A"))
		Name (_UID, 0)
		Name (_PCL, Package () { \_SB })

		/*
		 * Presence is reported if either the EC's battery-present bit
		 * or a sane last-full-charge capacity says so.
		 *
		 * EPWS bit 1 is derived from the pack detect pin and is valid
		 * as soon as the EC runs. B0FC needs a slow SMBus transaction
		 * to the pack's gas gauge, so after the pack has been out it
		 * still reads 0 when _STA is first evaluated. The EC SCI never
		 * fires on this board, so nothing ever notifies the OS to look
		 * again and the battery stays invisible for the whole boot.
		 *
		 * The capacity check is kept as a fallback so that a status bit
		 * whose battery-absent meaning is unconfirmed can only ever add
		 * presence, never wrongly remove it.
		 */
		Method (_STA, 0, NotSerialized)
		{
			Local0 = \_SB.PCI0.LPCB.EC0.EPWS
			If (((Local0 & 0x02) == 0x02))
			{
				Return (0x1F)
			}

			Local1 = \_SB.PCI0.LPCB.EC0.B0FC
			If (((Local1 == 0x00) || (Local1 == 0xFFFF)))
			{
				Return (0x0F)
			}

			Return (0x1F)
		}

		Method (_BIF, 0, Serialized)
		{
			Name (BPKG, Package (0x0D)
			{
				0x01,		/* power unit: mAh / mA */
				0xFFFFFFFF,	/* design capacity */
				0xFFFFFFFF,	/* last full charge capacity */
				0x01,		/* battery technology: rechargeable */
				0xFFFFFFFF,	/* design voltage */
				0x00,		/* design capacity of warning */
				0x00,		/* design capacity of low */
				0x01,		/* capacity granularity 1 */
				0x01,		/* capacity granularity 2 */
				"K53SC",	/* model number */
				"",		/* serial number */
				"LION",		/* battery type */
				"ASUS"		/* OEM information */
			})

			Local0 = \_SB.PCI0.LPCB.EC0.B0DC
			If ((Local0 != 0xFFFF))
			{
				BPKG [0x01] = Local0
			}

			Local1 = \_SB.PCI0.LPCB.EC0.B0FC
			If ((Local1 != 0xFFFF))
			{
				BPKG [0x02] = Local1
				BPKG [0x05] = (Local1 / 0x0A)
				BPKG [0x06] = (Local1 / 0x14)
			}

			Local2 = \_SB.PCI0.LPCB.EC0.B0DV
			If ((Local2 != 0xFFFF))
			{
				BPKG [0x04] = Local2
			}

			Return (BPKG)
		}

		Method (_BST, 0, Serialized)
		{
			Name (BPKG, Package (0x04)
			{
				0x00,		/* battery state */
				0xFFFFFFFF,	/* present rate */
				0xFFFFFFFF,	/* remaining capacity */
				0xFFFFFFFF	/* present voltage */
			})

			/*
			 * EB0S bit0 (discharging) and bit1 (charging) already
			 * match the ACPI _BST state bits of the same number.
			 */
			BPKG [0x00] = (\_SB.PCI0.LPCB.EC0.EB0S & 0x03)

			/* B0CC is signed; ACPI wants an unsigned magnitude. */
			Local0 = \_SB.PCI0.LPCB.EC0.B0CC
			If ((Local0 != 0xFFFF))
			{
				If ((Local0 & 0x8000))
				{
					Local0 = (0x00010000 - Local0)
				}

				BPKG [0x01] = Local0
			}

			Local1 = \_SB.PCI0.LPCB.EC0.B0RC
			If ((Local1 != 0xFFFF))
			{
				BPKG [0x02] = Local1
			}

			Local2 = \_SB.PCI0.LPCB.EC0.B0VL
			If ((Local2 != 0xFFFF))
			{
				BPKG [0x03] = Local2
			}

			Return (BPKG)
		}
	}

	Device (ADP0)
	{
		Name (_HID, "ACPI0003")
		Name (_UID, 0)
		Name (_PCL, Package () { \_SB })

		Method (_STA, 0, NotSerialized)
		{
			Return (0x0F)
		}

		Method (_PSR, 0, NotSerialized)
		{
			Return (\_SB.PCI0.LPCB.EC0.EPWS & 0x01)
		}
	}

	/*
	 * EC query handlers.
	 *
	 * Transcribed from the stock DSDT, where each hotkey query does
	 * If (ATKP) { ATKN (code) }. The notify codes are what asus_wmi's
	 * sparse keymap expects, so the OS driver turns them into keycodes.
	 *
	 * Only the queries whose stock body is a plain hotkey notify are
	 * reproduced. Stock's _Q0E/_Q0F/_Q10/_Q11/_Q84/_QA8 and the lid,
	 * sleep-button and thermal-zone queries reference objects this
	 * DSDT does not declare, so they are deliberately left out rather
	 * than guessed at.
	 *
	 * Note the EC is not currently observed to raise any of these:
	 * pressing Fn+F keys yields plain AT scancodes and does not
	 * increment the GPE 0x1B counter. Handling them costs nothing and
	 * an unraised query is simply never called.
	 */
	Method (_Q01, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x52)
	}

	Method (_Q02, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x53)
	}

	Method (_Q03, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x54)
	}

	Method (_Q04, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x55)
	}

	Method (_Q05, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x56)
	}

	Method (_Q0C, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x50)
	}

	Method (_Q0D, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x51)
	}

	Method (_Q12, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x6B)  /* touchpad toggle */
	}

	Method (_Q13, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x32)  /* mute */
	}

	Method (_Q14, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x31)  /* volume down */
	}

	Method (_Q15, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x30)  /* volume up */
	}

	Method (_Q6C, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x40)
	}

	Method (_Q6D, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x41)
	}

	Method (_Q6E, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x43)
	}

	Method (_Q6F, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x45)
	}

	Method (_Q71, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x5C)
	}

	Method (_Q72, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x8A)
	}

	Method (_Q73, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x82)
	}

	Method (_Q80, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x5C)
	}

	Method (_Q86, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x32)  /* mute */
	}

	Method (_Q87, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x31)  /* volume down */
	}

	Method (_Q88, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x30)  /* volume up */
	}

	Method (_Q89, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x45)
	}

	Method (_QA5, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x6E)
	}

	Method (_QB3, 0, NotSerialized)
	{
		\_SB.ATKD.ATKN (0x6D)
	}

	/* AC adapter connected or removed. */
	Method (_QA0, 0, NotSerialized)
	{
		Notify (\_SB.PCI0.LPCB.EC0.ADP0, 0x80)
		Notify (\_SB.PCI0.LPCB.EC0.BAT0, 0x80)
	}

	/* Battery state changed. */
	Method (_QA1, 0, NotSerialized)
	{
		Notify (\_SB.PCI0.LPCB.EC0.BAT0, 0x80)
	}

	/* Battery information changed (pack inserted or removed). */
	Method (_QA3, 0, NotSerialized)
	{
		Notify (\_SB.PCI0.LPCB.EC0.BAT0, 0x81)
	}
}
