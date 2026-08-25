# The S3/S5 hang, and how it was found

For most of this port's life neither suspend nor poweroff worked. Both left the
machine halted: display blanked, CPU stopped, but **rails still up, LEDs lit and
the fan at full throttle**. Only holding the power button ~10 s dropped the
rails, and doing that left the board unable to boot until battery and AC were
both pulled.

This is a write-up of the diagnosis, because the conclusion was the opposite of
what months of register-level debugging suggested.

## What was eliminated (all negative)

Every one of these was checked against the vendor firmware and matched, and the
fault persisted:

| Suspect | How it was ruled out |
|---|---|
| coreboot's SMM sleep handler | Cleared `SLP_SMI_EN` at runtime so SMM never ran — hung identically |
| Linux's shutdown path | A bare `PM1_CNT = SLP_TYP(7)\|SLP_EN` write from userspace reproduces it exactly, with the OS fully up |
| ACPI `_S5` | Correct: `Package {0x07,0,0,0}` in the live DSDT |
| `busmaster_disable_on_bus()` | Cannot hang — 0xCF8/0xCFC config reads always complete |
| AFTERG3 / power-failure state | `PMCON_3` bit0 set (stay-off), correct |
| Pending wake events | Nothing enabled pending in `PM1_STS/EN` or `GPE0_STS/EN` |
| GPIO configuration | **Every GPIO register byte-identical** to vendor firmware |
| `GEN_PMCON_3`, incl. SLP_S4# stretch | Set to the vendor value bit-for-bit; still hung |
| FD / FD2 (`0x3418`, `0x3428`) | Set to vendor values, including re-enabling MEI1; still hung |
| TCO_EN / TCO_LOCK | Build-tested, negative |

The lesson: *the entire chipset side was already correct.*

## The measurement that settled it

A Raspberry Pi Pico running [sigrok-pico](https://github.com/pico-coder/sigrok-pico),
soldered to `SLP_S3#`, `SLP_S4#`, `SLP_S5#`, `PM_SUSACK#`, `PWRBTN#` and
`PM_PWROK`. These signals move on millisecond-to-second timescales, so 20 kS/s
over 30 s is ample — capture *duration* matters, not sample rate.

Note sigrok-pico requires a **contiguous channel mask starting at D2**;
`--channels D3,...` alone fails with "Digital channel mask not continous".

Three captures, and the comparison is the whole answer:

```
S3 suspend (FAILS)
  12.4441s  SLP_S3#   1 -> 0   ASSERT
            SLP_S4#/S5#         stay high   (correct for S3)
            PM_PWROK            NEVER MOVES

Power-button hold (WORKS)
  16.3911s  SLP_S3#/S4#/S5#     assert
  18.5700s  PM_PWROK  1 -> 0    drops 2.18 s later

Software S5 (FAILS)
   7.4370s  SLP_S3#/S4#/S5#     assert   <- identical to the working case
            PM_PWROK            NEVER MOVES
```

The sleep signals are **identical** between the working and failing power-downs.
They cannot be the discriminator. The PCH does its job perfectly; nothing acts
on the result.

## Why the EC

The IT8572E pinout (LQFP-128) settles the architecture:

- **Inputs from the PCH:** `PM_SUSB#` (pin 107) = SLP_S3#, `PM_SUSC#` (pin 21) =
  SLP_S5#, `PM_SLP_SUS#` (70), `PM_RSMRST#` (112), `PM_PWRBTN#` (56)
- **Rail control outputs:** `CPU_VRON` (76), `VSUS_ON_R` (86), `SUSB_EC#_C` (97)
- **Power-good chain:** `SUS_PWRGD` (67), `ALL_SYSTEM_PWRGD` (68),
  `CORE_PWRGD` (69), `PM_PWROK` (77), `PM_SYSPWROK` (85)

The EC receives the sleep signals and owns the VR enables. **Nothing else can
drop the rails.**

## Reading the EC's own firmware

The IT8572E does not have its own flash — it shares the host SPI chip. Its
complete 64 KiB firmware sits at **0x200000**, the region this board's FMD calls
`VENDOR_DATA`. It is not banked; the whole image is there in every stock BIOS
dump.

Confirmed by fingerprinting a live EC memory dump against the flash image:
16129/16384 bytes matched, the only divergence being a 255-byte runtime scratch
block.

Disassembled with Ghidra (`8051:BE:16:default`, flat at base 0). **A bare 8051
image auto-analyses to zero functions** — the script must `disassemble()` the
vector table (every 8 bytes from 0) and then chase references.

Useful scans on the raw image:
- `MOV DPTR,#imm16` (`90 hi lo`) followed by `MOVX @DPTR,A` (`f0`) enumerates
  every hardware register the firmware touches
- `CJNE A,#imm` (`b4 imm rel`) chains locate the command dispatchers

## The two bytes

```
0x4f0 = 0x03    bit0  disables the EC host watchdog        (test at 0x6d30)
                bit1  opens the shutdown gate              (test at 0x7f84)
                bit2  when set, aborts the power-button handler (test at 0x67b6)
0x4f3 = 0x02    bit1  master shutdown gate                 (tests at 0x7f8b, 0x6d45)
```

Under coreboot these read `0x04` and `0x00`; under vendor firmware, `0x03` and
`0x02`. Note `0x03` is self-consistent: it opens the shutdown path *and*
disables the watchdog, so arming the gate does not expose the EC's own watchdog
shutdown.

Corroborating evidence: the EC records a reason code at `0x4f6` whenever it
begins a power transition. Under coreboot it read `0x00` even with standby power
preserved across a hang — the EC was **never asked**, rather than asking and
refusing. After the fix it reads `0xb1`, exactly as under vendor firmware,
because the EC now runs its own power-on sequence.

The EC exposes **no host command to power off** — all eight routes to its
shutdown entry (`0x68ff`) are internal conditions (thermal at 120 °C, battery
counters, watchdogs). So "just send the EC a shutdown command" is not available;
the state has to be right instead.

## Result

`k53sc_ec_arm_power_sequencer()` writes both bytes from `mainboard_init()`,
using the `0x81` EC RAM write primitive the vendor firmware itself implements.

```
S5 after the fix
  10.5572s  SLP_S3#/S4#/S5#   assert
  10.5685s  PM_PWROK  1 -> 0  drops 11.3 ms later

S3 after the fix
   7.9965s  SLP_S3#           assert    (S4/S5 correctly stay high)
   8.0085s  PM_PWROK  1 -> 0  drops 12.0 ms later
```

Poweroff powers the machine off. Suspend genuinely suspends, with the fan
stopping, and resumes cleanly. An orderly power-down leaves the board bootable —
no boot loop, no battery pull — confirming that the unbootable state was always
a consequence of force-killing a hung machine.
