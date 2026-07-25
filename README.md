# SVP7500 + Intel IPU7 Camera Fix Pack

Restore RGB camera functionality on Linux for laptops with the Synaptics SVP7500 CVS bridge (USB `06CB:0701`) and Intel IPU7 (Panther Lake / Lunar Lake).

> ⚠️ **Testing scope:** All testing was done on **CachyOS** with a custom-built **linux-cachyos-susfix 7.0.5** kernel (CachyOS's `linux-cachyos` source plus our own kernel patch for the `ipu7_pci_remove` ordering bug). The DKMS modules themselves should be distro-agnostic (just C code against the kernel API), so Fedora / Arch / Debian / Ubuntu *should* work — **but we haven't tested those personally.** If you try it on another distro, please report back via the issue tracker.
>
> Specifically untested:
> - Fedora 43/44 (regular workstation) — should work, kernel version compatible
> - Fedora 44 Silverblue — DKMS on an immutable OS is finicky; you'll likely need `rpm-ostree install dkms kernel-devel` followed by a reboot before running our installer. Layering DKMS modules on Silverblue is known-awkward.
> - Ubuntu / Debian — should work with `linux-headers-$(uname -r)`
> - Stock Arch / EndeavourOS — should work; we run a custom kernel but the DKMS modules don't depend on those custom patches

## Which problem do you have?

There are **two completely different kinds of laptop IR camera**, and the fixes
have nothing in common. Check before you spend time here:

```bash
# Is your IR camera a USB UVC webcam?
lsusb -v 2>/dev/null | grep -B4 'bInterfaceClass.*14 Video'
ls /sys/bus/usb/drivers/uvcvideo/

# Or a MIPI sensor behind an Intel IPU?
v4l2-ctl --list-devices | grep -A2 ipu
```

| your camera | what you need |
|---|---|
| **USB UVC IR webcam** (`uvcvideo` bound, interface class 14) | **not this repo** — use [linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter), which flips the vendor UVC control that switches the emitter on |
| **MIPI CSI-2 sensor on Intel IPU6/IPU7** (driver `intel-ipu7`/`ipu6`, sensor in the media graph, bridge is USB class 255 vendor-specific) | **this repo** |

On IPU platforms the sensor is not a USB webcam at all — it reaches the host
over MIPI CSI-2 through the IPU, and the Synaptics bridge exposes only a
vendor-specific bulk interface carrying an I2C tunnel. There is no UVC device to
send a control to, so UVC-based tools cannot help, and conversely nothing here
applies to a UVC webcam.

## Affected hardware

Confirmed working:
- Dell XPS 16 DA16260 (Panther Lake) on CachyOS — primary dev hardware
- Dell XPS 16 DA16260 (Panther Lake) on Fedora 44 Silverblue — independently confirmed by @tverhaeghe (intel/vision-drivers#37)
- Dell Pro 14 PB14250 (Lunar Lake) on Arch — install confirmed by @acmodeu (intel/ipu7-drivers#26), streaming TBD

Likely also helps (untested by us, please report):
- Dell Latitude 9440 / 7440 / 7450
- Lenovo ThinkPad X9
- Dell Pro Max 16 MA16250
- ASUS Vivobook X1407Q (Snapdragon X — different host, same sensor)
- Any laptop with Intel IPU7 + Synaptics SVP7500 + OV08x40/HM1092 sensors

## What you get

| Status | Camera |
|--------|--------|
| ✅ Works | RGB front-facing camera (OV08x40) — for video calls, photos, etc. |
| ✅ **Working** | **IR camera (HM1092)** — Windows Hello-style face auth via Howdy |

## Quick install

> 🛟 **Back up your kernel + initramfs first.** DKMS modules can occasionally break boot if they fail to load and something on the boot path depends on them. These camera modules shouldn't be on the boot path, but be safe:
>
> ```bash
> sudo cp /boot/vmlinuz-$(uname -r){,.pre-svp7500-fix.bak}
> sudo cp /boot/initramfs-$(uname -r).img{,.pre-svp7500-fix.bak}  # Fedora/RHEL
> # OR
> sudo cp /boot/initrd.img-$(uname -r){,.pre-svp7500-fix.bak}     # Debian/Ubuntu
> # OR (Arch / CachyOS)
> sudo cp /boot/initramfs-linux*.img{,.pre-svp7500-fix.bak}
> ```
>
> If you're on Btrfs with `snapper`, just take a snapshot:
> `sudo snapper create --description "pre-svp7500-fix"`
>
> **Recovery if something breaks:** boot to your previous kernel entry (most bootloaders keep one), then:
> ```bash
> sudo dkms remove -m intel-cvs -v 1.0 --all
> sudo dkms remove -m hm1092 -v 1.0 --all
> sudo dkms remove -m int3472-patched -v 1.0 --all
> sudo dkms remove -m ipu-bridge-patched -v 1.0 --all
> sudo rm -f /etc/udev/rules.d/99-svp7500-no-autosuspend.rules
> sudo reboot
> ```

Requires DKMS and kernel headers:
```bash
# Fedora
sudo dnf install dkms kernel-devel

# Arch / CachyOS
sudo pacman -S dkms linux-headers

# Debian / Ubuntu
sudo apt install dkms "linux-headers-$(uname -r)"
```

Then:
```bash
sudo ./install.sh
sudo reboot
```

After reboot:
```bash
cam --list                                # should show 1 camera (your front-facing RGB)
cam --camera=1 --capture=5 --file=/tmp/test.raw    # capture 5 frames
```

If the camera does not show up, check `sudo dmesg | grep -E 'Intel CVS|hm1092|ov08x40'` and report results to https://github.com/intel/vision-drivers/issues/37

## What's in here

5 components, each fixes a different piece of the broken stack:

### 1. `intel-cvs` DKMS (the headline fix)
- Patches `cvs_init()` to remove a buggy `IRQF_ONESHOT` flag from `devm_request_irq()`. The flag was meaningless on a non-threaded handler and caused a kernel WARNING. **More importantly: it made IRQ delivery from the SVP7500 unreliable, which is why the bridge wedges itself after brief idle periods.**
- Adds verbatim Windows-format MIPI config payloads (RGB + IR), captured from USBPcap traces of Windows on identical hardware.
- Exposes a sysfs `cmd` interface (`echo state > cmd`, `echo mipi-ir > cmd`, etc.) for runtime experiments.

### 2. `int3472-patched` DKMS
- Adds support for GPIO type `0x02` (IR LED) — needed for HM1092 sensors.
- Adds an SSDB `controllogicid` fallback walk through the ACPI namespace. Required on USBIO platforms (where the `_DEP` chain is broken and `acpi_dev_get_next_consumer_dev()` returns NULL).

### 3. `ipu-bridge-patched` DKMS
- Adds `HIMX1092` to the `supported_sensors[]` array so the kernel actually enumerates the IR sensor.

### 4. `hm1092` DKMS
- New v4l2-subdev driver for Himax HM1092.
- 198-register init sequence reverse-engineered from a Windows USBPcap during Hello face auth.
- Lazy IR LED management: LED is OFF when the sensor is in standby, only turns ON during streaming. Matches Windows behavior. Stock implementations leave the LED ON 24/7 after module load.

### 5. `ov05c10` DKMS
- RGB sensor driver for boards that pair the SVP7500 bridge with the **OV05C10** (`OVTI05C1`) sensor — e.g. the **Dell Pro Plus 14 PB14250** — instead of the OV08x40 used on the DA16260.
- The driver is the out-of-tree Intel one from [`intel/ipu6-drivers`](https://github.com/intel/ipu6-drivers) (`drivers/media/i2c/ov05c10.c`); it was never mainlined, so affected boards have no RGB camera until it's installed. The bridge half already enumerates `OVTI05C1` — this supplies the missing sensor driver.
- Packaged as DKMS so it survives kernel upgrades. Builds clean against 6.18 / 7.0 / 7.1.

### 6. udev rule
- Disables USB autosuspend on the SVP7500 device. Bridge firmware appears to have issues with power state transitions; keeping it always-on prevents some failure modes.

## Why this needed reverse engineering at all

The Synaptics SVP7500 is a proprietary MIPI bridge chip. Synaptics has not published its command reference publicly. Combined with the Intel IPU7 staging-driver stack (also fairly opaque), the camera "just doesn't work" on most Linux distros for affected laptops.

This fix pack is the result of three months of community reverse-engineering: USBPcap captures from Windows installs, Ghidra analysis of `Vision.sys`, kernel-side patches, and a lot of iteration.

### IR camera — SOLVED (2026-07-25)

The IR camera streams, and Howdy authenticates against it from the lock screen.

**Root cause: `V4L2_CID_LINK_FREQ` was set to the MIPI per-lane bit rate instead
of the DDR clock — exactly 2x too high.** `ipu7-isys` therefore programmed the
CSI-2 D-PHY at ~721 Mbps against a sensor transmitting at ~361. The clock lane
came up, but no data packet ever framed, so the port produced zero SOF forever.

```
648x368 @30, 1 lane, RAW10:
  LLP 1620 x FLL 740 x 30 fps          = 35,964,000 px/s   (pixel_rate)
  x 10 bpp                             = 359,640,000 bit/s (bit rate)
  V4L2_CID_LINK_FREQ = DDR clock       = 180,480,000        <-- correct
  what the driver published            = 360,960,000        <-- 2x too high
```

The wrong value came from the natural derivation — the sensor's own PLL
registers (`19.2 MHz x 94 / 5 = 360.96 MHz`). That is genuinely the PLL output;
it is just the bit clock, not what V4L2 wants. Anyone reverse-engineering this
sensor from its PLL configuration lands on the same number. It was finally
pinned down by extracting the mode-descriptor array from the Windows
`hm1092.sys`, where `pixel_rate = 36,000,000` sits beside `link = 360,960,000`,
making the factor of two unambiguous.

**Previous hypotheses in this README and in
[intel/vision-drivers#37](https://github.com/intel/vision-drivers/issues/37)
were wrong and are retracted:**

* The CVS bridge does **not** block the data lane. With the bridge given no MIPI
  link configuration at all, the sensor's clock still reaches the IPU.
* `HOST_SET_MIPI_CONFIG` (0x0830) is **not** needed for IR. Windows never sends
  one — every 0x0830 in all seven USB captures carries RGB geometry, and
  648x368 appears in no USB payload. This fix pack was sending one; Windows does
  not.
* The register init table was never wrong — it is byte-identical to Windows in
  content and order, confirmed both from the USB captures and by extracting the
  tables from `hm1092.sys` (all four Dell driver builds carry identical tables).
* There is no frame-trigger, sync or slave-mode register anywhere in the sensor
  or in any Windows driver build.

Full write-up: [IR-FINDINGS.md](IR-FINDINGS.md)

### Howdy integration

`howdy/ir_reader.py` is a Howdy recorder that reads the IR node directly.
It deliberately bypasses libcamera/PipeWire, because libcamera's SoftwareIsp
**debayers** this monochrome sensor (it is tagged SGRBG10) and PipeWire
renegotiates the stream to 1920x1080, landing the 648x368 payload in a
mostly-black buffer. It also drives the IR illuminator, which the sensor driver
cannot because INT3472 owns that GPIO.

Gotchas that cost real debugging time:

* The V4L2 control is **`link_frequency`, not `link_freq`** — the wrong name
  fails *silently* and yields convincing fake negatives. Always confirm the
  kernel's `config phy N ... mbps M` line actually changed.
* `/dev/videoN`, `/dev/v4l-subdevN` and libcamera indexes **shuffle between
  boots**. Resolve by entity name (`tools/find-ir-node.sh`), never hardcode.
* Howdy's `dark_threshold` is **not brightness** — it is the percentage of
  near-black pixels, and a frame is rejected when it *exceeds* the threshold.
  IR frames here are ~70-77% black, so the stock `60` rejects everything. Use 90.
* Howdy's recognition runs as the **unprivileged user** under a lock screen, so
  the illuminator needs `udev/99-hm1092-ir-led.rules` or it silently never fires
  and every frame is too dark to detect a face.

## Uninstall

```bash
sudo dkms remove -m intel-cvs -v 1.0 --all
sudo dkms remove -m hm1092 -v 1.0 --all
sudo dkms remove -m int3472-patched -v 1.0 --all
sudo dkms remove -m ipu-bridge-patched -v 1.0 --all
sudo rm -f /etc/udev/rules.d/99-svp7500-no-autosuspend.rules
sudo rm -rf /usr/src/intel-cvs-1.0 /usr/src/hm1092-1.0 \
            /usr/src/int3472-patched-1.0 /usr/src/ipu-bridge-patched-1.0
sudo udevadm control --reload-rules
sudo reboot
```

## License

The DKMS modules contain code from Intel (`intel-cvs`, `ipu-bridge`), Himax (sensor reference), and original work on top. License terms inherit from each upstream component — primarily GPL-2.0.

## Credits

- @jibsta210 — patch development, reverse engineering, testing
- @tverhaeghe — USBPcap traces from Windows on matching hardware (the key dataset)
- Intel `vision-drivers` and `ipu7-drivers` upstream maintainers — for the base code we patched
- Hans de Goede (@hdegoede) — Linux mainline IPU6/7 camera maintainer
