# SVP7500 + Intel IPU7 Camera Fix Pack

**What this is:** a set of DKMS kernel modules that make the built-in camera work
on Linux laptops where the webcam is a MIPI sensor behind a **Synaptics SVP7500
"CVS" bridge** (USB `06CB:0701`) wired to an **Intel IPU7** imaging unit —
recent Dell XPS / Dell Pro / Latitude and similar Meteor/Arrow/Lunar/Panther
Lake machines. **Who needs it:** anyone on those machines whose camera produces
no device at all, or a device that never delivers a frame, on a stock kernel.
**Who does not:** if your webcam is an ordinary USB UVC device — the vast
majority of laptops, including most non-Dell machines — nothing here applies and
you should not install it.

Run the [hardware check](#step-0--check-your-hardware-first-2-minutes) below
before you install anything. It takes two minutes and tells you definitively
whether this package is for your machine.

> ### Testing scope — please read
>
> **The author owns and verifies exactly one machine:** a Dell XPS 16 (DA16260,
> Panther Lake) on CachyOS, across kernels **7.0.5 through 7.2.0-rc4** including
> **stock `linux-cachyos` 7.1.4** — so a custom kernel is *not* required. On that
> one machine the full stack is verified end to end: RGB camera, IR camera
> streaming, and Howdy face unlock.
>
> **Everything else is third-party reports**, not something the author can
> reproduce or debug directly:
>
> | reporter | machine | distro | reported |
> |---|---|---|---|
> | @acmodeu | Dell Pro 14 PB14250 (CSI-2 port 1) | Arch / CachyOS | install OK; surfaced the port-1 difference |
> | @Aohzan | Dell Pro 14 (`INTC10DE` bridge) | Arch | surfaced the differing bridge ACPI id |
> | @dalandro | Dell Pro 14 Plus PB14250 | Ubuntu | RGB path, OV05C10 sensor |
> | @tverhaeghe | Dell XPS 16 DA16260 | Fedora 44 Silverblue | RGB working ([vision-drivers#37](https://github.com/intel/vision-drivers/issues/37)) |
>
> **IR streaming and Howdy face unlock have not been independently confirmed on
> hardware other than the author's.** The RGB path has. If you get IR working
> (or not) on a different machine, a report is genuinely valuable.
>
> The DKMS modules are plain C against the kernel API with no distro
> assumptions, so Fedora, Debian and stock Arch should work — untested by the
> author. On **Fedora Silverblue** you will likely need
> `rpm-ostree install dkms kernel-devel` and a reboot first; layering DKMS on an
> immutable OS is known-awkward.

---

## Step 0 — check your hardware FIRST (2 minutes)

Run this whole block. It is read-only and changes nothing.

```bash
echo "--- 1. CVS bridge (Synaptics SVP7500) ---"
lsusb -d 06cb:0701 || echo "NOT PRESENT"

echo "--- 2. Bridge ACPI id ---"
ls /sys/bus/i2c/devices/ 2>/dev/null | grep -iE 'INTC10(CF|DE|E0|E1)' || echo "none"

echo "--- 3. Sensors the firmware declares ---"
ls /sys/bus/acpi/devices/ 2>/dev/null | grep -iE 'HIMX1092|OVTI08F4|OVTI05C1|INT3472' || echo "none"

echo "--- 4. Intel IPU present? ---"
lspci -nn | grep -iE 'image signal|imaging|IPU' || echo "no IPU on PCI"

echo "--- 5. Is it actually a plain USB webcam? ---"
ls /sys/bus/usb/drivers/uvcvideo/ 2>/dev/null | grep -q ':' && echo "UVC WEBCAM BOUND — see table below" || echo "no UVC webcam"
```

### Reading the result

**This package is for you** if you see the bridge in (1) *or* an `INTC10xx` id in
(2), plus a sensor in (3). The bridge id tells you your platform:

| ACPI id | platform |
|---|---|
| `INTC10CF` | Meteor Lake |
| `INTC10DE` | Lunar Lake |
| `INTC10E0` | Arrow Lake |
| `INTC10E1` | Panther Lake |

Sensors you may see in (3): `OVTI08F4` (OV08x40, RGB), `OVTI05C1` (OV05C10,
RGB), `HIMX1092` (HM1092, IR). `INT3472` is the power/GPIO controller that owns
the IR illuminator.

**MIPI/IPU sensor vs UVC webcam** — this is the distinction that matters most:

| what you have | how you can tell | what you need |
|---|---|---|
| **MIPI CSI-2 sensor on an Intel IPU** | sensor appears in the media graph (`media-ctl -p`), bridge is USB **class 255 vendor-specific**, no UVC interface, `uvcvideo` binds nothing | **this repo** |
| **USB UVC webcam** | `lsusb -v` shows `bInterfaceClass 14 Video`, `uvcvideo` is bound, `/dev/video0` exists and works in any app | **not this repo.** For a UVC IR emitter use [linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter) |

On IPU platforms the sensor is not a USB webcam at all: it reaches the host over
MIPI CSI-2 through the IPU, and the Synaptics bridge exposes only a
vendor-specific bulk interface carrying an I2C tunnel. There is no UVC device to
send a control to, so UVC-based tools cannot possibly help — and conversely
nothing here applies to a UVC webcam.

### Machines this does NOT help

Stop here and do not install if any of these describe you:

- **`uvcvideo` is bound to your camera** — you have an ordinary USB webcam. If it
  is broken, this is not the cause.
- **No `06cb:0701` and no `INTC10xx`** — you do not have a CVS bridge. Some
  laptops have IPU cameras with a *different* bridge; this pack does not cover them.
- **IPU6 machines** (Tiger/Alder/Raptor Lake, `intel-ipu6` driver) — related
  stack, different target. See [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers).
- **AMD, Qualcomm/Snapdragon or Apple silicon laptops** — no Intel IPU.
- **Your camera already works.** This pack replaces core camera modules; there is
  no upside and a real downside.

---

## Step 1 — prerequisites

```bash
# Arch / CachyOS
sudo pacman -S dkms linux-headers v4l-utils

# Fedora
sudo dnf install dkms kernel-devel v4l-utils

# Debian / Ubuntu
sudo apt install dkms "linux-headers-$(uname -r)" v4l-utils
```

Optional but recommended on Btrfs: `sudo snapper create -d "pre-svp7500-fix"`.

## Step 2 — install

```bash
git clone https://github.com/jibsta210/svp7500-camera-fix-pack
cd svp7500-camera-fix-pack
sudo ./install.sh            # add --kernel-only if you do not use Howdy
```

**What to expect.** The installer builds every module against *every* installed
kernel, so you get one `✓` line per module per kernel:

```
==> Installing DKMS modules
    ✓ hm1092 -> 7.1.4-2-cachyos
    ✓ hm1092 -> 7.2.0-rc4-1-cachyos
    ✓ intel-cvs -> 7.1.4-2-cachyos
    ...
```

Read those lines before you reboot. They are the only proof anything happened:

| line | meaning |
|---|---|
| `✓ <module> -> <kernel>` | built and installed for that kernel |
| `! <module> failed for <kernel>` | build error — missing headers for *that* kernel is the usual cause |
| `! <module> not found in package (looked in dkms/ and kernel/)` | **packaging bug — please report it.** Do not reboot expecting a fix; nothing was installed |

The psys section may legitimately say `ipu7-drivers DKMS not installed —
skipping psys patches`. That is **fine and expected** if you do not have Intel's
`ipu7-drivers` DKMS package (many distros ship IPU7 in-kernel). It is *not* a
sign your DKMS install is broken. By contrast, `psys patch file not found in
this package` is a packaging bug on our side — report that one.

## Step 3 — reboot

```bash
sudo reboot
```

**A reboot is required, not optional.** `hm1092` leaks module references and can
never be swapped live: unbind succeeds, the refcount stays above zero, and
`rmmod` reports the module in use.

---

## Verification

```bash
sudo ./tools/verify.sh
```

Run it as **root** — the live capture test is skipped otherwise.

### What a HEALTHY machine prints

```
=== IPU7 IR stack verification — 7.2.0-rc4-1-cachyos ===
  module intel_ipu7                  loaded
  module intel_ipu7_isys             loaded
  module intel_ipu7_psys             loaded
  module intel_cvs                   loaded
  module hm1092                      loaded
  /dev/ipu7-psys0                    present          <-- the one that matters
  loaded modules match disk          yes              <-- no stale initramfs copy
  link_frequency                     180480000 (CORRECT)
  psys suspend patches               2/2
  IR flood LED                       present (=0)     <-- 0 is CORRECT when idle
  howdy ir_reader                    installed

--- live IR capture (needs root) ---
  SOF on csi2-2                      9 <-- STREAMING
```

Three of those lines are routinely misread, so to be explicit:

- **`/dev/ipu7-psys0 present`** is the load-bearing line for the RGB camera. If
  it says `MISSING`, the camera will not work no matter what else looks good.
- **`psys suspend patches 2/2` does NOT mean the psys stack is healthy.** It only
  counts two *suspend* fixes inside the built module. It can read `2/2` while
  `/dev/ipu7-psys0` is `MISSING` and the camera is completely dead. Always read
  the `psys0` line first; `2/2` answers a different question. (This line is
  absent entirely on distros that do not ship the DKMS psys module — also fine.)
- **`IR flood LED present (=0)`** — `0` is correct. The illuminator is off in
  standby by design and only lights during capture, matching Windows. A stock
  implementation leaves it on 24/7.

`link_frequency`, the LED and the capture lines only appear if you have the IR
sensor. On an RGB-only board (e.g. OV05C10 machines) their absence is normal.

### What a BROKEN machine prints

```
  /dev/ipu7-psys0                    MISSING
      -> intel_ipu7:      kernel
      -> intel_ipu7_psys: dkms
      -> split provenance means the defer check reads garbage. Fix:
         sudo kernel/ipu7-psys-patches/fix-psys-defer.sh
      -> kernel says:
           intel_ipu7_psys: probe deferred
      -> aux device: ABSENT (intel_ipu7 never created it)
  STALE MODULES (loaded build != build on disk):
      ipu_bridge  loaded=1a2b3c4d...  disk=9f8e7d6c...
      -> the running kernel is NOT using what you just built.
         Regenerate the initramfs and reboot:  sudo mkinitcpio -P
```

Two failure modes worth naming, because both cost real debugging hours:

1. **Split provenance.** `intel_ipu7` from the kernel + `intel_ipu7_psys` from
   DKMS means the two disagree about `struct ipu7_device`'s layout, so the
   readiness check reads the wrong offset and psys defers forever. `isys` binds
   normally because it ships with the kernel, which makes the failure look
   selective and sends people hunting the wrong component.
2. **Stale modules.** *A DKMS rebuild does not regenerate the initramfs.* If a
   module ships in the initramfs, the kernel keeps loading the **old** build no
   matter how many times you rebuild — and every downstream symptom points
   somewhere else. Fix with `sudo mkinitcpio -P` (Arch/CachyOS),
   `sudo dracut -f` (Fedora), or `sudo update-initramfs -u` (Debian/Ubuntu),
   then reboot.

For the RGB camera specifically:

```bash
cam --list                                         # expect 1 camera
cam --camera=1 --capture=5 --file=/tmp/test.raw    # expect 5 frames
```

For the IR node and CSI-2 port:

```bash
./tools/find-ir-node.sh
```

It reports the CSI-2 port as either `auto-detected from the sensor's link` or
`GUESSED — could not follow the sensor's link`. If it says GUESSED, the value is
a fallback and probably wrong for your machine — include that output in a report.

---

## Recovery — if the camera does not come back

**Nothing in this pack is in the boot path.** These are camera modules: `hm1092`,
`intel_cvs`, `ipu-bridge`, `int3472`, `ov05c10`. A module that fails to build or
load costs you a camera, not a bootable system. There is no scenario in which
removing them is required to boot.

**Your other kernels keep working copies.** The installer builds per-kernel, and
a failure on one kernel does not touch the modules already installed for another.
If a specific kernel misbehaves, pick a different entry in your bootloader menu
and you are back to a known state.

To back the whole thing out:

```bash
for m in intel-cvs hm1092 int3472-patched ipu-bridge-patched ov05c10; do
  sudo dkms remove -m $m -v 1.0 --all 2>/dev/null
done
sudo rm -f /etc/udev/rules.d/99-svp7500-no-autosuspend.rules \
           /etc/udev/rules.d/99-hm1092-ir-led.rules
sudo rm -rf /usr/src/intel-cvs-1.0 /usr/src/hm1092-1.0 \
            /usr/src/int3472-patched-1.0 /usr/src/ipu-bridge-patched-1.0 \
            /usr/src/ov05c10-1.0
sudo udevadm control --reload-rules
sudo mkinitcpio -P      # or: dracut -f  /  update-initramfs -u
sudo reboot
```

The installer backs up anything it replaces: previous `/usr/src/<module>-<ver>`
trees become `.bak-<timestamp>`, and Howdy's `video_capture.py` and
`config.ini` are copied aside the same way before being touched.

---

## Known-different hardware

The author's machine is **not** representative, and four things vary between
otherwise-similar laptops. All four are now discovered at runtime rather than
hardcoded:

| varies | example spread | how it is handled |
|---|---|---|
| **CSI-2 port** | port 2 on XPS 16 DA16260, **port 1** on Dell Pro 14 | followed from the sensor's own link in the media graph |
| **I2C bus number** | appears in the entity name (`hm1092 12-0024` vs `5-0024`) | entities resolved by name, never by bus |
| **Bridge ACPI id** | `INTC10E1` (PTL) vs **`INTC10DE`** (LNL), plus `INTC10CF`/`INTC10E0` | all four in the driver's match table |
| **IR LED ownership** | INT3472 owns the illuminator GPIO, not the sensor driver | udev rule grants the `video` group access so Howdy can fire it unprivileged |

`/dev/videoN`, `/dev/v4l-subdevN` and libcamera indexes **shuffle between boots**
even on one machine, so nothing should ever be hardcoded to a number.

These differences were only discoverable because people ran this on hardware the
author does not own and reported precisely what differed. Thanks to
**@acmodeu** (CSI-2 port 1 on the Dell Pro 14), **@Aohzan** (the `INTC10DE`
bridge id), and **@dalandro** (Dell Pro 14 Plus PB14250 on Ubuntu, OV05C10
sensor). Every one of those was a wrong assumption baked into the tooling.

---

## If it does not work, what to send me

Open an issue with the output of **all** of these. Every slow diagnosis so far
started with a report missing one of them — most often the module paths, which
are what reveal a stale or split-provenance install.

```bash
# 1. the whole stack, one command (this is the important one)
sudo ./tools/verify.sh 2>&1 | tee /tmp/svp7500-report.txt

# 2. environment
uname -r; head -2 /etc/os-release

# 3. what DKMS thinks is installed, for which kernels
dkms status

# 4. WHERE each module is actually loaded from — kernel vs updates/dkms.
#    This is what exposes split provenance and stale builds.
for m in intel_ipu7 intel_ipu7_isys intel_ipu7_psys ipu_bridge intel_cvs hm1092 ov05c10; do
  printf '%-20s %s\n' "$m" "$(modinfo -n $m 2>&1)"
done

# 5. kernel messages from the camera stack
sudo dmesg | grep -iE 'ipu7|ipu-bridge|intel_cvs|hm1092|ov08x40|ov05c10|int3472'

# 6. the media graph (entity names, ports, links)
media-ctl -d /dev/media0 -p

# 7. your hardware ids
lsusb -d 06cb:0701; ls /sys/bus/i2c/devices/ | grep -i INTC
```

For reference, a healthy install on the author's machine shows this provenance in
step 4 — `intel_ipu7`/`isys` from the kernel tree and the rest from
`updates/dkms`:

```
intel_ipu7           /lib/modules/<ver>/kernel/drivers/staging/media/ipu7/intel-ipu7.ko.zst
intel_ipu7_isys      /lib/modules/<ver>/kernel/drivers/staging/media/ipu7/intel-ipu7-isys.ko.zst
intel_ipu7_psys      /lib/modules/<ver>/updates/dkms/intel-ipu7-psys.ko.zst
ipu_bridge           /lib/modules/<ver>/updates/dkms/ipu-bridge.ko.zst
intel_cvs            /lib/modules/<ver>/updates/dkms/intel_cvs.ko.zst
hm1092               /lib/modules/<ver>/updates/dkms/hm1092.ko.zst
```

Paths differ legitimately across distros (`.ko` vs `.ko.zst`, `extra/` vs
`updates/dkms/`); what matters is that a module is not loaded from two places
and not older than what you just built.

Issue tracker: [intel/vision-drivers#37](https://github.com/intel/vision-drivers/issues/37)

---

## What's in here

6 components, each fixing a different piece of the broken stack.

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
- The driver is the out-of-tree Intel one from [`intel/ipu6-drivers`](https://github.com/intel/ipu6-drivers) (`drivers/media/i2c/ov05c10.c`); it was never mainlined, so affected boards have no RGB camera until it is installed. The bridge half already enumerates `OVTI05C1` — this supplies the missing sensor driver.
- Packaged as DKMS so it survives kernel upgrades. Builds clean against 6.18 / 7.0 / 7.1.

### 6. udev rules
- Disables USB autosuspend on the SVP7500. Bridge firmware has trouble with power state transitions; keeping it always-on prevents some failure modes.
- Grants the `video` group write access to the IR illuminator's brightness, so Howdy can fire it as an unprivileged user from a lock screen.

## Why this needed reverse engineering at all

The Synaptics SVP7500 is a proprietary MIPI bridge chip. Synaptics has not published its command reference publicly. Combined with the Intel IPU7 staging-driver stack (also fairly opaque), the camera "just doesn't work" on most Linux distros for affected laptops.

This fix pack is the result of three months of community reverse-engineering: USBPcap captures from Windows installs, Ghidra analysis of `Vision.sys`, kernel-side patches, and a lot of iteration.

### IR camera — SOLVED (2026-07-25)

The IR camera streams, and Howdy authenticates against it from the lock screen —
verified on the author's machine.

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

## License

The DKMS modules contain code from Intel (`intel-cvs`, `ipu-bridge`), Himax (sensor reference), and original work on top. License terms inherit from each upstream component — primarily GPL-2.0.

## Credits

- @jibsta210 — patch development, reverse engineering, testing
- @tverhaeghe — USBPcap traces from Windows on matching hardware (the key dataset)
- @acmodeu, @Aohzan, @dalandro — testing on hardware the author does not own; between them they surfaced the CSI-2 port, bridge ACPI id and sensor differences that the tooling now discovers instead of assuming
- Intel `vision-drivers` and `ipu7-drivers` upstream maintainers — for the base code we patched
- Hans de Goede (@hdegoede) — Linux mainline IPU6/7 camera maintainer
