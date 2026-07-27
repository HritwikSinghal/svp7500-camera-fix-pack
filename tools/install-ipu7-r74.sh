#!/bin/bash
# ===========================================================================
# Put ipu7-drivers back on r74, the last revision that works.
#
#   sudo tools/install-ipu7-r74.sh            # do it
#   sudo tools/install-ipu7-r74.sh --dry-run  # show every step, change nothing
#   sudo tools/install-ipu7-r74.sh --check    # just report what you have
#
# WHY
#   Revisions r76 and later carry the 2026-06-29 vendor drop (commit 0e8c71a),
#   which appends two fields to struct ipu7_bus_device:
#
#       struct mutex acquire_fw_task_buffer_lock;
#       unsigned int (*get_running_fw_task_count)(struct ipu7_bus_device *adev);
#
#   and makes ipu7_psys_probe() WRITE to one of them. That struct is allocated
#   by intel_ipu7. On every distro that ships the staging intel_ipu7 with the
#   kernel while psys comes from DKMS -- which is Arch, CachyOS and anything
#   else on a recent kernel -- the two disagree about its layout, so psys writes
#   past the end of a kernel-owned allocation and locks memory that is not a
#   mutex.
#
#   The symptom is silent: /dev/ipu7-psys0 never appears and the RGB camera is
#   gone. isys binds normally because it ships alongside intel_ipu7, which makes
#   the failure look selective and sends people debugging the wrong component.
#
#   Reported upstream: https://github.com/intel/ipu7-drivers/issues/93
#   r76 additionally produced a runtime psys_ioctl GPF on the author's machine.
#
#   Check whether it applies to you:
#       modinfo -n intel_ipu7        # kernel/drivers/staging/media/ipu7/...
#       modinfo -n intel_ipu7_psys   # updates/dkms/...
#   Split provenance like that is the trigger.
#
# WHAT THIS DOES
#   Builds ipu7-drivers at commit 24d8923 (r74) for every installed kernel,
#   re-applies the psys patches this pack needs, and pins the package so the
#   next -Syu does not undo it. It does NOT reboot.
# ===========================================================================
set -euo pipefail

R74_COMMIT=24d8923
R74_VER="r74.$R74_COMMIT"
UPSTREAM=https://github.com/intel/ipu7-drivers
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHDIR=""
for c in "$HERE/../dkms/ipu7-psys-patches" "$HERE/../kernel/ipu7-psys-patches"; do
  [[ -d $c ]] && { PATCHDIR="$(cd "$c" && pwd)"; break; }
done

DRY=0 CHECK=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --check)   CHECK=1 ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m✗\033[0m %s\n' "$*"; }
run()  { if [[ $DRY -eq 1 ]]; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

# --- what do we have now? ----------------------------------------------------
say "Current state"
CUR=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*|\1|p' | sort -u | head -1)
PKG=$(pacman -Q intel-ipu7-dkms-git 2>/dev/null | awk '{print $2}' || true)
printf '    %-26s %s\n' "dkms ipu7-drivers"  "${CUR:-<none>}"
printf '    %-26s %s\n' "pacman package"     "${PKG:-<not installed via pacman>}"
printf '    %-26s %s\n' "/dev/ipu7-psys0"    "$([ -e /dev/ipu7-psys0 ] && echo present || echo MISSING)"
printf '    %-26s %s\n' "intel_ipu7 from"    "$(modinfo -n intel_ipu7 2>/dev/null | grep -qE '/kernel/' && echo kernel || echo dkms)"
printf '    %-26s %s\n' "intel_ipu7_psys from" "$(modinfo -n intel_ipu7_psys 2>/dev/null | grep -qE '/updates/' && echo dkms || echo kernel)"

# rNN ordering is numeric, so a plain string compare would call r9 newer than r76
rnum() { echo "${1:-r0}" | sed -n 's/^r\([0-9]\+\).*/\1/p'; }
CURN=$(rnum "${CUR:-}")
if [[ -n ${CURN:-} && $CURN -ge 76 ]]; then
  bad "r$CURN carries the ABI break — psys cannot bind on this kernel"
elif [[ -n ${CURN:-} && $CURN -eq 74 ]]; then
  ok "already on r74"
  if [[ -e /dev/ipu7-psys0 ]]; then
    # Do NOT fall through. Everything below rebuilds, and a rebuild that fails
    # leaves a kernel with no psys module at all -- i.e. it would break a
    # machine that was working, immediately after telling the user there was
    # nothing to do.
    ok "and psys0 is present — nothing to do here, stopping"
    exit 0
  fi
  warn "but psys0 is MISSING, so something else is wrong; see tools/verify.sh"
elif [[ -n ${CURN:-} ]]; then
  warn "r$CURN is older than r74; this will move you FORWARD to r74"
fi
[[ $CHECK -eq 1 ]] && exit 0

[[ $EUID -eq 0 || $DRY -eq 1 ]] || { echo; echo "run as root: sudo $0"; exit 1; }

# --- fetch r74 ---------------------------------------------------------------
say "Fetching ipu7-drivers $R74_VER"
SRC=/usr/src/ipu7-drivers-$R74_VER
if [[ -d $SRC && -f $SRC/dkms.conf ]]; then
  ok "already present at $SRC"
else
  TMP=$(mktemp -d)
  run git clone -q "$UPSTREAM" "$TMP/src"
  run git -C "$TMP/src" checkout -q "$R74_COMMIT"
  run mkdir -p "$SRC"
  run cp -rT "$TMP/src" "$SRC"
  run rm -rf "$TMP"
  # dkms matches the directory name against PACKAGE_VERSION; a mismatch makes
  # `dkms add` succeed and every later command silently address a different tree.
  run sed -i "s/^PACKAGE_VERSION=\".*\"$/PACKAGE_VERSION=\"$R74_VER\"/" "$SRC/dkms.conf"
  ok "installed source at $SRC"
fi

# --- patches -----------------------------------------------------------------
say "psys patches"
if [[ -z $PATCHDIR ]]; then
  warn "patch directory not found next to this script — skipping (psys0 will not appear)"
else
  if [[ -f $PATCHDIR/psys-suspend-BC.patch ]]; then
    if [[ $DRY -eq 1 ]]; then
      printf '    would apply: psys-suspend-BC.patch\n'
    elif patch -p1 -d "$SRC" --forward --silent < "$PATCHDIR/psys-suspend-BC.patch" 2>/dev/null; then
      ok "suspend patches applied"
    else
      ok "suspend patches already applied"
    fi
  fi
  # Off by default since v1.1. Measured 2026-07-27: without the skip this
  # machine gets /dev/ipu7-psys0 and "IPU psys probe done", so it was never
  # needed here; WITH the skip a reporter's machine got "psys device_register
  # failed" (-22), because psys probed before intel_ipu7 was ready. The check
  # exists for a reason and removing it unconditionally turns a hang into a
  # crash. Opt in with WANT_DEFER_FIX=1 only if you have established you need it.
  if [[ ${WANT_DEFER_FIX:-0} -ne 1 ]]; then
    warn "psys defer fix NOT applied (off by default — set WANT_DEFER_FIX=1 if you have established you need it)"
  elif [[ -f $PATCHDIR/fix-psys-defer.sh ]]; then
    # Do NOT wrap this in run() with output redirected: the redirect swallows
    # run()'s "would run" line and the success branch then claims the patch was
    # applied during a dry run. Reporting success for something that did not
    # happen is the exact defect this project keeps shipping.
    if [[ $DRY -eq 1 ]]; then
      printf '    would run: fix-psys-defer.sh %s\n' "$SRC"
    elif bash "$PATCHDIR/fix-psys-defer.sh" "$SRC" >/dev/null 2>&1; then
      ok "defer check neutralised"
    else
      warn "defer fix did not apply — check /dev/ipu7-psys0 after rebooting"
    fi
  fi
fi

# --- remove the broken revision, build r74 -----------------------------------
say "Building for every installed kernel"
# Deliberately NOT `dkms remove` first. Remove-then-install opens a window where
# the machine has no psys module at all, and if the build then fails -- which is
# more likely than usual here, since the source was just patched -- the camera is
# dead on a machine that was working before this script ran. `dkms install
# --force` replaces in place and leaves the old module until the new one is
# ready. The stale registration is tidied only AFTER a successful build.
run dkms add "ipu7-drivers/$R74_VER" >/dev/null 2>&1 || true

BUILT=0 FAILED=0
for k in $(ls /lib/modules); do
  [[ -d /lib/modules/$k/build ]] || continue
  if [[ $DRY -eq 1 ]]; then
    printf '    would build for: %s\n' "$k"; BUILT=$((BUILT+1)); continue
  fi
  # build --force recompiles; install --force only re-places a cached artifact.
  # Without the build step, patching the source and re-running this changes
  # nothing at all and still reports success.
  dkms build --force "ipu7-drivers/$R74_VER" -k "$k" >/dev/null 2>&1 || true
  if dkms install --force "ipu7-drivers/$R74_VER" -k "$k" >/dev/null 2>&1; then
    ok "$k"; BUILT=$((BUILT+1))
  else
    bad "$k — FAILED"; FAILED=$((FAILED+1))
  fi
done

# --- pin ---------------------------------------------------------------------
say "Pinning"
if [[ -n ${PKG:-} ]] && command -v pacman >/dev/null 2>&1; then
  if grep -qE '^\s*IgnorePkg.*intel-ipu7-dkms-git' /etc/pacman.conf 2>/dev/null; then
    ok "intel-ipu7-dkms-git already in IgnorePkg"
  else
    warn "intel-ipu7-dkms-git is NOT pinned — the next -Syu will reinstall the broken revision"
    echo "         add to /etc/pacman.conf:"
    echo "           IgnorePkg = intel-ipu7-dkms-git"
  fi
else
  ok "not a pacman-managed install; nothing to pin"
fi

# --- verdict -----------------------------------------------------------------
say "Result"
if [[ $DRY -eq 1 ]]; then
  echo "    dry run — nothing was changed"
  exit 0
fi
if [[ $BUILT -eq 0 ]]; then
  bad "nothing was built — ipu7-drivers is NOT installed for any kernel"
  echo "       your camera will not work until this succeeds"
  exit 1
fi
if [[ $FAILED -gt 0 ]]; then
  bad "$FAILED kernel(s) failed to build; booting those leaves the camera broken"
  exit 1
fi
if [[ -n ${CUR:-} && $CUR != "$R74_VER" ]]; then
  dkms remove "ipu7-drivers/$CUR" --all >/dev/null 2>&1 || true
  ok "removed the old $CUR registration (after the new one built cleanly)"
fi
ok "$BUILT kernel(s) built at $R74_VER"
cat <<'EOF'

    REBOOT to load it. Do not modprobe -r intel_ipu7_psys to pick it up live —
    it page faults in ipu7_fw_psys_close even at refcount 0, and psys0 stays
    gone until you reboot anyway.

    Afterwards:  sudo tools/verify.sh   (expect /dev/ipu7-psys0 present)
EOF
