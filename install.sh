#!/bin/bash
# ===========================================================================
# IPU7 IR face-unlock stack — installer
#
# Brings up the HIMX1092 (HM1092) infrared camera behind a Synaptics SVP7500
# "CVS" bridge on Intel IPU7 (Panther Lake / Lunar Lake class), and wires it
# into Howdy for IR face authentication.
#
# Tested on: Dell XPS 16 (DA16260), CachyOS, kernels 7.1.x / 7.2-rc
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DO_KERNEL=1 DO_HOWDY=1
for a in "$@"; do
  case "$a" in
    --kernel-only) DO_HOWDY=0 ;;
    --howdy-only)  DO_KERNEL=0 ;;
    -h|--help) sed -n '2,12p' "$0"; echo; echo "Usage: sudo ./install.sh [--kernel-only|--howdy-only]"; exit 0 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }

say(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){  printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
if [[ $DO_KERNEL -eq 1 ]]; then
say "Installing DKMS modules"
for m in hm1092 intel-cvs int3472-patched ipu-bridge-patched; do
  src="$HERE/kernel/$m"
  [[ -d $src ]] || { warn "$m not in package, skipping"; continue; }
  ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$src/dkms.conf" | head -1)
  ver=${ver:-1.0}
  dst="/usr/src/${m}-${ver}"

  if [[ -d $dst ]]; then
    cp -a "$dst" "${dst}.bak-$(date +%Y%m%d-%H%M%S)"
    warn "existing $m backed up"
  fi
  mkdir -p "$dst"; cp -r "$src/." "$dst/"

  dkms status | grep -q "^${m}/${ver}" && dkms remove "${m}/${ver}" --all >/dev/null 2>&1 || true
  dkms add "${m}/${ver}" >/dev/null 2>&1 || true

  # Build for EVERY installed kernel. Building only $(uname -r) has repeatedly
  # left other kernels with stale modules and a dead camera after a reboot.
  for k in $(ls /lib/modules); do
    [[ -d /lib/modules/$k/build ]] || continue
    if dkms install "${m}/${ver}" -k "$k" >/dev/null 2>&1; then
      ok "$m -> $k"
    else
      warn "$m failed for $k"
    fi
  done
done

# --- vendor IPU7 psys suspend patches --------------------------------------
say "IPU7 psys suspend patches (s2idle)"
P="$HERE/kernel/ipu7-psys-patches/psys-suspend-BC.patch"
SRC=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
if [[ -n ${SRC:-} && -d /usr/src/ipu7-drivers-$SRC && -f $P ]]; then
  # Pick the tree DKMS actually HAS INSTALLED. Selecting with `ls | tail -1`
  # grabs a stale leftover tree and silently patches the wrong source.
  if patch -p1 -d "/usr/src/ipu7-drivers-$SRC" --forward --silent < "$P"; then
    ok "patches applied to ipu7-drivers-$SRC"
  else
    ok "already applied"
  fi
  # psys defers forever when intel_ipu7 comes from the kernel and psys from
  # DKMS: they disagree on struct ipu7_device's layout, so the ready_to_probe
  # read lands at the wrong offset. Result is a MISSING /dev/ipu7-psys0 and no
  # RGB camera, while isys binds normally because it ships with the kernel.
  if bash "$HERE/kernel/ipu7-psys-patches/fix-psys-defer.sh" "/usr/src/ipu7-drivers-$SRC" >/dev/null 2>&1; then
    ok "psys defer check neutralised"
  else
    warn "psys defer fix did not apply — check /dev/ipu7-psys0 after reboot"
  fi

  for k in $(ls /lib/modules); do
    [[ -d /lib/modules/$k/build ]] || continue
    dkms remove  "ipu7-drivers/$SRC" -k "$k" >/dev/null 2>&1 || true
    dkms install "ipu7-drivers/$SRC" -k "$k" >/dev/null 2>&1 && ok "ipu7-drivers -> $k" || warn "ipu7-drivers failed for $k"
  done
else
  warn "ipu7-drivers DKMS not installed — skipping psys patches"
fi
fi

# ---------------------------------------------------------------------------
if [[ $DO_HOWDY -eq 1 ]]; then
say "IR illuminator permissions"
# Howdy's recognition process runs as the UNPRIVILEGED USER when invoked from a
# lock screen / PAM stack. The illuminator is root-only sysfs by default, so it
# silently never fires there and every frame is too dark to detect a face --
# authentication times out while working perfectly under sudo.
install -m 0644 "$HERE/udev/99-hm1092-ir-led.rules" /etc/udev/rules.d/
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=leds --action=change 2>/dev/null || true
LEDB=/sys/class/leds/HIMX1092_00::ir_flood_led/brightness
if [[ -e $LEDB ]]; then
  ok "illuminator: $(stat -c '%U:%G %a' "$LEDB")"
else
  warn "illuminator LED not present yet (appears once int3472 binds)"
fi

say "Howdy IR integration"
HR=/usr/lib/howdy/recorders
if [[ -d $HR ]]; then
  install -m 0444 "$HERE/howdy/ir_reader.py" "$HR/ir_reader.py"
  ok "installed $HR/ir_reader.py"

  if ! grep -q 'ir_reader' "$HR/video_capture.py"; then
    cp "$HR/video_capture.py" "$HR/video_capture.py.bak-$(date +%Y%m%d-%H%M%S)"
    chmod 644 "$HR/video_capture.py"
    patch -p0 -d / --forward --silent < "$HERE/howdy/video_capture.patch" \
      && ok "patched video_capture.py" || warn "video_capture.py patch failed — apply howdy/video_capture.patch by hand"
    chmod 444 "$HR/video_capture.py"
  else
    ok "video_capture.py already has the ir plugin"
  fi

  CFG=/etc/howdy/config.ini
  if [[ -f $CFG ]]; then
    cp "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
    # device_path is set by the user after checking which /dev/videoN is the IR
    # capture node (see tools/find-ir-node.sh) -- node numbers are NOT stable.
    sed -i 's/^recording_plugin *=.*/recording_plugin = ir/' "$CFG"
    # dark_threshold is the % of NEAR-BLACK pixels above which a frame is
    # rejected -- NOT brightness. IR frames are ~70-77% black because the flood
    # lights only the face, so the stock 60 rejects every frame.
    sed -i 's/^dark_threshold *=.*/dark_threshold = 90/' "$CFG"
    sed -i 's/^timeout *=.*/timeout = 6/' "$CFG"
    ok "config: recording_plugin=ir, dark_threshold=90"
    warn "set device_path to your IR node: $HERE/tools/find-ir-node.sh"
  else
    warn "no /etc/howdy/config.ini — is Howdy installed?"
  fi
else
  warn "Howdy not found at /usr/lib/howdy — skipping (use --kernel-only)"
fi
fi

say "Done"
cat <<'EOF'
    REBOOT is required: hm1092 leaks module references and can never be
    swapped live (unbind succeeds, refcount stays >0, rmmod says "in use").

    After rebooting:
      tools/verify.sh          check the whole stack
      tools/find-ir-node.sh    identify the IR /dev/videoN
      sudo howdy -U $USER add  enrol a face model
EOF
