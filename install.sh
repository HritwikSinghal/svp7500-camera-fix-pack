#!/bin/bash
#
# Synaptics SVP7500 + Intel IPU7 camera fix pack — installer (v0.4)
#
# v0.4 adds (over v0.3):
#   - intel-cvs: HOST_SET_MIPI_CONFIG (0x830) is now sent as 5 separate I2C
#     transactions of 52/52/52/52/48 bytes (matching Windows USBPcap wire
#     pattern exactly, instead of one 256-byte transaction split at USB layer)
#   - Patched in-tree usbio.ko adding USBIO_QUIRK_I2C_ALLOW_400KHZ for
#     Synaptics 06cb:0701 (matches Lattice NX33 quirk pattern; gets I2C from
#     100kHz → 400kHz, eliminating "Invalid speed" log spam)
#   - intel_cvs: new sysfs commands `cmd-NNNN` (raw 2-byte opcode probe),
#     `set-vision`, `factory-reset` for further investigation
#   - hm1092: 3 runtime-tunable module params for IR experimentation
#     (mipi_ir_delay_ms, dump_regs_on_stream, ae_kick_period_ms)
#
# Note: IR streaming is still NOT working on Linux (gap is bridge-side and
# appears to be in the secure firmware/CSE handshake path that's missing the
# ivsc_pkg_himx1092_0.bin firmware blob). RGB camera (OV08X40) WORKS, twice
# independently confirmed. See intel/ipu7-drivers#51 + #72 for full details.
#
# Restores RGB camera functionality on Linux for laptops with:
#   - Intel IPU7 (Panther Lake or Lunar Lake)
#   - Synaptics SVP7500 CVS bridge (USB 06CB:0701)
#   - OmniVision OV08x40 RGB sensor + Himax HM1092 IR sensor
#
# Tested platforms (confirmed working):
#   - Dell XPS 16 PB16250 / Panther Lake (CachyOS 7.0.5-2-cachyos-susfix)
#   - Dell XPS 16 DA16260 / Panther Lake (Fedora 44 Silverblue 7.0.4-200, via
#     @tverhaeghe intel/vision-drivers#37 comment 4433909742, RGB-only)
#
# Should also help (untested, please report):
#   - Dell Latitude 9440/7440/7450, Lenovo ThinkPad X9,
#     ASUS Vivobook X1407Q, any other laptop with the SVP7500 bridge.
#
# What's included:
#   1. intel-cvs DKMS — bridge controller driver
#      * IRQF_ONESHOT fix (real kernel API bug — bridge stability)
#      * Verbatim RGB + IR 0x830 MIPI configs from Windows USBPcap traces
#      * sysfs cmd interface: [state, version, id, reset, acquire,
#        mipi, mipi-ir, replay-rgb-init]
#      * NEW v0.3: cvs_replay_rgb_hello_init() — kernel-side replay of 344
#        Windows-Hello RGB sensor writes (calibration LUT to 0x005b-0x005e)
#        via i2c_transfer(). Triggered via `echo replay-rgb-init > .../cmd`.
#      * NEW v0.3: cvs_send_mipi_ir_config() exported for hm1092 to call
#        kernel-internally (matching Windows-Hello sensor-streams-first order).
#   2. int3472-patched DKMS — ACPI power config helper
#      * IR LED GPIO type 0x02 support
#      * SSDB controllogicid fallback for USBIO platforms
#   3. ipu-bridge-patched DKMS — sensor enumeration helper
#      * HIMX1092 added to supported_sensors list
#   4. hm1092 DKMS — IR sensor driver
#      * Lazy IR LED (only on during streaming)
#      * 240-register Windows-faithful init sequence
#      * NEW v0.3: hm1092_set_stream(1) calls cvs_send_mipi_ir_config()
#        AFTER writing MODE_SELECT=0x01 (Windows-Hello ordering)
#      * NEW v0.3: 3 diagnostic module params for runtime IR experimentation:
#        - mipi_ir_delay_ms       (ms between MODE_SELECT and bridge 0x830)
#        - dump_regs_on_stream    (log 0x4b20/0x0101 chip-vs-init at stream)
#        - ae_kick_period_ms      (periodic 0x0104=0x01 every N ms)
#        Tune via /sys/module/hm1092/parameters/* — no rebuild needed.
#      * NEW v0.3: sysfs 'stream' attr at /sys/bus/i2c/.../i2c-HIMX1092:00/
#   5. udev rule — disable USB autosuspend for SVP7500
#      (bridge firmware can wedge on power state transitions)
#
# Status:
#   - RGB camera (port 0, ov08x40): WORKS after install (2 independent confirms)
#   - IR camera (port 2, hm1092): still under investigation
#     * Sensor: enumerates, probes, reaches MODE_SELECT=0x01 streaming
#     * Bridge: accepts our verbatim IR 0x830 (returns success)
#     * Gap: bridge does not forward port-2 MIPI (verified via direct
#       IPU7 CSI-2 MMIO read — zero packets received)
#     * Hypotheses tested + eliminated 2026-05-12:
#       - OTP register mismatch (read live, values match init)
#       - Windows-trace 182ms sensor-to-bridge timing gap
#       - AE-loop periodic 0x0104=0x01 (Windows fires every ~132ms)
#     * Under investigation: iaisptrustlet64.dll RE for post-0x830 trigger
#
# Requirements:
#   - DKMS (sudo dnf install dkms / sudo pacman -S dkms / etc.)
#   - Kernel headers matching your running kernel
#   - root / sudo access
#
# Source: https://github.com/intel/vision-drivers/issues/37
# Findings: https://gist.github.com/jibsta210/8316b6a0bc58910891512945c4e91a08
# Repo:    https://github.com/jibsta210/svp7500-camera-fix-pack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="${KVER:-$(uname -r)}"
KEEP_GOING=${KEEP_GOING:-0}

log()  { echo -e "\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[X]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo $0)"

log "SVP7500 camera fix pack installer"
log "Target kernel: $KVER"
log ""

# Pre-flight
log "Pre-flight checks..."
command -v dkms >/dev/null || die "DKMS not found. Install with: dnf install dkms (Fedora) / pacman -S dkms (Arch) / apt install dkms (Debian)"

KHDR="/lib/modules/$KVER/build"
[[ -d "$KHDR" ]] || die "Kernel headers not found at $KHDR. Install with: dnf install kernel-devel (Fedora) / pacman -S linux-headers (Arch) / apt install linux-headers-$(uname -r) (Debian)"
ok "DKMS + kernel headers present"

# Mandatory: back up vmlinuz + initramfs before touching anything kernel-side.
# Even though our DKMS modules are camera-only (not on the boot path),
# any DKMS install + udev change can theoretically affect boot. Cheap insurance.
log ""
log "Backing up vmlinuz + initramfs before install..."
BAK_TS=$(date +%Y%m%d-%H%M%S)
BAK_SUFFIX=".pre-svp7500-fix.${BAK_TS}.bak"
BACKED_UP=0

# vmlinuz (kernel image) — common locations
for vmlinuz in /boot/vmlinuz-"$KVER" /boot/vmlinuz-linux /boot/vmlinuz-linux-* /boot/vmlinuz; do
    if [[ -f "$vmlinuz" && ! -L "$vmlinuz" ]]; then
        cp -a "$vmlinuz" "${vmlinuz}${BAK_SUFFIX}"
        ok "  vmlinuz   → ${vmlinuz}${BAK_SUFFIX}"
        BACKED_UP=$((BACKED_UP + 1))
    fi
done

# initramfs (multiple distro naming conventions)
for initrd in /boot/initramfs-"$KVER".img /boot/initramfs-linux*.img /boot/initrd.img-"$KVER" /boot/initrd.img-* /boot/initramfs*.img; do
    if [[ -f "$initrd" && "$initrd" != *.bak ]]; then
        cp -a "$initrd" "${initrd}${BAK_SUFFIX}"
        ok "  initramfs → ${initrd}${BAK_SUFFIX}"
        BACKED_UP=$((BACKED_UP + 1))
    fi
done

if [[ $BACKED_UP -eq 0 ]]; then
    warn "  Could not auto-detect kernel/initramfs files to back up."
    warn "  You probably have a non-standard /boot layout."
    warn "  Strongly recommend backing up manually before continuing."
    warn "  Press Ctrl-C now to abort, or wait 10 seconds to continue..."
    sleep 10
else
    ok "Backed up $BACKED_UP file(s). Restore: cp <file>${BAK_SUFFIX} <file> if needed."
fi

# Bonus: if user has snapper, take a system snapshot too
if command -v snapper >/dev/null 2>&1 && snapper -c root list >/dev/null 2>&1; then
    if snapper -c root create --description "pre-svp7500-camera-fix-pack" 2>/dev/null; then
        ok "Snapper Btrfs snapshot created (root config)"
    fi
fi
log ""

# Check for SVP7500 hardware
if lsusb -d 06cb:0701 >/dev/null 2>&1; then
    ok "Synaptics SVP7500 (06CB:0701) detected"
else
    warn "Synaptics SVP7500 not detected via USB — installing anyway in case hardware appears later"
fi

# Install each DKMS module
install_dkms() {
    local name="$1"
    local version="$2"
    local srcdir="$SCRIPT_DIR/dkms/$name-$version"

    [[ -d "$srcdir" ]] || { warn "Source dir $srcdir not found, skipping"; return 1; }

    log "Installing $name-$version..."

    # Remove old version if present
    if dkms status | grep -q "^$name/"; then
        log "  removing existing $name install"
        dkms remove -m "$name" -v "$version" --all 2>/dev/null || true
    fi

    # Copy source
    if [[ -d "/usr/src/$name-$version" ]]; then
        log "  /usr/src/$name-$version exists, backing up to .bak"
        rm -rf "/usr/src/$name-$version.bak"
        mv "/usr/src/$name-$version" "/usr/src/$name-$version.bak"
    fi
    cp -a "$srcdir" "/usr/src/"

    # Add + install
    dkms add "$name/$version" 2>/dev/null || true
    if dkms install "$name/$version" -k "$KVER"; then
        ok "  $name-$version installed for $KVER"
    else
        warn "  $name-$version build FAILED for $KVER"
        if [[ "$KEEP_GOING" != "1" ]]; then
            warn "  Set KEEP_GOING=1 to continue past failures"
            return 1
        fi
    fi
}

# Order matters — bridge first, then power helpers, then sensors
install_dkms "intel-cvs" "1.0"        || true
install_dkms "int3472-patched" "1.0"  || true
install_dkms "ipu-bridge-patched" "1.0" || true
install_dkms "hm1092" "1.0"           || true

# Patched in-tree usbio.ko (adds USBIO_QUIRK_I2C_ALLOW_400KHZ for Synaptics 06cb:0701)
# Only install if (a) the bridge is present and (b) we have an MOK signing key.
log ""
log "Considering patched usbio.ko (in-tree module — adds 400KHz quirk for SVP7500)..."
if ! lsusb -d 06cb:0701 >/dev/null 2>&1; then
    warn "  Synaptics SVP7500 (06CB:0701) not present — skipping usbio patch"
elif [[ ! -f /var/lib/dkms/mok.key ]] || [[ ! -f /var/lib/dkms/mok.pub ]]; then
    warn "  No DKMS MOK key found at /var/lib/dkms/ — skipping usbio patch"
    warn "  (the patched usbio.ko needs to be signed for Secure Boot)"
else
    USBIO_DIR="$SCRIPT_DIR/usbio-patch"
    BACKUP_DIR=/var/cache/svp7500-fix-pack
    mkdir -p "$BACKUP_DIR"

    # Build out-of-tree against the running kernel
    log "  building patched usbio.ko..."
    if (cd "$USBIO_DIR" && make 2>&1 | tail -5); then
        # Strip + sign + compress
        strip --strip-debug "$USBIO_DIR/usbio.ko" 2>/dev/null || true
        /lib/modules/"$KVER"/build/scripts/sign-file sha256 \
            /var/lib/dkms/mok.key /var/lib/dkms/mok.pub "$USBIO_DIR/usbio.ko"
        zstd -f --rm "$USBIO_DIR/usbio.ko" 2>&1 | tail -1

        # Backup the in-tree original ONCE (preserves the very first one — never overwrites)
        ORIG=/lib/modules/"$KVER"/kernel/drivers/usb/misc/usbio.ko.zst
        if [[ ! -f "$BACKUP_DIR/usbio.ko.zst.orig" ]] && [[ -f "$ORIG" ]]; then
            cp "$ORIG" "$BACKUP_DIR/usbio.ko.zst.orig"
            ok "  backed up original usbio.ko.zst → $BACKUP_DIR/usbio.ko.zst.orig"
        fi

        # Install
        cp "$USBIO_DIR/usbio.ko.zst" "$ORIG"
        depmod -a
        ok "  patched usbio.ko installed (revert: cp $BACKUP_DIR/usbio.ko.zst.orig $ORIG && depmod -a && reboot)"
    else
        warn "  usbio build failed — skipping (existing module unchanged, RGB still works without this patch)"
    fi
fi

# Install udev rule
log ""
log "Installing udev rule..."
cp "$SCRIPT_DIR/udev/99-svp7500-no-autosuspend.rules" /etc/udev/rules.d/
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --action=change 2>/dev/null || true
ok "udev rule installed and reloaded"

# Final report
echo ""
log "Installed DKMS modules:"
dkms status | grep -E '(intel-cvs|hm1092|int3472|ipu-bridge)' || warn "No fix-pack DKMS modules showing as installed"

echo ""
ok "==== Install complete (v0.4) ===="
echo ""
echo "  Next steps:"
echo "    1. REBOOT to load the new modules cleanly"
echo "    2. After reboot, check kernel log for the bridge probe:"
echo "         sudo dmesg | grep -E 'Intel CVS|hm1092'"
echo "       You should see 'cvs_common_probe:Transfer of ownership success'"
echo "       and NO 'WARNING: kernel/irq/manage.c:1502 at __setup_irq'"
echo ""
echo "    3. Test the RGB camera with libcamera:"
echo "         cam --list             # should show your front camera"
echo "         cam --camera=1 --capture=5 --file=/tmp/test.raw"
echo ""
echo "  RGB camera works. IR is still under investigation. Help us narrow it:"
echo ""
echo "    A. After reboot, please post a comment on intel/vision-drivers#37"
echo "       with: (a) your laptop model, (b) lsusb -d 06cb:0701 output,"
echo "       (c) whether 'cam --camera=1 --capture=10' captures 10 frames."
echo ""
echo "    B. New in v0.3: diagnostic sysfs surfaces for IR experimentation:"
echo "       - /sys/bus/i2c/devices/i2c-INTC10E1:00/cmd"
echo "         accepts: state, version, id, reset, acquire, mipi,"
echo "                  mipi-ir, replay-rgb-init"
echo "       - /sys/module/hm1092/parameters/{mipi_ir_delay_ms,"
echo "         dump_regs_on_stream, ae_kick_period_ms}"
echo "         tunable at runtime (no rebuild needed)"
echo ""
echo "  Known issues:"
echo "    - IR camera (HM1092, Windows Hello) DOES NOT yet stream."
echo "      Three hypotheses systematically ruled out 2026-05-12:"
echo "      OTP mismatch, sensor->bridge timing, AE-loop kicks."
echo "      Current investigation: iaisptrustlet64.dll RE."
echo ""
echo "  Found a bug? Report at https://github.com/intel/vision-drivers/issues/37"
echo "  Repo + releases:  https://github.com/jibsta210/svp7500-camera-fix-pack"
echo "  Findings writeup: https://gist.github.com/jibsta210/8316b6a0bc58910891512945c4e91a08"
