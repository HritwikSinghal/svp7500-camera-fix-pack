#!/bin/bash
# Swap our out-of-tree intel_cvs for the MAINLINE cvs driver
# (drivers/media/i2c/cvs, Miguel Vadillo, in-tree since 7.2-rc1).
#
# WHY: if mainline works, the out-of-tree surface drops from five DKMS modules
# to one sensor driver, which changes the upstreaming story completely.
#
# SAFETY
#   * Touches camera modules only. Not boot-critical, not in the initramfs
#     (verified: mkinitcpio MODULES has no cvs/hm1092 entry).
#   * Bootloader, kernel and initramfs are untouched.
#   * Worst case: the camera does not work until you run --revert.
#   * hm1092 references cvs_send_mipi_ir_config as a WEAK symbol and guards the
#     call, so it still loads with mainline cvs; that call simply becomes a
#     no-op. Harmless -- Windows never sends an IR 0x830 either.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

K=$(uname -r)
DST=/lib/modules/$K/updates/cvs.ko
BL=/etc/modprobe.d/99-try-mainline-cvs.conf
BUILD=${BUILD:-/tmp/cvs-mainline-build}

case "${1:-}" in
--revert)
    echo "==> reverting to out-of-tree intel_cvs"
    rm -f "$BL" "$DST"
    depmod -a "$K"
    echo "    removed $BL"
    echo "    removed $DST"
    echo "    REBOOT to restore the original driver"
    exit 0 ;;
--status)
    echo "  blacklist file : $([ -f "$BL" ] && echo PRESENT || echo absent)"
    echo "  mainline cvs.ko: $([ -f "$DST" ] && echo installed || echo absent)"
    echo "  loaded now     : $(lsmod | grep -E '^intel_cvs|^cvs ' | awk '{print $1}' | paste -sd, - || echo none)"
    exit 0 ;;
esac

[[ -f $BUILD/cvs.ko ]] || {
    echo "build the mainline module first:"
    echo "  make -C /lib/modules/\$(uname -r)/build M=$BUILD CC=clang LD=ld.lld LLVM=1 modules"
    exit 1; }

echo "==> installing mainline cvs.ko"
install -D -m 0644 "$BUILD/cvs.ko" "$DST"

echo "==> blacklisting the out-of-tree intel_cvs"
cat > "$BL" <<'CONF'
# Temporary: test the mainline cvs driver (drivers/media/i2c/cvs) in place of
# the out-of-tree intel_cvs. Both claim ACPI INTC10DE / INTC10E0 / INTC10E1, so
# only one may bind.
#
# NOTE: "blacklist" alone is NOT enough here. It only suppresses automatic
# loading by alias; it does not stop a module being pulled in as a DEPENDENCY,
# and hm1092 references intel_cvs (weak symbol cvs_send_mipi_ir_config). A
# blacklist-only attempt on 2026-07-26 left BOTH drivers loaded, fighting over
# the same bridge, and broke the camera -- which looked like mainline cvs
# failing when it had simply never been given the chance to bind.
#
# "install ... /bin/false" blocks dependency loading too.
#
# Undo with:  tools/try-mainline-cvs.sh --revert   (then reboot)
blacklist intel_cvs
install intel_cvs /bin/false
CONF

depmod -a "$K"
echo
echo "    installed : $DST"
echo "    blacklist : $BL"
echo
echo "    REBOOT, then check:"
echo "      lsmod | grep -E '^cvs|^intel_cvs'     # expect cvs, not intel_cvs"
echo "      sudo tools/verify.sh"
echo "      dmesg | grep -i cvs"
echo
echo "    If anything misbehaves:"
echo "      sudo tools/try-mainline-cvs.sh --revert && reboot"
