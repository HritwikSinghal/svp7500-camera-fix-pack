#!/bin/bash
# Identify the IR capture node + sensor subdev. Node numbers and libcamera
# indexes SHUFFLE between boots -- always resolve by entity name, never hardcode.
set -u
M=${1:-/dev/media0}
echo "media device: $M"
SD=$(media-ctl -d $M -p 2>/dev/null | awk '/entity .*hm1092/{f=1} f&&/device node name/{print $NF; exit}')
echo "  hm1092 subdev : ${SD:-NOT FOUND}"
CSI=$(media-ctl -d $M -p 2>/dev/null | grep -oE 'Intel IPU7 CSI2 [0-9]+' | while read -r e; do
        media-ctl -d $M -p 2>/dev/null | grep -A30 "entity .*: $e " | grep -q hm1092 && echo "$e"; done | head -1)
# the capture entity the sensor's CSI2 port feeds
CAP=$(media-ctl -d $M -p 2>/dev/null | awk '/entity .*Intel IPU7 CSI2 2 /{f=1} f&&/-> "Intel IPU7 ISYS Capture/{gsub(/.*-> "/,"");gsub(/":.*/,"");print;exit}')
NODE=$(media-ctl -d $M -p 2>/dev/null | awk -v e="$CAP" '$0 ~ "entity .*: "e" "{f=1} f&&/device node name/{print $NF; exit}')
echo "  CSI2 port     : ${CSI:-Intel IPU7 CSI2 2}"
echo "  capture entity: ${CAP:-?}"
echo "  IR video node : ${NODE:-?}   <-- put this in /etc/howdy/config.ini device_path"
[ -n "${SD:-}" ] && echo "  link_frequency: $(v4l2-ctl -d "$SD" --get-ctrl=link_frequency 2>/dev/null)"
