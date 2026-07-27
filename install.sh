#!/bin/bash
# ===========================================================================
# IPU7 IR face-unlock stack — installer
#
# Brings up the HIMX1092 (HM1092) infrared camera behind a Synaptics SVP7500
# "CVS" bridge on Intel IPU7 (Panther Lake / Lunar Lake class), and wires it
# into Howdy for IR face authentication.
#
# Tested on: Dell XPS 16 (DA16260), CachyOS, kernels 7.0.5 through 7.2.0-rc4
#            (including stock linux-cachyos 7.1.4 — no custom kernel needed).
#            Also reported working on Arch and Ubuntu by other users.
#
# This installer counts what it actually did, proves each step from the state
# it left on disk, and exits non-zero when that comes to nothing. It has to:
# the published version looked for modules under kernel/<name>/ while the
# package ships dkms/<name>-<version>/, printed a skip line for all four, and
# then printed "Done" -- so it installed NOTHING for every user who ever ran
# it, and told each of them it had worked. A dkms exit code is not evidence
# that a module was installed; a .ko under /lib/modules is.
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DO_KERNEL=1 DO_HOWDY=1 DRY_RUN=0 DO_INITRAMFS=1

# The four modules the IR stack cannot work without. Missing any of them is a
# packaging error, not a user error, so preflight refuses to start.
REQUIRED_MODULES=(hm1092 intel-cvs int3472-patched ipu-bridge-patched)
# Board-specific extras. ov05c10 is the RGB sensor on SVP7500 boards that pair
# the bridge with OVTI05C1 (Dell Pro Plus 14 PB14250) instead of OV08x40; it is
# inert on boards that do not have that sensor, and its absence must never fail
# the install for everyone else.
OPTIONAL_MODULES=(ov05c10)

usage(){
  # Print this file's own header block, so --help can never drift from the
  # comment that documents the tool.
  awk 'NR>2 { if (/^# ={10,}$/) exit; sub(/^# ?/,""); print }' "$0"
  cat <<'EOF'

Usage: sudo ./install.sh [--kernel-only|--howdy-only] [--dry-run]

  --kernel-only     DKMS modules, psys patches, udev, initramfs. No Howdy.
  --howdy-only      Howdy IR integration only. No DKMS work.
  --dry-run         Run every check and print every intended action, but
                    change nothing at all. Still requires root, because the
                    root-only checks are part of what it is verifying.
  --no-initramfs    Skip the initramfs rebuild (you must do it yourself, or
                    the kernel keeps loading the modules it already has).
  -h, --help        This text.

Exit status: 0 success, 1 install did not achieve what it set out to,
             2 preflight failed / bad usage (nothing was touched).
EOF
}

for a in "$@"; do
  case "$a" in
    --kernel-only) DO_HOWDY=0 ;;
    --howdy-only)  DO_KERNEL=0 ;;
    --dry-run)     DRY_RUN=1 ;;
    --no-initramfs) DO_INITRAMFS=0 ;;
    -h|--help)     usage; exit 0 ;;
    # Unknown flags used to be ignored in silence, so a typo like --kernal-only
    # ran the FULL install while the user believed they had scoped it.
    *) printf 'unknown option: %s\n\n' "$a" >&2; usage >&2; exit 2 ;;
  esac
done

say(){  printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok(){   printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$*"; }
bad(){  printf '    \033[31m✗\033[0m %s\n' "$*"; }
plan(){ printf '    \033[36m·\033[0m %s\n' "$*"; }

# Every command that changes the system goes through run()/run_quiet(). That is
# what makes --dry-run worth trusting: there is exactly one place where this
# script can touch the machine, and one flag that closes it.
run(){
  if [[ $DRY_RUN -eq 1 ]]; then plan "would run: $*"; return 0; fi
  "$@"
}
run_quiet(){
  if [[ $DRY_RUN -eq 1 ]]; then plan "would run: $*"; return 0; fi
  "$@" >/dev/null 2>&1
}

# --- tally -----------------------------------------------------------------
# Counters exist so the end of the run can state plainly what happened. "Done"
# with no numbers behind it is how a no-op passed for a success for months.
MOD_OK=0 MOD_FAIL=0 MOD_SKIP=0
KBUILD_OK=0 KBUILD_FAIL=0
PATCH_OK=0 PATCH_FAIL=0
HOWDY_OK=0 HOWDY_FAIL=0
IPU7_REBUILD_FAIL=0
STEPS_SKIPPED=0
INITRAMFS_STATE="not attempted"
declare -a INSTALLED_MODULES=() FAILED_MODULES=() SKIPPED_NOTES=() ACTIONS=()

skip_step(){ STEPS_SKIPPED=$((STEPS_SKIPPED+1)); SKIPPED_NOTES+=("$1"); warn "$1"; }
action(){ ACTIONS+=("$1"); }

# `set -e` means an unhandled failure jumps straight past the summary, and a
# run that ends with no verdict at all is just a quieter version of the bug
# this script is built to avoid. Say so, loudly, with the line number.
trap 'printf "\n\033[1;31m==> ABORTED at line %s (exit %s) — the summary never ran, so treat this as a FAILED install and re-run after fixing the error above.\033[0m\n" "$LINENO" "$?"' ERR

# ---------------------------------------------------------------------------
# Preflight. Nothing below this point may touch the system until every check
# here has passed, and every failure names the exact thing that is missing.
# Half-installing and then discovering the compiler is absent leaves a machine
# in a state nobody can reason about.
# ---------------------------------------------------------------------------
PF_FAIL=0
pf_bad(){ bad "$*"; PF_FAIL=$((PF_FAIL+1)); }

say "Preflight"

# Root first: every later check reads root-only paths, and a dry run that
# skipped this would be describing a different script than the real one.
if [[ $EUID -ne 0 ]]; then
  bad "must run as root: sudo $0 $*"
  printf '\n\033[1m==> Preflight failed — nothing was changed\033[0m\n'
  exit 2
fi
ok "running as root"

# Resolve a module's source directory. The published package lays modules out as
# dkms/<name>-<version>/ while the development tree uses kernel/<name>/. Looking
# in only one of them silently skips EVERY module and reports success -- which is
# exactly what shipped, and it installed nothing at all for anyone who used it.
find_src() {
  local m=$1 d
  for d in "$HERE"/dkms/"$m"-*/ "$HERE/dkms/$m" "$HERE/kernel/$m"; do
    [[ -d $d && -f $d/dkms.conf ]] && { echo "${d%/}"; return 0; }
  done
  return 1
}

declare -A SRC_OF=()
if [[ $DO_KERNEL -eq 1 ]]; then
  for m in "${REQUIRED_MODULES[@]}"; do
    if s=$(find_src "$m"); then
      SRC_OF[$m]=$s
      ok "package: $m -> ${s#"$HERE"/}"
    else
      # Name the real problem: an incomplete download or a broken release
      # tarball, NOT anything about the user's machine.
      pf_bad "package is missing module '$m' (no dkms/$m-*/dkms.conf, no kernel/$m/dkms.conf) — this clone/tarball is incomplete, re-download it"
    fi
  done
  for m in "${OPTIONAL_MODULES[@]}"; do
    if s=$(find_src "$m"); then
      SRC_OF[$m]=$s
      ok "package: $m (optional) -> ${s#"$HERE"/}"
    else
      skip_step "optional module '$m' not in this package — boards using the OV05C10 RGB sensor will not get it"
    fi
  done
fi

# Tools. Each one is checked by name so the error can say which is absent
# instead of surfacing later as an unexplained build failure.
need_tool(){ command -v "$1" >/dev/null 2>&1 || pf_bad "required tool not found: $1 — $2"; }
if [[ $DO_KERNEL -eq 1 ]]; then
  need_tool dkms   "install it (pacman -S dkms / apt install dkms / dnf install dkms)"
  need_tool depmod "part of kmod — install kmod"
  need_tool make   "install base-devel / build-essential"
  need_tool patch  "install the 'patch' package"
fi
[[ $DO_HOWDY -eq 1 ]] && need_tool patch "install the 'patch' package"

# The dkms.conf files build with clang/LLVM. Without it every single module
# fails, and dkms's own message is buried in a build log the user never sees.
# Read the requirement out of the shipped dkms.conf rather than hardcoding it,
# so this check stays true if the build recipe changes.
if [[ $DO_KERNEL -eq 1 && ${#SRC_OF[@]} -gt 0 ]]; then
  MAKELINES=$(cat "${SRC_OF[@]/%//dkms.conf}" 2>/dev/null || true)
  declare -a COMPILERS=()
  grep -q 'CC=clang'  <<<"$MAKELINES" && COMPILERS+=(clang)
  grep -q 'LD=ld.lld' <<<"$MAKELINES" && COMPILERS+=(ld.lld)
  grep -q 'LLVM=1'    <<<"$MAKELINES" && COMPILERS+=(llvm-ar)
  for c in "${COMPILERS[@]:-}"; do
    [[ -n $c ]] || continue
    command -v "$c" >/dev/null 2>&1 || pf_bad "the modules in this package build with LLVM and '$c' is not installed — pacman -S clang lld llvm / apt install clang lld llvm / dnf install clang lld llvm"
  done
fi

# At least one kernel with a build tree, or there is nothing to build against.
KERNELS=() NOBUILD=()
for d in /lib/modules/*/; do
  [[ -d $d ]] || continue
  k=${d%/}; k=${k##*/}
  if [[ -d /lib/modules/$k/build ]]; then KERNELS+=("$k"); else NOBUILD+=("$k"); fi
done
if [[ $DO_KERNEL -eq 1 ]]; then
  if [[ ${#KERNELS[@]} -eq 0 ]]; then
    pf_bad "no installed kernel has a build tree under /lib/modules/*/build — install headers: pacman -S linux-headers / apt install linux-headers-\$(uname -r) / dnf install kernel-devel"
  else
    ok "kernels with a build tree: ${KERNELS[*]}"
    [[ ${#NOBUILD[@]} -gt 0 ]] && warn "no build tree (will be left unbuilt): ${NOBUILD[*]}"
    # Missing headers for the kernel you are actually on is the case that looks
    # like "the fix did nothing" after a reboot into that same kernel.
    RUNNING=$(uname -r)
    if [[ ! -d /lib/modules/$RUNNING/build ]]; then
      warn "the RUNNING kernel $RUNNING has no build tree — nothing will be built for it; install its headers or boot a kernel that has them"
    fi
  fi
fi

# Initramfs generator. A DKMS rebuild does not regenerate the initramfs, so if
# any of these modules is in the initramfs the kernel keeps loading the OLD
# build no matter how many times it is rebuilt, and every symptom points
# somewhere else. Refusing up front beats a silent skip at the end.
INITRAMFS_CMD=""
if [[ $DO_KERNEL -eq 1 && $DO_INITRAMFS -eq 1 ]]; then
  if   command -v mkinitcpio      >/dev/null 2>&1; then INITRAMFS_CMD="mkinitcpio -P"
  elif command -v dracut          >/dev/null 2>&1; then INITRAMFS_CMD="dracut --regenerate-all --force"
  elif command -v update-initramfs >/dev/null 2>&1; then INITRAMFS_CMD="update-initramfs -u -k all"
  else
    pf_bad "no initramfs generator found (looked for mkinitcpio, dracut, update-initramfs) — install one, or re-run with --no-initramfs and rebuild the initramfs yourself"
  fi
  [[ -n $INITRAMFS_CMD ]] && ok "initramfs generator: $INITRAMFS_CMD"
fi

# Howdy-side prerequisites, checked only when the Howdy phase will run.
if [[ $DO_HOWDY -eq 1 ]]; then
  for f in "$HERE/udev/99-hm1092-ir-led.rules" "$HERE/howdy/ir_reader.py" "$HERE/howdy/video_capture.patch"; do
    [[ -f $f ]] || pf_bad "package is missing ${f#"$HERE"/} — this clone/tarball is incomplete, re-download it"
  done
fi

if [[ $PF_FAIL -gt 0 ]]; then
  printf '\n\033[1m==> Preflight failed (%d problem(s)) — nothing was changed\033[0m\n' "$PF_FAIL"
  exit 2
fi
ok "preflight passed"
[[ $DRY_RUN -eq 1 ]] && say "DRY RUN — every action below is printed, nothing is executed"

# ---------------------------------------------------------------------------
# Proof helpers
# ---------------------------------------------------------------------------

# Names of the .ko files a dkms.conf promises to build.
built_module_names(){
  sed -n 's/^BUILT_MODULE_NAME\[[0-9]*\]="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$1/dkms.conf"
}

# Did a module actually land for this kernel? Search ONLY the out-of-tree
# destinations (updates/, extra/, weak-updates/). Never kernel/ -- the in-tree
# copies of ipu-bridge and intel_skl_int3472_* live there, and finding one of
# those would make a build that failed outright look like a success.
ko_present(){
  local k=$1 n=$2 d hit
  for d in updates extra weak-updates; do
    [[ -d /lib/modules/$k/$d ]] || continue
    hit=$(find "/lib/modules/$k/$d" -type f \( -name "${n}.ko" -o -name "${n}.ko.*" \
          -o -name "${n//-/_}.ko" -o -name "${n//-/_}.ko.*" \) 2>/dev/null | head -1)
    [[ -n $hit ]] && { echo "$hit"; return 0; }
  done
  return 1
}

# Where dkms put the build log, so a failure can point at its own evidence
# instead of at the user.
dkms_log(){
  local m=$1 v=$2 k=$3 f
  for f in "/var/lib/dkms/$m/$v/$k/$(uname -m)/log/make.log" "/var/lib/dkms/$m/$v/build/make.log"; do
    [[ -f $f ]] && { echo "$f"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
if [[ $DO_KERNEL -eq 1 ]]; then
say "Installing DKMS modules"

# A required module that did not install must land in the failed count (which
# drives the exit status); an optional one only in the skipped list.
count_module_failure(){
  if [[ $2 == required ]]; then
    MOD_FAIL=$((MOD_FAIL+1)); FAILED_MODULES+=("$1")
  else
    MOD_SKIP=$((MOD_SKIP+1))
  fi
}

install_module(){
  local m=$1 kind=$2
  local src=${SRC_OF[$m]:-}
  if [[ -z $src ]]; then
    # Only reachable for optional modules; required ones failed preflight.
    MOD_SKIP=$((MOD_SKIP+1))
    return 0
  fi

  local ver dst
  ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$src/dkms.conf" | head -1)
  ver=${ver:-1.0}
  dst="/usr/src/${m}-${ver}"

  if [[ -d $dst ]]; then
    if run cp -a "$dst" "${dst}.bak-$(date +%Y%m%d-%H%M%S)"; then
      warn "existing $m backed up"
    else
      warn "could not back up $dst — continuing without a backup"
    fi
  fi
  # If the source cannot even be staged there is no point pretending: mark the
  # module failed and move on, so the summary counts it and the run exits 1.
  if ! run mkdir -p "$dst"; then
    bad "$m: cannot create $dst (is /usr/src writable?)"
    count_module_failure "$m" "$kind"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    plan "would copy $src/. -> $dst/"
  elif ! cp -r "$src/." "$dst/"; then
    bad "$m: failed to copy sources into $dst"
    count_module_failure "$m" "$kind"
    return 0
  fi

  dkms status 2>/dev/null | grep -q "^${m}/${ver}" && run_quiet dkms remove "${m}/${ver}" --all || true
  run_quiet dkms add "${m}/${ver}" || true

  # Build for EVERY installed kernel. Building only $(uname -r) has repeatedly
  # left other kernels with stale modules and a dead camera after a reboot.
  local names k good=0 badk=0
  mapfile -t names < <(built_module_names "$src")
  [[ ${#names[@]} -gt 0 ]] || names=("$m")

  for k in "${KERNELS[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      plan "would run: dkms install ${m}/${ver} -k $k   (then check for ${names[*]} under /lib/modules/$k/{updates,extra})"
      good=$((good+1)); KBUILD_OK=$((KBUILD_OK+1))
      continue
    fi
    if ! dkms install "${m}/${ver}" -k "$k" >/dev/null 2>&1; then
      badk=$((badk+1)); KBUILD_FAIL=$((KBUILD_FAIL+1))
      bad "$m: build FAILED for $k"
      if lg=$(dkms_log "$m" "$ver" "$k"); then
        warn "  build log: $lg"
        tail -n 5 "$lg" 2>/dev/null | sed 's/^/          /'
      else
        warn "  no dkms build log found under /var/lib/dkms/$m/$ver/"
      fi
      continue
    fi
    # dkms said yes. Now make it prove it: a .ko for every module the
    # dkms.conf promised, on this kernel, in an out-of-tree location.
    local missing=() n
    for n in "${names[@]}"; do
      ko_present "$k" "$n" >/dev/null || missing+=("$n")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
      good=$((good+1)); KBUILD_OK=$((KBUILD_OK+1))
      ok "$m -> $k  (verified: ${names[*]})"
    else
      badk=$((badk+1)); KBUILD_FAIL=$((KBUILD_FAIL+1))
      bad "$m -> $k: dkms reported success but ${missing[*]} is not under /lib/modules/$k/{updates,extra,weak-updates} — treat this as a FAILED install"
    fi
  done

  if [[ $good -gt 0 ]]; then
    MOD_OK=$((MOD_OK+1)); INSTALLED_MODULES+=("$m")
    # Written as a full if, not `[[ ]] && warn`: a trailing test that is false
    # makes the function return 1, and under `set -e` that aborts the whole
    # install after the FIRST module. Exactly the kind of silent early exit
    # this rewrite exists to prevent.
    if [[ $badk -gt 0 ]]; then warn "$m: installed for $good kernel(s), failed for $badk"; fi
  else
    if [[ $kind == required ]]; then
      MOD_FAIL=$((MOD_FAIL+1)); FAILED_MODULES+=("$m")
    else
      MOD_SKIP=$((MOD_SKIP+1))
      SKIPPED_NOTES+=("optional module $m failed to build for every kernel (harmless unless your RGB sensor is OV05C10)")
    fi
    bad "$m: not installed for ANY kernel"
  fi
  return 0
}

for m in "${REQUIRED_MODULES[@]}"; do install_module "$m" required; done
for m in "${OPTIONAL_MODULES[@]}"; do
  [[ -n ${SRC_OF[$m]:-} ]] && install_module "$m" optional
done

# --- SVP7500 USB autosuspend ------------------------------------------------
# Bridge firmware wedges on USB power-state transitions; keeping it always-on
# prevents a class of "camera worked, then stopped after idle" reports. The
# published installer shipped this rule and never installed it, so nobody got
# the fix the README told them they had.
say "SVP7500 USB autosuspend rule"
if [[ -f "$HERE/udev/99-svp7500-no-autosuspend.rules" ]]; then
  run mkdir -p /etc/udev/rules.d
  if ! run install -m 0644 "$HERE/udev/99-svp7500-no-autosuspend.rules" /etc/udev/rules.d/; then
    # A failing install(1) used to produce no line at all here, which is how a
    # step that did not happen ends up inside a successful-looking run.
    bad "could not write /etc/udev/rules.d/99-svp7500-no-autosuspend.rules (install exited non-zero — read-only /etc? immutable file?)"
    action "copy udev/99-svp7500-no-autosuspend.rules to /etc/udev/rules.d/ by hand"
  elif [[ $DRY_RUN -eq 1 ]]; then
    # The "would run" line above already said it; claiming "installed" during a
    # dry run is the same lie in a smaller font.
    run_quiet udevadm control --reload-rules || true
  elif [[ -f /etc/udev/rules.d/99-svp7500-no-autosuspend.rules ]]; then
    ok "installed /etc/udev/rules.d/99-svp7500-no-autosuspend.rules"
    run_quiet udevadm control --reload-rules || true
  else
    bad "install reported success but /etc/udev/rules.d/99-svp7500-no-autosuspend.rules is not there"
    action "copy udev/99-svp7500-no-autosuspend.rules to /etc/udev/rules.d/ by hand"
  fi
else
  skip_step "udev/99-svp7500-no-autosuspend.rules missing from this package — bridge autosuspend will stay enabled"
fi

# --- vendor IPU7 psys suspend patches --------------------------------------
say "IPU7 psys suspend patches (s2idle)"
# Each precondition is tested and reported on its own. The published installer
# collapsed them into one if-chain, so a missing patch FILE printed
# "ipu7-drivers DKMS not installed" and sent a user to audit a DKMS install
# that was perfectly healthy.
P=""
for c in "$HERE/dkms/ipu7-psys-patches/psys-suspend-BC.patch" \
         "$HERE/kernel/ipu7-psys-patches/psys-suspend-BC.patch"; do
  [[ -f $c ]] && { P="$c"; break; }
done
DEFERFIX=""
for c in "$HERE/kernel/ipu7-psys-patches/fix-psys-defer.sh" \
         "$HERE/dkms/ipu7-psys-patches/fix-psys-defer.sh"; do
  [[ -f $c ]] && { DEFERFIX="$c"; break; }
done
# Pick the tree DKMS actually HAS INSTALLED. Selecting with `ls | tail -1`
# grabs a stale leftover tree and silently patches the wrong source.
SRC=$(dkms status 2>/dev/null | sed -n 's|^ipu7-drivers/\([^,]*\),.*installed.*|\1|p' | head -1)
IPUSRC="/usr/src/ipu7-drivers-${SRC:-}"

PSYS_TREE_OK=0
if [[ -z ${SRC:-} ]]; then
  # Not a failure. These patches only apply to a DKMS-installed ipu7-drivers
  # tree; if intel_ipu7 comes from your kernel package there is nothing here to
  # patch, and the rest of the install is unaffected.
  skip_step "no ipu7-drivers package under DKMS ('dkms status' lists none) — psys patches do not apply to this system"
elif [[ ! -d $IPUSRC ]]; then
  skip_step "dkms lists ipu7-drivers/$SRC but $IPUSRC does not exist — the DKMS source tree was deleted; reinstall ipu7-drivers, then re-run"
else
  PSYS_TREE_OK=1
  ok "ipu7-drivers source tree: $IPUSRC"
fi

if [[ $PSYS_TREE_OK -eq 1 ]]; then
  # 1) the s2idle suspend patch
  if [[ -z $P ]]; then
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "psys-suspend-BC.patch is not in this package (looked in dkms/ and kernel/ipu7-psys-patches/) — packaging bug, nothing to do with your DKMS install"
    action "re-download the package: psys-suspend-BC.patch is missing, so s2idle suspend is unfixed"
  elif [[ $DRY_RUN -eq 1 ]]; then
    # --dry-run of patch(1) is a real, read-only test: it says whether the
    # hunks still apply to this ipu7-drivers revision.
    if patch -p1 -d "$IPUSRC" --forward --dry-run --silent < "$P" >/dev/null 2>&1; then
      plan "would apply psys-suspend-BC.patch to $IPUSRC (patch --dry-run: applies cleanly)"
      PATCH_OK=$((PATCH_OK+1))
    elif grep -q 'pm_runtime_resume_and_get' "$IPUSRC/drivers/media/pci/intel/ipu7/psys/ipu-psys.c" 2>/dev/null; then
      plan "psys-suspend-BC.patch is already applied in $IPUSRC — would be a no-op"
      PATCH_OK=$((PATCH_OK+1))
    else
      # Distinguishing "already applied" from "will not apply" is the whole
      # point of a dry run; counting both as fine would waste it.
      bad "psys-suspend-BC.patch does NOT apply to $IPUSRC and its marker is absent — a real run would fail here"
      PATCH_FAIL=$((PATCH_FAIL+1))
      action "the suspend patch needs rebasing onto ipu7-drivers-$SRC before a real run will fix s2idle"
    fi
  elif PERR=$(patch -p1 -d "$IPUSRC" --forward --silent < "$P" 2>&1); then
    PATCH_OK=$((PATCH_OK+1)); ok "suspend patch applied to ipu7-drivers-$SRC"
  else
    # --forward exits non-zero on an already-applied patch too, so confirm from
    # the source before claiming either outcome. patch(1)'s own complaint is
    # held back until we know which of the two it is -- printing "hunks FAILED"
    # above an "already applied" line is how a fine install reads as broken.
    if grep -q 'pm_runtime_resume_and_get' "$IPUSRC/drivers/media/pci/intel/ipu7/psys/ipu-psys.c" 2>/dev/null; then
      PATCH_OK=$((PATCH_OK+1)); ok "suspend patch already applied"
    else
      PATCH_FAIL=$((PATCH_FAIL+1))
      bad "suspend patch did not apply to $IPUSRC and its marker is absent — this ipu7-drivers revision has moved; apply ${P#"$HERE"/} by hand"
      printf '%s\n' "$PERR" | sed 's/^/          /'
      action "apply $P to $IPUSRC by hand (see the .rej files), then rebuild ipu7-drivers — until then suspend/resume can oops the psys driver"
    fi
  fi

  # 2) the defer-check fix, evaluated independently of (1). These are separate
  # failures with separate symptoms and must never gate each other.
  #
  # psys defers forever when intel_ipu7 comes from the kernel and psys from
  # DKMS: they disagree on struct ipu7_device's layout, so the ready_to_probe
  # read lands at the wrong offset. Result is a MISSING /dev/ipu7-psys0 and no
  # RGB camera, while isys binds normally because it ships with the kernel.
  PSYSC="$IPUSRC/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"
  if [[ -z $DEFERFIX ]]; then
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "fix-psys-defer.sh is not in this package — packaging bug; without it /dev/ipu7-psys0 may never appear"
    action "re-download the package: fix-psys-defer.sh is missing"
  elif [[ ! -f $PSYSC ]]; then
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "$PSYSC not found — this ipu7-drivers tree has a different layout; run ${DEFERFIX#"$HERE"/} by hand against your source"
    action "locate ipu-psys.c in $IPUSRC and run $DEFERFIX against it"
  elif [[ $DRY_RUN -eq 1 ]]; then
    # Read-only inspection of exactly what the fix looks for.
    if grep -q 'DKMS struct layout mismatch' "$PSYSC"; then
      plan "defer fix already applied in $PSYSC — would be a no-op"
      PATCH_OK=$((PATCH_OK+1))
    elif grep -qE 'if \(!.*ipu7_bus_ready_to_probe\)' "$PSYSC"; then
      plan "would run: $DEFERFIX $IPUSRC   (defer check found in $PSYSC)"
      PATCH_OK=$((PATCH_OK+1))
    else
      bad "the defer check pattern is NOT in $PSYSC — fix-psys-defer.sh would refuse; a real run would leave /dev/ipu7-psys0 missing"
      PATCH_FAIL=$((PATCH_FAIL+1))
      action "inspect $PSYSC by hand: the ready_to_probe defer check this fix targets is not where it was"
    fi
  elif DERR=$(bash "$DEFERFIX" "$IPUSRC" 2>&1); then
    PATCH_OK=$((PATCH_OK+1)); ok "psys defer check neutralised"
  else
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "psys defer fix did not apply to $PSYSC — it said:"
    # fix-psys-defer.sh explains itself (wrong revision, pattern moved, ...).
    # Swallowing that output is how "did not apply" becomes unactionable.
    printf '%s\n' "$DERR" | sed 's/^/          /'
    action "/dev/ipu7-psys0 may not appear: the psys defer fix failed, see above"
  fi

  # 3) rebuild ipu7-drivers for every kernel, and verify the psys .ko landed.
  for k in "${KERNELS[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      plan "would run: dkms remove/install ipu7-drivers/$SRC -k $k"
      continue
    fi
    run_quiet dkms remove "ipu7-drivers/$SRC" -k "$k" || true
    if dkms install "ipu7-drivers/$SRC" -k "$k" >/dev/null 2>&1; then
      if ko_present "$k" intel-ipu7-psys >/dev/null || ko_present "$k" intel_ipu7_psys >/dev/null; then
        ok "ipu7-drivers -> $k  (verified: intel_ipu7_psys)"
      else
        warn "ipu7-drivers -> $k: built, but no intel_ipu7_psys .ko under /lib/modules/$k/{updates,extra} — check what this revision names its psys module"
      fi
    else
      IPU7_REBUILD_FAIL=$((IPU7_REBUILD_FAIL+1))
      bad "ipu7-drivers FAILED to build for $k"
      if lg=$(dkms_log ipu7-drivers "$SRC" "$k"); then
        warn "  build log: $lg"; tail -n 5 "$lg" 2>/dev/null | sed 's/^/          /'
      fi
      action "ipu7-drivers did not rebuild for $k — psys patches are NOT in effect there"
    fi
  done
fi

# --- initramfs --------------------------------------------------------------
# A DKMS rebuild does NOT regenerate the initramfs. If any of these modules is
# pulled into the initramfs, the kernel keeps loading the OLD build no matter
# how many times it is rebuilt, and every downstream symptom points somewhere
# else entirely. This cost hours on 2026-07-26: ipu-bridge was rebuilt
# correctly and the running kernel kept using the stale copy, so a sensor
# driver kept reading a link frequency that had already been fixed.
say "Regenerating initramfs"
if [[ $DO_INITRAMFS -eq 0 ]]; then
  INITRAMFS_STATE="SKIPPED (--no-initramfs)"
  skip_step "initramfs not regenerated (--no-initramfs) — do it yourself before rebooting or the kernel may keep loading the old modules"
  action "regenerate your initramfs by hand, then reboot"
elif [[ -z $INITRAMFS_CMD ]]; then
  # Preflight should have caught this; belt and braces.
  INITRAMFS_STATE="NOT REGENERATED (no generator found)"
  bad "no initramfs generator found — the kernel may keep loading the previous build of these modules"
  action "regenerate your initramfs by hand, then reboot"
elif [[ $DRY_RUN -eq 1 ]]; then
  INITRAMFS_STATE="would run: $INITRAMFS_CMD"
  plan "would run: $INITRAMFS_CMD"
elif $INITRAMFS_CMD; then
  INITRAMFS_STATE="regenerated ($INITRAMFS_CMD)"
  ok "initramfs regenerated with: $INITRAMFS_CMD"
else
  INITRAMFS_STATE="FAILED ($INITRAMFS_CMD)"
  bad "$INITRAMFS_CMD failed — the kernel will keep loading the modules already in your initramfs"
  action "rerun '$INITRAMFS_CMD' and fix the error it prints before rebooting"
fi
fi

# ---------------------------------------------------------------------------
if [[ $DO_HOWDY -eq 1 ]]; then
say "IR illuminator permissions"
# Howdy's recognition process runs as the UNPRIVILEGED USER when invoked from a
# lock screen / PAM stack. The illuminator is root-only sysfs by default, so it
# silently never fires there and every frame is too dark to detect a face --
# authentication times out while working perfectly under sudo.
run mkdir -p /etc/udev/rules.d
if ! run install -m 0644 "$HERE/udev/99-hm1092-ir-led.rules" /etc/udev/rules.d/; then
  HOWDY_FAIL=$((HOWDY_FAIL+1))
  bad "could not write /etc/udev/rules.d/99-hm1092-ir-led.rules (install exited non-zero — read-only /etc?)"
  action "copy udev/99-hm1092-ir-led.rules to /etc/udev/rules.d/ by hand, or the illuminator stays root-only and Howdy times out"
elif [[ $DRY_RUN -eq 1 ]]; then
  :
elif [[ -f /etc/udev/rules.d/99-hm1092-ir-led.rules ]]; then
  ok "installed /etc/udev/rules.d/99-hm1092-ir-led.rules"
else
  HOWDY_FAIL=$((HOWDY_FAIL+1))
  bad "install reported success but /etc/udev/rules.d/99-hm1092-ir-led.rules is not there"
fi
run_quiet udevadm control --reload-rules || true
run_quiet udevadm trigger --subsystem-match=leds --action=change || true
LEDB=/sys/class/leds/HIMX1092_00::ir_flood_led/brightness
if [[ -e $LEDB ]]; then
  ok "illuminator: $(stat -c '%U:%G %a' "$LEDB")"
else
  # Not an error at install time -- the LED node only exists once int3472 has
  # bound, which is after the reboot this installer asks for.
  warn "illuminator LED not present yet (appears once int3472 binds — expected before the reboot)"
fi

say "Howdy IR integration"
HR=/usr/lib/howdy/recorders
if [[ -d $HR ]]; then
  if ! run install -m 0444 "$HERE/howdy/ir_reader.py" "$HR/ir_reader.py"; then
    HOWDY_FAIL=$((HOWDY_FAIL+1)); bad "could not write $HR/ir_reader.py (install exited non-zero)"
    action "copy howdy/ir_reader.py to $HR/ by hand"
  elif [[ $DRY_RUN -eq 1 ]]; then
    HOWDY_OK=$((HOWDY_OK+1))
  elif [[ -f $HR/ir_reader.py ]]; then
    HOWDY_OK=$((HOWDY_OK+1)); ok "installed $HR/ir_reader.py"
  else
    HOWDY_FAIL=$((HOWDY_FAIL+1)); bad "$HR/ir_reader.py was not written"
  fi

  if ! grep -q 'ir_reader' "$HR/video_capture.py"; then
    # Howdy ships video_capture.py mode 0444, so the backup and the chmod both
    # have to succeed before patching. Report, do not abort: an abort here
    # would skip the summary entirely.
    run cp "$HR/video_capture.py" "$HR/video_capture.py.bak-$(date +%Y%m%d-%H%M%S)" \
      || warn "could not back up video_capture.py — continuing without a backup"
    run chmod 644 "$HR/video_capture.py" || warn "could not make video_capture.py writable — the patch below will probably fail"
    if [[ $DRY_RUN -eq 1 ]]; then
      if patch -p0 -d / --forward --dry-run --silent < "$HERE/howdy/video_capture.patch" >/dev/null 2>&1; then
        plan "would patch $HR/video_capture.py (patch --dry-run: applies cleanly)"
      else
        plan "would patch $HR/video_capture.py (patch --dry-run: does NOT apply against your Howdy version — you would have to apply howdy/video_capture.patch by hand)"
      fi
      HOWDY_OK=$((HOWDY_OK+1))
    elif PERR=$(patch -p0 -d / --forward --silent < "$HERE/howdy/video_capture.patch" 2>&1); then
      # Confirm from the file, not from patch's exit code.
      if grep -q 'ir_reader' "$HR/video_capture.py"; then
        HOWDY_OK=$((HOWDY_OK+1)); ok "patched video_capture.py"
      else
        HOWDY_FAIL=$((HOWDY_FAIL+1)); bad "patch succeeded but video_capture.py has no ir_reader hook"
      fi
    else
      HOWDY_FAIL=$((HOWDY_FAIL+1))
      bad "video_capture.py patch failed — your Howdy version differs; apply howdy/video_capture.patch by hand"
      printf '%s\n' "$PERR" | sed 's/^/          /'
      action "apply $HERE/howdy/video_capture.patch to $HR/video_capture.py by hand"
    fi
    run chmod 444 "$HR/video_capture.py" || warn "could not restore video_capture.py to mode 0444"
  else
    HOWDY_OK=$((HOWDY_OK+1)); ok "video_capture.py already has the ir plugin"
  fi

  CFG=/etc/howdy/config.ini
  if [[ -f $CFG ]]; then
    run cp "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)" \
      || warn "could not back up $CFG — continuing without a backup"
    # device_path is set by the user after checking which /dev/videoN is the IR
    # capture node (see tools/find-ir-node.sh) -- node numbers are NOT stable.
    # dark_threshold is the % of NEAR-BLACK pixels above which a frame is
    # rejected -- NOT brightness. IR frames are ~70-77% black because the flood
    # lights only the face, so the stock 60 rejects every frame.
    if [[ $DRY_RUN -eq 1 ]]; then
      plan "would set in $CFG: recording_plugin=ir, dark_threshold=90, timeout=6"
      HOWDY_OK=$((HOWDY_OK+1))
    else
      sed -i 's/^recording_plugin *=.*/recording_plugin = ir/' "$CFG" || true
      sed -i 's/^dark_threshold *=.*/dark_threshold = 90/' "$CFG" || true
      sed -i 's/^timeout *=.*/timeout = 6/' "$CFG" || true
      # sed reports success even when it matched nothing (and fails silently on
      # a read-only /etc), so read every value back out of the file. Checking
      # only one of the three would call a half-written config a success.
      cfgmiss=()
      grep -qE '^recording_plugin *= *ir' "$CFG" || cfgmiss+=("recording_plugin = ir")
      grep -qE '^dark_threshold *= *90'    "$CFG" || cfgmiss+=("dark_threshold = 90")
      grep -qE '^timeout *= *6'            "$CFG" || cfgmiss+=("timeout = 6")
      if [[ ${#cfgmiss[@]} -eq 0 ]]; then
        HOWDY_OK=$((HOWDY_OK+1)); ok "config: recording_plugin=ir, dark_threshold=90, timeout=6"
      else
        HOWDY_FAIL=$((HOWDY_FAIL+1))
        bad "$CFG still does not contain: ${cfgmiss[*]} — the keys may be named differently, or /etc may be read-only"
        action "edit $CFG by hand so it contains: ${cfgmiss[*]}"
      fi
    fi
    warn "set device_path to your IR node: $HERE/tools/find-ir-node.sh"
    action "set device_path in $CFG using $HERE/tools/find-ir-node.sh (node numbers shuffle between boots)"
  else
    HOWDY_FAIL=$((HOWDY_FAIL+1))
    bad "no /etc/howdy/config.ini — Howdy's recorders directory exists but its config does not; finish installing Howdy, then re-run with --howdy-only"
  fi
else
  # Name the thing that is missing: Howdy. Not the camera, not DKMS.
  skip_step "Howdy is not installed (no $HR) — skipped the whole Howdy phase; install Howdy, then re-run with --howdy-only"
fi
fi

# ---------------------------------------------------------------------------
# Summary. Plain counts, so "it worked" is a claim the numbers can contradict.
# ---------------------------------------------------------------------------
say "Summary"
# In a dry run the counts describe what WOULD happen; label them that way, or
# the summary over-claims exactly like the script this replaces.
LBL_INSTALLED="modules installed"
if [[ $DRY_RUN -eq 1 ]]; then
  printf '    \033[1mDRY RUN — nothing on this system was changed\033[0m\n'
  LBL_INSTALLED="modules to install"
fi
if [[ $DO_KERNEL -eq 1 ]]; then
  # Denominator = the required four plus whichever optional modules this
  # package actually shipped, so the fraction never flatters the result.
  TARGETS=${#REQUIRED_MODULES[@]}
  for m in "${OPTIONAL_MODULES[@]}"; do [[ -n ${SRC_OF[$m]:-} ]] && TARGETS=$((TARGETS+1)); done
  printf '    %-17s : %d / %d  %s\n' "$LBL_INSTALLED" "$MOD_OK" "$TARGETS" "${INSTALLED_MODULES[*]:-(none)}"
  printf '    %-17s : %d%s\n' "modules failed" "$MOD_FAIL" "${FAILED_MODULES[*]:+  ${FAILED_MODULES[*]}}"
  printf '    %-17s : %d ok, %d failed  (over %d kernel(s))\n' "per-kernel builds" "$KBUILD_OK" "$KBUILD_FAIL" "${#KERNELS[@]}"
  printf '    %-17s : %d applied, %d failed\n' "patches" "$PATCH_OK" "$PATCH_FAIL"
  if [[ $IPU7_REBUILD_FAIL -gt 0 ]]; then
    printf '    %-17s : FAILED for %d kernel(s)\n' "ipu7-drivers" "$IPU7_REBUILD_FAIL"
  fi
  printf '    %-17s : %s\n' "initramfs" "$INITRAMFS_STATE"
fi
if [[ $DO_HOWDY -eq 1 ]]; then
  printf '    %-17s : %d ok, %d failed\n' "howdy steps" "$HOWDY_OK" "$HOWDY_FAIL"
fi
printf '    %-17s : %d\n' "steps skipped" "$STEPS_SKIPPED"
for s in "${SKIPPED_NOTES[@]:-}"; do [[ -n $s ]] && printf '        - %s\n' "$s"; done

RC=0
if [[ $DO_KERNEL -eq 1 ]]; then
  # Zero modules installed is a FAILURE, not a "Done". This is the single check
  # that would have caught the empty install on the first user's first run.
  if [[ $MOD_OK -eq 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      bad "NOTHING WOULD BE INSTALLED. A real run would change nothing — fix the problems above first."
    else
      bad "NOTHING WAS INSTALLED. Do not reboot expecting a change — nothing would be different."
    fi
    RC=1
  elif [[ $MOD_FAIL -gt 0 ]]; then
    bad "${MOD_FAIL} required module(s) did not install: ${FAILED_MODULES[*]}. The stack will not work until they do."
    RC=1
  fi
  # A patch that did not apply is also something that did not happen, and it
  # must not hide behind a green module count.
  if [[ $IPU7_REBUILD_FAIL -gt 0 ]]; then
    bad "ipu7-drivers did not rebuild for ${IPU7_REBUILD_FAIL} kernel(s) — the patched psys source is not in the modules those kernels will load."
    RC=1
  fi
  if [[ $PATCH_FAIL -gt 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      bad "${PATCH_FAIL} psys patch(es) would NOT apply on this machine — a real run would install the modules and leave those fixes out."
    else
      bad "${PATCH_FAIL} psys patch(es) did not apply. The modules are installed, but those fixes are NOT in effect — see the lines above."
    fi
    RC=1
  fi
fi
if [[ $DO_HOWDY -eq 1 ]]; then
  if [[ $DO_KERNEL -eq 0 && $HOWDY_OK -eq 0 ]]; then
    bad "--howdy-only was asked for and no Howdy step succeeded."
    RC=1
  elif [[ $HOWDY_FAIL -gt 0 ]]; then
    # One missing piece (ir_reader.py, the video_capture hook, the config) is
    # enough for face auth to never work, so it cannot ride out on the count of
    # the steps that did succeed.
    bad "${HOWDY_FAIL} Howdy step(s) failed — IR face auth will not work until they are done."
    RC=1
  fi
fi
if [[ ${#ACTIONS[@]} -gt 0 ]]; then
  printf '\n    \033[1mstill needs your attention:\033[0m\n'
  for a in "${ACTIONS[@]}"; do printf '        - %s\n' "$a"; done
fi

if [[ $RC -ne 0 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Dry run found problems — nothing was changed"
    echo "    A real run would hit the failures listed above. Fix them first."
  else
    say "FAILED"
    echo "    Fix what is listed above and re-run. Nothing here is retry-unsafe:"
    echo "    the installer backs up whatever it replaces and re-applies patches"
    echo "    idempotently."
  fi
  exit $RC
fi

if [[ $DRY_RUN -eq 1 ]]; then
  say "Dry run complete — re-run without --dry-run to apply"
  exit 0
fi

say "Done"
if [[ $DO_KERNEL -eq 1 ]]; then
  cat <<EOF
    REBOOT is required: hm1092 leaks module references and can never be
    swapped live (unbind succeeds, refcount stays >0, rmmod says "in use").
EOF
  # Only claim the initramfs was rebuilt if it actually was. Telling someone
  # their initramfs is current when it is not sends them hunting a hardware
  # fault while the kernel quietly loads last week's module.
  case $INITRAMFS_STATE in
    regenerated*) echo "    The initramfs was regenerated above, so the rebooted kernel loads what" ;;
    *)            echo "    The initramfs was NOT regenerated ($INITRAMFS_STATE) — rebuild it before" ;;
  esac
  case $INITRAMFS_STATE in
    regenerated*) echo "    was just built rather than the copy it already had." ;;
    *)            echo "    rebooting, or the kernel may keep loading the modules it already has." ;;
  esac
  cat <<EOF

    After rebooting:
      sudo $HERE/verify.sh          check the whole stack
      $HERE/tools/find-ir-node.sh   identify the IR /dev/videoN
      sudo howdy -U \$USER add       enrol a face model
EOF
else
  # --howdy-only touches no kernel module, so do not send anyone for a reboot
  # they do not need.
  cat <<EOF
    No reboot needed — nothing kernel-side was changed. Next:
      $HERE/tools/find-ir-node.sh   identify the IR /dev/videoN, then set
                                    device_path in /etc/howdy/config.ini
      sudo howdy -U \$USER add       enrol a face model
      sudo howdy test               watch the IR frames
EOF
fi
exit 0
