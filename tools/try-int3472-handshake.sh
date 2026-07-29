#!/bin/bash
# ===========================================================================
# EXPERIMENT: give the ov05c10 a 50 ms handshake regulator delay
#
#   sudo ./try-int3472-handshake.sh            # apply
#   sudo ./try-int3472-handshake.sh --revert    # put it back
#
# WHAT THIS TESTS
#   Intel's ipu6-drivers PR #427 (merged 2026-03-18, shipped in Ubuntu
#   linux-oem-6.17 via Launchpad bug 2147409) raised the INT3472 handshake
#   regulator enable delay from 25 ms to 50 ms:
#
#       -   ret = skl_int3472_register_regulator(int3472, gpio, 25 * USEC_PER_MSEC,
#       +   ret = skl_int3472_register_regulator(int3472, gpio, 50 * USEC_PER_MSEC,
#
#   Mainline's quirk table has per-sensor delays for INT33F0, INT347E and
#   OVTI08F4 (45 ms) but nothing for OVTI05C1, so an ov05c10 gets the 25 ms
#   default. Half the settle time a rail needs is consistent with a sensor
#   that answers on I2C, enumerates, accepts a mode and then delivers no
#   frames.
#
#   This adds an OVTI05C1 entry at 50 ms rather than raising the global
#   default, so boards that work today are untouched.
#
# NO TRADE-OFF ANY MORE
#   An earlier version of this replaced a module that predated `ir_flood`
#   landing in mainline, so applying it cost you the IR illuminator. That is
#   fixed: discrete.c and friends are now the in-tree v7.1 sources with the
#   OVTI05C1 entry added on top, so the module keeps everything mainline has:
#
#       rebased + quirk   OVTI05C1: yes   ir_flood: yes   OVTI08F4: yes
#       stock in-tree     OVTI05C1: no    ir_flood: yes   OVTI08F4: yes
#
#   It is still an EXPERIMENT — nobody has shown the delay is what ails the
#   ov05c10 — but it no longer costs you a working sensor to find out.
# ===========================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$HERE/dkms/int3472-patched-1.0
VER=1.0

say(){ printf '  %s\n' "$*"; }

if [[ ${1:-} == --revert ]]; then
  say "removing int3472-patched, restoring the in-tree module"
  dkms remove -m int3472-patched -v $VER --all >/dev/null 2>&1 || true
  if command -v mkinitcpio >/dev/null 2>&1; then mkinitcpio -P >/dev/null 2>&1
  elif command -v dracut >/dev/null 2>&1; then dracut --regenerate-all --force >/dev/null 2>&1
  elif command -v update-initramfs >/dev/null 2>&1; then update-initramfs -u -k all >/dev/null 2>&1; fi
  say "done — REBOOT. The IR illuminator comes back with the in-tree module."
  exit 0
fi

grep -q 'OVTI05C1' "$SRC/discrete.c" || {
  echo "this copy of discrete.c has no OVTI05C1 quirk — git pull first"; exit 1; }

rm -rf /usr/src/int3472-patched-$VER
cp -a "$SRC" /usr/src/int3472-patched-$VER
dkms remove -m int3472-patched -v $VER --all >/dev/null 2>&1 || true
dkms add -m int3472-patched -v $VER >/dev/null 2>&1 || true

BUILT=0
for k in $(ls /lib/modules); do
  [[ -d /lib/modules/$k/build ]] || continue
  if dkms build --force int3472-patched/$VER -k "$k" >/dev/null 2>&1 &&
     dkms install --force int3472-patched/$VER -k "$k" >/dev/null 2>&1; then
    say "built + installed for $k"
    BUILT=$((BUILT+1))
  else
    say "FAILED for $k — see /var/lib/dkms/int3472-patched/$VER/build/make.log"
  fi
done
[[ $BUILT -gt 0 ]] || { echo "  nothing built; not touching the initramfs"; exit 1; }

# The in-tree module loads from the initramfs, so without this the old one
# still wins at boot and the whole experiment silently tests nothing.
if command -v mkinitcpio >/dev/null 2>&1; then mkinitcpio -P >/dev/null 2>&1
elif command -v dracut >/dev/null 2>&1; then dracut --regenerate-all --force >/dev/null 2>&1
elif command -v update-initramfs >/dev/null 2>&1; then update-initramfs -u -k all >/dev/null 2>&1; fi

cat <<'EOF'

  REBOOT, then check three things:

    # 1. is our module the one that loaded?
    modinfo -n intel_skl_int3472_discrete      # want .../updates/dkms/...

    # 2. did the RGB sensor start delivering?
    cam --list
    cam --camera=1 --capture=5 --file=/tmp/rgb.raw

    # 3. the illuminator should STILL be there — if it is gone, revert
    ls /sys/class/leds/HIMX1092_00::ir_flood_led

  If #2 still gives no frames, revert — the delay was not the problem and
  there is no reason to keep paying for it:

    sudo ./tools/try-int3472-handshake.sh --revert
EOF
