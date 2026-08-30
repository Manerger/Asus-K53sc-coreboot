/* SPDX-License-Identifier: GPL-2.0-only */

/*
 * NVIDIA Optimus ACPI interface for the discrete GeForce GT 520MX (10de:1051).
 *
 * The NVIDIA Windows driver refuses to start the GPU (Code 43,
 * CM_PROB_FAILED_POST_START) unless the platform exposes the Optimus _DSM.
 * nouveau does not need it -- it parses the VBIOS and runs devinit itself --
 * which is why the card worked under Linux with only the _ROM method that
 * coreboot's pci_rom_ssdt() generates.
 *
 * Reverse-engineered from the factory AMI DSDT (OEM "_ASUS_", table
 * "NoteBook").  The stock firmware placed these methods in
 * \_SB.PCI0.PEGR.GFX0; coreboot names the same two devices PEGP and DEV0
 * (northbridge/intel/sandybridge/acpi/peg.asl), so the scope differs while
 * the semantics below are kept identical to the factory implementation.
 *
 * GPIO naming differs too.  The factory firmware declared its own region over
 * GPIOBASE (which it programmed to 0x500) and named the pins PI17/PO50/PO54;
 * coreboot programs GPIOBASE to 0x480 and southbridge/intel/bd82x6x/acpi/pch.asl
 * already exposes every level bit globally as \GPnn, so those are used directly:
 *
 *	\GP17	dGPU power good		(input,  stock PI17)
 *	\GP50	dGPU power enable	(output, stock PO50)
 *	\GP54	dGPU reset/enable	(output, stock PO54)
 */

Scope (\)
{
	/* Optimus power state, as negotiated through _DSM function 0x1A. */
	Name (OMPR, 0x02)

	/*
	 * Hybrid-graphics mux state. The factory firmware keeps these on the
	 * integrated GPU (\_SB.PCI0.GFX0) as part of a larger hybrid state
	 * block that only its own ASL reads back; nothing outside the DSDT
	 * observes them, so local equivalents behave identically from the
	 * driver's point of view.
	 *
	 *   HLMX/HCMX/HDMX/HHMX  LCD/CRT/DVI/HDMI muxed to the discrete GPU
	 *   HLMM/HCMM/HDMU/HHMM  the corresponding "mux mode" flags
	 */
	Name (HLMX, Zero)
	Name (HCMX, Zero)
	Name (HDMX, Zero)
	Name (HHMX, Zero)
	Name (HLMM, Zero)
	Name (HCMM, Zero)
	Name (HDMU, Zero)
	Name (HHMM, Zero)
}

Scope (\_SB.PCI0.PEGP.DEV0)
{
	/*
	 * NVIDIA's subsystem ID override. Config space 0x2c is read-only on
	 * this part; writing the ID to 0x40 back-fills it. coreboot does this
	 * once at boot (mainboard.c), but the register is write-once *per
	 * reset*: any power cycle of the GPU clears it, and it has been
	 * observed going back to zero under Linux as soon as runtime power
	 * management put the card into D3cold. Windows power-cycles the GPU
	 * while the NVIDIA driver initialises, so the ID has to be restored
	 * every time the device is powered back up, or the driver finds a
	 * board it cannot identify.
	 */
	OperationRegion (NVCF, PCI_Config, 0x40, 0x04)
	Field (NVCF, DWordAcc, NoLock, Preserve)
	{
		SSIO,   32
	}

	/*
	 * Vendor/device ID, for the presence check. The factory firmware read
	 * this through a SystemMemory region hardcoded at MMCONF 0xE0100000;
	 * coreboot places MMCONF at 0xf0000000, so that address would be wrong
	 * here. A PCI_Config region resolves through the device instead and is
	 * independent of where MMCONF lives.
	 */
	OperationRegion (NVID, PCI_Config, 0x00, 0x04)
	Field (NVID, DWordAcc, NoLock, Preserve)
	{
		VID0,   32
	}

	Method (RSSI, 0, NotSerialized)
	{
		SSIO = 0x17621043
	}

	/*
	 * Bring the discrete GPU up.  This mirrors the factory _ON() exactly.
	 *
	 * coreboot already leaves the rails in this method's end state
	 * (GP17 = 1, GP50 = 1, GP54 = 0), so under the current configuration
	 * this is a no-op reassertion rather than a cold power-up.  It is kept
	 * faithful so that runtime power management has a correct sequence to
	 * call if it is ever wired up.
	 */
	Method (DGON, 0, Serialized)
	{
		/*
		 * If power-good is already asserted the GPU is up and running.
		 * Driving GP50/GP54 in that state would reset a live GPU -- and
		 * because _OFF here is a no-op, that is exactly the state _PS0
		 * finds it in. Do nothing but re-stamp the subsystem ID.
		 *
		 * The factory firmware has no such guard because its _OFF really
		 * does cut the rails, so its _ON only ever runs against a GPU
		 * that is genuinely powered down.
		 */
		If ((\GP17 == One)) {
			RSSI ()
			Return (Zero)
		}

		\GP50 = Zero
		Sleep (100)
		\GP54 = Zero
		Sleep (100)

		/*
		 * Wait for power-good, but bounded. The factory loop is
		 * unbounded; an ACPI method that never returns hangs the OS's
		 * power transition instead of just failing it. ~1 s is far more
		 * than the rail needs.
		 */
		Local0 = 100
		While ((Local0 > Zero)) {
			If ((\GP17 == One)) {
				Local0 = Zero
			} Else {
				Sleep (10)
				Local0--
			}
		}

		\GP50 = One
		Sleep (100)

		/* A cold power-up clears the override. */
		RSSI ()
		Return (Zero)
	}

	/*
	 * Display-switching block, ported from the factory firmware.
	 *
	 * The discrete GPU has no display outputs wired on this board -- the
	 * panel and HDMI both hang off the iGPU -- so these report a static,
	 * consistent state rather than driving anything. They exist because
	 * the factory firmware exposes them and the NVIDIA driver may probe
	 * for them. The backlight methods (_BCL/_BCM/_BQC) are deliberately
	 * NOT ported: they depend on vendor plumbing (\_SB.BRTI, PWBT, STBR,
	 * HWHG) and brightness on this board is owned by the EC and the iGPU.
	 */
	Name (NXTD, One)
	Name (LCDM, 0x01)
	Name (CRTM, 0x02)
	Name (TVOM, 0x04)
	Name (DVIM, 0x08)
	Name (HDMM, 0x10)
	Name (DONE, Zero)
	Name (DOSF, One)
	Name (BRNC, Zero)
	Name (DGPS, Zero)
	/* Which outputs the platform considers available. */
	Name (AVLD, 0x1F)

	Method (_INI, 0, NotSerialized)
	{
	}

	Method (_DOS, 1, NotSerialized)
	{
		DOSF = (Arg0 & 0x03)
		BRNC = (Arg0 >> 0x02)
		BRNC &= 0x01
	}

	Method (_DOD, 0, NotSerialized)
	{
		Return (Package (0x04)
		{
			0x0110,
			0x80000100,
			0x80007330,
			0x80006340
		})
	}

	Device (LCDD)
	{
		Name (_ADR, 0x0110)

		Method (_DCS, 0, NotSerialized)
		{
			If ((^^AVLD & ^^LCDM)) {
				Return (0x1F)
			}
			Return (0x1D)
		}

		Method (_DGS, 0, NotSerialized)
		{
			If ((^^NXTD & ^^LCDM)) {
				Return (One)
			}
			Return (Zero)
		}

		Method (_DSS, 1, NotSerialized)
		{
			^^DONE = One
		}
	}

	Device (CRTD)
	{
		Name (_ADR, 0x80000100)

		Method (_DCS, 0, NotSerialized)
		{
			If ((^^AVLD & ^^CRTM)) {
				Return (0x1F)
			}
			Return (0x1D)
		}

		Method (_DGS, 0, NotSerialized)
		{
			If ((^^NXTD & ^^CRTM)) {
				Return (One)
			}
			Return (Zero)
		}

		Method (_DSS, 1, NotSerialized)
		{
			If ((Arg0 & 0x40000000)) {
				If ((Arg0 & 0x80000000)) {
					^^DONE = One
				}
			}
		}
	}

	Device (HDMI)
	{
		Name (_ADR, 0x80007330)

		Method (_DCS, 0, NotSerialized)
		{
			If ((^^AVLD & ^^HDMM)) {
				Return (0x1F)
			}
			Return (0x1D)
		}

		Method (_DGS, 0, NotSerialized)
		{
			If ((^^NXTD & ^^HDMM)) {
				Return (One)
			}
			Return (Zero)
		}

		Method (_DSS, 1, NotSerialized)
		{
			If ((Arg0 & 0x40000000)) {
				If ((Arg0 & 0x80000000)) {
					^^DONE = One
				}
			}
		}
	}

	/* _STA: the discrete GPU is present, enabled and functioning. */
	Method (_STA, 0, Serialized)
	{
		Return (0x0F)
	}

	Method (DSTA, 0, Serialized)
	{
		Return (_STA ())
	}

	/*
	 * MXM display-switching methods. NVIDIA drivers probe for these on
	 * hybrid-graphics hardware; the factory firmware provides both.
	 *
	 * MXDS is ported verbatim, including its bug: the predicate is
	 * "Arg0 & 0x00", which is always zero, so the factory firmware always
	 * takes the else branch and never returns the mux state. The driver
	 * was written against that behaviour, so reproducing it is safer than
	 * "fixing" it to the presumably intended "Arg0 & 0x01".
	 */
	Method (MXDS, 1, NotSerialized)
	{
		If ((Arg0 & 0x00)) {
			Return (\HLMX)
		}

		\HLMX = One
		\HCMX = One
		Sleep (100)

		/*
		 * The factory method just falls off the end here, which iasl
		 * rejects under coreboot's warnings-as-errors. An ACPI method
		 * that completes without an explicit Return yields Zero, so
		 * returning it explicitly keeps runtime behaviour identical.
		 */
		Return (Zero)
	}

	Method (MXMX, 1, NotSerialized)
	{
		\HLMM = One
		\HCMM = One
		\HDMU = One
		\HHMM = One
		\HLMX = One
		\HCMX = One
		\HDMX = One
		\HHMX = One
		Return (One)
	}

	/*
	 * The factory firmware exposes _ON/_OFF on the device itself rather
	 * than through a PowerResource. _OFF is deliberately a no-op here:
	 * coreboot leaves the discrete GPU powered, and actually cutting its
	 * rails from ACPI has not been validated on this board.
	 */
	Method (_ON, 0, NotSerialized)
	{
		DGON ()
	}

	Method (_OFF, 0, NotSerialized)
	{
	}

	/*
	 * Power-state bookkeeping, matching the factory firmware's semantics.
	 *
	 * An earlier version of this file gated _PS0 on OMPR, which was wrong:
	 * OMPR is the *policy* the driver requests through _DSM function 0x1A,
	 * while DGPS is the flag _PS3 sets to record that the GPU was actually
	 * powered down. Stock powers back up on DGPS and only consults OMPR to
	 * decide whether a power-down is wanted at all.
	 */
	Name (_PSC, Zero)

	Method (_PS0, 0, NotSerialized)
	{
		_PSC = Zero

		If ((DGPS != Zero)) {
			DON ()
			DGPS = Zero
		}

		/* The GPU may have just come back from D3; re-stamp the ID. */
		RSSI ()
	}

	Method (DON, 0, NotSerialized)
	{
		DGON ()
	}

	Method (_PS3, 0, NotSerialized)
	{
		If ((\OMPR == 0x03)) {
			If ((DGPS == Zero)) {
				DOFF ()
				DGPS = One
			}
			\OMPR = 0x02
		}

		_PSC = 0x03
	}

	Method (DOFF, 0, NotSerialized)
	{
		_OFF ()
	}

	/* Presence check, as the factory firmware exposes it. */
	Method (PRST, 0, NotSerialized)
	{
		If ((VID0 == 0x105110DE)) {
			Return (One)
		}
		Return (Zero)
	}

	/*
	 * Optimus _DSM, UUID a486d8f8-0bda-471b-a72b-6042a6b5bee0.
	 *
	 * Only revision 0x0100 is defined; anything else must report
	 * "unsupported" (0x80000002).  Two functions are implemented, matching
	 * the factory firmware:
	 *
	 *   0x00  return the supported-function mask (0x04030001)
	 *   0x1A  Optimus caps/power control -- latch the requested power
	 *         policy into OMPR and report the current GPU power state
	 */
	Method (_DSM, 4, Serialized)
	{
		If (Arg0 == ToUUID ("a486d8f8-0bda-471b-a72b-6042a6b5bee0")) {
			If (Arg1 != 0x0100) {
				Return (Buffer (0x04) { 0x02, 0x00, 0x00, 0x80 })
			}

			/* Arg3 is a 4-byte little-endian parameter buffer. */
			Local0 = (DerefOf (Arg3 [0x03]) << 0x18)
			Local0 += (DerefOf (Arg3 [0x02]) << 0x10)
			Local0 += (DerefOf (Arg3 [0x01]) << 0x08)
			Local0 += DerefOf (Arg3 [0x00])

			If (Arg2 == 0x00) {
				Return (Buffer (0x04) { 0x01, 0x00, 0x03, 0x04 })
			}

			If (Arg2 == 0x1A) {
				If (Local0 & One) {
					Local2 = (Local0 >> 0x18)
					If (Local2 == 0x03) {
						OMPR = 0x03
					}
					If (Local2 == 0x02) {
						OMPR = 0x02
					}
				}

				If (\GP54 == Zero) {
					Return (Buffer (0x04) { 0x59, 0x00, 0x00, 0x01 })
				} Else {
					Return (Buffer (0x04) { 0x41, 0x00, 0x00, 0x01 })
				}
			}

			Return (Buffer (0x04) { 0x02, 0x00, 0x00, 0x80 })
		}

		Return (Zero)
	}
}

/*
 * NVIDIA Optimus WMI interface, ported from the factory firmware.
 *
 * The factory device forwarded "_DSM" requests to the *integrated* GPU's
 * _DSM (\_SB.PCI0.GFX0._DSM), which owned the Optimus GUID there. coreboot's
 * iGPU has no _DSM, and this port implements the Optimus _DSM directly on the
 * discrete GPU instead, so the forward goes to PEGP.DEV0.
 */
Scope (\_SB.PCI0)
{
	Device (WMI1)
	{
		Name (_HID, "PNP0C14")
		Name (_UID, "OPT1")
		Name (_WDG, Buffer (0x14)
		{
			0x3C, 0x5C, 0xCB, 0xF6, 0xAE, 0x9C, 0xBD, 0x4E,
			0xB5, 0x77, 0x93, 0x1E, 0xA3, 0x2A, 0x2C, 0xC0,
			0x4D, 0x58, 0x01, 0x02
		})

		Method (WMMX, 3, NotSerialized)
		{
			CreateDWordField (Arg2, Zero, FUNC)

			/* "_DSM" */
			If ((FUNC == 0x4D53445F)) {
				If ((SizeOf (Arg2) >= 0x1C)) {
					CreateField (Arg2, Zero, 0x80, MUID)
					CreateDWordField (Arg2, 0x10, REVI)
					CreateDWordField (Arg2, 0x14, SFNC)
					CreateField (Arg2, 0xE0, 0x20, XRG0)
					Return (\_SB.PCI0.PEGP.DEV0._DSM (MUID, REVI, SFNC, XRG0))
				}
			}

			/* "NOPG" -- power the discrete GPU up */
			If ((FUNC == 0x47504F4E)) {
				\_SB.PCI0.PEGP.DEV0.DGPS = One
				\_SB.PCI0.PEGP.DEV0._PS0 ()
			}

			Return (Zero)
		}
	}
}
