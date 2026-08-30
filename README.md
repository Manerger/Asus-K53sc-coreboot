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
- **Both GPUs, on Linux and Windows** — the discrete GeForce GT 520MX works under
  nouveau via PRIME offload, under the proprietary NVIDIA driver (390.157), and
  under Windows (391.35), since the firmware started programming the GPU's PCI
  subsystem ID. Windows needs one extra piece, a boot-time device restart; see
  [`os-integration/windows/nvidia-dgpu-fix.ps1`](os-integration/windows/nvidia-dgpu-fix.ps1)
- **Suspend (S3) and poweroff (S5)** — see below; these were the hard part

## The function row

The brightness and media keys work, but through an OS-side keymap rather than
firmware — see [`os-integration/`](os-integration/). That is a property of this
unit, not a gap in the port: its EC adjusts the panel privately via `LCD_BL_PWM`
and never raises the `_Q0E`/`_Q0F` ACPI queries its DSDT declares, so **no** OS
is told about those keys. Under stock firmware the screen changed but nothing
was reported, which is the same thing seen from the other side.

The media row is the default and **tapping Fn on its own** flips it to real
F1–F12. Fn+F5/F6 emit an identical scancode pair, so an Apple-style
"Fn inverts the row" scheme is impossible here; a toggle is the closest
equivalent. Windows gets the same behaviour from an AutoHotkey script.

Thermal management works too: the EC's trip points read 88/90 °C, the same as
the vendor firmware. (An earlier 103/105 °C reading was an artifact of
`asus_wmi` not loading, because coreboot's DSDT had no `ATKD` device to bind
to — not a firmware difference. Declaring `ATKD` resolved it.)

## Two autoport traps worth knowing

This board was brought up with `autoport`, which records what is **present and
active at sample time**. Anything absent or powered down got written off, and
each one looked like a hardware fault until traced:

| symptom | cause | fix |
|---|---|---|
| Discrete GPU missing | `device ref peg10 off` — the GPU was power-gated by Optimus when autoport ran | enable `peg10` |
| Optical drive powers up but never enumerates | `sata_port_map = 0x1` — no drive was fitted when autoport ran, so AHCI reported "1/6 ports implemented" and ports 2-6 as DUMMY | set the map to `0x3` |

Power reaches such devices from the rail regardless, so they look alive while
the controller never scans them. **If something on this board seems dead, check
the devicetree before suspecting the hardware.** Four USB ports are still
disabled in `usb_port_config` and have not been individually verified.

## Firmware options

The board carries a CMOS option table, so a few things are switchable from a
booted system without rebuilding:

```bash
nvramtool -a                    # list all options
nvramtool -w dgpu=Disable       # turn the discrete GPU off, then reboot
```

`dgpu=Disable` clears the PEG10 device, and sandybridge's `disable_peg()` then
clears `DEVEN_PEG10`. The port disappears from PCI entirely — verified on
hardware: both `01:00.0` (the GPU) and `00:01.0` (the PEG bridge) are absent
from `lspci`, so the GPU draws no power rather than merely being hidden.

## Project status

**This port is functionally complete and not expected to change much.**
Everything listed under "what works" is verified on hardware. The items below
were investigated and deliberately closed off, recorded here so nobody repeats
the work:

| not done | why |
|---|---|
| **UEFI Secure Boot** | Builds and fits, but only by disabling edk2's LVGL renderer (−195 KB) — the payload is otherwise ~49 KB too large. That trades a graphical firmware UI for protection that starts at the payload; coreboot itself is unverified, so anyone able to write the SPI flash bypasses it. Judged not worth it here. |
| **fTPM** | Impossible on this hardware. Intel PTT needs ME 11+; this is ME 7 on Cougar Point. A discrete TPM footprint exists at `U6201` (28-pin LPC, with crystal `X6201`) but is unpopulated, and the boardview carries no BOM to identify the part. |
| **CSM / legacy boot in edk2** | A CSM is a proprietary 16-bit blob shipped inside vendor UEFI firmware; edk2's UefiPayloadPkg has none and coreboot cannot supply one. Free flash space does not change this. Use the SeaBIOS payload for legacy boot. |
| **Reclaiming ME flash space** | `me_cleaner` frees ~1.2 MiB inside the ME region, but it lands *below* `VENDOR_DATA` at `0x200000` — the EC's own firmware, at a hardware-fixed offset. `COREBOOT` already runs to the top of flash and is walled in beneath, so the space is unusable for CBFS. |

The Intel ME **is** neutered on this machine (`me_cleaner -S`: 11 partitions to
one, 1.5 MB of code to 47 KB, `AltMeDisable` set, MEI gone from the PCI bus) —
done for the security benefit, not for space.

## Known limitations

- **Fn+F5 / Fn+F6 cannot be distinguished.** They emit an identical scancode
  pair (`0x23` then `0x14`), so no keymap can separate them. This is why the
  function row uses a toggle rather than an Fn layer. Everything those keys
  should do is available on the plain row instead.
- **Under Windows the discrete GPU needs a boot-time device restart.** The NVIDIA
  driver fails its *initial* start with Code 43 (`CM_PROB_FAILED_POST_START`) and
  `ProblemStatus` `STATUS_SUCCESS` — it starts, runs its own validation and
  declines, with no OS-level error. Restarting the device once the system is up
  succeeds every time, so
  [`os-integration/windows/nvidia-dgpu-fix.ps1`](os-integration/windows/nvidia-dgpu-fix.ps1)
  does that from a startup task. This is a timing problem in the driver's first
  start, not a firmware fault: the subsystem ID is programmed, the full Optimus
  ACPI surface is present, the card matches `nvami.inf` natively, and the same
  firmware drives it correctly under Linux. Ruled out by measurement: OS version
  (10 and 11 alike), driver version (391.35 and 392.68), INF matching, the
  subsystem ID (re-stamping it earlier from `_STA`/`_INI` changes nothing and
  Windows keeps enumerating the correct `SUBSYS` throughout), `OPVK`, HVCI, and
  any extra vendor init — Ghidra shows the factory DXE driver does nothing beyond
  the config `0x40` write this port replicates.

- The two binary blobs are not included; see
  [`BLOBS.md`](src/mainboard/asustek_computer/k53sc/BLOBS.md).

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
