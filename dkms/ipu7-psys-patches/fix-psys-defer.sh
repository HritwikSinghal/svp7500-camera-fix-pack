#!/bin/bash
# ===========================================================================
# ipu7 psys: bound the ready_to_probe wait instead of trusting or ignoring it
#
#   sudo ./fix-psys-defer.sh [/usr/src/ipu7-drivers-<ver>]
#
# THE PROBLEM
#   psys probe opens with
#
#       if (!isp->ipu7_bus_ready_to_probe)
#               return -EPROBE_DEFER;
#
#   `isp` points at a struct ipu7_device allocated by the KERNEL's intel_ipu7,
#   while DKMS psys was built against the ipu7-drivers headers. Where the two
#   disagree on that struct's layout the read lands at the wrong offset and the
#   flag never reads true, so psys defers forever: /dev/ipu7-psys0 never
#   appears, PipeWire's libcamera monitor finds nothing, and every application
#   sees no camera at all -- while `cam -l` and `cam -c` from a terminal work
#   perfectly, which is what makes this so easy to misdiagnose.
#
# WHY THIS IS NOT AN UNCONDITIONAL SKIP ANY MORE
#   It used to replace the condition with `if (0)`. That is correct on a machine
#   where the flag never arrives, and WRONG on one where it would have: skipping
#   the wait lets psys probe before intel_ipu7 has finished, and
#   device_register() then fails with -EINVAL. Measured on two boards
#   (intel/ipu7-drivers#26):
#
#       this author's Dell XPS 16   skip needed    without it psys never binds
#       a reporter's Dell           skip harmful   with it, device_register -22
#
#   Both are explained by the same thing: the flag is simply not ready at first
#   probe. All that differs is whether proceeding anyway is survivable. So the
#   right behaviour is neither "always trust the flag" nor "never trust it" --
#   it is WAIT FOR IT, BOUNDED, and proceed only once waiting has clearly
#   failed.
#
# WHAT THIS DOES
#   Defer while the flag is false, up to PSYS_READY_TIMEOUT_S seconds from the
#   first attempt. Past that, warn loudly and proceed. On a board where the flag
#   arrives, psys now probes at the RIGHT time instead of too early. On a board
#   where it never arrives, the deadline expires and behaviour is what the old
#   skip gave -- so nothing that works today regresses.
# ===========================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

TIMEOUT_S=${PSYS_READY_TIMEOUT_S:-10}

SRC="${1:-}"
if [[ -z $SRC ]]; then
  V=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
  [[ -n ${V:-} ]] || { echo "ipu7-drivers not installed under DKMS; pass the source dir"; exit 1; }
  SRC=/usr/src/ipu7-drivers-$V
fi

F="$SRC/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"
[[ -f $F ]] || { echo "not found: $F"; exit 1; }

if grep -q 'psys_ready_deadline' "$F"; then
  echo "already applied: $F"
  exit 0
fi

# Accept either the pristine condition or the old unconditional skip, so a tree
# carrying the previous version of this fix upgrades cleanly rather than being
# reported as an unknown shape.
if grep -qE 'if \(!.*ipu7_bus_ready_to_probe\)' "$F"; then
  OLD='if (!adev->isp->ipu7_bus_ready_to_probe)'
elif grep -q 'DKMS struct layout mismatch' "$F"; then
  OLD='if (0) /* DKMS struct layout mismatch; skip defer */'
else
  echo "neither the defer check nor the old skip was found in $F"
  echo "inspect by hand:"
  grep -n 'ready_to_probe\|EPROBE_DEFER' "$F" || true
  exit 1
fi

cp -a "$F" "$F.pre-deferfix-$(date +%Y%m%d-%H%M%S)"

python3 - "$F" "$OLD" "$TIMEOUT_S" <<'PY'
import sys, re
path, old, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = open(path).read()

# NL is assembled at runtime. Writing a literal backslash-n inside a template
# that passes through a shell heredoc turns it into a REAL newline and splits
# the C string literal, which does not compile. This has bitten this project
# before; build the escape rather than typing it.
NL = chr(92) + "n"

new = (
 "/*\n"
 "\t * Wait for intel_ipu7 to declare itself ready, but not forever.\n"
 "\t *\n"
 "\t * Where DKMS psys and an in-kernel intel_ipu7 disagree about struct\n"
 "\t * ipu7_device's layout this flag is read at the wrong offset and never\n"
 "\t * reads true, so psys would defer for the whole boot and no application\n"
 "\t * would ever see a camera. Where the layouts DO agree the flag is\n"
 "\t * meaningful, and skipping the wait makes psys probe too early, which\n"
 "\t * then fails in device_register() with -EINVAL.\n"
 "\t *\n"
 "\t * So defer while it is false, up to %ds from the first attempt, then\n"
 "\t * proceed and say so. Both boards in intel/ipu7-drivers#26 are satisfied\n"
 "\t * by this; neither is by a fixed answer in either direction.\n"
 "\t */\n"
 "\tif (!adev->isp->ipu7_bus_ready_to_probe) {\n"
 "\t\tstatic unsigned long psys_ready_deadline;\n"
 "\n"
 "\t\tif (!psys_ready_deadline)\n"
 "\t\t\tpsys_ready_deadline = jiffies + %d * HZ;\n"
 "\n"
 "\t\tif (time_before(jiffies, psys_ready_deadline))\n"
 "\t\t\treturn -EPROBE_DEFER;\n"
 "\n"
 "\t\tdev_warn(dev,\n"
 '\t\t\t "ipu7_bus_ready_to_probe still clear after %ds; proceeding anyway%s");\n'
 "\t}"
) % (timeout, timeout, timeout, NL)

pat = re.escape(old) + r'\s*\n\s*return -EPROBE_DEFER;'
if not re.search(pat, s):
    sys.exit("could not match the defer statement")
s = re.sub(pat, lambda _: new, s, count=1)
open(path, "w").write(s)
print("  patched")
PY

echo
grep -n -A6 'psys_ready_deadline' "$F" | head -12 | sed 's/^/    /'
cat <<EOF

Now rebuild for EVERY installed kernel. 'dkms install --force' does NOT
recompile -- it reinstalls a cached artifact -- so the build step is required:

    V=\$(dkms status | sed -n 's|^ipu7-drivers/\\([^,]*\\),.*installed.*|\\1|p' | head -1)
    for k in \$(ls /lib/modules); do
      [ -d /lib/modules/\$k/build ] || continue
      sudo dkms build   --force ipu7-drivers/\$V -k \$k
      sudo dkms install --force ipu7-drivers/\$V -k \$k
    done

Then REBOOT. Do not modprobe -r intel_ipu7_psys to pick it up live: it page
faults in ipu7_fw_psys_close even at refcount 0.
EOF
