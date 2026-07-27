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
#   Builds ipu7-drivers at commit 24d8923 (r74) for every installed kernel and
#   re-applies the psys patches this pack needs. It proves each build from the
#   .ko on disk, not from dkms's exit code. It does NOT reboot.
#
#   It does NOT edit /etc/pacman.conf: it CHECKS whether the package is pinned
#   and prints the IgnorePkg line to add if it is not. The header used to say it
#   pinned the package, which it never did -- so a user who read that and did
#   not read the output was one -Syu away from the broken revision returning.
#
# Exit status: 0 every kernel got a psys module on disk AND the patches are in
#                the source that built them,
#              1 something above did not happen (it is named),
#              2 bad usage.
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
    # Print the file's own header rather than a hardcoded line range: '2,46p'
    # silently truncated the moment the header grew, so --help stopped showing
    # the exit-status contract it had just gained.
    -h|--help) awk 'NR>2 { if (/^# ={10,}$/) exit; sub(/^# ?/,""); print }' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

# Counted, not narrated. A patch that did not apply and a module that is not on
# disk both have to be able to reach the exit status; a `warn` cannot.
PATCH_FAIL=0
NOKO=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m✗\033[0m %s\n' "$*"; }
run()  { if [[ $DRY -eq 1 ]]; then printf '    would run: %s\n' "$*"; else "$@"; fi; }

# Did a module actually land for this kernel? Out-of-tree destinations only --
# finding the kernel's own copy would make a failed build look like a success.
ko_landed(){
  local k=$1 n=$2 d
  for d in updates extra weak-updates; do
    [[ -d /lib/modules/$k/$d ]] || continue
    find "/lib/modules/$k/$d" -type f \( -name "${n}.ko" -o -name "${n}.ko.*" \
         -o -name "${n//-/_}.ko" -o -name "${n//-/_}.ko.*" \) 2>/dev/null \
      | grep -q . && return 0
  done
  return 1
}

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
  [[ -e /dev/ipu7-psys0 ]] && ok "and psys0 is present — nothing to do here" \
                           || warn "but psys0 is MISSING, so something else is wrong; see tools/verify.sh"
elif [[ -n ${CURN:-} ]]; then
  warn "r$CURN is older than r74; this will move you FORWARD to r74"
fi
[[ $CHECK -eq 1 ]] && exit 0

[[ $EUID -eq 0 || $DRY -eq 1 ]] || { echo; echo "run as root: sudo $0"; exit 1; }

# --- fetch r74 ---------------------------------------------------------------
say "Fetching ipu7-drivers $R74_VER"
SRC=/usr/src/ipu7-drivers-$R74_VER
# Reusing an existing tree skips the PACKAGE_VERSION rewrite below, so check it
# here: dkms matches the directory name against PACKAGE_VERSION, and a mismatch
# makes `dkms add` succeed while every later command addresses a different tree.
# A leftover from an interrupted run would have been accepted with a ✓.
if [[ -d $SRC && -f $SRC/dkms.conf ]] \
   && grep -q "^PACKAGE_VERSION=\"$R74_VER\"$" "$SRC/dkms.conf"; then
  ok "already present at $SRC (PACKAGE_VERSION=$R74_VER)"
elif [[ -d $SRC && -f $SRC/dkms.conf ]]; then
  bad "$SRC exists but its dkms.conf says $(sed -n 's/^PACKAGE_VERSION=//p' "$SRC/dkms.conf" | head -1), not \"$R74_VER\""
  echo "       dkms would address a different tree than the one this builds."
  echo "       Remove it and re-run:  sudo rm -rf $SRC"
  exit 1
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
  # Only claim it after looking. This printed a green "installed source at ..."
  # during --dry-run, for a clone that had not happened.
  if [[ $DRY -eq 1 ]]; then
    printf '    would install the source at %s\n' "$SRC"
  elif [[ -f $SRC/dkms.conf ]]; then
    ok "installed source at $SRC"
  else
    bad "the source was NOT written to $SRC (no dkms.conf there) — nothing below can build"
    exit 1
  fi
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
    # `patch --forward` exits non-zero for "already applied" AND for "does not
    # apply at all", and this used to print a green "already applied" for both.
    # A patch that never went anywhere near the source came out as a ✓. Ask the
    # source itself: if the patch reverses cleanly, it is in there.
    elif patch -p1 -d "$SRC" --reverse --dry-run --silent \
           < "$PATCHDIR/psys-suspend-BC.patch" >/dev/null 2>&1; then
      ok "suspend patches already applied"
    else
      PATCH_FAIL=$((PATCH_FAIL+1))
      bad "psys-suspend-BC.patch does NOT apply to $SRC and is NOT already in it"
      echo "       s2idle suspend will oops this psys build; the revision may have moved"
    fi
  fi
  if [[ -f $PATCHDIR/fix-psys-defer.sh ]]; then
    # Do NOT wrap this in run() with output redirected: the redirect swallows
    # run()'s "would run" line and the success branch then claims the patch was
    # applied during a dry run. Reporting success for something that did not
    # happen is the exact defect this project keeps shipping.
    if [[ $DRY -eq 1 ]]; then
      printf '    would run: fix-psys-defer.sh %s\n' "$SRC"
    elif DERR=$(bash "$PATCHDIR/fix-psys-defer.sh" "$SRC" 2>&1); then
      ok "defer check neutralised"
    else
      # This is the whole reason /dev/ipu7-psys0 appears. Downgrading it to a
      # warning meant the run went on to print "N kernel(s) built at r74" and
      # exit 0 while shipping a psys that defers forever -- the exact camera
      # this script exists to bring back.
      PATCH_FAIL=$((PATCH_FAIL+1))
      bad "the defer fix did NOT apply to $SRC — it said:"
      printf '%s\n' "$DERR" | sed 's/^/          /'
      echo "       without it psys reads ipu7_bus_ready_to_probe at the wrong offset"
      echo "       and defers forever: /dev/ipu7-psys0 will not appear after the reboot"
    fi
  fi
fi

# --- remove the broken revision, build r74 -----------------------------------
say "Building for every installed kernel"
if [[ -n ${CUR:-} && $CUR != "$R74_VER" ]]; then
  run dkms remove "ipu7-drivers/$CUR" --all || true
  # `|| true` swallowed the failure and the ✓ printed anyway. Ask dkms what it
  # still has: an old revision left registered is what the next `dkms
  # autoinstall` rebuilds, so a false "removed" here is the broken module
  # coming straight back.
  if [[ $DRY -eq 1 ]]; then
    printf '    would remove ipu7-drivers/%s\n' "$CUR"
  elif dkms status 2>/dev/null | grep -qE "^ipu7-drivers[/,] *$CUR"; then
    warn "dkms still lists ipu7-drivers/$CUR — the old revision was NOT removed"
    echo "         it can be rebuilt by 'dkms autoinstall' and shadow r74 again"
    echo "         remove it by hand: sudo dkms remove ipu7-drivers/$CUR --all"
  else
    ok "removed $CUR"
  fi
fi
run dkms add "ipu7-drivers/$R74_VER" >/dev/null 2>&1 || true

BUILT=0 FAILED=0
for k in $(ls /lib/modules); do
  [[ -d /lib/modules/$k/build ]] || continue
  if [[ $DRY -eq 1 ]]; then
    printf '    would build for: %s\n' "$k"; BUILT=$((BUILT+1)); continue
  fi
  if dkms install "ipu7-drivers/$R74_VER" -k "$k" >/dev/null 2>&1; then
    # dkms's exit code is not evidence. Prove the psys module from disk, using
    # the names the vendor tree's own dkms.conf promises -- this whole package
    # exists because "dkms said yes" was once allowed to mean "installed".
    miss=()
    mapfile -t names < <(sed -n 's/^BUILT_MODULE_NAME\[[0-9]*\]="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$SRC/dkms.conf")
    [[ ${#names[@]} -gt 0 ]] || names=(intel-ipu7-psys)
    for n in "${names[@]}"; do
      ko_landed "$k" "$n" || miss+=("$n")
    done
    if [[ ${#miss[@]} -eq 0 ]]; then
      ok "$k  (verified on disk: ${names[*]})"; BUILT=$((BUILT+1))
    else
      bad "$k — dkms reported success but ${miss[*]} is not under /lib/modules/$k/{updates,extra,weak-updates}"
      NOKO=$((NOKO+1)); FAILED=$((FAILED+1))
    fi
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
  if [[ $NOKO -gt 0 ]]; then
    bad "$FAILED kernel(s) did not end up with a psys module on disk; booting those leaves the camera broken"
  else
    bad "$FAILED kernel(s) failed to build; booting those leaves the camera broken"
  fi
  exit 1
fi
# Everything can build and the camera still not come back: the defer fix is what
# makes /dev/ipu7-psys0 appear at all. It may not ride out on the build count.
if [[ $PATCH_FAIL -gt 0 ]]; then
  bad "$BUILT kernel(s) built, but $PATCH_FAIL psys patch(es) are NOT in that source"
  echo "       so this is r74 WITHOUT the fixes that make it work. Do not reboot"
  echo "       expecting a camera: fix what is reported above and re-run."
  exit 1
fi
ok "$BUILT kernel(s) built at $R74_VER, psys patches present in the source"
cat <<'EOF'

    REBOOT to load it. Do not modprobe -r intel_ipu7_psys to pick it up live —
    it page faults in ipu7_fw_psys_close even at refcount 0, and psys0 stays
    gone until you reboot anyway.

    Afterwards:  sudo tools/verify.sh   (expect /dev/ipu7-psys0 present)
EOF
