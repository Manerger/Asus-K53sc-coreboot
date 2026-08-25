/* SPDX-License-Identifier: GPL-2.0-only */

/*
 * ASUS ATK WMI device.
 *
 * The stock firmware declares this as an ACPI-WMI device in the \_SB scope;
 * Linux binds asus_wmi / asus_nb_wmi to it, and those drivers are what manage
 * hotkeys, LEDs, backlight and parts of the thermal policy. Without it no ASUS
 * driver loads at all and the EC is left unmanaged by the OS.
 *
 * This is a deliberately minimal first stage: the device, both WMI blocks and
 * the WMNB dispatch entry points that asus_wmi calls while probing. Device
 * queries report "unsupported" rather than claiming hardware support that is
 * not backed here. Real device support can be added incrementally once the
 * driver is confirmed to bind.
 *
 * WMI blocks, transcribed from the stock _WDG:
 *   97845ed0-4e6d-11de-8a39-0800200c9a66  method block, object id "BN" -> WMNB
 *   0b3cbb35-e3c2-45ed-91c2-4c5a6d195d1c  event block, notify id 0xff
 */

Device (ATKD)
{
	Name (_HID, "PNP0C14")
	Name (_UID, "ATK")

	Name (_WDG, Buffer (0x28)
	{
		/* 97845ed0-4e6d-11de-8a39-0800200c9a66, "BN", 1 inst, method */
		0xD0, 0x5E, 0x84, 0x97, 0x6D, 0x4E, 0xDE, 0x11,
		0x8A, 0x39, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
		0x4E, 0x42, 0x01, 0x02,

		/* 0b3cbb35-e3c2-45ed-91c2-4c5a6d195d1c, notify 0xff, event */
		0x35, 0xBB, 0x3C, 0x0B, 0xC2, 0xE3, 0xED, 0x45,
		0x91, 0xC2, 0x4C, 0x5A, 0x6D, 0x19, 0x5D, 0x1C,
		0xFF, 0x00, 0x01, 0x08
	})

	/* Set once INIT has been seen, mirroring the stock flag. */
	Name (ATKP, Zero)

	/* Model name returned by INIT. */
	Name (MNAM, "K53SC")

	/*
	 * Pending hotkey codes.
	 *
	 * The WMI layer only dispatches a Notify whose value matches an event
	 * ID declared in _WDG, which is 0xFF here. The key code therefore
	 * cannot be passed as the Notify value; stock queues it and notifies
	 * 0xFF, and the driver then calls _WED(0xFF) to collect it. This is a
	 * clean reimplementation of stock's 16-entry ring rather than a literal
	 * copy, because stock's indices rely on an initial value that is not
	 * visible in the disassembly.
	 */
	Name (ATKQ, Package (0x10)
	{
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	})
	Name (AQHI, 0)	/* read index */
	Name (AQTI, 0)	/* write index */
	Name (AQNO, 0)	/* queued entries */

	Method (IANQ, 1, Serialized)
	{
		If ((AQNO >= 0x10))
		{
			Return (Zero)
		}

		ATKQ [AQTI] = Arg0
		AQTI = ((AQTI + One) & 0x0F)
		AQNO++
		Return (One)
	}

	Method (GANQ, 0, Serialized)
	{
		If (AQNO)
		{
			Local0 = DerefOf (ATKQ [AQHI])
			AQHI = ((AQHI + One) & 0x0F)
			AQNO--
			Return (Local0)
		}

		Return (Ones)
	}

	Method (_WED, 1, NotSerialized)
	{
		If ((Arg0 == 0xFF))
		{
			Return (GANQ ())
		}

		Return (Ones)
	}

	Method (WMNB, 3, Serialized)
	{
		CreateDWordField (Arg2, 0x00, IIA0)

		Local0 = (Arg1 & 0xFFFFFFFF)

		Switch (ToInteger (Local0))
		{
			/* "INIT" - hand back an identifier and latch the flag. */
			Case (0x54494E49)
			{
				ATKP = One
				Return (MNAM)
			}

			/* "BSTS" - boot status flags. Nothing to report. */
			Case (0x53545342)
			{
				Return (Zero)
			}

			/*
			 * "SFUN" - supported function mask. This is the value
			 * the stock firmware reports for this model. asus_wmi
			 * uses it to decide which hotkey handling to enable, and
			 * reporting zero left it treating the machine as having
			 * no special functions at all.
			 */
			Case (0x4E554653)
			{
				Return (0x001A0AF7)
			}

			/*
			 * "DSTS" - device status. Bit 16 set means "device
			 * present/supported"; returning zero reports every
			 * queried device as unsupported.
			 */
			Case (0x53545344)
			{
				Return (Zero)
			}

			/* "DEVS" - set device state. Nothing is settable yet. */
			Case (0x53564544)
			{
				Return (Zero)
			}
		}

		/* Unknown or unimplemented command. */
		Return (Zero)
	}

	/*
	 * Deliver a hotkey event to the ASUS driver.
	 *
	 * Stock gates every hotkey on ATKP so that nothing is delivered
	 * before the driver has run INIT. Keep that gate: a Notify to a
	 * device with no driver bound is harmless but pointless, and
	 * matching stock keeps the behaviour comparable.
	 */
	Method (ATKN, 1, NotSerialized)
	{
		If (ATKP)
		{
			IANQ (Arg0)
			Notify (\_SB.ATKD, 0xFF)
		}
	}
}
