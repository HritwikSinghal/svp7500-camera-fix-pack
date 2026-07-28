#!/bin/bash
# ===========================================================================
# verify.sh — did this package actually fix the camera on this machine?
#
# Checks only the paths this board HAS. A Dell Pro 14 Plus with an OV05C10 and
# no IR sensor is a supported, working configuration; the previous version of
# this script checked the IR path unconditionally and printed four MISSING lines
# and `SOF on csi2-2  0 <-- NO FRAMES` at an owner whose camera was working
# perfectly. That reads as a failed install, and the reasonable conclusion --
# "this does not work on my laptop" -- was wrong.
#
# Three rules this file follows, because breaking them is what made the last
# version untrustworthy:
#
#   1. A check that did not run prints "not tested" and why. It never prints a
#      failure. `NO FRAMES` from a capture that was never attempted is a lie in
#      the same family as "==> Done" from an install that did nothing.
#   2. Nothing is hardcoded to this laptop. The CSI-2 port, the media device,
#      the video node and the sensor all come from the media graph via
#      lib-detect.sh. The old copy had `Intel IPU7 CSI2 2` in five places.
#   3. It does not clear the kernel ring buffer. `dmesg -C` used to run here,
#      which erased every boot-time probe message -- including the evidence the
#      README's own bug-report recipe asks you to paste two steps later.
#
# Exit status: 0 the camera stack is healthy for the sensors this board has,
#              1 something is broken (the verdict names it),
#              2 could not determine (not root, or no media device to look at).
# ===========================================================================
set -u

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)

usage(){
  awk 'NR>2 { if (/^# ={10,}$/) exit; sub(/^# ?/,""); print }' "$(readlink -f "${BASH_SOURCE[0]}")"
  cat <<EOF

Usage: sudo $ROOT/tools/verify.sh

  -h, --help   this text

Run it as root. Without root the module and config checks still work, but the
live capture test cannot run and the verdict will be UNDETERMINED rather than
a claim this script cannot support.
EOF
}
case ${1:-} in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) printf 'verify.sh: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac

# Named literally, one per line, so the package selftest can see that verify.sh
# depends on them and fail if either is ever dropped from a release.
for lib in "$ROOT/tools/lib-detect.sh" "$ROOT/tools/check-hardware.sh"; do
  if [ ! -f "$lib" ]; then
    printf 'verify.sh: %s is missing from this package — re-download it.\n' "$lib" >&2
    exit 2
  fi
done
# shellcheck source=/dev/null
. "$ROOT/tools/lib-detect.sh"
# shellcheck source=/dev/null
. "$ROOT/tools/check-hardware.sh"

VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)
[ -n "$VERSION" ] || VERSION="(not a git checkout)"

# --- verdict accumulators ---------------------------------------------------
# BROKEN entries are things proven wrong. UNTESTED entries are things this run
# could not establish either way -- kept strictly apart, because merging them is
# how "I did not look" turns into "it is fine".
declare -a BROKEN=() UNTESTED=() NEXT=()
broke(){ BROKEN+=("$1"); }
untested(){ UNTESTED+=("$1"); }
next(){ NEXT+=("$1"); }

p(){    printf '  %-32s %s\n' "$1" "$2"; }
sub(){  printf '      %s\n' "$*"; }
sec(){  printf '\n%s\n' "$*"; }

mod_loaded(){ lsmod 2>/dev/null | grep -q "^$1 "; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Where a module would come from on THIS kernel, and whose build it is.
mod_path(){ modinfo -n "$1" 2>/dev/null || true; }
mod_origin(){
  case ${1:-} in
    "") printf 'not installed' ;;
    */updates/*|*/extra/*|*/weak-updates/*) printf 'dkms' ;;
    */kernel/*) printf 'kernel' ;;
    *) printf 'other' ;;
  esac
}

ko_cat(){
  case $1 in
    *.zst) have zstd && zstd -dcq "$1" 2>/dev/null || return 1 ;;
    *.xz)  have xz   && xz -dc "$1"    2>/dev/null || return 1 ;;
    *.gz)  have gzip && gzip -dc "$1"  2>/dev/null || return 1 ;;
    *)     cat "$1" 2>/dev/null || return 1 ;;
  esac
}

IS_ROOT=0; [ "${EUID:-$(id -u)}" -eq 0 ] && IS_ROOT=1

printf '=== IPU7 camera stack verification ===\n'
p "kernel"       "$(uname -r)"
p "fix-pack"     "$VERSION"
p "running as"   "$([ $IS_ROOT -eq 1 ] && echo root || echo "$(id -un) — not root, some checks cannot run")"

# ---------------------------------------------------------------------------
sec "-- this board --"
detect_hardware
ld_detect || true

p "CVS bridge on USB"   "${HW_BRIDGE:-not present}"
p "bridge ACPI id"      "${HW_ACPI:-none}"
p "sensors in firmware" "${HW_SENSORS:-none}"
p "media device"        "${LD_MEDIA:-NOT FOUND}"

# Which sensors does this board actually have? Everything below is scoped to
# the answer, so a board without an IR sensor is never told its IR is missing.
HAS_IR=0; HAS_RGB=0; RGB_DRV=""
case ${HW_SENSORS:-} in *HIMX1092*|*himx1092*) HAS_IR=1 ;; esac
[ -n "$LD_IR_SENS" ] && HAS_IR=1
case ${HW_SENSORS:-} in *OVTI05C1*|*ovti05c1*) HAS_RGB=1; RGB_DRV=ov05c10 ;; esac
case ${HW_SENSORS:-} in *OVTI08F4*|*ovti08f4*) HAS_RGB=1; RGB_DRV=ov08x40 ;; esac
if [ -n "$LD_RGB_DRV" ]; then HAS_RGB=1; RGB_DRV=$LD_RGB_DRV; fi

p "IR sensor (HM1092)"  "$([ $HAS_IR  -eq 1 ] && echo "present${LD_IR_SENS:+ — $LD_IR_SENS}" || echo "not on this board")"
p "RGB sensor"          "$([ $HAS_RGB -eq 1 ] && echo "${RGB_DRV:-present}${LD_RGB_SENS:+ — $LD_RGB_SENS}" || echo "not detected")"

if [ -z "$LD_MEDIA" ]; then
  sub "${LD_WHY:-no media graph could be read}"
  untested "there is no media device to inspect, so nothing below could be confirmed against the hardware"
fi

# ---------------------------------------------------------------------------
sec "-- core stack --"
for m in intel_ipu7 intel_ipu7_isys intel_ipu7_psys ipu_bridge intel_cvs; do
  if mod_loaded "$m"; then
    p "module $m" "loaded ($(mod_origin "$(mod_path "$m")"))"
  else
    pth=$(mod_path "$m")
    if [ -z "$pth" ]; then
      p "module $m" "NOT LOADED — and not installed for this kernel"
    else
      p "module $m" "NOT LOADED — installed at $pth"
    fi
    case $m in
      intel_cvs)   broke "intel_cvs is not loaded — the SVP7500 bridge is never brought up, so no sensor can be reached" ;;
      ipu_bridge)  broke "ipu_bridge is not loaded — the firmware's sensor descriptions are never turned into v4l2 devices" ;;
      intel_ipu7)  broke "intel_ipu7 is not loaded — the imaging unit driver never bound; no camera of any kind can work" ;;
      *)           broke "$m is not loaded" ;;
    esac
  fi
done

# --- /dev/ipu7-psys0, and WHY it is missing --------------------------------
# The single most load-bearing line in this file. The previous version answered
# "why" with one unconditional paragraph about split provenance -- even when it
# had just printed that both modules came from the kernel, i.e. not split at
# all -- and sent the reader to a script whose own precondition it had not
# checked. On the common non-Arch case that is a dead end with a dead camera.
PSYS_OK=0
if [ -e /dev/ipu7-psys0 ]; then
  p "/dev/ipu7-psys0" "present"
  PSYS_OK=1
else
  p "/dev/ipu7-psys0" "MISSING — the RGB camera cannot work without it"
  broke "/dev/ipu7-psys0 does not exist — intel_ipu7_psys never bound"

  IPU7_P=$(mod_path intel_ipu7); PSYS_P=$(mod_path intel_ipu7_psys)
  IPU7_O=$(mod_origin "$IPU7_P"); PSYS_O=$(mod_origin "$PSYS_P")
  sub "intel_ipu7:      ${IPU7_P:-NOT INSTALLED on this kernel}  [$IPU7_O]"
  sub "intel_ipu7_psys: ${PSYS_P:-NOT INSTALLED on this kernel}  [$PSYS_O]"

  # Ranked, and only the causes actually evidenced here. The top line must be
  # the one that matters: if intel_ipu7 itself never loaded, nothing about psys
  # is the real story and sending someone to patch a psys source tree wastes
  # their evening.
  if ! mod_loaded intel_ipu7; then
    sub "-> intel_ipu7 is not loaded at all. psys binds to a device that driver"
    sub "   creates, so nothing here is a psys problem: fix intel_ipu7 first."
  elif [ -z "$PSYS_P" ]; then
    sub "-> intel_ipu7_psys is not installed for $(uname -r) at all, so there is"
    sub "   nothing to bind. It was never built for this kernel, or was built"
    sub "   for a different one."
    next "install the headers for $(uname -r) and re-run 'sudo $ROOT/install.sh'"
  elif _bv=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*|\1|p' | sort -u | head -1) &&
       [ -n "$_bv" ] &&
       [ -f "/usr/src/ipu7-drivers-$_bv/drivers/media/pci/intel/ipu7/psys/ipu-psys.c" ] &&
       ! grep -q 'bus_register(&ipu7_psys_bus)' \
         "/usr/src/ipu7-drivers-$_bv/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"; then
    # Ranked ABOVE split provenance on purpose. This one is deterministic on
    # kernel 7.1+ whatever the provenance is, and it is checkable from the
    # source without root, so when it applies it is the answer rather than a
    # theory. Getting the order wrong sends people to rebuild DKMS over and
    # over against a bug no rebuild can fix.
    sub "-> the psys BUS IS NEVER REGISTERED. ipu-psys.c puts its char device on"
    sub "   a custom 'intel-ipu7-psys' bus, but registers itself with"
    sub "   module_auxiliary_driver(), which registers only the aux driver --"
    sub "   bus_register() is called nowhere in the tree. Kernels up to ~7.0"
    sub "   tolerated a device on an unregistered bus; 7.1 rejects it, so probe"
    sub "   reaches its last step and fails with -EINVAL. Confirm in dmesg:"
    sub "     bus_add_device: cannot add device 'ipu7-psys0' to unregistered bus"
    sub "     psys device_register failed ... failed with error -22"
    sub "   Fix: sudo $ROOT/dkms/ipu7-psys-patches/fix-psys-busreg.sh"
    sub "        then rebuild for every kernel and reboot"
    next "apply fix-psys-busreg.sh AND fix-psys-debugfs.sh, rebuild for every kernel, reboot"
  elif [ "$IPU7_O" = kernel ] && [ "$PSYS_O" = dkms ]; then
    sub "-> SPLIT PROVENANCE: intel_ipu7 comes from your kernel package and"
    sub "   intel_ipu7_psys from DKMS. The two disagree about struct"
    sub "   ipu7_device's layout, so psys reads ipu7_bus_ready_to_probe at the"
    sub "   wrong offset and defers forever. isys binds normally because it"
    sub "   ships with the kernel, which makes the failure look selective."
    # Never print a Fix: line for a script whose precondition has not been met.
    if dkms status 2>/dev/null | grep -qE '^ipu7-drivers[/,]'; then
      # Do NOT advise applying a fix that may already be applied. Telling
      # someone to run fix-psys-defer.sh when their source already carries it
      # sends them round the same loop with nothing to show for it, which is
      # exactly what happened to a reporter for three rounds.
      #
      # The defer fix is `if (0) /* ... */` -- a compiler-removed branch, not a
      # string. It CANNOT be detected in the built module by any means, so the
      # source is the only place worth looking. The suspend patches add real
      # dev_warn() string literals, so those ARE visible in the module, and the
      # two together tell us which step is actually missing.
      _iv=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*|\1|p' | sort -u | head -1)
      _isrc=/usr/src/ipu7-drivers-$_iv/drivers/media/pci/intel/ipu7/psys/ipu-psys.c
      if [ ! -f "$_isrc" ]; then
        sub "   the ipu7-drivers source for $_iv is not at $_isrc,"
        sub "   so the patch state cannot be determined."
        next "report this with 'dkms status' and 'ls /usr/src | grep ipu7'"
      elif ! grep -qE 'psys_ready_deadline|DKMS struct layout mismatch' "$_isrc"; then
        sub "   the defer fix is NOT in your source. That is the thing to fix:"
        sub "   Fix: sudo $ROOT/dkms/ipu7-psys-patches/fix-psys-defer.sh"
        sub "        then rebuild for every kernel and reboot"
        next "apply fix-psys-defer.sh, rebuild ipu7-drivers for every kernel, reboot"
      elif [ "$(ko_cat "$PSYS_P" 2>/dev/null | grep -aoE 'psys not ready after resume|ioctl: resume failed' | sort -u | wc -l)" -lt 2 ]; then
        sub "   your SOURCE is already patched, but the built module is not:"
        sub "   the suspend patches are missing from it, so the source was"
        sub "   patched after the last build, or the rebuild did not happen."
        sub "   Fix: sudo dkms install --force ipu7-drivers/$_iv -k \$(uname -r)"
        sub "        then reboot"
        next "rebuild ipu7-drivers: sudo dkms install --force ipu7-drivers/$_iv -k \$(uname -r), then reboot"
      else
        sub "   NOTE: your source AND your built module already carry the"
        sub "   patches, so the usual fix does not apply and re-running it will"
        sub "   change nothing. psys is deferring for a different reason."
        sub "   This is worth reporting rather than retrying."
        next "the psys patches are already applied and built — do NOT re-run fix-psys-defer.sh; open an issue with this output plus the UNFILTERED log: sudo dmesg | grep -n -B5 -A40 -iE 'psys|WARNING:|Call Trace:'   (a psys-only filter hides the kernel WARN that explains it)"
      fi
    else
      sub "   fix-psys-defer.sh cannot help here: it patches an ipu7-drivers"
      sub "   DKMS source tree, and 'dkms status' lists no ipu7-drivers. The"
      sub "   psys module you have came from somewhere else."
      next "your intel_ipu7_psys is not from an ipu7-drivers DKMS tree — report this with the output of 'dkms status' and 'modinfo -n intel_ipu7_psys'"
    fi
  else
    sub "-> both modules come from the same place ($IPU7_O), so this is NOT the"
    sub "   split-provenance case. Other causes, in the order worth checking:"
    sub "   * the module was refused at load time (see 'kernel says' below)"
    sub "   * Secure Boot rejects unsigned DKMS modules"
    sub "   * intel_ipu7 never created the psys auxiliary device (see below)"
    next "paste this whole output into an issue — the psys failure here is not one of the known shapes"
  fi

  if [ $IS_ROOT -eq 1 ]; then
    r=$(dmesg 2>/dev/null | grep -iE 'psys|ipu7' \
        | grep -iE 'defer|fail|error|denied|signature|rejected|taint' | tail -5)
    if [ -n "$r" ]; then
      sub "kernel says:"
      printf '%s\n' "$r" | sed 's/^/           /'

      # A kernel WARN() prints a stack trace whose lines contain neither "psys"
      # nor "ipu7", so the filter above deletes it outright. Not hypothetical:
      # psys probe failing with -EINVAL from kobject_add_internal() comes with
      # "attempted to be registered with empty name" and a full backtrace, and a
      # reporter's filtered logs hid exactly that for four rounds while I guessed
      # at causes. If warnings sit anywhere in the log, point at them.
      w=$(dmesg 2>/dev/null | grep -icE 'WARNING:|Call Trace:|empty name')
      if [ "${w:-0}" -gt 0 ]; then
        sub "   NOTE: the log also holds $w warning/backtrace line(s) that a"
        sub "   psys/ipu7 filter hides. A WARN is how the kernel reports the"
        sub "   CAUSE of an -EINVAL like this — read them:"
        sub "     sudo dmesg | grep -n -B5 -A40 -iE 'WARNING:|empty name'"
      fi
      case $r in
        *"Key was rejected"*|*"signature"*)
          next "the kernel REJECTED the module's signature — enrol your DKMS key with mokutil, or disable Secure Boot" ;;
      esac
    else
      sub "kernel says: nothing about ipu7/psys in the current ring buffer"
    fi
  else
    sub "kernel says: not checked (dmesg needs root on this system)"
  fi
  a=$(ls /sys/bus/auxiliary/devices/ 2>/dev/null | grep -i psys | head -1)
  sub "aux device: ${a:-ABSENT (intel_ipu7 never created it)}"
fi

# --- stale modules ----------------------------------------------------------
# A DKMS rebuild does NOT regenerate the initramfs. A module that ships there
# keeps loading the OLD build no matter how many times you rebuild it, and every
# downstream symptom points somewhere else. This cost hours on 2026-07-26.
stale=0; checked=0
for m in intel_ipu7 intel_ipu7_isys intel_ipu7_psys ipu_bridge intel_cvs hm1092 ov05c10 ov08x40; do
  [ -e "/sys/module/$m/srcversion" ] || continue
  l=$(cat "/sys/module/$m/srcversion" 2>/dev/null || true)
  d=$(modinfo -F srcversion "$m" 2>/dev/null || true)
  [ -n "$l" ] && [ -n "$d" ] || continue
  checked=$((checked+1))
  if [ "$l" != "$d" ]; then
    [ $stale -eq 0 ] && printf '  %s\n' "STALE MODULES (loaded build != build on disk):"
    stale=1
    sub "$m  loaded=${l:0:8}...  disk=${d:0:8}..."
  fi
done
if [ $stale -eq 1 ]; then
  sub "-> the running kernel is NOT using what was built. Regenerate the"
  sub "   initramfs and reboot:  mkinitcpio -P / dracut -f / update-initramfs -u"
  broke "the loaded modules are not the ones on disk — the initramfs still carries the old build"
  next "regenerate the initramfs and reboot; until then nothing the installer built is in effect"
elif [ $checked -gt 0 ]; then
  p "loaded modules match disk" "yes ($checked checked)"
else
  p "loaded modules match disk" "not tested (no camera module is loaded)"
fi

# ---------------------------------------------------------------------------
sec "-- RGB camera --"
if [ $HAS_RGB -eq 0 ] && [ -z "$RGB_DRV" ]; then
  p "RGB sensor driver" "not tested (no RGB sensor detected on this board)"
  untested "no RGB sensor was detected, so the RGB path was not checked"
else
  if mod_loaded "$RGB_DRV"; then
    p "module $RGB_DRV" "loaded ($(mod_origin "$(mod_path "$RGB_DRV")"))"
  elif [ -n "$(mod_path "$RGB_DRV")" ]; then
    p "module $RGB_DRV" "NOT LOADED — installed at $(mod_path "$RGB_DRV")"
    broke "$RGB_DRV is installed but not loaded — the RGB sensor has no driver bound"
  else
    p "module $RGB_DRV" "MISSING — not installed for this kernel"
    broke "$RGB_DRV is not installed for $(uname -r) — this board's RGB sensor has no driver"
    next "run 'sudo $ROOT/install.sh' and read its summary; $RGB_DRV never landed for this kernel"
  fi
fi
if have cam; then
  CAMS=$(cam --list 2>/dev/null | grep -cE '^[0-9]+:' || true)
  if [ "${CAMS:-0}" -gt 0 ]; then
    p "libcamera (cam --list)" "$CAMS camera(s)"
  else
    p "libcamera (cam --list)" "0 cameras <-- nothing usable by applications"
    broke "libcamera enumerates no camera — no application (browser, PipeWire, Firefox) can open one"
  fi
else
  p "libcamera (cam --list)" "not tested ('cam' not installed — package: libcamera-tools)"
  untested "libcamera's 'cam' tool is not installed, so application-level enumeration was not checked"
fi

# USB autosuspend on the CVS bridge. The bridge does not survive being runtime
# suspended: it stops answering bulk transfers (-110 ETIMEDOUT), the hub drops
# it (-108 ESHUTDOWN), the i2c adapters go with it, both sensors unbind, and
# the media graph empties -- then it re-enumerates and does it again, every few
# seconds, forever.
#
# The giveaway is that it only starts when a DESKTOP session does: on a bare
# console nothing runs power management, the bridge is stable, and `cam -l`
# lists both cameras. One reporter chased this as a firmware crash-loop (and so
# did I) before their console boot showed the stack was fine.
#
# This package ships a udev rule to pin it, but a power daemon -- TLP in
# particular, which sets USB_AUTOSUSPEND=1 by default -- can reapply autosuspend
# after udev has run, so check the live value rather than the rule file.
for _ud in /sys/bus/usb/devices/*; do
  [ "$(cat "$_ud/idVendor" 2>/dev/null)" = "06cb" ] || continue
  _ctl=$(cat "$_ud/power/control" 2>/dev/null)
  _dly=$(cat "$_ud/power/autosuspend_delay_ms" 2>/dev/null)
  if [ "$_ctl" = "on" ]; then
    p "CVS bridge autosuspend" "disabled (control=on) — correct"
  else
    p "CVS bridge autosuspend" "ENABLED (control=${_ctl:-?}) — the bridge will drop off the bus"
    broke "USB autosuspend is enabled on the CVS bridge; it does not survive being suspended"
    sub "-> symptom: the camera works until a desktop session starts, then the"
    sub "   bridge cycles every few seconds (Bulk out failed -110, USB"
    sub "   disconnect, re-enumerate) and no application can hold it open."
    sub "   Fix now, no reboot:"
    sub "     echo on | sudo tee $_ud/power/control"
    sub "     echo -1 | sudo tee $_ud/power/autosuspend_delay_ms"
    sub "   Durably: install udev/99-svp7500-no-autosuspend.rules (install.sh"
    sub "   does). If it keeps reverting, a power daemon is overriding udev --"
    sub "   TLP sets USB_AUTOSUSPEND=1 by default; add USB_DENYLIST=\"06cb:0701\""
    sub "   to /etc/tlp.conf."
    next "disable USB autosuspend on the CVS bridge — it drops off the bus otherwise"
  fi
  [ -n "$_dly" ] && [ "$_dly" != "-1" ] && [ "$_ctl" = "on" ] && \
    sub "note: autosuspend_delay_ms is $_dly, expected -1"
  break
done

# Which libcamera pipeline handler is PipeWire actually using? This decides
# whether browsers work, and nothing else in this script can see it.
#
#   simple -> libcamera's SoftwareIsp. Fine at the sensor's native resolution,
#             but ANY smaller size (640x480, 720p, 1080p -- what every browser
#             asks for) selects the binned sensor mode, and the statistics pass
#             indexes past the end of a 64-bin array and calls abort(). Inside
#             WirePlumber that kills the process and the app reports "camera in
#             use by another application".
#   ipu7   -> the hardware ISP via /dev/ipu7-psys0. Every resolution works.
#
# Read it from WirePlumber's journal rather than `cam`: the CLI loads the
# SYSTEM libcamera, so it reports `simple` even on a machine where PipeWire is
# correctly using the hardware handler. Checking the wrong one is how this got
# missed for months.
_PH=$(journalctl --user -u wireplumber -b --no-pager -o cat 2>/dev/null \
        | grep -oE 'for pipeline handler [a-z0-9_]+' | tail -1 | awk '{print $NF}')
if [ -z "$_PH" ] && [ -n "${SUDO_USER:-}" ]; then
  _PH=$(runuser -u "$SUDO_USER" -- journalctl --user -u wireplumber -b --no-pager -o cat 2>/dev/null \
        | grep -oE 'for pipeline handler [a-z0-9_]+' | tail -1 | awk '{print $NF}')
fi
case "${_PH:-}" in
  ipu7)
    p "libcamera pipeline" "ipu7 — hardware ISP" ;;
  simple)
    p "libcamera pipeline" "simple — SOFTWARE ISP, browsers will crash"
    broke "PipeWire is using libcamera's software ISP, which aborts at every resolution a browser asks for"
    sub "-> the camera works from the CLI at its native resolution and fails in"
    sub "   every application. 640x480, 720p and 1080p select the binned sensor"
    sub "   mode and libcamera aborts inside WirePlumber:"
    sub "     Assertion '__n < this->size()' failed."
    sub "     SwStatsCpu::processBayerFrame2 <- Debayer{Cpu,EGL}::process"
    sub "   LIBCAMERA_SOFTISP_MODE=cpu does NOT help — it is the shared stats path."
    sub "   Fix: build the IPU7 pipeline handler (hardware ISP via psys0):"
    sub "     https://github.com/jibsta210/ipu7-camera-linux -> libcamera-pipeline/BUILD.md"
    sub "   NOTE: its ISP parameters were captured for OV08X40. Another RGB"
    sub "   sensor will need its own and may not work unmodified."
    next "build the IPU7 libcamera pipeline handler — without it browsers cannot open this camera" ;;
  "")
    p "libcamera pipeline" "not tested (no wireplumber journal for this boot)"
    untested "could not determine which libcamera pipeline handler PipeWire is using" ;;
  *)
    p "libcamera pipeline" "$_PH" ;;
esac

# THE DANGEROUS COMBINATION. The bus fix lets probe run past device_register()
# and straight into ipu7_psys_init_debugfs(), which dereferences
# psys->adev->isp->ipu7_dir -- a field read at the wrong offset when psys is
# DKMS and intel_ipu7 is the kernel's. That is not a failed probe, it is a wild
# pointer in module_init: the udev worker dies and the rest soft-lock, so the
# machine does not boot. Warn loudly whenever one is applied without the other.
_dv=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers[/,] *\([^,]*\),.*|\1|p' | sort -u | head -1)
_dsrc=/usr/src/ipu7-drivers-$_dv/drivers/media/pci/intel/ipu7/psys/ipu-psys.c
if [ -n "$_dv" ] && [ -f "$_dsrc" ]; then
  if grep -q 'bus_register(&ipu7_psys_bus)' "$_dsrc" &&
     ! grep -q 'debugfs_create_dir("ipu7-psys", NULL)' "$_dsrc"; then
    p "psys debugfs deref" "UNPATCHED while the bus fix IS applied"
    broke "psys will dereference a wild pointer in module_init and can make this machine UNBOOTABLE"
    sub "-> the bus fix lets probe reach ipu7_psys_init_debugfs(), which reads"
    sub "   psys->adev->isp->ipu7_dir at the wrong struct offset and passes the"
    sub "   result to debugfs_create_dir(). Expect, at boot:"
    sub "     Oops: general protection fault ... debugfs_create_dir"
    sub "     watchdog: BUG: soft lockup ... [modprobe]"
    sub "   Fix BEFORE rebooting:"
    sub "     sudo $ROOT/dkms/ipu7-psys-patches/fix-psys-debugfs.sh"
    sub "     then rebuild for every kernel"
    sub "   Already stuck? Boot once with  modprobe.blacklist=intel_ipu7_psys"
    next "apply fix-psys-debugfs.sh and rebuild BEFORE rebooting — psys can oops the kernel as it stands"
  elif grep -q 'debugfs_create_dir("ipu7-psys", NULL)' "$_dsrc"; then
    p "psys debugfs deref" "patched (no wild isp->ipu7_dir deref)"
  fi
fi

# PipeWire reaches libcamera through a SEPARATE SPA plugin, shipped in its own
# package that nothing pulls in automatically (an *optional* dependency of
# pipewire on Arch). Without it WirePlumber's libcamera monitor runs and creates
# no devices, so `wpctl status` shows an empty Video section and every
# application reports no camera -- while `cam --list` and `cam --capture` work
# perfectly, because they use libcamera directly and never touch the plugin.
#
# That split is why this is worth its own check: the two most obvious tests
# disagree, and the one that looks authoritative is the one that is wrong.
_SPA=""
for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu; do
  for c in "$d"/spa-0.2/libcamera/libspa-libcamera.so; do
    [ -e "$c" ] && { _SPA="$c"; break 2; }
  done
done
if [ -n "$_SPA" ]; then
  p "PipeWire libcamera plugin" "present"
else
  p "PipeWire libcamera plugin" "MISSING — applications will see no camera"
  broke "libspa-libcamera.so is not installed, so PipeWire cannot expose any libcamera device"
  sub "-> this is the usual reason 'cam --list' finds cameras but 'wpctl status'"
  sub "   shows an empty Video section. PipeWire talks to libcamera through a"
  sub "   separate SPA plugin that is NOT installed by default and that nothing"
  sub "   else depends on."
  sub "   Arch / CachyOS:  sudo pacman -S pipewire-libcamera"
  sub "   Fedora:          sudo dnf install pipewire-plugin-libcamera"
  sub "   Debian/Ubuntu:   sudo apt install pipewire-libcamera"
  sub "   then: systemctl --user restart pipewire wireplumber"
  next "install the PipeWire libcamera plugin, then 'systemctl --user restart pipewire wireplumber'"
fi

# Only meaningful once the plugin is there -- reporting an empty Video section
# when the plugin is missing would just restate the line above.
# wpctl talks to the PipeWire instance in the CALLER's session. This script is
# meant to be run with sudo, and root's session has no camera devices in it --
# so asking as root reports zero on a machine whose user session has two, and
# calls a working install BROKEN. Ask as the desktop user.
wpctl_status(){
  _u=${SUDO_USER:-}
  [ -z "$_u" ] && _u=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "root" { print $3; exit }')
  [ -z "$_u" ] && _u=$(logname 2>/dev/null || true)
  if [ $IS_ROOT -eq 1 ] && [ -n "$_u" ] && [ "$_u" != root ]; then
    _uid=$(id -u "$_u" 2>/dev/null || true)
    if [ -n "$_uid" ]; then
      runuser -u "$_u" -- env XDG_RUNTIME_DIR="/run/user/$_uid" timeout 20 wpctl status 2>/dev/null
      return
    fi
  fi
  timeout 20 wpctl status 2>/dev/null
}

if [ -n "$_SPA" ] && have wpctl; then
  WPCAMS=$(wpctl_status | sed -n '/Video/,/Sinks/p' | grep -cE '\[libcamera\]' || true)
  if [ "${WPCAMS:-0}" -gt 0 ]; then
    p "PipeWire video devices" "$WPCAMS"
  elif [ "${CAMS:-0}" -gt 0 ]; then
    p "PipeWire video devices" "0 — libcamera sees $CAMS, PipeWire exposes none"
    broke "PipeWire exposes no camera although libcamera enumerates $CAMS — applications will find nothing"
    next "restart the stack: 'systemctl --user restart pipewire wireplumber', then re-run this script"
  fi
fi

# ---------------------------------------------------------------------------
sec "-- IR camera / face unlock --"
IR_BROKEN=0
if [ $HAS_IR -eq 0 ] && [ -z "${HW_SENSORS:-}" ]; then
  # "no IR sensor on this board" is a claim, and an empty firmware sensor list
  # is not evidence for it -- it is the absence of evidence either way. Saying
  # n/a here would let a machine whose ACPI could not be read reach RESULT: OK
  # on the strength of a check that never found anything to look at.
  p "IR path" "not tested — this machine's firmware declared no sensor ids"
  sub "no HIMX1092/OVTI08F4/OVTI05C1/INT3472 under /sys/bus/acpi/devices, and no"
  sub "hm1092 entity in the media graph. That is not the same as 'this board has"
  sub "no IR sensor' — it means nothing was found to answer the question with."
  untested "whether this board has an IR sensor could not be established: the firmware declared no sensor ids and there is no hm1092 in the media graph"
elif [ $HAS_IR -eq 0 ]; then
  p "IR path" "n/a (no IR sensor on this board)"
  sub "HIMX1092 is not declared by this machine's firmware and no hm1092 entity"
  sub "is in the media graph. This is normal on RGB-only boards — nothing below"
  sub "this line is missing, it simply does not apply to you."
else
  if mod_loaded hm1092; then
    p "module hm1092" "loaded ($(mod_origin "$(mod_path hm1092)"))"
  else
    p "module hm1092" "MISSING — the IR sensor has no driver bound"
    broke "hm1092 is not loaded — IR face unlock cannot work"; IR_BROKEN=1
  fi

  # link_frequency must be the DDR clock (180,480,000), not the per-lane bit
  # rate. Publishing the bit rate ran the D-PHY at 2x the sensor's rate: the
  # clock lane came up and no data packet ever framed.
  if [ -n "$LD_IR_SD" ] && have v4l2-ctl; then
    LF=$(v4l2-ctl -d "$LD_IR_SD" --get-ctrl=link_frequency 2>/dev/null | grep -oE '\(([0-9]+)' | tr -d '(' || true)
    if [ -z "${LF:-}" ]; then
      p "link_frequency" "not tested (the control could not be read from $LD_IR_SD)"
      untested "link_frequency could not be read from the IR subdev"
    elif [ "$LF" = "180480000" ]; then
      p "link_frequency" "180480000 (correct)"
    else
      p "link_frequency" "$LF <-- WRONG, must be 180480000"
      broke "the IR sensor publishes link_frequency=$LF; at anything but 180480000 the CSI-2 D-PHY is misprogrammed and no frame ever arrives"; IR_BROKEN=1
    fi
  elif [ -z "$LD_IR_SD" ]; then
    p "link_frequency" "not tested (no IR subdev node in the media graph)"
    untested "link_frequency was not read: the hm1092 subdev is not in the media graph"
  else
    p "link_frequency" "not tested (v4l2-ctl is not installed — package: v4l-utils)"
    untested "link_frequency was not read: v4l2-ctl is not installed"
  fi

  # The illuminator. 0 while idle is CORRECT -- it only lights during capture,
  # matching Windows. A stock implementation leaves it on 24/7.
  L=/sys/class/leds/HIMX1092_00::ir_flood_led/brightness
  if [ -e "$L" ]; then
    p "IR flood LED" "present (brightness=$(cat "$L" 2>/dev/null || echo '?')) — 0 is correct while idle"
    perm=$(stat -c '%U:%G %a' "$L" 2>/dev/null || true)
    mode=$(stat -c '%a' "$L" 2>/dev/null || true)
    p "IR flood LED perms" "${perm:-unknown}"
    # Group-write is what matters: Howdy's recognition runs as YOUR user under a
    # lock screen. Without it the illuminator never fires, every frame is too
    # dark to find a face, and the failure looks like bad recognition.
    case ${mode:+${mode: -2:1}} in
      "") sub "could not read this LED's permissions ('stat' is not installed?)" ;;
      2|3|6|7) ;;
      *) sub "the video group cannot write this LED, so Howdy (which runs as your"
         sub "own user under a lock screen) can never turn the illuminator on"
         next "install udev/99-hm1092-ir-led.rules — re-run 'sudo $ROOT/install.sh' — so the video group can write $L" ;;
    esac
  else
    p "IR flood LED" "MISSING — INT3472 did not create the illuminator LED"
    broke "the IR illuminator LED node does not exist — Howdy will see only dark frames"; IR_BROKEN=1
  fi
fi

# --- psys suspend patches ---------------------------------------------------
# Resolve the module rather than constructing its path: it is .ko.zst under
# updates/dkms on Arch, an uncompressed .ko on Debian, and under extra/ on
# Fedora. Building the Arch path meant this line silently vanished on three of
# the four distros the README invites people to use, and the README then told
# the reader that absence was "also fine" -- turning a detection gap into a shrug.
PSYSKO=$(mod_path intel_ipu7_psys)
if [ -z "$PSYSKO" ]; then
  p "psys suspend patches" "n/a (intel_ipu7_psys is not installed on this kernel)"
elif [ "$(mod_origin "$PSYSKO")" != dkms ]; then
  p "psys suspend patches" "n/a (intel_ipu7_psys comes from your kernel package, not DKMS)"
elif ! ko_cat "$PSYSKO" >/dev/null 2>&1; then
  # Deliberately NOT counted as an untested check in the verdict: this line
  # answers "will s2idle suspend oops the psys driver", not "does the camera
  # work", and the verdict claims only the second. It is still reported, so it
  # cannot be silently dropped.
  p "psys suspend patches" "not tested (cannot read $PSYSKO — install zstd/xz)"
  next "the s2idle suspend patches could not be checked: install zstd (or xz) and re-run if suspend misbehaves"
else
  n=$(ko_cat "$PSYSKO" 2>/dev/null | grep -aoE 'psys not ready after resume|ioctl: resume failed' | sort -u | wc -l)
  # "in the loaded build" was wrong: this reads the file modinfo -n points at,
  # which is what the NEXT boot loads. It prints for a module that is not loaded
  # at all, and it printed "2/2" beside a MISSING /dev/ipu7-psys0 -- a green
  # number for a driver that never bound. Say which artefact was read.
  # What the SOURCE says, so a mismatch can be named as a mismatch. Five separate
  # failures on this project were all "the thing you fixed is not the thing that
  # is running" -- a stale module, a stale initramfs, a stale copy in the search
  # path, headers disagreeing with the running kernel, and a DKMS build that did
  # not pick up its own source. Every one presented as something else. Comparing
  # source against module is the check that catches the whole class.
  _sv=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*|\1|p' | sort -u | head -1)
  _ss=/usr/src/ipu7-drivers-$_sv/drivers/media/pci/intel/ipu7/psys/ipu-psys.c
  _sn=0
  [ -f "$_ss" ] && _sn=$(grep -acE 'psys not ready after resume|ioctl: resume failed' "$_ss" 2>/dev/null)

  if [ "${n:-0}" -eq 2 ]; then
    p "psys suspend patches" "2/2 present in the module on disk"
  elif [ -f "$_ss" ] && [ "${_sn:-0}" -gt 0 ]; then
    # The source has them and the module does not. This is not "partly patched",
    # it is a build that never ran -- and telling someone to re-apply patches
    # here sends them round a loop with nothing left to apply, which is exactly
    # what happened to a reporter for three rounds.
    p "psys suspend patches" "$n/2 in the module, but PRESENT in the source"
    sub "-> your source is patched and your module is not: the rebuild never"
    sub "   happened, or DKMS built from somewhere other than $_ss"
    sub "   Fix: sudo dkms install --force ipu7-drivers/$_sv -k \$(uname -r)"
    sub "   Then check BEFORE rebooting — it takes seconds instead of a cycle:"
    case "$PSYSKO" in
      *.zst) _dc="zstd -dcq" ;;
      *.xz)  _dc="xz -dc" ;;
      *.gz)  _dc="gzip -dc" ;;
      *)     _dc="cat" ;;
    esac
    sub "     sudo $_dc \"\$(modinfo -n intel_ipu7_psys)\" | grep -ac 'psys not ready after resume'"
    sub "   If that still prints 0, DKMS is not building what you patched:"
    sub "     ls -l /var/lib/dkms/ipu7-drivers/$_sv/source"
    next "the psys source is patched but the built module is not — rebuild with 'sudo dkms install --force ipu7-drivers/$_sv -k \$(uname -r)', do NOT re-apply the patches"
  else
    p "psys suspend patches" "$n/2 in the module on disk — s2idle suspend is only partly patched"
    next "re-run install.sh: the s2idle suspend patch is not fully present in the psys module ($n of 2 markers)"
  fi
  sub "read from $PSYSKO, not from the running kernel"
  mod_loaded intel_ipu7_psys || sub "intel_ipu7_psys is NOT loaded, so this describes what the next boot would load"
  sub "this counts SUSPEND fixes only; it says nothing about whether psys binds"
fi

# --- Howdy ------------------------------------------------------------------
if [ $HAS_IR -eq 1 ]; then
  HR=""
  for d in /usr/lib/howdy/recorders /usr/local/lib/howdy/recorders /lib/howdy/recorders \
           /usr/lib/security/howdy/recorders /usr/local/lib/security/howdy/recorders; do
    [ -d "$d" ] && { HR=$d; break; }
  done
  if [ -z "$HR" ]; then
    p "howdy" "not installed (no recorders directory found)"
  else
    p "howdy ir_reader" "$([ -e "$HR/ir_reader.py" ] && echo "installed in $HR" || echo "MISSING from $HR")"
    [ -e "$HR/ir_reader.py" ] || broke "Howdy is installed but howdy/ir_reader.py is not — face unlock has no IR recorder"
    CFG=""
    for c in /etc/howdy/config.ini "$(dirname "$HR")/config.ini" \
             /usr/lib/howdy/config.ini /usr/local/lib/howdy/config.ini \
             /usr/lib/security/howdy/config.ini; do
      [ -f "$c" ] && { CFG=$c; break; }
    done
    if [ -z "$CFG" ]; then
      p "howdy config" "NOT FOUND"
      broke "Howdy's config.ini could not be found, so nothing selects the IR recorder"
    else
      p "howdy config" "$CFG"
      for k in recording_plugin device_path dark_threshold; do
        v=$(sed -n "s/^${k}[[:space:]]*=[[:space:]]*//p" "$CFG" | head -1)
        p "  $k" "${v:-(unset)}"
      done
      DEV=$(sed -n 's/^device_path[[:space:]]*=[[:space:]]*//p' "$CFG" | head -1)
      if [ -z "$DEV" ]; then
        next "set device_path in $CFG — run $ROOT/tools/find-ir-node.sh to get the right /dev/videoN"
      elif [ -n "$LD_NODE" ] && [ "$DEV" != "$LD_NODE" ]; then
        sub "config says $DEV, the media graph says the IR node is $LD_NODE"
        sub "node numbers shuffle between boots, so this may simply be stale"
        next "device_path in $CFG is $DEV but the IR capture node is currently $LD_NODE"
      fi
    fi
  fi
fi

# --- live IR capture --------------------------------------------------------
sec "-- live IR capture --"
CAPTURE_RESULT=skipped
if [ $HAS_IR -eq 0 ]; then
  p "capture test" "n/a (no IR sensor on this board)"
elif [ $IS_ROOT -eq 0 ]; then
  p "capture test" "not tested (needs root)"
  untested "the live IR capture test needs root and was not run"
elif [ -z "$LD_CSI_PORT" ] || [ -z "$LD_NODE" ] || [ -z "$LD_IR_SENS" ] || [ -z "$LD_CAP" ]; then
  # Refuse to guess. The old copy assumed CSI2 port 2 and /dev/video16, and on
  # a port-1 board that produced a confident "NO FRAMES" on a healthy camera.
  p "capture test" "not tested — the media graph could not be resolved"
  sub "CSI-2 port: ${LD_CSI_PORT:-UNDETECTED}   capture node: ${LD_NODE:-UNDETECTED}"
  # NOTE: no apostrophes inside a ${x:-default} — bash parses quotes inside the
  # default word even within double quotes, and one stray ' swallows the rest of
  # the file into a string literal.
  sub "${LD_WHY:-could not follow the links out of the sensor}"
  sub "guessing a port or a video node here is how a working camera gets"
  sub "reported as broken, so no capture was attempted."
  untested "the IR capture test could not run: the CSI-2 port and/or capture node could not be resolved from the media graph"
  next "run $ROOT/tools/find-ir-node.sh and include its output in any report"
elif ! have v4l2-ctl || ! have media-ctl; then
  p "capture test" "not tested (v4l-utils is not installed)"
  untested "v4l-utils is not installed, so no capture was attempted"
else
  p "CSI-2 port" "$LD_CSI_PORT (followed from ${LD_IR_SENS}'s own link)"
  p "capture node" "$LD_NODE"

  # Turn on just the one SOF line, and put dynamic_debug back the way it was.
  # Leaving it on fills the kernel log with SOF spam long after verification.
  # NEVER enable the whole isys module here: that logs every MMIO access and
  # preceded a hard freeze on 2026-07-24.
  DYN=/sys/kernel/debug/dynamic_debug/control
  DYN_WAS=off
  if [ -r "$DYN" ]; then
    grep -m1 'sof_event' "$DYN" 2>/dev/null | grep -q '=p' && DYN_WAS=on
    [ "$DYN_WAS" = on ] || { echo "format sof_event +p" > "$DYN" 2>/dev/null || true; }
    trap '[ "$DYN_WAS" = on ] || echo "format sof_event -p" > "$DYN" 2>/dev/null || true' EXIT
  fi

  # A fresh boot leaves the CSI2->capture link disabled and the pads at their
  # 4096x3072 default, so streaming returns zero frames. Configure the graph
  # first, by the entity NAMES this machine actually has.
  #
  # Every one of these used to end in `2>/dev/null || true`. That is the same
  # bug as the hardcoded CSI-2 port wearing different clothes: when OUR setup
  # step fails, the stream that follows cannot produce a frame, and the zero
  # was then reported as "the IR sensor produced no start-of-frame" -- a hard
  # BROKEN verdict manufactured by this script's own failed command, on a
  # camera nobody has yet shown to be faulty. A step that did not happen may
  # not be used as evidence about the hardware.
  MC_ERR=""
  mc(){
    if ! MC_OUT=$(media-ctl -d "$LD_MEDIA" "$@" 2>&1); then
      [ -n "$MC_ERR" ] || MC_ERR="media-ctl $* -> ${MC_OUT:-(no message)}"
      return 1
    fi
    return 0
  }
  mc --set-v4l2 "\"$LD_IR_SENS\":0 [fmt:SGRBG10_1X10/648x368]" || true
  mc --set-v4l2 "\"$LD_CSI\":0 [fmt:SGRBG10_1X10/648x368]" || true
  mc --set-v4l2 "\"$LD_CSI\":1 [fmt:SGRBG10_1X10/648x368]" || true
  mc -l "\"$LD_CSI\":1 -> \"$LD_CAP\":0 [1]" || true

  if [ -n "$MC_ERR" ]; then
    p "capture test" "not tested — the media graph could not be configured"
    sub "$MC_ERR"
    sub "the pads and the CSI2->capture link were not set up, so a stream now"
    sub "could not produce a frame whatever the sensor did. Reporting NO FRAMES"
    sub "from that would blame the camera for this script's own failed command."
    untested "the IR capture test could not run: media-ctl failed to configure the graph ($MC_ERR)"
    next "run 'sudo media-ctl -d $LD_MEDIA -p' and include its output in any report — the graph could not be configured for the capture test"
  else
    # Mark the end of the ring buffer and count only what arrives after it. The
    # old copy ran `dmesg -C`, wiping every boot-time probe message -- including
    # the evidence the README asks you to paste two steps later.
    MARK=$(dmesg 2>/dev/null | wc -l)
    # Keep v4l2-ctl's exit status AND its message. Discarding them meant an
    # EBUSY -- the node already held open by PipeWire, which is the normal state
    # on a desktop -- came out as "0 <-- no frames arrived" and RESULT: BROKEN.
    CAP_OUT=$(timeout 15 v4l2-ctl -d "$LD_NODE" \
        --set-fmt-video=width=648,height=368,pixelformat=BA10 \
        --stream-mmap --stream-count=5 --stream-to=/dev/null 2>&1)
    CAP_RC=$?
    NOW=$(dmesg 2>/dev/null | wc -l)
    if [ "$CAP_RC" -ne 0 ]; then
      p "capture test" "not tested — v4l2-ctl could not stream from $LD_NODE (exit $CAP_RC)"
      printf '%s\n' "$CAP_OUT" | sed -n '1,3p' | sed 's/^/      /'
      case $CAP_OUT in
        *"Device or resource busy"*|*EBUSY*)
          sub "something already has the node open — PipeWire and any camera app"
          sub "hold it. Close them (or 'systemctl --user stop pipewire') and re-run." ;;
        *) sub "the stream never started, so no conclusion can be drawn about the sensor" ;;
      esac
      untested "the IR capture test could not run: v4l2-ctl exited $CAP_RC on $LD_NODE without streaming"
      next "free $LD_NODE (close camera apps / stop PipeWire) and re-run 'sudo $ROOT/tools/verify.sh' — the capture never started, so IR is untested"
    elif [ "$NOW" -lt "$MARK" ]; then
      p "SOF on csi2-$LD_CSI_PORT" "not tested (the kernel ring buffer wrapped during the test)"
      untested "the kernel log wrapped mid-test, so start-of-frame events could not be counted"
    else
      SOF=$(dmesg 2>/dev/null | tail -n +$((MARK + 1)) | grep -c "sof_event::csi2-$LD_CSI_PORT" || true)
      if [ "${SOF:-0}" -gt 0 ]; then
        p "SOF on csi2-$LD_CSI_PORT" "$SOF <-- STREAMING"
        CAPTURE_RESULT=ok
      else
        p "SOF on csi2-$LD_CSI_PORT" "0 <-- no frames arrived"
        CAPTURE_RESULT=fail
        broke "the IR sensor produced no start-of-frame on csi2-$LD_CSI_PORT — the graph was configured and v4l2-ctl streamed without error, so the sensor itself delivered nothing"; IR_BROKEN=1
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# One verdict, one exit code. Everything above is evidence; this is the answer.
# The previous version ended on whatever the last check returned, so
# `verify.sh && echo ok` meant nothing, and a reader needed three paragraphs of
# README to work out which lines they were supposed to ignore.
printf '\n'
if [ ${#NEXT[@]} -gt 0 ]; then
  printf 'What to do next:\n'
  for x in "${NEXT[@]}"; do printf '  - %s\n' "$x"; done
  printf '\n'
fi

if [ ${#BROKEN[@]} -gt 0 ]; then
  printf 'RESULT: BROKEN\n'
  for x in "${BROKEN[@]}"; do printf '  * %s\n' "$x"; done
  if [ ${#UNTESTED[@]} -gt 0 ]; then
    printf '  (also not tested: %d check(s) — see above)\n' "${#UNTESTED[@]}"
  fi
  printf '\nPaste this whole output into an issue, plus:  uname -r; dkms status\n'
  exit 1
fi

if [ ${#UNTESTED[@]} -gt 0 ]; then
  printf 'RESULT: UNDETERMINED — nothing is proven broken, but these were not tested:\n'
  for x in "${UNTESTED[@]}"; do printf '  * %s\n' "$x"; done
  printf '\nThis is not a pass. Re-run as root, with v4l-utils installed, to get a\nreal answer:  sudo %s/tools/verify.sh\n' "$ROOT"
  exit 2
fi

if [ $HAS_IR -eq 0 ]; then
  printf 'RESULT: OK — RGB camera working, no IR sensor on this board\n'
elif [ "$CAPTURE_RESULT" = ok ]; then
  printf 'RESULT: OK — RGB camera working, IR camera streaming\n'
else
  # Unreachable today: every path that skips the capture records an UNTESTED
  # entry and has already exited 2 above. It stays as a hard floor, because the
  # branch it replaces said "RESULT: OK — RGB camera working, IR present" for
  # exactly this state -- a pass built on the sensor merely EXISTING, which is
  # not the same claim as the IR camera working. One future edit that skips the
  # capture without recording why would have turned "never tested" into OK.
  printf 'RESULT: UNDETERMINED — RGB camera working; the IR capture was skipped\n'
  printf 'without recording why, so nothing here can say whether IR works.\n'
  exit 2
fi
exit 0
