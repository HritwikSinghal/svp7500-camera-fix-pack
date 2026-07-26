#!/bin/bash
# Verify the IPU7 IR stack end to end.
set -u
p(){ printf '  %-34s %s\n' "$1" "$2"; }
echo "=== IPU7 IR stack verification — $(uname -r) ==="

for m in intel_ipu7 intel_ipu7_isys intel_ipu7_psys intel_cvs hm1092; do
  lsmod | grep -q "^$m " && p "module $m" "loaded" || p "module $m" "MISSING"
done
p "/dev/ipu7-psys0" "$([ -e /dev/ipu7-psys0 ] && echo present || echo MISSING)"
# A MISSING psys0 is almost always the DKMS/kernel struct-layout mismatch, not a
# race: psys reads isp->ipu7_bus_ready_to_probe at the wrong offset and defers
# forever. isys binds normally because it ships with the kernel, which makes the
# failure look selective and sends people hunting the wrong thing. Note that the
# "psys suspend patches" line below can read 2/2 while this is broken -- it only
# checks the SUSPEND fixes and says nothing about the defer check.
if [ ! -e /dev/ipu7-psys0 ]; then
  echo "      -> intel_ipu7:      $(modinfo -n intel_ipu7 2>/dev/null | grep -qE '/kernel/' && echo kernel || echo dkms)"
  echo "      -> intel_ipu7_psys: $(modinfo -n intel_ipu7_psys 2>/dev/null | grep -qE '/updates/' && echo dkms || echo kernel)"
  echo "      -> split provenance means the defer check reads garbage. Fix:"
  echo "         sudo kernel/ipu7-psys-patches/fix-psys-defer.sh   (then rebuild all kernels + reboot)"
fi

# the fix: LINK_FREQ must be the DDR clock (180,480,000), not the bit rate
SD=$(media-ctl -d /dev/media0 -p 2>/dev/null | awk '/entity .*hm1092/{f=1} f&&/device node name/{print $NF; exit}')
if [ -n "${SD:-}" ]; then
  LF=$(v4l2-ctl -d "$SD" --get-ctrl=link_frequency 2>/dev/null | grep -oE '\(([0-9]+)' | tr -d '(')
  if [ "${LF:-0}" = "180480000" ]; then p "link_frequency" "180480000 (CORRECT)"
  else p "link_frequency" "${LF:-?} <-- WRONG, must be 180480000"; fi
fi

# psys suspend fix
KO=/lib/modules/$(uname -r)/updates/dkms/intel-ipu7-psys.ko.zst
if [ -e "$KO" ]; then
  n=$(zstd -dcq "$KO" 2>/dev/null | strings | grep -cE 'psys not ready after resume|ioctl: resume failed')
  p "psys suspend patches" "$n/2"
fi

# IR illuminator
L=/sys/class/leds/HIMX1092_00::ir_flood_led/brightness
p "IR flood LED" "$([ -e $L ] && echo "present (=$(cat $L))" || echo MISSING)"

# Howdy
p "howdy ir_reader" "$([ -e /usr/lib/howdy/recorders/ir_reader.py ] && echo installed || echo MISSING)"
if [ -f /etc/howdy/config.ini ]; then
  p "howdy plugin" "$(grep -oP '^recording_plugin\s*=\s*\K.*' /etc/howdy/config.ini)"
  p "howdy device_path" "$(grep -oP '^device_path\s*=\s*\K.*' /etc/howdy/config.ini)"
  p "howdy dark_threshold" "$(grep -oP '^dark_threshold\s*=\s*\K.*' /etc/howdy/config.ini)"
fi

# live capture test
echo
echo "--- live IR capture (needs root) ---"
if [ "$EUID" -eq 0 ] && [ -n "${SD:-}" ]; then
  NODE=$(grep -oP '^device_path\s*=\s*\K.*' /etc/howdy/config.ini 2>/dev/null)
  echo "format sof_event +p" > /sys/kernel/debug/dynamic_debug/control 2>/dev/null
  # A fresh boot leaves the CSI2->capture link DISABLED and the pads at their
  # 4096x3072 default, so streaming returns zero frames. Configure the graph
  # first -- resolving entities by NAME, since node numbers shuffle per boot.
  SENS=$(media-ctl -d /dev/media0 -p 2>/dev/null | grep -oE '^- entity [0-9]+: hm1092[^(]*' | sed 's/^- entity [0-9]*: //;s/ *$//' | head -1)
  CAP=$(media-ctl -d /dev/media0 -p 2>/dev/null | awk '/entity .*Intel IPU7 CSI2 2 /{f=1} f&&/-> "Intel IPU7 ISYS Capture/{gsub(/.*-> "/,"");gsub(/":.*/,"");print;exit}')
  if [ -n "${SENS:-}" ] && [ -n "${CAP:-}" ]; then
    media-ctl -d /dev/media0 --set-v4l2 "\"$SENS\":0 [fmt:SGRBG10_1X10/648x368]" 2>/dev/null
    media-ctl -d /dev/media0 --set-v4l2 '"Intel IPU7 CSI2 2":0 [fmt:SGRBG10_1X10/648x368]' 2>/dev/null
    media-ctl -d /dev/media0 --set-v4l2 '"Intel IPU7 CSI2 2":1 [fmt:SGRBG10_1X10/648x368]' 2>/dev/null
    media-ctl -d /dev/media0 -l "\"Intel IPU7 CSI2 2\":1 -> \"$CAP\":0 [1]" 2>/dev/null
  fi
  dmesg -C >/dev/null 2>&1
  timeout 15 v4l2-ctl -d "${NODE:-/dev/video16}" \
      --set-fmt-video=width=648,height=368,pixelformat=BA10 \
      --stream-mmap --stream-count=5 --stream-to=/dev/null >/dev/null 2>&1
  SOF=$(dmesg | grep -c 'sof_event::csi2-2')
  p "SOF on csi2-2" "$SOF $([ "$SOF" -gt 0 ] && echo '<-- STREAMING' || echo '<-- NO FRAMES')"
else
  p "live capture" "run as root to test"
fi
