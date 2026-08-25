# coreboot port — ASUS K53SC

A working coreboot port for the **ASUS K53SC** (K53SV MAIN BOARD REV 3.1):
Intel HM65 Cougar Point, ITE IT8572E EC, 4 MiB Macronix MX25L3206E SPI.

This is not a coreboot fork — it is the board directory plus a patch series
that applies to upstream coreboot, which is what you actually need to build it.

## What works

- **Sandy Bridge and Ivy Bridge** CPUs from one image (tested i3-2310M and i7-3840QM)
- Native graphics via libgfxinit with the factory VBT
- Native backlight control
- Battery and AC status, correct on cold boot and hot insert
- Six Fn hotkeys (volume, mute, touchpad, …) via the ASUS ATK WMI layer
- HDMI output
- **UEFI boot** — edk2 UefiPayloadPkg with SMMSTORE for variables
- **Both GPUs** — the discrete GeForce GT 520MX works under nouveau via PRIME offload
- **Suspend (S3) and poweroff (S5)** — see below; these were the hard part

## What does not

- Brightness keys: the EC never raises the ACPI queries for them
- Thermal trip points differ from the vendor firmware's values

## The S3/S5 fix

Neither suspend nor poweroff worked for most of this port's life. Both left the
machine halted with the display blanked, the rails still up, the LEDs lit and
the fan at full throttle. Only a ~10 s power-button hold could drop the rails.

**coreboot was not at fault.** A logic analyser on `SLP_S3#`/`SLP_S4#`/`SLP_S5#`,
`PM_PWROK`, `SUSACK#` and `PWRBTN#` showed the PCH asserting all three sleep
signals correctly and simultaneously — bit-identically to a known-good
power-button shutdown — while `PM_PWROK` never moved at all. Matching every
comparable PCH register to the vendor firmware (GPIOs byte-identical,
`GEN_PMCON_3`, FD/FD2, `SMI_EN`/`GPE0_EN`/TCO, the ACPI `_S5` object and the SMM
sleep handler) changed nothing, because the chipset was already correct.

The IT8572E is this board's power sequencer. It receives the sleep signals
(`PM_SUSB#` pin 107, `PM_SUSC#` pin 21) and owns the VR enables (`CPU_VRON`
pin 76, `VSUS_ON_R` pin 86). Two bytes of its RAM decide whether it acts on
them, and coreboot left both wrong:

| byte | broken | correct | meaning |
|---|---|---|---|
| `0x4f0` | `0x04` | `0x03` | bit0 disables the EC host watchdog; bit1 opens the shutdown gate; bit2 (set) aborts the power-button handler |
| `0x4f3` | `0x00` | `0x02` | bit1 is the master shutdown gate |

`k53sc_ec_arm_power_sequencer()` sets these from `mainboard_init()`, using the
`0x81` EC RAM write primitive the vendor firmware itself implements. With it,
`PM_PWROK` follows the sleep assertion in ~12 ms; without it, never.

Full write-up: [`docs/ec-power-sequencer.md`](docs/ec-power-sequencer.md).

## Building

You need two binary blobs that are **not** included here — they are ASUS/Intel
and NVIDIA copyrighted material. See
[`src/mainboard/asustek_computer/k53sc/BLOBS.md`](src/mainboard/asustek_computer/k53sc/BLOBS.md)
for what they are and how to extract them from your own stock image.

```bash
git clone https://review.coreboot.org/coreboot.git
cd coreboot
git am /path/to/this/repo/patches/*.patch
# supply data.vbt and dgpu-vbios.rom, then:
cp /path/to/this/repo/config-current .config
make olddefconfig && make
```

`config-current` is the configuration that built the running firmware
(edk2 payload, discrete GPU enabled, SMMSTORE).

## Flashing

Internally, with the board booted. **flashrom 1.7.0 needs `--noverify-all`** or
it tries to read the whole chip, hits the locked ME region and aborts before
writing:

```bash
flashrom -p internal -c "MX25L3206E/MX25L3208E" --noverify-all \
    --fmap -i COREBOOT -w build/coreboot.rom
```

Externally, SOIC-8 clip on the SPI chip — **take the main battery out**, not
just AC. With it in, the 3.3 V standby rail fights the programmer and erases
fail in ways that look like a single bad sector.

### Three traps worth knowing

- `COREBOOT` starts at **0x211000**, not 0x210000 (that is FMAP). `cbfstool`
  prints offsets in decimal. Use `--fmap` and never hand-write the layout.
- **Reading back only the range you wrote proves nothing** — it re-reads exactly
  what you wrote and cannot detect a wrong range. Verify the whole BIOS region,
  and check that `0x211000` begins with `LARCHIVE`.
- **`VENDOR_DATA` at 0x200000 is the EC firmware**, not vendor junk. The
  IT8572E shares the host SPI chip. Erasing that region leaves the EC with no
  firmware. Keep it `PRESERVE` in any FMD change.

## Licence

coreboot is GPL-2.0-only; every source file here carries its SPDX header.
