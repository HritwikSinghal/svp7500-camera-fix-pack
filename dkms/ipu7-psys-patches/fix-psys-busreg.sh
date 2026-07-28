#!/bin/bash
# ===========================================================================
# ipu7 psys: register the intel-ipu7-psys bus before the aux driver
#
#   sudo ./fix-psys-busreg.sh [/usr/src/ipu7-drivers-<ver>]
#
# THE PROBLEM
#   psys defines its own bus and puts its char device on it:
#
#       static const struct bus_type ipu7_psys_bus = {
#               .name = "intel-ipu7-psys",
#       };
#       ...
#       psys->dev.bus = &ipu7_psys_bus;
#       ret = device_register(&psys->dev);
#
#   but the module registers itself with
#
#       module_auxiliary_driver(ipu7_psys_driver);
#
#   which registers the AUXILIARY DRIVER ONLY. `bus_register(&ipu7_psys_bus)`
#   is never called anywhere in the tree, so that bus does not exist.
#
#   Kernels up to ~7.0 tolerated registering a device onto an unregistered bus.
#   Kernel 7.1 hardened `bus_add_device()` to reject it, so probe now dies:
#
#       bus_add_device: cannot add device 'ipu7-psys0' to unregistered bus
#                       'intel-ipu7-psys'
#       intel-ipu7-psys ipu7-psys0: psys device_register failed
#       probe with driver intel_ipu7_psys.psys failed with error -22
#
#   -22 is -EINVAL from that rejection. No /dev/ipu7-psys0, so PipeWire's
#   libcamera monitor enumerates nothing and every application reports no
#   camera -- while `cam -l` and `cam -c` still work, which makes this very
#   easy to misread as a libcamera or PipeWire problem.
#
# NOT THE SAME BUG AS THE DEFER ONE
#   fix-psys-defer.sh addresses psys never being allowed to *start* probing.
#   This addresses probing correctly and then failing at the last step. A board
#   can need one, the other, or both. If you are seeing -22 rather than a
#   silent never-binds, this is your fix and the defer timeout is irrelevant.
#
# WHY IT IS SAFE EVERYWHERE
#   Registering a bus before putting devices on it is simply correct. On
#   kernels that tolerated the omission this changes nothing observable; on
#   7.1+ it is the difference between a working camera and no camera. So it is
#   applied unconditionally rather than gated on a version test.
#
#   Reported upstream: intel/ipu7-drivers (see the fix-pack README).
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

if grep -q 'bus_register(&ipu7_psys_bus)' "$F"; then
  echo "already applied: $F"
  exit 0
fi

if ! grep -q 'module_auxiliary_driver(ipu7_psys_driver);' "$F"; then
  echo "unexpected shape -- neither the fix nor the upstream registration was found"
  grep -n 'module_auxiliary_driver\|module_init\|bus_register' "$F" || true
  exit 1
fi

cp -a "$F" "$F.pre-busreg-$(date +%Y%m%d-%H%M%S)"

python3 - "$F" <<'PY'
import sys
path = sys.argv[1]
s = open(path).read()

# De-const the bus so this also builds on kernels whose bus_register() still
# takes a non-const pointer (the driver-core const conversion landed mid-6.x).
# Harmless on newer kernels -- it only moves the struct out of .rodata.
s = s.replace(
    "static const struct bus_type ipu7_psys_bus = {",
    "static struct bus_type ipu7_psys_bus = {",
)

old = "module_auxiliary_driver(ipu7_psys_driver);"
new = """/*
 * Register the psys bus before the auxiliary driver.
 *
 * module_auxiliary_driver() registers only the aux driver, but probe puts its
 * char device on the custom `intel-ipu7-psys` bus, which nothing ever
 * registers. Kernel 7.1 hardened bus_add_device() to reject that, so
 * device_register() returns -EINVAL and /dev/ipu7-psys0 is never created.
 */
static int __init ipu7_psys_module_init(void)
{
\tint ret;

\tret = bus_register(&ipu7_psys_bus);
\tif (ret)
\t\treturn ret;
\tret = auxiliary_driver_register(&ipu7_psys_driver);
\tif (ret)
\t\tbus_unregister(&ipu7_psys_bus);
\treturn ret;
}
module_init(ipu7_psys_module_init);

static void __exit ipu7_psys_module_exit(void)
{
\tauxiliary_driver_unregister(&ipu7_psys_driver);
\tbus_unregister(&ipu7_psys_bus);
}
module_exit(ipu7_psys_module_exit);"""

if old not in s:
    sys.exit("could not find the registration macro")

s = s.replace(old, new, 1)
open(path, "w").write(s)
print("  patched")
PY

echo
grep -n 'bus_register\|module_init(ipu7_psys\|module_exit(ipu7_psys' "$F" | sed 's/^/    /'
cat <<'EOF'

Now rebuild for EVERY installed kernel. 'dkms install --force' does NOT
recompile -- it reinstalls a cached artifact -- so the build step is required:

    V=$(dkms status | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
    for k in $(ls /lib/modules); do
      [ -d /lib/modules/$k/build ] || continue
      sudo dkms build   --force ipu7-drivers/$V -k $k
      sudo dkms install --force ipu7-drivers/$V -k $k
    done

Then REBOOT. Do not modprobe -r intel_ipu7_psys to pick it up live: it page
faults in ipu7_fw_psys_close even at refcount 0.

Afterwards /sys/bus/intel-ipu7-psys should exist and /dev/ipu7-psys0 with it.
EOF
