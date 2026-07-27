#!/bin/bash
# ===========================================================================
# Is int3472-patched needed on this kernel?
#
#   int3472-needed.sh [kernel-release]   ->  exit 0 = needed, 1 = redundant
#
# WHY THIS EXISTS
#   int3472-patched was written when mainline's INT3472 driver did not map the
#   STROBE GPIO to an "ir_flood" LED class device. Mainline gained that, so on
#   kernels that have it our copy is not merely redundant -- it is WORSE.
#
#   Verified 2026-07-26 on this machine:
#     kernel 7.1.1 / 7.1.4 in-tree intel_skl_int3472_discrete.ko
#         contains ir_flood + skl_int3472_register_led   (3 matches)
#     our int3472-patched build for the same kernels
#         contains ir_flood                              (0 matches)
#
#   DKMS installs ours into updates/dkms/, which outranks kernel/, so we replace
#   a driver that publishes /sys/class/leds/<sensor>::ir_flood_led with one that
#   does not. Both howdy/ir_reader.py (which writes that brightness file) and
#   udev/99-hm1092-ir-led.rules (which chgrps it to the video group) depend on
#   that node existing. Without it the illuminator never fires for an
#   unprivileged lock-screen auth, every frame is too dark, and authentication
#   times out while working perfectly under sudo.
#
#   On 7.2.0-rc4 this machine has ZERO int3472 DKMS files installed and the IR
#   camera, illuminator and face unlock all work -- via the in-tree driver.
#
#   Our copy also cannot build on >= 7.1: it dereferences int3472->pled, which
#   mainline replaced with leds[]/n_leds.
# ===========================================================================
set -euo pipefail

K="${1:-$(uname -r)}"
M="/usr/lib/modules/$K/kernel/drivers/platform/x86/intel/int3472/intel_skl_int3472_discrete.ko"
[[ -f $M ]] || M="$M.zst"
[[ -f $M ]] || M="/lib/modules/$K/kernel/drivers/platform/x86/intel/int3472/intel_skl_int3472_discrete.ko.zst"

# DKMS moves the original aside when it shadows a module, so check there too --
# otherwise a machine that ALREADY has our module installed looks like a kernel
# with no in-tree driver, and we would keep shipping the shadow forever.
if [[ ! -f $M ]]; then
  # NOTE: a bare `[[ cond ]] && cmd` as the last statement of a block returns
  # the condition's status, so under `set -e` a false condition kills the whole
  # script. That silently produced an empty "redundant" verdict for a kernel
  # with no in-tree module at all. Use an if.
  O=$(find "/var/lib/dkms/int3472-patched/original_module/$K" -name '*discrete*.ko*' 2>/dev/null | head -1 || true)
  if [[ -n ${O:-} ]]; then
    M="$O"
  fi
fi

if [[ ! -f ${M:-} ]]; then
  echo "int3472: no in-tree module found for $K -- assuming the patch IS needed"
  exit 0
fi

if [[ $M == *.zst ]]; then
  hits=$(zstd -dcq "$M" 2>/dev/null | strings | grep -cE '^ir_flood$|skl_int3472_register_led' || true)
else
  hits=$(strings "$M" 2>/dev/null | grep -cE '^ir_flood$|skl_int3472_register_led' || true)
fi

if [[ ${hits:-0} -gt 0 ]]; then
  echo "int3472: $K already registers the IR flood LED in-tree -- patch NOT needed"
  echo "         (installing it would replace that driver with one that does not,"
  echo "          removing /sys/class/leds/*ir_flood_led and breaking the illuminator)"
  exit 1
fi

echo "int3472: $K has no in-tree ir_flood support -- patch IS needed"
exit 0
