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
#
# The contract, in one line: exit 0 means everything that was asked for
# actually happened. Anything else exits non-zero and names what did not
# happen and why. A stale initramfs, a kernel that did not get the modules, a
# patch that half-applied and a phase that was never selected are all failures,
# not footnotes -- each of them leaves a user rebooting into an unchanged
# system while the installer says "Done".
# ===========================================================================
# `set -E` (errtrace) is what makes the ERR trap below apply inside functions
# and subshells too. Without it an unhandled failure in install_module exits
# with no banner, no summary and no explanation -- the quiet version of the
# exact bug this script exists to prevent.
set -Eeuo pipefail

# readlink -f, not dirname alone: invoked through a symlink (a copy in
# /usr/local/bin, say) plain dirname resolves to the symlink's directory, no
# module is found, and preflight tells the user their download is incomplete
# when it is perfectly intact.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DO_KERNEL=1 DO_HOWDY=1 DRY_RUN=0 DO_INITRAMFS=1 FORCE=0
SEEN_KERNEL_ONLY=0 SEEN_HOWDY_ONLY=0

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

  --kernel-only     DKMS modules, psys patches, udev rules, initramfs.
                    No Howdy. Cannot be combined with --howdy-only.
  --howdy-only      Howdy IR integration and the udev rules it depends on.
                    No DKMS work. Cannot be combined with --kernel-only.
  --dry-run         Run every check and print every intended action, but
                    change nothing at all. Still requires root, because the
                    root-only checks are part of what it is verifying.
  --no-initramfs    Skip the initramfs rebuild (you must do it yourself, or
                    the kernel keeps loading the modules it already has).
                    This is the ONLY way to finish successfully without a
                    regenerated initramfs.
  --force           Continue past the two preflight refusals that are about
                    your machine rather than the package: hardware that does
                    not look like a supported board, and a running kernel with
                    no build tree. Everything else still applies.
                    --force-no-hardware is accepted as a synonym.
  -h, --help        This text.

Exit status: 0 success — everything selected actually happened,
             1 the install did not achieve what it set out to,
             2 preflight failed / bad usage (nothing was touched).
EOF
}

for a in "$@"; do
  case "$a" in
    --kernel-only) DO_HOWDY=0; SEEN_KERNEL_ONLY=1 ;;
    --howdy-only)  DO_KERNEL=0; SEEN_HOWDY_ONLY=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    --no-initramfs) DO_INITRAMFS=0 ;;
    --force|--force-no-hardware) FORCE=1 ;;
    -h|--help)     usage; exit 0 ;;
    # Unknown flags used to be ignored in silence, so a typo like --kernal-only
    # ran the FULL install while the user believed they had scoped it.
    *) printf 'unknown option: %s\n\n' "$a" >&2; usage >&2; exit 2 ;;
  esac
done

# --kernel-only --howdy-only together deselects EVERY phase. That ran the whole
# script, touched nothing, and printed "Done" — a perfect no-op reporting
# success, which is the bug this rewrite exists to kill.
if [[ $SEEN_KERNEL_ONLY -eq 1 && $SEEN_HOWDY_ONLY -eq 1 ]]; then
  printf 'error: --kernel-only and --howdy-only are mutually exclusive — together they select NO phase, so the run would do nothing and still report success.\n' >&2
  printf '       Pass one of them, or neither to install everything.\n\n' >&2
  usage >&2
  exit 2
fi
# Belt and braces for any future flag that can zero a phase.
if [[ $DO_KERNEL -eq 0 && $DO_HOWDY -eq 0 ]]; then
  printf 'error: no phase selected — there is nothing for this run to do.\n' >&2
  exit 2
fi

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
UDEV_FAIL=0
IPU7_REBUILD_FAIL=0
STEPS_SKIPPED=0
RUNNING_NOBUILD=0
HOWDY_PHASE_DONE=0
SECUREBOOT="not checked"
INITRAMFS_STATE="not attempted"
declare -a INSTALLED_MODULES=() FAILED_MODULES=() SKIPPED_NOTES=() ACTIONS=()
declare -a KFAIL_NOTES=() PSYS_SNAPS=() HR_TRIED=() CFG_TRIED=()
declare -A MOD_KERNELS=() KCOUNT=() KFAIL_KERNELS=()

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
#
# When the package ships more than one version of a module, take the HIGHEST
# (sort -V): the plain glob returns them alphabetically, so hm1092-1.0 would be
# picked over hm1092-1.10 and the newer fix would never be installed.
find_src() {
  local m=$1 d
  local -a vers=()
  for d in "$HERE"/dkms/"$m"-*/; do
    [[ -d $d && -f $d/dkms.conf ]] && vers+=("${d%/}")
  done
  if [[ ${#vers[@]} -gt 0 ]]; then
    mapfile -t vers < <(printf '%s\n' "${vers[@]}" | sort -V)
    printf '%s\n' "${vers[${#vers[@]}-1]}"
    return 0
  fi
  for d in "$HERE/dkms/$m" "$HERE/kernel/$m"; do
    [[ -d $d && -f $d/dkms.conf ]] && { printf '%s\n' "${d%/}"; return 0; }
  done
  return 1
}

# How many versioned copies of a module the package ships. More than one is a
# packaging mistake worth naming: only one of them will ever be installed.
count_src(){
  local m=$1 d n=0
  for d in "$HERE"/dkms/"$m"-*/; do [[ -d $d && -f $d/dkms.conf ]] && n=$((n+1)); done
  printf '%s' "$n"
}

declare -A SRC_OF=()
declare -a MISSING_MODULES=()
if [[ $DO_KERNEL -eq 1 ]]; then
  for m in "${REQUIRED_MODULES[@]}"; do
    if s=$(find_src "$m"); then
      SRC_OF[$m]=$s
      ok "package: $m -> ${s#"$HERE"/}"
      [[ $(count_src "$m") -gt 1 ]] && warn "package ships more than one version of $m — using the highest, ${s##*/}"
    else
      MISSING_MODULES+=("$m")
    fi
  done
  if [[ ${#MISSING_MODULES[@]} -eq ${#REQUIRED_MODULES[@]} ]]; then
    # None of them found: far more likely a wrong directory than four
    # simultaneously corrupt downloads. Say the true thing.
    pf_bad "this does not look like the fix-pack directory (looked in $HERE): none of ${REQUIRED_MODULES[*]} is here. Run the installer from inside the clone/tarball."
  else
    for m in "${MISSING_MODULES[@]:-}"; do
      [[ -n $m ]] || continue
      pf_bad "package is missing module '$m' (no dkms/$m-*/dkms.conf, no kernel/$m/dkms.conf) — this clone/tarball is incomplete, re-download it"
    done
  fi
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
  need_tool modinfo "part of kmod — install kmod"
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
RUNNING=$(uname -r)
if [[ $DO_KERNEL -eq 1 ]]; then
  if [[ ${#KERNELS[@]} -eq 0 ]]; then
    pf_bad "no installed kernel has a build tree under /lib/modules/*/build — install headers: pacman -S linux-headers / apt install linux-headers-\$(uname -r) / dnf install kernel-devel"
  else
    ok "kernels with a build tree: ${KERNELS[*]}"
    [[ ${#NOBUILD[@]} -gt 0 ]] && warn "no build tree (will be left unbuilt): ${NOBUILD[*]}"
    # Missing headers for the kernel you are actually on is the case that looks
    # like "the fix did nothing" after a reboot into that same kernel: every
    # module builds, for kernels you are not running, and the installer asks
    # for a reboot that changes nothing.
    if [[ ! -d /lib/modules/$RUNNING/build ]]; then
      RUNNING_NOBUILD=1
      if [[ $FORCE -eq 1 ]]; then
        warn "the RUNNING kernel $RUNNING has no build tree — --force given, continuing, but NOTHING in this run applies to the kernel you are on"
      else
        pf_bad "the RUNNING kernel ($RUNNING) has no build tree at /lib/modules/$RUNNING/build — nothing would be built for the kernel you are on, so the reboot this installer asks for would change nothing. Install its headers (pacman -S linux-headers / apt install linux-headers-$RUNNING / dnf install kernel-devel), boot a kernel that has them, or re-run with --force to build only for the other kernels."
      fi
    fi
  fi
fi

# Initramfs generator. A DKMS rebuild does not regenerate the initramfs, so if
# any of these modules is in the initramfs the kernel keeps loading the OLD
# build no matter how many times it is rebuilt, and every symptom points
# somewhere else. Refusing up front beats a silent skip at the end.
INITRAMFS_CMD=""
if [[ $DO_KERNEL -eq 1 ]]; then
  # Detected even under --no-initramfs, so the "do it yourself" instruction can
  # name the actual command instead of leaving the user to guess it.
  if   command -v mkinitcpio      >/dev/null 2>&1; then INITRAMFS_CMD="mkinitcpio -P"
  elif command -v dracut          >/dev/null 2>&1; then INITRAMFS_CMD="dracut --regenerate-all --force"
  elif command -v update-initramfs >/dev/null 2>&1; then INITRAMFS_CMD="update-initramfs -u -k all"
  fi
  if [[ -n $INITRAMFS_CMD ]]; then
    [[ $DO_INITRAMFS -eq 1 ]] && ok "initramfs generator: $INITRAMFS_CMD"
  elif [[ $DO_INITRAMFS -eq 1 ]]; then
    pf_bad "no initramfs generator found (looked for mkinitcpio, dracut, update-initramfs) — install one, or re-run with --no-initramfs and rebuild the initramfs yourself"
  fi
fi

# udev payload. Both rules are installed in every mode (see the udev section):
# the illuminator rule is a kernel/udev concern even though only Howdy needs it.
for f in "$HERE/udev/99-hm1092-ir-led.rules" "$HERE/udev/99-svp7500-no-autosuspend.rules"; do
  [[ -f $f ]] || pf_bad "package is missing ${f#"$HERE"/} — this clone/tarball is incomplete, re-download it"
done
# Howdy-side payload, checked only when the Howdy phase will run.
if [[ $DO_HOWDY -eq 1 ]]; then
  for f in "$HERE/howdy/ir_reader.py" "$HERE/howdy/video_capture.patch"; do
    [[ -f $f ]] || pf_bad "package is missing ${f#"$HERE"/} — this clone/tarball is incomplete, re-download it"
  done
fi

# --- is this machine even a candidate? --------------------------------------
# Without this the installer will happily build and install five modules on an
# AMD laptop or an IPU6 machine and print a green summary. That is not
# harmless: int3472-patched and ipu-bridge-patched are replacements for IN-TREE
# modules and land in updates/, which depmod prefers over kernel/ -- so on an
# unrelated Intel MIPI laptop this would override working drivers system-wide.
#
# The detection lives in tools/check-hardware.sh, which a stranger can also run
# on its own before cloning anything -- one command instead of the README's old
# five commands and two cross-referenced tables. One implementation, so the
# script that answers "is this for my laptop?" and the installer that enforces
# the answer can never disagree.
if [[ ! -f "$HERE/tools/check-hardware.sh" ]]; then
  pf_bad "package is missing tools/check-hardware.sh — this clone/tarball is incomplete, re-download it"
else
  # shellcheck source=/dev/null
  . "$HERE/tools/check-hardware.sh"
  detect_hardware
  [[ -n $HW_BRIDGE  ]] && ok "CVS bridge on USB: $HW_BRIDGE"
  [[ -n $HW_ACPI    ]] && ok "bridge ACPI id: $HW_ACPI"
  [[ -n $HW_SENSORS ]] && ok "sensors declared by firmware: $HW_SENSORS"
  [[ -n $HW_IPU     ]] && ok "Intel imaging unit on PCI: $HW_IPU"
  HW_RC=0; hw_verdict || HW_RC=$?
  case $HW_RC in
    0) ok "hardware: this machine looks like a supported board" ;;
    2)
      if [[ $FORCE -eq 1 ]]; then
        warn "$HW_REASON --force was given, continuing — this package REPLACES ipu_bridge and intel_skl_int3472 system-wide and can break a working IPU6 camera"
        action "if your camera stops working, back this out: see the 'dkms remove' block in the README"
      else
        pf_bad "$HW_REASON Nothing was changed. (--force overrides, at your own risk.)"
      fi
      ;;
    *)
      if [[ $FORCE -eq 1 ]]; then
        warn "$HW_REASON --force was given, continuing anyway"
        action "this machine did not look like a supported board; if the camera does not work, back the package out (README 'dkms remove' block) rather than debugging it"
      else
        pf_bad "$HW_REASON Nothing was changed — run $HERE/tools/check-hardware.sh for the detail, or re-run with --force if you know better."
      fi
      ;;
  esac
fi

# --- Secure Boot ------------------------------------------------------------
# With Secure Boot on, every dkms build succeeds, every .ko lands, this script
# can prove all of it, and the kernel then refuses to load a single unsigned
# module after the reboot. Dell laptops ship with it enabled.
sb_state(){
  local o f
  if command -v mokutil >/dev/null 2>&1; then
    o=$(mokutil --sb-state 2>/dev/null || true)
    grep -qi 'enabled'  <<<"$o" && { printf 'ENABLED';  return 0; }
    grep -qi 'disabled' <<<"$o" && { printf 'disabled'; return 0; }
  fi
  for f in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -f $f ]] || continue
    if od -An -tu1 "$f" 2>/dev/null | awk 'NR==1{print $5}' | grep -q '^1$'; then
      printf 'ENABLED'
    else
      printf 'disabled'
    fi
    return 0
  done
  if [[ -d /sys/firmware/efi ]]; then printf 'unknown (no mokutil, no SecureBoot efivar)'
  else printf 'n/a (not a UEFI boot)'; fi
}
if [[ $DO_KERNEL -eq 1 ]]; then
  SECUREBOOT=$(sb_state)
  case $SECUREBOOT in
    ENABLED)
      warn "Secure Boot is ENABLED — unsigned DKMS modules will build and install here and then be REFUSED by the kernel at boot ('Key was rejected by service'). Nothing below can detect that; it happens after the reboot."
      action "Secure Boot is on: enrol your DKMS signing key with MOK (mokutil --import), or disable Secure Boot in firmware — otherwise none of these modules will load"
      ;;
    *) ok "secure boot: $SECUREBOOT" ;;
  esac
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

# A module compiled INTO the kernel can never be replaced by a DKMS build. That
# is a real configuration on other distros (CONFIG_IPU_BRIDGE=y), and it makes
# a perfectly successful install completely inert.
module_builtin(){
  local k=$1 n=$2 f="/lib/modules/$1/modules.builtin"
  [[ -f $f ]] || return 1
  grep -qE "/(${n}|${n//-/_})\.ko\$" "$f"
}

# Presence is not precedence. Prove that modprobe on that kernel would resolve
# OUR module and not the in-tree copy it replaces.
ko_resolves_out_of_tree(){
  local k=$1 n=$2 p
  p=$(modinfo -k "$k" -n "$n" 2>/dev/null || true)
  [[ -n $p ]] || p=$(modinfo -k "$k" -n "${n//-/_}" 2>/dev/null || true)
  # No answer at all: modules.dep may not name it. ko_present already proved
  # the file is there, so do not invent a failure we cannot substantiate.
  [[ -n $p ]] || return 0
  case $p in
    */updates/*|*/extra/*|*/weak-updates/*) return 0 ;;
    *) printf '%s' "$p"; return 1 ;;
  esac
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

# Every version of a module DKMS knows about. Parses BOTH status formats:
#   dkms >= 3: "name/version, kernel, arch: installed"
#   dkms 2.x : "name, version, kernel, arch: installed"   (Ubuntu 22.04, Debian)
# Reading only the first told Ubuntu users their module was not under DKMS.
dkms_versions_of(){
  dkms status 2>/dev/null | sed -nE "s|^$1[/,] *([^,:]+).*|\1|p" | sort -u
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

  local ver dst bak had_prior=0
  # Tolerant of the unquoted form (PACKAGE_VERSION=2.0), and FATAL when it
  # cannot be read: the old default of "1.0" made dkms build a version the
  # dkms.conf never declared, which surfaces as an unexplained build failure.
  ver=$(sed -n 's/^PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$src/dkms.conf" | head -1)
  if [[ -z $ver ]]; then
    bad "$m: cannot read PACKAGE_VERSION from ${src#"$HERE"/}/dkms.conf — refusing to guess a version, because a guessed one makes dkms build a tree that does not exist"
    action "fix PACKAGE_VERSION in ${src#"$HERE"/}/dkms.conf, or re-download the package"
    count_module_failure "$m" "$kind"
    return 0
  fi
  dst="/usr/src/${m}-${ver}"
  bak="${dst}.bak"

  # A DIFFERENT version of the same module already registered with DKMS is not
  # something to install over: dkms usually refuses, and when it does not you
  # end up with two builds of the same module name and depmod picking one.
  local -a others=()
  mapfile -t others < <(dkms_versions_of "$m" | grep -vx "$ver" || true)
  if [[ ${#others[@]} -gt 0 ]]; then
    bad "$m: a DIFFERENT version is already registered with DKMS (${others[*]}), and this package ships $ver — installing alongside it leaves two builds of the same module and which one loads is undefined"
    action "remove the other copy first: sudo dkms remove $m/${others[0]} --all   (then re-run this installer)"
    count_module_failure "$m" "$kind"
    return 0
  fi

  # Replace the staged tree rather than merging into it: `cp -r src/.` leaves
  # files from a previous release behind, and a per-run .bak-<timestamp> copy
  # grows /usr/src without bound for a script users are told to re-run. One
  # backup, at a fixed path, overwritten each time.
  if [[ -d $dst ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      plan "would move the existing $dst aside to $bak (replacing any previous backup)"
    else
      rm -rf "$bak"
      if mv "$dst" "$bak"; then
        warn "existing $m moved aside to $bak"
      else
        bad "$m: cannot move $dst aside (is /usr/src writable?)"
        count_module_failure "$m" "$kind"
        return 0
      fi
    fi
  fi
  if ! run mkdir -p "$dst"; then
    bad "$m: cannot create $dst (is /usr/src writable?)"
    count_module_failure "$m" "$kind"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    plan "would copy $src/. -> $dst/"
  elif ! cp -r "$src/." "$dst/"; then
    bad "$m: failed to copy sources into $dst"
    if [[ -d $bak ]]; then
      rm -rf "$dst"
      mv "$bak" "$dst" && warn "$m: the previous $dst was restored from the backup"
    fi
    count_module_failure "$m" "$kind"
    return 0
  fi

  # Register the tree with DKMS -- WITHOUT tearing down what is installed now.
  #
  # This used to be an unconditional `dkms remove ... --all` followed by an
  # install. `dkms remove` deletes the .ko files that are working at this
  # moment; if the build that follows then fails, the machine is left with NO
  # module at all -- strictly worse than before the installer ran, and on the
  # second run of a script users are explicitly told to re-run. Verified: a
  # re-run whose builds fail wipes every previously-installed module.
  #
  # `dkms install --force` rebuilds and replaces in place with no window where
  # nothing is installed, and it reads the source through
  # /var/lib/dkms/<m>/<ver>/source, which is a symlink to the /usr/src tree we
  # have just refreshed. So the ONLY case that still needs a remove is a stale
  # registration whose source symlink points somewhere else entirely -- there,
  # not removing would silently rebuild a different tree.
  #
  # `readlink -f` prints a canonical path even when the file is NOT there (it
  # only needs the parent to exist), so the -e test is load-bearing: without it
  # a module DKMS has never heard of compares "different" and gets removed --
  # the destructive path, on the case that needs it least.
  local reg_src="" want_src=""
  if [[ -e /var/lib/dkms/${m}/${ver}/source ]]; then
    reg_src=$(readlink -f "/var/lib/dkms/${m}/${ver}/source" 2>/dev/null || true)
  fi
  want_src=$(readlink -f "$dst" 2>/dev/null || true)
  if [[ -n $reg_src && -n $want_src && $reg_src != "$want_src" ]]; then
    had_prior=1
    warn "$m: DKMS has $ver registered against $reg_src, not $dst — re-registering it (the currently installed $m is removed to do so)"
    run_quiet dkms remove "${m}/${ver}" --all || true
  fi
  # Already-added is not an error: dkms says so and exits non-zero, and the
  # install below rebuilds from the refreshed source either way.
  run_quiet dkms add "${m}/${ver}" || true

  # Build for EVERY installed kernel. Building only $(uname -r) has repeatedly
  # left other kernels with stale modules and a dead camera after a reboot.
  local names k good=0 badk=0
  local -a badkernels=() okkernels=()
  mapfile -t names < <(built_module_names "$src")
  [[ ${#names[@]} -gt 0 ]] || names=("$m")

  for k in "${KERNELS[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      plan "would run: dkms install --force ${m}/${ver} -k $k   (then check for ${names[*]} under /lib/modules/$k/{updates,extra})"
      good=$((good+1)); okkernels+=("$k"); KBUILD_OK=$((KBUILD_OK+1))
      continue
    fi

    # Nothing to replace if the kernel has it built in.
    local builtin=() n
    for n in "${names[@]}"; do module_builtin "$k" "$n" && builtin+=("$n"); done
    if [[ ${#builtin[@]} -gt 0 ]]; then
      badk=$((badk+1)); KBUILD_FAIL=$((KBUILD_FAIL+1)); badkernels+=("$k")
      bad "$m -> $k: ${builtin[*]} is built INTO that kernel (it is listed in /lib/modules/$k/modules.builtin) — a DKMS module cannot replace a built-in one, so this fix can never take effect on $k"
      action "$k has ${builtin[*]} compiled in (CONFIG_...=y) — this package cannot fix that kernel; use one that builds it as a module"
      continue
    fi

    # --force replaces in place. A plain remove-then-install leaves a window
    # where the module is gone from /lib/modules, and if the build then fails
    # the machine is left with NOTHING installed -- worse than before the run.
    if ! dkms install --force "${m}/${ver}" -k "$k" >/dev/null 2>&1; then
      badk=$((badk+1)); KBUILD_FAIL=$((KBUILD_FAIL+1)); badkernels+=("$k")
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
    local missing=() wrong=() p
    for n in "${names[@]}"; do
      ko_present "$k" "$n" >/dev/null || missing+=("$n")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      badk=$((badk+1)); KBUILD_FAIL=$((KBUILD_FAIL+1)); badkernels+=("$k")
      bad "$m -> $k: dkms reported success but ${missing[*]} is not under /lib/modules/$k/{updates,extra,weak-updates} — treat this as a FAILED install"
      continue
    fi
    # Present is not the same as preferred: if modprobe on that kernel still
    # resolves the in-tree copy, the fix is on disk and inert.
    for n in "${names[@]}"; do
      if ! p=$(ko_resolves_out_of_tree "$k" "$n"); then wrong+=("$n -> $p"); fi
    done
    if [[ ${#wrong[@]} -gt 0 ]]; then
      badk=$((badk+1)); KBUILD_FAIL=$((KBUILD_FAIL+1)); badkernels+=("$k")
      bad "$m -> $k: the kernel would still load the IN-TREE copy (${wrong[*]}) — the build landed but depmod does not prefer it"
      action "run 'sudo depmod -a $k' and re-run; if it persists, something in /etc/depmod.d is reordering the search path"
      continue
    fi
    good=$((good+1)); KBUILD_OK=$((KBUILD_OK+1)); okkernels+=("$k")
    ok "$m -> $k  (verified: ${names[*]})"
  done

  for k in "${okkernels[@]:-}"; do
    [[ -n $k ]] || continue
    KCOUNT[$k]=$(( ${KCOUNT[$k]:-0} + 1 ))
  done
  for k in "${badkernels[@]:-}"; do
    [[ -n $k ]] || continue
    KFAIL_KERNELS[$k]=1
  done
  [[ ${#okkernels[@]} -gt 0 ]] && MOD_KERNELS[$m]="${okkernels[*]}"

  if [[ $good -gt 0 ]]; then
    MOD_OK=$((MOD_OK+1)); INSTALLED_MODULES+=("$m")
    # Written as a full if, not `[[ ]] && warn`: a trailing test that is false
    # makes the function return 1, and under `set -e` that aborts the whole
    # install after the FIRST module. Exactly the kind of silent early exit
    # this rewrite exists to prevent.
    if [[ $badk -gt 0 ]]; then
      warn "$m: installed for $good kernel(s), FAILED for: ${badkernels[*]}"
      KFAIL_NOTES+=("$m did not build for: ${badkernels[*]}")
    fi
  else
    if [[ $kind == required ]]; then
      MOD_FAIL=$((MOD_FAIL+1)); FAILED_MODULES+=("$m")
    else
      MOD_SKIP=$((MOD_SKIP+1))
      SKIPPED_NOTES+=("optional module $m failed to build for every kernel (harmless unless your RGB sensor is OV05C10)")
    fi
    if [[ ${#badkernels[@]} -gt 0 ]]; then KFAIL_NOTES+=("$m did not build for: ${badkernels[*]}"); fi
    # Say which of the two situations this is, because they need different
    # things from the user. Either an older build is still on disk and the
    # machine is no worse than before, or there is now nothing at all -- and
    # claiming the wrong one is its own failure: a user told "NOT installed at
    # all" panics over a working camera, and one told "the old build is still
    # there" when it is not reboots into a dead one.
    local -a still=()
    if [[ $DRY_RUN -eq 0 ]]; then
      for k in "${KERNELS[@]}"; do
        for n in "${names[@]}"; do
          ko_present "$k" "$n" >/dev/null && { still+=("$k"); break; }
        done
      done
    fi
    if [[ ${#still[@]} -gt 0 ]]; then
      bad "$m: this run installed it for NO kernel. An EARLIER build of $m is still on disk for: ${still[*]} — nothing was removed, so those kernels keep what they had, but they do NOT have what this package ships"
      action "$m did not build; ${still[*]} still carry the previous build of it. Fix the build error above and re-run"
    elif [[ $had_prior -eq 1 && $DRY_RUN -eq 0 ]]; then
      bad "$m: not installed for ANY kernel — and its previous registration had to be replaced, so $m is NOT installed at all right now"
      action "$m is not installed for any kernel and the previous copy is gone. Fix the build error above and re-run BEFORE rebooting"
    else
      bad "$m: not installed for ANY kernel"
    fi
  fi
  return 0
}

for m in "${REQUIRED_MODULES[@]}"; do install_module "$m" required; done
for m in "${OPTIONAL_MODULES[@]}"; do
  [[ -n ${SRC_OF[$m]:-} ]] && install_module "$m" optional
done
fi

# --- udev rules -------------------------------------------------------------
# Both rules install in every mode. The illuminator rule used to live inside the
# Howdy phase, so --kernel-only promised "udev" and delivered only half of it:
# the LED stayed root-only and every later IR capture as a normal user was
# silently too dark. The autosuspend rule keeps the bridge firmware from
# wedging on USB power-state transitions ("worked, then stopped after idle").
say "udev rules"
install_rule(){
  local f=$1 src="$HERE/udev/$1" dest="/etc/udev/rules.d/$1"
  if [[ ! -f $src ]]; then
    UDEV_FAIL=$((UDEV_FAIL+1))
    bad "udev/$f is missing from this package — cannot install it"
    action "re-download the package: udev/$f is missing"
    return 0
  fi
  if ! run install -m 0644 "$src" /etc/udev/rules.d/; then
    # A failing install(1) used to produce no line at all here, which is how a
    # step that did not happen ends up inside a successful-looking run.
    UDEV_FAIL=$((UDEV_FAIL+1))
    bad "could not write $dest (install exited non-zero — read-only /etc? immutable file?)"
    action "copy udev/$f to /etc/udev/rules.d/ by hand"
  elif [[ $DRY_RUN -eq 1 ]]; then
    : # the "would run" line above already said it
  elif [[ -f $dest ]]; then
    ok "installed $dest"
  else
    UDEV_FAIL=$((UDEV_FAIL+1))
    bad "install reported success but $dest is not there"
    action "copy udev/$f to /etc/udev/rules.d/ by hand"
  fi
  return 0
}
run mkdir -p /etc/udev/rules.d
install_rule 99-svp7500-no-autosuspend.rules
install_rule 99-hm1092-ir-led.rules
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

# ---------------------------------------------------------------------------
if [[ $DO_KERNEL -eq 1 ]]; then
# --- vendor IPU7 psys suspend patches --------------------------------------
say "IPU7 psys suspend patches (s2idle)"
# Each precondition is tested and reported on its own. The published installer
# collapsed them into one if-chain, so a missing patch FILE printed
# "ipu7-drivers DKMS not installed" and sent a user to audit a DKMS install
# that was perfectly healthy.
#
# Both lookups use the SAME candidate order (dkms/ first, kernel/ second). They
# used to be opposite, so the day the two shipped copies diverge the script
# would disagree with itself about which tree is authoritative.
P=""
for c in "$HERE/dkms/ipu7-psys-patches/psys-suspend-BC.patch" \
         "$HERE/kernel/ipu7-psys-patches/psys-suspend-BC.patch"; do
  [[ -f $c ]] && { P="$c"; break; }
done
DEFERFIX=""
for c in "$HERE/dkms/ipu7-psys-patches/fix-psys-defer.sh" \
         "$HERE/kernel/ipu7-psys-patches/fix-psys-defer.sh"; do
  [[ -f $c ]] && { DEFERFIX="$c"; break; }
done

# Pick the tree DKMS actually HAS INSTALLED. Selecting with `ls | tail -1`
# grabs a stale leftover tree and silently patches the wrong source. Parse both
# dkms status formats, and fall back to the DKMS tree itself -- reading only
# the dkms>=3 format told every Ubuntu 22.04 user "no ipu7-drivers under DKMS"
# and skipped the whole psys phase on a machine that had one.
SRC=$(dkms_versions_of ipu7-drivers | head -1) || true
SRC_STATE="installed"
if [[ -n ${SRC:-} ]]; then
  dkms status 2>/dev/null | grep -qE "^ipu7-drivers[/,] *${SRC}.*installed" || SRC_STATE="registered but NOT installed"
else
  for d in /var/lib/dkms/ipu7-drivers/*/; do
    [[ -d $d ]] || continue
    b=${d%/}; b=${b##*/}
    [[ $b == kernel-* ]] && continue
    [[ -e ${d%/}/source ]] || continue
    SRC=$b; SRC_STATE="found under /var/lib/dkms (dkms status did not list it)"
    break
  done
fi
IPUSRC="/usr/src/ipu7-drivers-${SRC:-}"
if [[ -n ${SRC:-} && -e /var/lib/dkms/ipu7-drivers/$SRC/source ]]; then
  REALSRC=$(readlink -f "/var/lib/dkms/ipu7-drivers/$SRC/source" 2>/dev/null || true)
  [[ -n ${REALSRC:-} && -d ${REALSRC:-/nonexistent} ]] && IPUSRC=$REALSRC
fi

PSYS_TREE_OK=0
if [[ -z ${SRC:-} ]]; then
  # Not a failure. These patches only apply to a DKMS-installed ipu7-drivers
  # tree; if intel_ipu7 comes from your kernel package there is nothing here to
  # patch, and the rest of the install is unaffected.
  skip_step "no ipu7-drivers package under DKMS ('dkms status' lists none, and /var/lib/dkms has none) — psys patches do not apply to this system"
elif [[ ! -d $IPUSRC ]]; then
  skip_step "dkms lists ipu7-drivers/$SRC but $IPUSRC does not exist — the DKMS source tree was deleted; reinstall ipu7-drivers, then re-run"
else
  PSYS_TREE_OK=1
  ok "ipu7-drivers source tree: $IPUSRC  ($SRC_STATE)"
fi

PSYSC="$IPUSRC/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"
# Both patches edit exactly one file. Snapshot it before each step, so a step
# that fails can put back the state it found -- and so a step that fails can
# never be blamed on, or undo, the step before it.
# The snapshot is registered (and reported at the end) only when the file it
# protects actually ends up changed, or when a restore from it failed. A backup
# of a file nobody touched is noise in a vendor tree.
psys_snapshot(){
  local b
  b="$PSYSC.before-$1-$(date +%Y%m%d-%H%M%S)"
  cp -a "$PSYSC" "$b" || return 1
  printf '%s' "$b"
}

if [[ $PSYS_TREE_OK -eq 1 ]]; then
  # 1) the s2idle suspend patch
  if [[ -z $P ]]; then
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "psys-suspend-BC.patch is not in this package (looked in dkms/ and kernel/ipu7-psys-patches/) — packaging bug, nothing to do with your DKMS install"
    action "re-download the package: psys-suspend-BC.patch is missing, so s2idle suspend is unfixed"
  elif [[ $DRY_RUN -eq 1 ]]; then
    # --dry-run of patch(1) is a real, read-only test: it says whether the
    # hunks still apply to this ipu7-drivers revision.
    if patch -p1 -d "$IPUSRC" --batch --forward --dry-run --silent < "$P" >/dev/null 2>&1; then
      plan "would apply psys-suspend-BC.patch to $IPUSRC (patch --dry-run: applies cleanly)"
      PATCH_OK=$((PATCH_OK+1))
    elif grep -q 'pm_runtime_resume_and_get' "$PSYSC" 2>/dev/null; then
      plan "psys-suspend-BC.patch is already applied in $IPUSRC — would be a no-op"
      PATCH_OK=$((PATCH_OK+1))
    else
      # Distinguishing "already applied" from "will not apply" is the whole
      # point of a dry run; counting both as fine would waste it.
      bad "psys-suspend-BC.patch does NOT apply to $IPUSRC and its marker is absent — a real run would refuse to touch the tree"
      PATCH_FAIL=$((PATCH_FAIL+1))
      action "the suspend patch needs rebasing onto ipu7-drivers-$SRC before a real run will fix s2idle"
    fi
  elif patch -p1 -d "$IPUSRC" --batch --forward --dry-run --silent < "$P" >/dev/null 2>&1; then
    # Only apply a patch whose dry run is clean. `patch --forward` applies the
    # hunks it can and rejects the rest, and a HALF-patched psys is not a
    # smaller problem than an unpatched one: the combination of a rewritten
    # psys_suspend without its companion ioctl guards is what oopses the kernel
    # with IRQs off. Half-applied, silently, into a vendor tree, with no backup
    # is how that shipped.
    if ! SNAP=$(psys_snapshot suspend); then
      PATCH_FAIL=$((PATCH_FAIL+1))
      bad "cannot write a backup of $PSYSC — refusing to patch a vendor source tree with no way back"
      action "check permissions/space on $IPUSRC, then re-run"
    elif PERR=$(patch -p1 -d "$IPUSRC" --batch --forward --silent < "$P" 2>&1); then
      PATCH_OK=$((PATCH_OK+1)); PSYS_SNAPS+=("$SNAP")
      ok "suspend patch applied to ipu7-drivers-$SRC  (backup: $SNAP)"
    else
      PATCH_FAIL=$((PATCH_FAIL+1))
      bad "the suspend patch FAILED even though its dry run was clean — patch said:"
      printf '%s\n' "$PERR" | sed 's/^/          /'
      if cp -a "$SNAP" "$PSYSC"; then
        rm -f "$PSYSC.rej" "$PSYSC.orig" "$SNAP"
        bad "$PSYSC was RESTORED from its pre-patch copy — the tree is back to the state it was in, with no half-applied patch in it"
      else
        PSYS_SNAPS+=("$SNAP")
        bad "could NOT restore $PSYSC from $SNAP — the tree may be half-patched; restore that file by hand before rebuilding ipu7-drivers"
        action "restore $PSYSC from $SNAP by hand — a half-applied suspend patch can oops the kernel with IRQs off"
      fi
      action "the s2idle suspend patch did not apply to ipu7-drivers-$SRC; suspend/resume can still oops the psys driver"
    fi
  elif grep -q 'pm_runtime_resume_and_get' "$PSYSC" 2>/dev/null; then
    # --forward exits non-zero on an already-applied patch too, so confirm from
    # the source before claiming either outcome.
    PATCH_OK=$((PATCH_OK+1)); ok "suspend patch already applied"
  else
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "psys-suspend-BC.patch does NOT apply to $IPUSRC (its dry run was rejected) and its marker is absent — NOTHING was written, the tree is untouched; this ipu7-drivers revision has moved"
    action "apply ${P#"$HERE"/} to $IPUSRC by hand, then rebuild ipu7-drivers — until then suspend/resume can oops the psys driver"
  fi

  # 2) the defer-check fix, evaluated independently of (1). These are separate
  # failures with separate symptoms and must never gate each other.
  #
  # psys defers forever when intel_ipu7 comes from the kernel and psys from
  # DKMS: they disagree on struct ipu7_device's layout, so the ready_to_probe
  # read lands at the wrong offset. Result is a MISSING /dev/ipu7-psys0 and no
  # RGB camera, while isys binds normally because it ships with the kernel.
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
  elif ! SNAP2=$(psys_snapshot defer); then
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "cannot write a backup of $PSYSC — refusing to run the defer fix against a vendor tree with no way back"
    action "check permissions/space on $IPUSRC, then re-run"
  elif DERR=$(bash "$DEFERFIX" "$IPUSRC" 2>&1); then
    PATCH_OK=$((PATCH_OK+1))
    if cmp -s "$SNAP2" "$PSYSC"; then rm -f "$SNAP2"; else PSYS_SNAPS+=("$SNAP2"); fi
    ok "psys defer check neutralised"
  else
    PATCH_FAIL=$((PATCH_FAIL+1))
    bad "psys defer fix did not apply to $PSYSC — it said:"
    # fix-psys-defer.sh explains itself (wrong revision, pattern moved, ...).
    # Swallowing that output is how "did not apply" becomes unactionable.
    printf '%s\n' "$DERR" | sed 's/^/          /'
    if cmp -s "$SNAP2" "$PSYSC"; then
      rm -f "$SNAP2"
      warn "$PSYSC was not modified — the tree is exactly as it was before this step"
    elif cp -a "$SNAP2" "$PSYSC"; then
      rm -f "$SNAP2"
      bad "$PSYSC had already been modified when it failed, and was RESTORED to the state it was in before this step"
    else
      PSYS_SNAPS+=("$SNAP2")
      bad "$PSYSC was modified and could NOT be restored from $SNAP2 — restore it by hand before rebuilding"
      action "restore $PSYSC from $SNAP2 by hand"
    fi
    action "run '$DEFERFIX $IPUSRC' by hand and fix what it reports, then rebuild ipu7-drivers — until the defer check is neutralised /dev/ipu7-psys0 may never appear"
  fi

  # 3) rebuild ipu7-drivers for every kernel, and verify the psys .ko landed.
  for k in "${KERNELS[@]}"; do
    if [[ $DRY_RUN -eq 1 ]]; then
      plan "would run: dkms install --force ipu7-drivers/$SRC -k $k"
      continue
    fi
    # --force, never remove-then-install: `dkms remove` deletes the psys module
    # that is working right now, and the build that follows is MORE likely than
    # usual to fail because the source was just patched. That sequence leaves
    # the machine with no psys module at all -- strictly worse than before this
    # installer ran.
    if dkms install --force "ipu7-drivers/$SRC" -k "$k" >/dev/null 2>&1; then
      # Prove it from disk, and take the names from the vendor tree's OWN
      # dkms.conf rather than guessing two spellings of "psys": a revision that
      # names it something else made this print a shrug ("check what this
      # revision names its psys module") for a step whose success was never
      # established. Nothing may pass on a check that did not happen.
      # NOT `local`: this loop is at top level, not inside a function, and
      # `local` there exits 1 -- which under `set -e` kills the script between
      # the psys step and the summary. An install that stops with no verdict is
      # the quiet version of the bug this whole script exists to prevent.
      psysnames=(); psysmissing=()
      if [[ -f $IPUSRC/dkms.conf ]]; then
        mapfile -t psysnames < <(built_module_names "$IPUSRC")
      fi
      if [[ ${#psysnames[@]} -eq 0 ]]; then
        psysnames=(intel-ipu7-psys intel_ipu7_psys)
        # Any one of the fallback spellings is enough; they are the same module.
        if ko_present "$k" intel-ipu7-psys >/dev/null || ko_present "$k" intel_ipu7_psys >/dev/null; then
          ok "ipu7-drivers -> $k  (verified: intel_ipu7_psys)"
        else
          IPU7_REBUILD_FAIL=$((IPU7_REBUILD_FAIL+1))
          bad "ipu7-drivers -> $k: dkms reported success but no psys module is under /lib/modules/$k/{updates,extra,weak-updates}, and $IPUSRC has no dkms.conf to say what it should be called — this rebuild cannot be confirmed, so treat it as FAILED"
          action "check what ipu7-drivers-$SRC builds and where it installs it; nothing verifiable landed for $k"
        fi
      else
        for n in "${psysnames[@]}"; do
          ko_present "$k" "$n" >/dev/null || psysmissing+=("$n")
        done
        if [[ ${#psysmissing[@]} -eq 0 ]]; then
          ok "ipu7-drivers -> $k  (verified: ${psysnames[*]})"
        else
          IPU7_REBUILD_FAIL=$((IPU7_REBUILD_FAIL+1))
          bad "ipu7-drivers -> $k: dkms reported success but ${psysmissing[*]} is not under /lib/modules/$k/{updates,extra,weak-updates} — the patched psys source is NOT in what $k will load"
          action "ipu7-drivers built for $k without installing ${psysmissing[*]}; the psys fixes are not in effect there"
        fi
      fi
    else
      IPU7_REBUILD_FAIL=$((IPU7_REBUILD_FAIL+1))
      bad "ipu7-drivers FAILED to rebuild for $k — $k keeps the module it already had, which was built from the UNPATCHED source, so the psys fixes are NOT in effect there (nothing was removed: this used 'dkms install --force')"
      if lg=$(dkms_log ipu7-drivers "$SRC" "$k"); then
        warn "  build log: $lg"; tail -n 5 "$lg" 2>/dev/null | sed 's/^/          /'
      fi
      action "ipu7-drivers did not rebuild for $k — fix the build error in the log above and run 'sudo dkms install --force ipu7-drivers/$SRC -k $k'"
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
  # NOTE: no apostrophes inside a ${x:-default} — bash parses quotes inside the
  # default word even in double quotes, and one stray ' swallows the rest of the
  # file into a string literal that still passes `bash -n`.
  action "regenerate your initramfs yourself (${INITRAMFS_CMD:-the initramfs command for your distro}) and then reboot — until you do, the kernel can keep loading the modules it already had"
elif [[ -z $INITRAMFS_CMD ]]; then
  # Preflight should have caught this; belt and braces.
  INITRAMFS_STATE="NOT REGENERATED (no generator found)"
  bad "no initramfs generator found — the kernel may keep loading the previous build of these modules"
  action "install mkinitcpio, dracut or update-initramfs, run it, and then reboot"
elif [[ $DRY_RUN -eq 1 ]]; then
  INITRAMFS_STATE="would run: $INITRAMFS_CMD"
  plan "would run: $INITRAMFS_CMD"
elif $INITRAMFS_CMD; then
  INITRAMFS_STATE="regenerated ($INITRAMFS_CMD)"
  ok "initramfs regenerated with: $INITRAMFS_CMD"
else
  INITRAMFS_STATE="FAILED ($INITRAMFS_CMD)"
  bad "$INITRAMFS_CMD failed — the kernel will keep loading the modules already in your initramfs"
  action "run '$INITRAMFS_CMD' yourself and fix the error it prints BEFORE rebooting — until it succeeds this install is not in effect"
fi
fi

# ---------------------------------------------------------------------------
if [[ $DO_HOWDY -eq 1 ]]; then
say "Howdy IR integration"
# Howdy's recorders directory moves between versions and packagings. Asserting
# one path meant a perfectly good /usr/local/lib/howdy install was told "Howdy
# is not installed" and half the product was skipped in silence.
HR=""
HR_TRIED=(/usr/lib/howdy/recorders /usr/local/lib/howdy/recorders /lib/howdy/recorders
          /usr/lib/security/howdy/recorders /usr/local/lib/security/howdy/recorders)
if command -v howdy >/dev/null 2>&1; then
  # Where the howdy executable actually lives, for packagings that put the
  # python tree next to it. A wrapper in a bin/ directory says nothing about
  # where the recorders are, so do not pretend to have looked there.
  HOWDY_DIR=$(dirname "$(readlink -f "$(command -v howdy)")")
  case $HOWDY_DIR in
    */bin|*/sbin) : ;;
    *) HR_TRIED+=("$HOWDY_DIR/recorders") ;;
  esac
fi
for d in "${HR_TRIED[@]}"; do
  [[ -d $d ]] && { HR=$d; break; }
done

if [[ -z $HR ]] && command -v howdy >/dev/null 2>&1; then
  # Howdy IS here; we simply could not find its recorders. Saying "Howdy is not
  # installed" would be a false statement about a healthy component, and
  # skipping is not honest when the user asked for the Howdy phase.
  HOWDY_FAIL=$((HOWDY_FAIL+1))
  bad "howdy is installed at $(command -v howdy) but its recorders directory was not found (looked in: ${HR_TRIED[*]}) — the IR recorder cannot be installed"
  action "find the directory containing Howdy's video_capture.py and copy howdy/ir_reader.py into it, then apply howdy/video_capture.patch by hand"
elif [[ -z $HR ]]; then
  # Name the thing that is missing: Howdy. Not the camera, not DKMS.
  skip_step "Howdy is not installed (no recorders directory in: ${HR_TRIED[*]}, and no 'howdy' in PATH) — the whole Howdy phase was skipped"
  action "IR face unlock is NOT set up: install Howdy, then run 'sudo $HERE/install.sh --howdy-only'"
else
  ok "howdy recorders: $HR"
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

  if [[ ! -f $HR/video_capture.py ]]; then
    HOWDY_FAIL=$((HOWDY_FAIL+1))
    bad "$HR/video_capture.py does not exist — this directory does not look like Howdy's recorders; the IR plugin cannot be hooked up"
    action "check your Howdy installation: $HR has no video_capture.py, so there is nothing to hook the IR recorder into. Re-run with --howdy-only once it is there"
  elif ! grep -q 'ir_reader' "$HR/video_capture.py"; then
    # Howdy ships video_capture.py mode 0444, so the backup and the chmod both
    # have to succeed before patching. Report, do not abort: an abort here
    # would skip the summary entirely.
    run cp "$HR/video_capture.py" "$HR/video_capture.py.bak-$(date +%Y%m%d-%H%M%S)" \
      || warn "could not back up video_capture.py — continuing without a backup"
    run chmod 644 "$HR/video_capture.py" || warn "could not make video_capture.py writable — the patch below will probably fail"
    if [[ $DRY_RUN -eq 1 ]]; then
      if patch -p0 --batch --forward --dry-run --silent "$HR/video_capture.py" < "$HERE/howdy/video_capture.patch" >/dev/null 2>&1; then
        plan "would patch $HR/video_capture.py (patch --dry-run: applies cleanly)"
        HOWDY_OK=$((HOWDY_OK+1))
      else
        bad "howdy/video_capture.patch does NOT apply to $HR/video_capture.py (dry run) — a real run would leave the IR plugin unhooked"
        HOWDY_FAIL=$((HOWDY_FAIL+1))
        action "your Howdy version differs: apply $HERE/howdy/video_capture.patch to $HR/video_capture.py by hand"
      fi
    elif PERR=$(patch -p0 --batch --forward --silent "$HR/video_capture.py" < "$HERE/howdy/video_capture.patch" 2>&1); then
      # Confirm from the file, not from patch's exit code.
      if grep -q 'ir_reader' "$HR/video_capture.py"; then
        HOWDY_OK=$((HOWDY_OK+1)); ok "patched video_capture.py"
      else
        HOWDY_FAIL=$((HOWDY_FAIL+1)); bad "patch succeeded but video_capture.py has no ir_reader hook"
        action "apply $HERE/howdy/video_capture.patch to $HR/video_capture.py by hand"
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

  # Howdy's config lives in different places depending on version and
  # packaging. Hardcoding /etc/howdy/config.ini failed a correctly installed
  # Ubuntu Howdy and told the user their Howdy install was incomplete.
  CFG=""
  CFG_TRIED=(/etc/howdy/config.ini "$(dirname "$HR")/config.ini"
             /usr/lib/howdy/config.ini /usr/local/lib/howdy/config.ini
             /usr/lib/security/howdy/config.ini)
  for c in "${CFG_TRIED[@]}"; do
    [[ -f $c ]] && { CFG=$c; break; }
  done
  if [[ -n $CFG ]]; then
    ok "howdy config: $CFG"
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
    HOWDY_PHASE_DONE=1
  else
    HOWDY_FAIL=$((HOWDY_FAIL+1))
    bad "Howdy's config.ini was not found (looked in: ${CFG_TRIED[*]}) — the recorder is installed but nothing selects it"
    action "find your Howdy config.ini and set: recording_plugin = ir, dark_threshold = 90, timeout = 6"
  fi
fi
fi

# ---------------------------------------------------------------------------
# Summary. Plain counts, so "it worked" is a claim the numbers can contradict.
# ---------------------------------------------------------------------------
# Last line of defence: if some future edit deselects every phase, this run did
# nothing and must not be allowed to reach "Done".
if [[ $DO_KERNEL -eq 0 && $DO_HOWDY -eq 0 ]]; then
  say "Summary"
  bad "no phase was selected — nothing was done"
  exit 1
fi

say "Summary"
# In a dry run the counts describe what WOULD happen; label them that way, or
# the summary over-claims exactly like the script this replaces. "20 builds ok"
# for compilations that never ran is the same bug in a smaller font.
LBL_INSTALLED="modules installed"
LBL_BUILDS="per-kernel builds"
LBL_PATCHES="patches"
LBL_HOWDY="howdy steps"
LBL_PERK="per kernel"
FOR_K=""
if [[ $DRY_RUN -eq 1 ]]; then
  printf '    \033[1mDRY RUN — nothing on this system was changed\033[0m\n'
  LBL_INSTALLED="modules to install"
  LBL_PERK="per kernel (planned)"
  FOR_K="would install for: "
fi
if [[ $DO_KERNEL -eq 1 ]]; then
  # Denominator = the required four plus whichever optional modules this
  # package actually shipped, so the fraction never flatters the result.
  TARGETS=${#REQUIRED_MODULES[@]}
  for m in "${OPTIONAL_MODULES[@]}"; do [[ -n ${SRC_OF[$m]:-} ]] && TARGETS=$((TARGETS+1)); done
  printf '    %-17s : %d / %d\n' "$LBL_INSTALLED" "$MOD_OK" "$TARGETS"
  # WHICH kernels, not just how many. A count cannot tell you that the kernel
  # you boot every day is the one that got nothing.
  for m in "${REQUIRED_MODULES[@]}" "${OPTIONAL_MODULES[@]}"; do
    [[ -n ${SRC_OF[$m]:-} ]] || continue
    if [[ -n ${MOD_KERNELS[$m]:-} ]]; then
      printf '        %-22s %s%s\n' "$m" "$FOR_K" "${MOD_KERNELS[$m]}"
    else
      printf '        %-22s %s\n' "$m" "NOT INSTALLED for any kernel"
    fi
  done
  if [[ ${#KERNELS[@]} -gt 0 ]]; then
    printf '    %-17s :\n' "$LBL_PERK"
    for k in "${KERNELS[@]}"; do
      note=""
      [[ $k == "$RUNNING" ]] && note="   <- the kernel you are running now"
      printf '        %-22s %d of %d module(s)%s\n' "$k" "${KCOUNT[$k]:-0}" "$TARGETS" "$note"
    done
  fi
  if [[ ${#NOBUILD[@]} -gt 0 ]]; then
    printf '        %-22s %s\n' "(no build tree)" "${NOBUILD[*]} — nothing was built for these"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    %-17s : %d planned  (over %d kernel(s)) — nothing was compiled\n' "$LBL_BUILDS" "$KBUILD_OK" "${#KERNELS[@]}"
    printf '    %-17s : %d would apply, %d would fail\n' "$LBL_PATCHES" "$PATCH_OK" "$PATCH_FAIL"
  else
    printf '    %-17s : %d ok, %d failed  (over %d kernel(s))\n' "$LBL_BUILDS" "$KBUILD_OK" "$KBUILD_FAIL" "${#KERNELS[@]}"
    printf '    %-17s : %d applied, %d failed\n' "$LBL_PATCHES" "$PATCH_OK" "$PATCH_FAIL"
  fi
  printf '    %-17s : %d\n' "modules failed" "$MOD_FAIL"
  if [[ ${#FAILED_MODULES[@]} -gt 0 ]]; then
    printf '        %s\n' "${FAILED_MODULES[*]}"
  fi
  if [[ $IPU7_REBUILD_FAIL -gt 0 ]]; then
    printf '    %-17s : FAILED for %d kernel(s)\n' "ipu7-drivers" "$IPU7_REBUILD_FAIL"
  fi
  printf '    %-17s : %s\n' "initramfs" "$INITRAMFS_STATE"
  printf '    %-17s : %s\n' "secure boot" "$SECUREBOOT"
fi
if [[ $UDEV_FAIL -gt 0 ]]; then
  printf '    %-17s : %d failed\n' "udev rules" "$UDEV_FAIL"
fi
if [[ $DO_HOWDY -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    %-17s : %d planned, %d would fail\n' "$LBL_HOWDY" "$HOWDY_OK" "$HOWDY_FAIL"
  else
    printf '    %-17s : %d ok, %d failed\n' "$LBL_HOWDY" "$HOWDY_OK" "$HOWDY_FAIL"
  fi
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
  # A module that built for SOME kernels is not a success. Booting one of the
  # others leaves the camera dead, and "5 / 5 installed" is exactly how that
  # gets missed -- it is the author's own 2026-07-17 incident.
  if [[ $KBUILD_FAIL -gt 0 ]]; then
    bad "${KBUILD_FAIL} per-kernel build(s) did not produce a usable module. Booting these kernels leaves the camera broken: ${!KFAIL_KERNELS[*]}"
    for s in "${KFAIL_NOTES[@]:-}"; do [[ -n $s ]] && printf '        - %s\n' "$s"; done
    action "these kernels did NOT get every module: ${!KFAIL_KERNELS[*]} — fix the build errors listed above and re-run, or do not boot them"
    RC=1
  fi
  # Nothing was built for the kernel the user is on: after the reboot this
  # installer asks for, their machine is byte-for-byte unchanged.
  if [[ $RUNNING_NOBUILD -eq 1 ]]; then
    bad "nothing was built for the kernel you are running ($RUNNING) — it has no build tree, so rebooting into it changes NOTHING."
    action "install the headers for $RUNNING (pacman -S linux-headers / apt install linux-headers-$RUNNING / dnf install kernel-devel) and re-run, or boot one of: ${KERNELS[*]}"
    RC=1
  elif [[ ${KCOUNT[$RUNNING]:-0} -eq 0 && ${#KERNELS[@]} -gt 0 && $MOD_OK -gt 0 ]]; then
    bad "no module was installed for the kernel you are running ($RUNNING) — rebooting into it changes nothing."
    action "see the per-kernel list above: $RUNNING got nothing; fix its build errors or boot a kernel that did get the modules"
    RC=1
  fi
  # A patch that did not apply is also something that did not happen, and it
  # must not hide behind a green module count.
  if [[ $IPU7_REBUILD_FAIL -gt 0 ]]; then
    # "did not rebuild" would be too narrow: this counter also covers a build
    # that dkms called a success but whose psys module could not be found on
    # disk. Both mean the same thing to the user and neither may pass, but the
    # summary must not assert the one that did not happen.
    bad "ipu7-drivers did not produce a verified psys module for ${IPU7_REBUILD_FAIL} kernel(s) — the patched psys source is not in what those kernels will load (see the lines above for which case it was)."
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
  # The initramfs is not a footnote: if it was not regenerated, the kernel can
  # keep loading the modules it already had and this whole install is inert.
  # --no-initramfs stays the one way to opt out cleanly, because that user
  # said so explicitly and was told what they now owe.
  case $INITRAMFS_STATE in
    FAILED*|"NOT REGENERATED"*)
      bad "the initramfs was NOT regenerated ($INITRAMFS_STATE) — the rebooted kernel may load the OLD modules, so this install is not in effect yet."
      RC=1
      ;;
  esac
fi
if [[ $UDEV_FAIL -gt 0 ]]; then
  bad "${UDEV_FAIL} udev rule(s) were not installed — the IR illuminator stays root-only (Howdy times out) and/or the bridge keeps autosuspending."
  RC=1
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
if [[ ${#PSYS_SNAPS[@]} -gt 0 ]]; then
  printf '\n    backups of the vendor psys source taken this run:\n'
  for s in "${PSYS_SNAPS[@]}"; do printf '        %s\n' "$s"; done
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
  COVERED=""
  for k in "${KERNELS[@]}"; do
    [[ ${KCOUNT[$k]:-0} -gt 0 ]] && COVERED="$COVERED $k"
  done
  cat <<'EOF'
    REBOOT is required: hm1092 leaks module references and can never be
    swapped live (unbind succeeds, refcount stays >0, rmmod says "in use").
EOF
  printf '    Modules were installed for:%s\n' "${COVERED:- (none)}"
  # Only claim the initramfs was rebuilt if it actually was. Telling someone
  # their initramfs is current when it is not sends them hunting a hardware
  # fault while the kernel quietly loads last week's module.
  case $INITRAMFS_STATE in
    regenerated*)
      echo "    The initramfs was regenerated above, so the rebooted kernel loads what"
      echo "    was just built rather than the copy it already had." ;;
    *)
      echo "    The initramfs was NOT regenerated ($INITRAMFS_STATE) — rebuild it before"
      echo "    rebooting, or the kernel may keep loading the modules it already has." ;;
  esac
  if [[ $SECUREBOOT == ENABLED ]]; then
    echo "    Secure Boot is ENABLED: until your DKMS signing key is enrolled with"
    echo "    mokutil, the kernel will refuse to load every module installed above."
  fi
  printf '\n    After rebooting:\n'
  printf '      sudo %s/tools/verify.sh          check the whole stack\n' "$HERE"
  printf '      %s/tools/find-ir-node.sh   identify the IR /dev/videoN\n' "$HERE"
  if [[ $HOWDY_PHASE_DONE -eq 1 ]]; then
    printf '      sudo howdy -U $USER add       enrol a face model\n'
  fi
else
  # --howdy-only touches no kernel module, so do not send anyone for a reboot
  # they do not need.
  printf '    No reboot needed — nothing kernel-side was changed. Next:\n'
  printf '      %s/tools/find-ir-node.sh   identify the IR /dev/videoN, then set\n' "$HERE"
  printf '                                    device_path in your Howdy config.ini\n'
  if [[ $HOWDY_PHASE_DONE -eq 1 ]]; then
    printf '      sudo howdy -U $USER add       enrol a face model\n'
    printf '      sudo howdy test               watch the IR frames\n'
  fi
fi
exit 0
