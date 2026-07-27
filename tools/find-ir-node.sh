#!/bin/bash
# Identify the IR capture node + sensor subdev, so you can put the right value
# in Howdy's config.ini. Node numbers, /dev/v4l-subdevN and libcamera indexes
# SHUFFLE between boots -- always resolve by entity name, never hardcode.
#
# The detection itself lives in tools/lib-detect.sh, which tools/verify.sh uses
# too. It used to live here AND, differently and wrongly, in verify.sh: this
# script followed the sensor's own link while verify.sh assumed CSI-2 port 2,
# which is right on the author's XPS 16 and wrong on a Dell Pro 14.
set -u

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
if [ ! -f "$ROOT/tools/lib-detect.sh" ]; then
  printf 'find-ir-node.sh: %s is missing from this package — re-download it.\n' \
    "$ROOT/tools/lib-detect.sh" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$ROOT/tools/lib-detect.sh"

if ! ld_detect; then
  printf 'could not look at the media graph: %s\n' "$LD_WHY" >&2
  exit 2
fi

echo "media device  : $LD_MEDIA"
echo "  hm1092 subdev : ${LD_IR_SD:-NOT FOUND}"
if [ -n "$LD_CSI" ]; then
  echo "  CSI2 port     : $LD_CSI   (followed from the sensor's own link)"
else
  # No fallback. A guessed port is indistinguishable from a detected one in the
  # output, and a wrong guess sends people debugging a camera that is fine.
  echo "  CSI2 port     : UNDETECTED — not guessing"
fi
echo "  capture entity: ${LD_CAP:-?}"
echo "  IR video node : ${LD_NODE:-UNDETECTED}   <-- device_path in your Howdy config.ini"
if [ -n "$LD_IR_SD" ] && command -v v4l2-ctl >/dev/null 2>&1; then
  echo "  link_frequency: $(v4l2-ctl -d "$LD_IR_SD" --get-ctrl=link_frequency 2>/dev/null)"
fi
[ -n "$LD_WHY" ] && echo "  note          : $LD_WHY"

# Exit non-zero when the thing this tool exists to print could not be found, so
# it is usable in a script and cannot be mistaken for a successful lookup.
[ -n "$LD_NODE" ] || exit 1
exit 0
