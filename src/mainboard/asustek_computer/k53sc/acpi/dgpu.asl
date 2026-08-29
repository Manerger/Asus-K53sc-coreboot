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
		\GP50 = Zero
		Sleep (100)
		\GP54 = Zero
		Sleep (100)

		/* Wait for the GPU's power-good input to assert. */
		Local0 = \GP17
		While (!Local0) {
			Sleep (10)
			Local0 = \GP17
		}

		\GP50 = One
		Sleep (100)

		/* A cold power-up clears the override. */
		RSSI ()
	}

	Method (_PS0, 0, NotSerialized)
	{
		If (OMPR == 0x03) {
			DGON ()
			OMPR = 0x02
		}

		/* The GPU may have just come back from D3; re-stamp the ID. */
		RSSI ()
	}

	Method (_PS3, 0, NotSerialized)
	{
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
