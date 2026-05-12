#!/bin/bash
#
# Synaptics SVP7500 + Intel IPU7 camera fix pack — installer
#
# Restores RGB camera functionality on Linux for laptops with:
#   - Intel IPU7 (Panther Lake or Lunar Lake)
#   - Synaptics SVP7500 CVS bridge (USB 06CB:0701)
#   - OmniVision OV08x40 RGB sensor + Himax HM1092 IR sensor
#
# Tested platforms: Dell XPS 16 PB16250 (Panther Lake).
# Should also help: Dell Latitude 9440/7440/7450, Lenovo ThinkPad X9,
# ASUS Vivobook X1407Q, any other laptop with the SVP7500 bridge.
#
# What's included:
#   1. intel-cvs DKMS — bridge controller driver
#      * IRQF_ONESHOT fix (real kernel API bug — bridge stability)
#      * Verbatim RGB + IR 0x830 MIPI configs from Windows traces
#      * sysfs cmd interface for manual experiments
#   2. int3472-patched DKMS — ACPI power config helper
#      * IR LED GPIO type 0x02 support
#      * SSDB controllogicid fallback for USBIO platforms
#   3. ipu-bridge-patched DKMS — sensor enumeration helper
#      * HIMX1092 added to supported_sensors list
#   4. hm1092 DKMS — IR sensor driver
#      * Lazy IR LED (only on during streaming)
#      * 198-register Windows-faithful init sequence
#   5. udev rule — disable USB autosuspend for SVP7500
#      (bridge firmware can wedge on power state transitions)
#
# Status:
#   - RGB camera (port 0, ov08x40): expected to WORK after install
#   - IR camera (port 2, hm1092): probes cleanly, streaming still
#     under investigation (the bridge accepts our IR config but
#     port-2 MIPI forwarding requires more work)
#
# Requirements:
#   - DKMS (sudo dnf install dkms / sudo pacman -S dkms / etc.)
#   - Kernel headers matching your running kernel
#   - root / sudo access
#
# Source: https://github.com/intel/vision-drivers/issues/37
# Findings: https://gist.github.com/jibsta210/8316b6a0bc58910891512945c4e91a08

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
ok "==== Install complete ===="
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
echo "  Known issues:"
echo "    - IR camera (HM1092, Windows Hello) DOES NOT yet stream on Linux."
echo "      The sensor enumerates and the bridge accepts our IR config,"
echo "      but port-2 MIPI forwarding is still under investigation."
echo "      RGB camera should work normally."
echo ""
echo "  Found a bug? Report at https://github.com/intel/vision-drivers/issues/37"
echo "  Findings: https://gist.github.com/jibsta210/8316b6a0bc58910891512945c4e91a08"
