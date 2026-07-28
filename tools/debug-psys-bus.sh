#!/bin/bash
# ===========================================================================
# Instrument the psys bus lifecycle.
#
#   sudo ./debug-psys-bus.sh            # add the prints
#   sudo ./debug-psys-bus.sh --revert   # take them back out
#
# WHY
#   On intel/ipu7-drivers#26 a reporter's board fails with:
#
#       bus_add_device: cannot add device 'ipu7-psys0' to unregistered
#                       bus 'intel-ipu7-psys'
#       intel-ipu7-psys ipu7-psys0: psys device_register failed
#       probe with driver intel_ipu7_psys.psys failed with error -22
#
#   That is not a timing problem and never was. `bus_register()` runs in
#   ipu7_psys_module_init() BEFORE auxiliary_driver_register(), and on failure
#   module_init returns early -- so the driver could not have probed at all if
#   the bus had never been registered. Yet at probe time the bus is not there.
#
#   Three explanations remain, and they need different fixes:
#
#     1. bus_register() failed, and the module is loaded anyway (two copies,
#        or a partially-torn-down first load).
#     2. bus_register() succeeded and something unregistered it afterwards
#        (module_exit ran between the first deferred probe and the retry).
#     3. dev->bus points somewhere other than the registered bus_type.
#
#   These prints separate them in a single boot instead of another round of
#   log-reading. They are pure instrumentation: no behaviour changes.
# ===========================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

REVERT=0
[[ ${1:-} == --revert ]] && REVERT=1

V=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
[[ -n ${V:-} ]] || { echo "ipu7-drivers not installed under DKMS"; exit 1; }
F=/usr/src/ipu7-drivers-$V/drivers/media/pci/intel/ipu7/psys/ipu-psys.c
[[ -f $F ]] || { echo "not found: $F"; exit 1; }

if [[ $REVERT -eq 1 ]]; then
  python3 - "$F" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
# The dev_info form is `dev_info(dev, "BUSDBG ...` -- the tag is not the first
# argument, so anchoring on `(\"BUSDBG` misses it and leaves a print behind.
pat = r'^[ \t]*(?:pr_info|dev_info)\(.*"BUSDBG.*\n'
n = len(re.findall(pat, s, re.M))
s = re.sub(pat, '', s, flags=re.M)
open(p, "w").write(s)
print("  removed %d debug prints" % n)
PY
  exit 0
fi

if grep -q 'BUSDBG' "$F"; then
  echo "already instrumented: $F"
  exit 0
fi

cp -a "$F" "$F.pre-busdbg-$(date +%Y%m%d-%H%M%S)"

python3 - "$F" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()

# Raw strings throughout: python must not turn the C source's newline escape
# into a real newline, which would split the string literal and fail to build.
edits = [
  # 1. Did bus_register() actually succeed, and at what address?
  (r'(\tret = bus_register\(&ipu7_psys_bus\);\n)',
   r'\1\tpr_info("BUSDBG bus_register(%p name=%s) = %d\\n", &ipu7_psys_bus, ipu7_psys_bus.name, ret);\n'),

  # 2. Did the aux driver register? (its probe runs inside this call)
  (r'(\tret = auxiliary_driver_register\(&ipu7_psys_driver\);\n)',
   r'\1\tpr_info("BUSDBG auxiliary_driver_register = %d\\n", ret);\n'),

  # 3. Did anything tear the module down between defer and retry?
  (r'(static void __exit ipu7_psys_module_exit\(void\)\n\{\n)',
   r'\1\tpr_info("BUSDBG module_exit: unregistering bus %p\\n", &ipu7_psys_bus);\n'),

  # 4. At the failing call, is dev->bus the same pointer we registered?
  (r'(\tret = device_register\(&psys->dev\);\n)',
   r'\tdev_info(dev, "BUSDBG device_register(%s) dev.bus=%p registered=%p name=%s\\n", dev_name(&psys->dev), psys->dev.bus, &ipu7_psys_bus, psys->dev.bus ? psys->dev.bus->name : "NULL");\n\1'),
]

for pat, rep in edits:
    s, n = re.subn(pat, rep, s, count=1)
    if n != 1:
        sys.exit("could not place a probe point: %s" % pat[:50])

open(p, "w").write(s)
print("  4 debug prints placed")
PY

echo
grep -n 'BUSDBG' "$F" | sed 's/^/    /'
cat <<'EOF'

Rebuild for every installed kernel (build --force actually recompiles;
install --force alone only re-places a cached artifact), then reboot:

    V=$(dkms status | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
    for k in $(ls /lib/modules); do
      [ -d /lib/modules/$k/build ] || continue
      sudo dkms build   --force ipu7-drivers/$V -k $k
      sudo dkms install --force ipu7-drivers/$V -k $k
    done
    sudo reboot

Then send the WHOLE thing, not a tail:

    sudo dmesg | grep -iE 'BUSDBG|ipu7|psys'
    lsmod | grep -i ipu7
    ls /sys/bus/ | grep -i ipu

Reading it:

  no BUSDBG bus_register line at all
      the module in memory is not this build -- a second copy is winning

  bus_register = <negative>
      registration genuinely failed; the errno says why (-EEXIST => the name
      is already taken, i.e. two psys modules)

  bus_register = 0, and a module_exit line before the failure
      something unloaded the module while the probe was deferred

  bus_register = 0, no module_exit, and dev.bus != registered
      the device is pointing at a different bus_type than the one registered
EOF
