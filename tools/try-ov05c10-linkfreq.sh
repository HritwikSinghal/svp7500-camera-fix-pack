#!/bin/bash
# ===========================================================================
# Try a different LINK_FREQ for the ov05c10's 2888x1808 mode.
#
#   sudo ./try-ov05c10-linkfreq.sh 450        # half of 900 -- the HM1092 bug shape
#   sudo ./try-ov05c10-linkfreq.sh 480        # what the pixel-rate arithmetic gives
#   sudo ./try-ov05c10-linkfreq.sh --revert   # back to stock (900)
#   sudo ./try-ov05c10-linkfreq.sh --show     # print the current value, change nothing
#
# THIS IS AN EXPERIMENT, NOT A FIX. It is here because the numbers look wrong,
# not because anyone has proven the right value.
#
# WHY
#   ov05c10.c ships:
#
#       ov05c10_link_freq_menu_items[] = { 900000000, 480000000 }
#       mode 2888x1808@30  ->  link_freq_index = 0   =  900 MHz
#       mode 2800x1576@30  ->  link_freq_index = 1   =  480 MHz
#       PIXEL_RATE            192000000
#
#   480 MHz is exactly 192e6 x 10bpp / 2 lanes / 2 -- the /2 because
#   V4L2_CID_LINK_FREQ is the DDR clock, NOT the per-lane bit rate. 900 MHz
#   fits no clean formula, and the two modes are out of proportion: mode 0 has
#   1.18x the pixels of mode 1 but claims 1.875x the link.
#
#   We have been bitten by precisely this on the HM1092 IR sensor, where
#   LINK_FREQ was published as the per-lane BIT RATE (360,960,000) when V4L2
#   wants the DDR clock (180,480,000). isys then programmed the D-PHY at twice
#   the sensor's actual rate, the clock lane toggled, data never framed, and
#   captures hung with zero SOF. That is what an ov05c10 `cam --capture` hang
#   looks like from the outside too.
#
#   Two candidates, hence the argument:
#     450  = 900/2, the exact HM1092 shape (published value was the bit rate)
#     480  = what PIXEL_RATE and 2 lanes work out to
#
# HOW TO TELL IF IT WORKED
#   Before and after, check what isys programmed the PHY to and whether any
#   frames arrive:
#
#     sudo dmesg | grep -iE 'config phy .* mbps'
#     sudo dmesg | grep -c 'sof_event'
#
#   The mbps line changing is the proof the new value took effect. Frames
#   arriving is the proof it was the right one.
#
#   ⚠ If the sensor's register table genuinely programs 900 MHz, lowering
#   LINK_FREQ makes the mismatch worse rather than better. Reverting costs one
#   rebuild.
# ===========================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

STOCK=900000000
SRC=/usr/src/ov05c10-1.0/ov05c10.c
[[ -f $SRC ]] || { echo "not found: $SRC (is ov05c10 installed?)"; exit 1; }

cur() { sed -n 's/^\t\([0-9]\+\)ULL,.*$/\1/p' "$SRC" | head -1; }

case "${1:-}" in
  --show)
    echo "  current menu[0] = $(cur) Hz"
    exit 0 ;;
  --revert) WANT=$STOCK ;;
  "")       echo "usage: $0 <450|480|--revert|--show>"; exit 2 ;;
  *)
    # accept 450, 480, or a full Hz value
    n=${1//[^0-9]/}
    [[ -n $n ]] || { echo "not a number: $1"; exit 2; }
    if [[ ${#n} -le 4 ]]; then WANT=$((n * 1000000)); else WANT=$n; fi ;;
esac

NOW=$(cur)
[[ -n ${NOW:-} ]] || { echo "could not read the current menu value from $SRC"; exit 1; }

if [[ $NOW == "$WANT" ]]; then
  echo "  already $WANT Hz — nothing to do"
  exit 0
fi

cp -a "$SRC" "$SRC.linkfreq-$(date +%Y%m%d-%H%M%S)"
# Only the FIRST menu entry: index 1 (480 MHz) is used by the 2800x1576 mode
# and is the value that already looks arithmetically right. Leave it alone.
python3 - "$SRC" "$NOW" "$WANT" <<'PY'
import sys
path, now, want = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
old = "\t%sULL,\n" % now
if old not in s:
    sys.exit("could not find menu entry %s" % now)
s = s.replace(old, "\t%sULL,\n" % want, 1)
open(path, "w").write(s)
PY

echo "  menu[0]: $NOW -> $WANT Hz"
grep -n -A4 'ov05c10_link_freq_menu_items\[\] = ' "$SRC" | sed 's/^/    /'

echo
echo "  rebuilding for every installed kernel..."
for k in $(ls /lib/modules); do
  [[ -d /lib/modules/$k/build ]] || continue
  dkms build   --force ov05c10/1.0 -k "$k" >/dev/null 2>&1 || { echo "    BUILD FAILED for $k"; continue; }
  dkms install --force ov05c10/1.0 -k "$k" >/dev/null 2>&1 && echo "    ok  $k"
done

cat <<EOF

  REBOOT, then:

    sudo dmesg | grep -iE 'config phy .* mbps'     # did the PHY rate change?
    cam --camera=1 --capture=5 --file=/tmp/rgb.raw # does it deliver frames?

  Back out with:  sudo $0 --revert
EOF
