# Patched `usbio.ko` for Synaptics SVP7500 (06cb:0701)

## What this is

`usbio.c` is a copy of the upstream Linux kernel `drivers/usb/misc/usbio.c` with **one change**: the `USBIO_QUIRK_I2C_ALLOW_400KHZ` flag added to the Synaptics Sabre device entry, matching the Lattice NX33 quirk pattern that's already there.

Without this quirk, kernel logs:
```
i2c_usbio.usbio-i2c.X: Invalid speed 400000 adjusting to bus max 100000
```
and the bridge runs I2C at 100kHz instead of 400kHz — 4× slower than the spec sheet for the SVP7500.

With this quirk, the bridge negotiates 400kHz cleanly, RGB still streams via libcamera, no regression observed.

This is a defensible upstream patch (matches the existing pattern for other USBIO devices in the same table) but isn't merged yet. The fix pack ships it as a swap-in `usbio.ko` while the upstream conversation plays out at intel/ipu7-drivers#51.

## How `install.sh` handles it

If the bridge is detected (`lsusb -d 06cb:0701`), `install.sh` will:

1. Compile this `usbio.c` against your running kernel's headers (uses `clang` to match upstream kernel build)
2. Sign the resulting `usbio.ko` with the same DKMS MOK key the rest of the fix pack uses (via `sign-file`)
3. Compress with `zstd` to match the system module format
4. Back up the original `usbio.ko.zst` to `/var/cache/svp7500-fix-pack/usbio.ko.zst.orig`
5. Install the patched version to `/lib/modules/$(uname -r)/kernel/drivers/usb/misc/usbio.ko.zst`
6. `depmod -a`

You'll need to reboot for the new module to take effect.

## Reverting

If anything goes wrong:
```bash
sudo cp /var/cache/svp7500-fix-pack/usbio.ko.zst.orig \
        /lib/modules/$(uname -r)/kernel/drivers/usb/misc/usbio.ko.zst
sudo depmod -a
sudo reboot
```

## Why this isn't a DKMS module

`usbio.ko` is **in-tree** in the Linux kernel — it's part of the kernel source proper, not an out-of-tree driver. DKMS handles out-of-tree modules cleanly but in-tree modules need the kernel source headers and a manual build. We do that out-of-tree here (Makefile uses `M=$(PWD)` against the kernel build dir).

The downside: kernel updates on your distro will reinstall the unpatched `usbio.ko` and you'll need to re-run `install.sh` to re-apply the patch. We could automate this with a pacman/dpkg hook in a future version.
