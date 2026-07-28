#!/bin/bash
# ===========================================================================
# ipu7 psys: stop dereferencing isp->ipu7_dir for the debugfs parent
#
#   sudo ./fix-psys-debugfs.sh [/usr/src/ipu7-drivers-<ver>]
#
# THE PROBLEM  --  THIS ONE OOPSES THE KERNEL DURING BOOT
#   ipu7_psys_init_debugfs() does:
#
#       dir = debugfs_create_dir("psys", psys->adev->isp->ipu7_dir);
#
#   `isp` points at a struct ipu7_device allocated by the KERNEL's intel_ipu7,
#   while DKMS psys was compiled against the ipu7-drivers headers. Where the
#   two disagree on that struct's layout, `ipu7_dir` is read at the wrong
#   offset and the "parent dentry" is whatever happens to sit there. Passing
#   that to debugfs_create_dir() is a wild pointer dereference in kernel
#   context:
#
#       Oops: general protection fault, probably LASS violation
#             for address 0x1010002
#       RIP: lookup_noperm_common+0x52/0xa0
#       Call Trace:
#        debugfs_create_dir+0x4b/0x160
#        ipu7_psys_probe+0x26c/0x3d0 [intel_ipu7_psys]
#        ...
#        ipu7_psys_module_init+0x36/0xff0 [intel_ipu7_psys]
#
#   Because this happens in module_init, driven by udev at boot, it takes the
#   udev worker down with it. The remaining workers then soft-lock:
#
#       watchdog: BUG: soft lockup - CPU#9 stuck for 26s! [modprobe:761]
#
#   Result: an UNBOOTABLE system, not merely a dead camera. Reported on a Dell
#   XPS 14 DA14260 running Arch 7.1.5, kernel built with CONFIG_DEBUG_FS=y
#   (which is the default on Arch, Fedora, Debian and Ubuntu).
#
# WHY IT ONLY APPEARS NOW
#   This code is only reached once psys probes far enough to get there. While
#   the bus was unregistered, probe died earlier at device_register() and this
#   line was unreachable. Fixing the bus (fix-psys-busreg.sh) makes probe get
#   further -- and straight into this. The two patches must ship together.
#
# THE FIX
#   Root the psys debugfs directory at the debugfs root instead of at a parent
#   read out of a struct whose layout we cannot trust:
#
#       dir = debugfs_create_dir("ipu7-psys", NULL);
#
#   NULL means "top of debugfs", which is always valid. The directory moves
#   from /sys/kernel/debug/ipu7/psys to /sys/kernel/debug/ipu7-psys -- a
#   cosmetic change to a debug-only path, in exchange for not dereferencing a
#   wild pointer. debugfs_create_dir() never returns NULL on failure and the
#   caller already handles IS_ERR, so nothing downstream changes.
# ===========================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

SRC="${1:-}"
if [[ -z $SRC ]]; then
  V=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
  [[ -n ${V:-} ]] || { echo "ipu7-drivers not installed under DKMS; pass the source dir"; exit 1; }
  SRC=/usr/src/ipu7-drivers-$V
fi

F="$SRC/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"
[[ -f $F ]] || { echo "not found: $F"; exit 1; }

if grep -q 'debugfs_create_dir("ipu7-psys", NULL)' "$F"; then
  echo "already applied: $F"
  exit 0
fi

if ! grep -q 'debugfs_create_dir("psys", psys->adev->isp->ipu7_dir)' "$F"; then
  echo "unexpected shape -- neither the fix nor the upstream call was found"
  grep -n 'debugfs_create_dir' "$F" || true
  exit 1
fi

cp -a "$F" "$F.pre-debugfs-$(date +%Y%m%d-%H%M%S)"

python3 - "$F" <<'PY'
import sys
path = sys.argv[1]
s = open(path).read()
old = 'debugfs_create_dir("psys", psys->adev->isp->ipu7_dir)'
new = 'debugfs_create_dir("ipu7-psys", NULL)'
if old not in s:
    sys.exit("could not find the debugfs call")
s = s.replace(old, new, 1)
open(path, "w").write(s)
print("  patched")
PY

echo
grep -n 'debugfs_create_dir' "$F" | sed 's/^/    /'
cat <<'EOF'

Now rebuild for EVERY installed kernel. 'dkms install --force' does NOT
recompile -- it reinstalls a cached artifact -- so the build step is required:

    V=$(dkms status | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
    for k in $(ls /lib/modules); do
      [ -d /lib/modules/$k/build ] || continue
      sudo dkms build   --force ipu7-drivers/$V -k $k
      sudo dkms install --force ipu7-drivers/$V -k $k
    done

Then REBOOT.

IF YOU CANNOT BOOT because this already crashed on you, add this to the kernel
command line from your bootloader (press `e` at the menu entry), boot once,
apply the fix, rebuild, then reboot normally:

    modprobe.blacklist=intel_ipu7_psys

That blocks only the psys module. Nothing else in this stack is in the boot
path, so the rest of the system comes up as usual -- without a camera.
EOF
