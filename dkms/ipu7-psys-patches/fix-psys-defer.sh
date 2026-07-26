#!/bin/bash
# ===========================================================================
# ipu7 psys: neutralise the ready_to_probe defer check
#
# SYMPTOM
#   /dev/ipu7-psys0 never appears. isys binds fine, psys does not. The RGB
#   camera is missing from `cam -l`, and libcamera has no pipeline to run.
#
# CAUSE
#   psys probe starts with
#       if (!isp->ipu7_bus_ready_to_probe)
#               return -EPROBE_DEFER;
#   `isp` points at a struct ipu7_device that was allocated by the KERNEL's
#   intel_ipu7 module, but the DKMS psys module was compiled against the
#   ipu7-drivers headers. The two disagree on the layout of that struct, so the
#   read lands at the wrong offset, returns garbage, and the check never passes.
#   psys defers forever.
#
#   Check your own machine:
#       modinfo -n intel_ipu7        # kernel/drivers/staging/media/ipu7/...
#       modinfo -n intel_ipu7_psys   # updates/dkms/...
#   Split provenance like that is the trigger. If both come from the same place
#   the layouts agree and you do not need this patch.
#
#   isys performs the identical check but ships from the kernel alongside
#   intel_ipu7, so its view of the struct is consistent and it binds normally.
#   That asymmetry is why the failure looks so selective.
#
# WHY A SCRIPT AND NOT A .patch
#   The surrounding code moves between ipu7-drivers revisions (r74 carries a
#   debugfs block that r76 does not, and so on), so a context diff rejects on
#   versions it was not generated against. This edits the one line by pattern.
#
# USAGE
#   sudo ./fix-psys-defer.sh                 # auto-detect the DKMS-installed tree
#   sudo ./fix-psys-defer.sh /usr/src/ipu7-drivers-rNN.xxxxx
# ===========================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

SRC="${1:-}"
if [[ -z $SRC ]]; then
  # Pick the tree DKMS actually HAS INSTALLED. `ls | tail -1` grabs a stale
  # leftover tree and silently patches source that is never built.
  V=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
  [[ -n ${V:-} ]] || { echo "ipu7-drivers not installed under DKMS; pass the source dir"; exit 1; }
  SRC=/usr/src/ipu7-drivers-$V
fi

F="$SRC/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"
[[ -f $F ]] || { echo "not found: $F"; exit 1; }

if grep -q 'DKMS struct layout mismatch' "$F"; then
  echo "already applied: $F"
  exit 0
fi

if ! grep -qE 'if \(!.*ipu7_bus_ready_to_probe\)' "$F"; then
  echo "defer check not found in $F"
  echo "either this revision dropped it, or the pattern changed — inspect by hand:"
  grep -n 'ready_to_probe\|EPROBE_DEFER' "$F" || true
  exit 1
fi

cp -a "$F" "$F.pre-deferfix-$(date +%Y%m%d-%H%M%S)"
sed -i -E 's|if \(!.*ipu7_bus_ready_to_probe\)|if (0) /* DKMS struct layout mismatch; skip defer */|' "$F"

echo "patched: $F"
grep -n -A1 'DKMS struct layout mismatch' "$F" | sed 's/^/    /'
cat <<'EOF'

Now rebuild for EVERY installed kernel, not just the running one -- building
only $(uname -r) leaves the others with an unpatched psys and a dead camera
after the next boot into them:

    V=$(dkms status | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
    for k in $(ls /lib/modules); do
      [ -d /lib/modules/$k/build ] || continue
      dkms remove  ipu7-drivers/$V -k $k
      dkms install ipu7-drivers/$V -k $k
    done

Then REBOOT. Do not modprobe -r intel_ipu7_psys to pick it up live: unloading
psys page-faults in ipu7_fw_psys_close even at refcount 0, and psys0 stays gone
until you reboot anyway.
EOF
