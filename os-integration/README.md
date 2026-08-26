# OS integration — the function row

These are **not** firmware. They are the OS-side pieces that make the Fn row
usable on this machine, and they are needed because of a hardware property of
this unit rather than anything missing from coreboot.

## Why they are needed

This unit's EC adjusts the panel brightness **privately**, through its own
`LCD_BL_PWM` output (IT8572E pin 30), and never raises the ACPI queries that
stock's DSDT declares for it (`_Q0E`/`_Q0F`). Those handlers are **vestigial**
here — ASUS shares that DSDT across the K53 family and this unit's keyboard
differs (F3/F4 are unlabelled).

The evidence is behavioural: under the **stock ASUS firmware**, Fn+F5/F6 changed
the screen but the OS never reported the change. So no operating system is told
about those keys — Windows included. Stock "worked" only because the EC did the
job internally without involving anyone.

Under coreboot the panel is driven by the GPU's PWM instead (native
`intel_backlight`), so the EC's private adjustment has nothing to act on and the
keys appear dead. The keypress *does* reach the OS as a plain function key,
which is what these remap.

## The constraint that shapes the design

Measured from `MSC_SCAN` on `/dev/input/event1`:

| press | scancodes | note |
|---|---|---|
| plain F1..F12 | `0x3b`..`0x44`, `0x57`, `0x58` | distinct, clean press/release |
| Fn tapped alone | `0x50` then `0x51` (~5 ms apart) | no keycode; does **not** autorepeat |
| **Fn+F5** | `0x23` then `0x14` | |
| **Fn+F6** | `0x23` then `0x14` | **identical to Fn+F5** |

**Fn+F5 and Fn+F6 are indistinguishable**, so the Fn layer cannot address those
keys individually and an Apple-style "Fn inverts the row" scheme is impossible.
A toggle is the closest achievable equivalent.

Note also that Fn+F1/F2/F9-F12 reach the OS on the **Asus WMI** input device via
the EC's ACPI query path, entirely independently of any keymap here.

## Linux

| file | goes to |
|---|---|
| `linux/61-k53sc-fnrow.hwdb` | `/etc/udev/hwdb.d/` |
| `linux/k53sc-fnrow` | `/usr/local/bin/` (mode 755) |
| `linux/k53sc-fnd` | `/usr/local/bin/` (mode 755) |
| `linux/k53sc-fnd.service` | `/etc/systemd/system/` |

```bash
sudo systemd-hwdb update && sudo udevadm trigger /dev/input/event1
sudo systemctl enable --now k53sc-fnd.service
```

Then **log out and back in** — a running compositor keeps its old keymap, and
the mapping looks broken until it re-reads it.

- The hwdb makes the media row the boot default.
- `k53sc-fnrow media|function|toggle|status` flips the row live via
  `EVIOCSKEYCODE`. It finds the keyboard by name, so it survives event
  renumbering.
- `k53sc-fnd` toggles the row when **Fn is tapped on its own**. It watches the
  Asus WMI and Video Bus devices too: Fn+F10's action lands on the WMI device
  ~190 ms later, and without watching it every Fn+F10 would toggle the row.
  It also handles F7 (backlight off/restore) and would handle F2, since Plasma
  binds neither `display_off` nor `wlan` by default.

**F1/F2 are deliberately not remapped.** Sleep and wifi-kill are destructive if
hit by accident — dropping out of a game or losing the network. They stay on
Fn+F1/Fn+F2 via the EC's own path. Volume and brightness are safe on bare keys
because a mistake self-corrects in a second.

## Windows

`windows/K53SC-FnRow.ahk` (AutoHotkey v2) does the same thing. The scancodes
carry over unchanged — Linux `MSC_SCAN` values *are* set-1 scancodes, which is
what Windows and AHK address as `scXXX`.

**Untested** — written from the Linux measurements, never run on Windows. Two
things to check: `sc050`/`sc051` are also Numpad2/Numpad3 in set-1, so the Fn
tap may misfire while using the numeric keypad; and brightness relies on
`WmiMonitorBrightnessMethods`, which not every panel exposes.
