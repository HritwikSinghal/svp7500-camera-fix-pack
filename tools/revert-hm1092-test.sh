#!/bin/bash
# Restore the known-good DKMS hm1092 after testing the upstream-candidate build.
#
# The upstream candidate is a rewrite of the register-access layer (hand-rolled
# i2c_transfer -> V4L2 CCI regmap) plus a conversion to enable_streams, runtime
# PM callbacks and firmware endpoint validation. If the camera does not come
# back after a reboot, run this and reboot again.
#
#   sudo tools/revert-hm1092-test.sh
#
# If the machine will not give you a shell with a working camera at all, the
# other installed kernels still carry the original DKMS build -- boot one of
# those from the bootloader menu and run this from there.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

K="${1:-$(uname -r)}"
M=/lib/modules/$K/updates/dkms/hm1092.ko.zst
B=$M.known-good

[[ -f $B ]] || { echo "no backup at $B — rebuild with: dkms install hm1092/1.0 -k $K"; exit 1; }

cp -a "$B" "$M"
depmod -a "$K"

echo "restored the known-good hm1092 for $K"
echo "REBOOT to load it — hm1092 leaks module references and cannot be swapped live."
