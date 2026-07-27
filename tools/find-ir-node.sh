#!/bin/bash
# Identify the IR capture node + sensor subdev. Node numbers and libcamera
# indexes SHUFFLE between boots -- always resolve by entity name, never hardcode.
set -u
M=${1:-/dev/media0}
echo "media device: $M"
SD=$(media-ctl -d $M -p 2>/dev/null | awk '/entity .*hm1092/{f=1} f&&/device node name/{print $NF; exit}')
echo "  hm1092 subdev : ${SD:-NOT FOUND}"
# Resolve the sensor's ENTITY NAME (not its /dev node) -- links are printed by
# entity name, and the name carries the i2c bus number, which varies per machine.
SENS=$(media-ctl -d $M -p 2>/dev/null | grep -oE '^- entity [0-9]+: hm1092[^(]*' | sed 's/^- entity [0-9]*: //;s/ *$//' | head -1)
# The CSI-2 port is NOT the same on every machine: port 2 on the XPS 16, port 1
# on the Dell Pro 14. Follow the sensor's own outgoing link rather than guessing.
# This previously read an unset $SD_ENT, which under `set -u` killed the subshell
# and silently fell back to port 2 -- while still printing "(auto-detected)".
CSI=$(media-ctl -d $M -p 2>/dev/null | awk -v s="$SENS" '$0 ~ "entity .*: "s" "{f=1} f&&/-> "/{gsub(/.*-> "/,"");gsub(/":.*/,"");if ($0 ~ /CSI2/){print;exit}}')
if [ -n "${CSI:-}" ]; then CSI_SRC="auto-detected from the sensor's link"
else CSI="Intel IPU7 CSI2 2"; CSI_SRC="GUESSED -- could not follow the sensor's link"; fi
CAP=$(media-ctl -d $M -p 2>/dev/null | awk -v c="$CSI" '$0 ~ "entity .*: "c" "{f=1} f&&/-> "Intel IPU7 ISYS Capture/{gsub(/.*-> "/,"");gsub(/":.*/,"");print;exit}')
NODE=$(media-ctl -d $M -p 2>/dev/null | awk -v e="$CAP" '$0 ~ "entity .*: "e" "{f=1} f&&/device node name/{print $NF; exit}')
echo "  CSI2 port     : ${CSI}   (${CSI_SRC})"
echo "  capture entity: ${CAP:-?}"
echo "  IR video node : ${NODE:-?}   <-- put this in /etc/howdy/config.ini device_path"
[ -n "${SD:-}" ] && echo "  link_frequency: $(v4l2-ctl -d "$SD" --get-ctrl=link_frequency 2>/dev/null)"
