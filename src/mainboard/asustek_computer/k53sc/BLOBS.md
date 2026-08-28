# Binary blobs this board needs

Two binaries from the factory firmware are required to build this board. They are
ASUS/Intel and NVIDIA copyrighted material, so they are **excluded from the public
repository** and must be extracted from **your own machine's** stock image.

| File | Size | What it is |
|---|---|---|
| `data.vbt` | 4060 | Intel Video BIOS Table - panel timings and port config |
| `dgpu-vbios.rom` | 56320 | NVIDIA GT 520MX (`10de:1051`) video BIOS |

Both live in this directory, and are referenced by:

    CONFIG_INTEL_GMA_VBT_FILE="src/mainboard/asustek_computer/k53sc/data.vbt"
    CONFIG_VGA_BIOS_FILE="src/mainboard/asustek_computer/k53sc/dgpu-vbios.rom"
    CONFIG_VGA_BIOS_ID="10de,1051"

`data.vbt` is needed for correct LVDS panel bring-up and for the external ports to
work. `dgpu-vbios.rom` is only needed if the discrete GPU is enabled (`device ref
peg10 on` in devicetree.cb); with `peg10 off` you can drop it and clear
`CONFIG_VGA_BIOS`.

## Getting a stock image

If the machine still has factory firmware, read it out:

    flashrom -p internal -c "MX25L3206E/MX25L3208E" -r stock.bin

Otherwise use a SOIC-8 clip on the 4 MiB MX25L3206E. **Take the main battery out**
for external reads and writes: with it in, the 3.3 V standby rail fights the
programmer and erases fail in ways that look like a single bad sector.

## Extracting

The VBT is found by its `$VBT` signature, the option ROM by the PCI ROM signature
`0x55AA` followed by a PCIR header naming the device:

```python
d = open("stock.bin", "rb").read()

# VBT
o = d.find(b"$VBT")
vbt_len = int.from_bytes(d[o+22:o+26], "little")
open("data.vbt", "wb").write(d[o:o+vbt_len])

# NVIDIA option ROM: walk 0x55AA candidates, check the PCIR vendor/device
i = 0
while True:
    i = d.find(b"\x55\xaa", i)
    if i < 0:
        break
    p = int.from_bytes(d[i+0x18:i+0x1a], "little")
    if 0 < p < 0x200 and d[i+p:i+p+4] == b"PCIR":
        ven = int.from_bytes(d[i+p+4:i+p+6], "little")
        dev = int.from_bytes(d[i+p+6:i+p+8], "little")
        size = int.from_bytes(d[i+p+16:i+p+18], "little") * 512
        if (ven, dev) == (0x10de, 0x1051):
            open("dgpu-vbios.rom", "wb").write(d[i:i+size])
            break
    i += 2
```

Verify the sizes match the table above before building.

## Alternative for the dGPU ROM

On a running system with the discrete GPU bound, the kernel exposes it:

    echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom
    sudo cat /sys/bus/pci/devices/0000:01:00.0/rom > dgpu-vbios.rom
    echo 0 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom

This is the same image the board's `_ROM` method hands the OS.
