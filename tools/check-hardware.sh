#!/bin/bash
# ===========================================================================
# check-hardware.sh — is this package for THIS laptop?
#
# Read-only. Touches nothing, needs no root, installs nothing. Answers one
# question on its last line:
#
#     APPLIES TO THIS MACHINE: yes/no — <reason>
#
# Two reasons it exists as a script rather than a paragraph:
#
# 1. The README used to ask a stranger to run five commands and cross-reference
#    two tables. People skim that, and the ones who skim it are exactly the ones
#    who should not install this.
# 2. install.sh SOURCES this file and refuses to run when it says no. Prose
#    stops nobody; the installer is the only thing that can. Without it the
#    installer would happily build five modules on an AMD ThinkPad and print a
#    green summary -- and two of those modules (ipu-bridge-patched,
#    int3472-patched) replace IN-TREE drivers and land in updates/, which depmod
#    prefers over kernel/. On an unrelated Intel MIPI laptop that overrides
#    working drivers system-wide.
#
# Exit status: 0 this package applies,
#              1 it does not (nothing here matches your hardware),
#              2 it must not be installed (IPU6 machine).
# ===========================================================================

# Set by detect_hardware(). Declared here so a caller under `set -u` can read
# them whether or not detection found anything.
HW_BRIDGE=""     # Synaptics CVS bridge on USB, as vendor:product
HW_ACPI=""       # bridge ACPI id (INTC10CF/DE/E0/E1)
HW_SENSORS=""    # sensor + PMIC ids the firmware declares
HW_IPU=""        # the imaging unit on PCI
HW_IPU6=0        # 1 = this is an IPU6 machine, which this package must not touch
HW_UVC=""        # a bound uvcvideo webcam, i.e. an ordinary USB camera

detect_hardware(){
  local d v p drv
  HW_BRIDGE=""; HW_ACPI=""; HW_SENSORS=""; HW_IPU=""; HW_IPU6=0; HW_UVC=""

  # 1) the Synaptics CVS bridge on USB. Match the vendor only: 06cb:0701 is the
  #    one on the author's machine and the product id is not the same on every
  #    board, so pinning the full id would tell other owners this is not for
  #    them when it is.
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
    v=$(cat "$d/idVendor" 2>/dev/null || true)
    p=$(cat "$d/idProduct" 2>/dev/null || true)
    if [ "$v" = "06cb" ]; then HW_BRIDGE="06cb:$p"; break; fi
  done

  # 2) the bridge's ACPI id — INTC10CF/DE/E0/E1 = MTL/LNL/ARL/PTL. @Aohzan's
  #    Dell Pro 14 is INTC10DE where the author's XPS 16 is INTC10E1.
  HW_ACPI=$( { ls /sys/bus/i2c/devices/ /sys/bus/acpi/devices/ 2>/dev/null || true; } \
             | grep -oiE 'INTC10(CF|DE|E0|E1)' | sort -u | tr '\n' ' ') || true

  # 3) the sensors and the GPIO/power controller the firmware declares
  HW_SENSORS=$( { ls /sys/bus/acpi/devices/ 2>/dev/null || true; } \
             | grep -oiE 'HIMX1092|OVTI08F4|OVTI05C1|INT3472' | sort -u | tr '\n' ' ') || true

  # 4) the IPU itself, and whether this is an IPU6 machine (a different stack)
  for d in /sys/bus/pci/devices/*/; do
    [ -f "$d/vendor" ] && [ -f "$d/class" ] || continue
    [ "$(cat "$d/vendor" 2>/dev/null || true)" = "0x8086" ] || continue
    case $(cat "$d/class" 2>/dev/null || true) in
      0x0480*) HW_IPU="${d%/}"; HW_IPU="${HW_IPU##*/} $(cat "$d/device" 2>/dev/null || true)" ;;
      *) continue ;;
    esac
    if [ -e "$d/driver" ]; then
      drv=$(basename "$(readlink -f "$d/driver")")
      case $drv in intel-ipu6*|intel_ipu6*) HW_IPU6=1 ;; esac
    fi
  done
  [ -d /sys/module/intel_ipu6 ] && HW_IPU6=1

  # 5) an ordinary USB webcam. Not a reason to refuse on its own -- some of
  #    these laptops have both -- but it is the single most common reason
  #    somebody lands here who does not need any of this.
  HW_UVC=$( { ls /sys/bus/usb/drivers/uvcvideo/ 2>/dev/null || true; } \
            | grep -E '^[0-9]' | tr '\n' ' ') || true
  return 0
}

# 0 = supported board, 1 = nothing here matches, 2 = IPU6 (must not install).
# Sets HW_REASON to a sentence naming what was and was not found.
HW_REASON=""
hw_verdict(){
  if [ "$HW_IPU6" = "1" ]; then
    HW_REASON="this is an IPU6 machine (intel_ipu6 is bound or loaded). This package is for IPU7, and its ipu-bridge/int3472 replacements would override the in-tree modules your camera uses. See https://github.com/intel/ipu6-drivers instead."
    return 2
  fi
  if { [ -n "$HW_BRIDGE" ] || [ -n "$HW_ACPI" ]; } && [ -n "$HW_SENSORS" ]; then
    HW_REASON="found a CVS bridge or its ACPI id, plus a sensor the firmware declares (bridge='${HW_BRIDGE:-none}' acpi='${HW_ACPI:-none}' sensors='${HW_SENSORS}')"
    return 0
  fi
  HW_REASON="no supported board found. Looked for: a Synaptics CVS bridge on USB (06cb:*), a bridge ACPI id (INTC10CF/DE/E0/E1) under /sys/bus/{i2c,acpi}/devices, and a sensor id (HIMX1092/OVTI08F4/OVTI05C1/INT3472). Found bridge='${HW_BRIDGE:-none}' acpi='${HW_ACPI:-none}' sensors='${HW_SENSORS:-none}'."
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  detect_hardware
  printf '=== hardware check — %s ===\n\n' "$(uname -r)"
  printf '  %-28s %s\n' "CVS bridge on USB"      "${HW_BRIDGE:-not present}"
  printf '  %-28s %s\n' "bridge ACPI id"         "${HW_ACPI:-none}"
  printf '  %-28s %s\n' "sensors in firmware"    "${HW_SENSORS:-none}"
  printf '  %-28s %s\n' "Intel imaging unit"     "${HW_IPU:-none on PCI}"
  printf '  %-28s %s\n' "IPU6 machine"           "$([ "$HW_IPU6" = 1 ] && echo YES || echo no)"
  printf '  %-28s %s\n' "USB (uvcvideo) webcam"  "${HW_UVC:-none bound}"
  echo
  hw_verdict; hw_rc=$?
  case $hw_rc in
    0) printf 'APPLIES TO THIS MACHINE: yes — %s\n' "$HW_REASON"
       printf '\nNext: sudo ./install.sh --dry-run   (rehearsal, changes nothing)\n' ;;
    2) printf 'APPLIES TO THIS MACHINE: NO — %s\n' "$HW_REASON"
       printf '\nDo not install this package here.\n' ;;
    *) printf 'APPLIES TO THIS MACHINE: no — %s\n' "$HW_REASON"
       if [ -n "$HW_UVC" ]; then
         printf '\nYour camera is an ordinary USB (uvcvideo) webcam. Nothing in this package\n'
         printf 'applies to it. For a UVC IR emitter see linux-enable-ir-emitter.\n'
       else
         printf '\ninstall.sh will refuse to run here unless you pass --force.\n'
       fi ;;
  esac
  exit $hw_rc
fi
