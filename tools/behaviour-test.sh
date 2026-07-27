#!/bin/bash
# ===========================================================================
# behaviour-test.sh — does install.sh REPORT what it did?
#
# tools/selftest.sh checks that the installer can FIND things: that the module
# directories exist, that the README quotes strings install.sh really prints,
# that no script reads an unset variable. It never runs install.sh past --help.
# That blind spot was measured, not guessed: three separate mutants of
# install.sh -- (A) the mutually-exclusive-flags no-op that deselects every
# phase, (B) every `dkms install` neutered so nothing is ever built, and (C) an
# initramfs failure no longer setting RC, so the installer prints "REBOOT is
# required" and exits 0 after mkinitcpio failed -- ALL THREE passed selftest and
# CI green. Every regression this package has shipped is a variation of the same
# thing: something did not happen and the exit code said it did.
#
# So this file tests the one property selftest cannot see:
#
#     exit 0     == everything selected actually happened
#     exit != 0  == it did not, and the output names what and why
#
# HOW IT RUNS WITHOUT HARDWARE, WITHOUT ROOT, AND WITHOUT TOUCHING YOUR MACHINE
#
#   Each scenario runs install.sh inside its own throwaway sandbox:
#
#     * a private mount + user namespace (`unshare --user --map-root-user
#       --mount`). Inside it we are uid 0 -- which is why install.sh's root
#       check passes without sudo -- and every mount below is visible ONLY to
#       that one process tree. Nothing propagates to the machine you are on.
#     * /lib/modules, /usr/src, /etc/udev, /var/lib/dkms and /sys are bind-
#       mounted over with fabricated contents: two invented kernels with build
#       trees, an empty /usr/src, a fake sysfs that check-hardware.sh reads as a
#       supported board.
#     * the Howdy directories install.sh searches (/usr/lib/howdy, /etc/howdy,
#       ...) are shadowed with empty ones, so a machine that really has Howdy
#       cannot have its recorders or its config.ini written to. The author's
#       laptop is one of those machines.
#     * PATH is rebuilt from scratch: a directory of shims (dkms, depmod,
#       modinfo, mkinitcpio, dracut, patch, mokutil, udevadm, uname, clang...)
#       whose exit codes and side effects each scenario scripts, plus a
#       directory of symlinks to the handful of real coreutils programs the
#       installer needs. Nothing else is reachable, which is what makes "no
#       initramfs generator is installed" a state we can actually create.
#
#   The dkms shim is not a stub that returns 0: it reads the real dkms.conf and
#   creates the .ko files it promises, under the DEST_MODULE_LOCATION the conf
#   asks for. That matters, because install.sh does not trust dkms's exit code
#   -- it proves the module from disk. A shim that only returned 0 would test
#   nothing, and a scenario where dkms lies (exit 0, no .ko) would be
#   indistinguishable from success.
#
#   Two interlocks refuse to run rather than risk the host: the inner half exits
#   non-zero unless it is genuinely in a mount namespace of its own AND every
#   expected bind mount is present in /proc/self/mountinfo. If the sandbox
#   cannot be built this script exits 3 and says so. It never skips quietly --
#   that would be this package's own bug, one level up.
#
# Usage:  ./tools/behaviour-test.sh [--list] [--only NAME] [--keep] [-v]
#
# Exit status: 0 every scenario behaved as specified,
#              1 at least one did not (each is named, with expected vs actual),
#              3 the sandbox could not be built, so NOTHING was tested.
# ===========================================================================
set -uo pipefail

SELF=$(readlink -f "$0")
ROOT=$(cd "$(dirname "$SELF")/.." && pwd)

# --- the fabricated world ---------------------------------------------------
KA=6.99.0-btA          # kernel with a build tree; the "running" one by default
KB=6.99.0-btB          # second kernel with a build tree
KC=6.99.0-btC          # kernel WITHOUT a build tree
IPUVER=0.0.r74         # the ipu7-drivers version DKMS "has installed"

# Real programs the installer, check-hardware.sh and fix-psys-defer.sh need.
# Anything not on this list is unreachable from inside a scenario, on purpose:
# that is how "no initramfs generator is installed" becomes a testable state on
# a laptop that has mkinitcpio.
# Deliberately short: everything on it is coreutils, util-linux or diffutils on
# every distro this package targets, and a missing one exits 3 rather than
# quietly changing what the test means.
SYSBIN=(bash sh cat cp mv rm mkdir ls sed awk grep find head tail sort cmp
        chmod install ln touch date stat readlink basename dirname tr od id wc
        env mktemp true false test printf)

# ---------------------------------------------------------------------------
# Scenario table.  name | args to install.sh | one-line statement of the rule
# ---------------------------------------------------------------------------
declare -a SCENARIOS=(
  flags-mutually-exclusive
  unknown-flag
  no-initramfs-generator
  hardware-not-supported
  package-missing-dkms-conf
  running-kernel-no-build-tree
  running-kernel-no-build-tree-force
  mkinitcpio-fails
  dkms-all-builds-fail
  dkms-fails-for-one-kernel
  dkms-lies-no-ko
  stale-registration-removed-then-build-fails
  psys-rebuild-produces-no-ko
  psys-patch-half-applies
  udev-rule-write-fails
  howdy-only-without-howdy
  secure-boot-not-enforced
  secure-boot-enforced-unsigned
  secure-boot-lockdown-integrity
  secure-boot-enforced-signed-and-trusted
  secure-boot-enforced-mok-asserted
  no-initramfs-flag
  dry-run-changes-nothing
  dry-run-predicts-signing-failure
  int3472-redundant-on-this-kernel
  int3472-shadow-from-an-earlier-run
  ov05c10-required-by-this-board
  full-success
  full-success-rerun
  full-success-from-another-cwd
)

declare -A RULE=(
  [flags-mutually-exclusive]="--kernel-only --howdy-only select no phase: must refuse, not run and print Done"
  [unknown-flag]="a typo'd flag must not silently run the FULL install"
  [no-initramfs-generator]="no mkinitcpio/dracut/update-initramfs: refuse before touching anything"
  [hardware-not-supported]="not an IPU7 board: refuse, naming the hardware as the reason"
  [package-missing-dkms-conf]="a module directory with no dkms.conf is an incomplete download, not a skip"
  [running-kernel-no-build-tree]="no headers for the kernel you are ON: refuse and name that kernel"
  [running-kernel-no-build-tree-force]="--force past it still fails: the reboot would change nothing"
  [mkinitcpio-fails]="initramfs generator exits 1: the install is NOT in effect, so neither is exit 0"
  [dkms-all-builds-fail]="nothing built anywhere: NOTHING WAS INSTALLED, never Done"
  [dkms-fails-for-one-kernel]="built for A, failed for B: fail, and name B"
  [dkms-lies-no-ko]="dkms exits 0 and no .ko lands: prove from disk, call it FAILED"
  [stale-registration-removed-then-build-fails]="remove succeeded, build then failed: say the module is now absent"
  [psys-rebuild-produces-no-ko]="no verified psys module: say the psys fixes are not in what the kernel loads"
  [psys-patch-half-applies]="dry run clean, apply failed: restore the vendor tree and fail"
  [udev-rule-write-fails]="a rule that was not written is a failure, not a footnote"
  [howdy-only-without-howdy]="--howdy-only with no Howdy achieved nothing: exit 1"
  [secure-boot-not-enforced]="Secure Boot ON but signatures unenforced: that is fine, and it must say why"
  [secure-boot-enforced-unsigned]="the kernel will refuse every module it just installed: exit 1"
  [secure-boot-lockdown-integrity]="lockdown [integrity] with Secure Boot OFF still refuses: read the mechanism"
  [secure-boot-enforced-signed-and-trusted]="signed by a trusted key: exit 0, and say which key"
  [secure-boot-enforced-mok-asserted]="--mok-enrolled takes it on trust: exit 0, and say it did not verify"
  [no-initramfs-flag]="the one documented way to exit 0 without a fresh initramfs, said out loud"
  [dry-run-changes-nothing]="exit 0 and not one byte written anywhere"
  [dry-run-predicts-signing-failure]="a rehearsal must predict the refusal, not discover it after the reboot"
  [int3472-redundant-on-this-kernel]="the kernel already publishes the IR flood LED: do not install ours over it, and say so"
  [int3472-shadow-from-an-earlier-run]="ours is already shadowing that kernel's driver: the illuminator is dead NOW, so exit 1"
  [ov05c10-required-by-this-board]="the firmware declares OVTI05C1: ov05c10 is not optional here, and failing it is exit 1"
  [full-success]="everything selected happened: exit 0 (a harness that only proves failure proves nothing)"
  [full-success-rerun]="run twice: second run exits 0 and says what it did NOT redo"
  [full-success-from-another-cwd]="invoked by absolute path and through a symlink, from /"
)

# ---------------------------------------------------------------------------
VERBOSE=0; KEEP=0; ONLY=""; PROVE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --prove) PROVE=1 ;;
    --list)
      printf '%-46s %s\n' "SCENARIO" "RULE"
      for s in "${SCENARIOS[@]}"; do printf '%-46s %s\n' "$s" "${RULE[$s]}"; done
      exit 0 ;;
    --only) ONLY=$2; shift ;;
    --keep) KEEP=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)
      awk 'NR>2 { if (/^# ={10,}$/) exit; sub(/^# ?/,""); print }' "$SELF"; exit 0 ;;
    --inner) INNER_SB=$2; shift; INNER=1 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ===========================================================================
# INNER HALF — runs inside the namespace. Builds the mounts, then install.sh.
# ===========================================================================
if [[ ${INNER:-0} -eq 1 ]]; then
  SB=$INNER_SB
  die_inner(){ printf 'SANDBOX REFUSED: %s\n' "$*"; exit 90; }

  # Interlock 1: we must not be in the host's mount namespace. If unshare
  # silently did nothing, every mount below would land on the real machine.
  [[ $(readlink /proc/self/ns/mnt) != "$(cat "$SB/outer-mntns")" ]] \
    || die_inner "still in the caller's mount namespace — refusing to touch the host"
  [[ $(id -u) -eq 0 ]] || die_inner "not uid 0 inside the namespace"
  [[ $SB == /tmp/* || $SB == "${TMPDIR:-/nonexistent}"/* ]] \
    || die_inner "sandbox root $SB is not under a temp directory"

  mount --make-rprivate / 2>/dev/null || true

  bind(){ # bind $1 over $2, only if $2 exists
    [[ -d $2 ]] || return 0
    mount --bind "$1" "$2" || die_inner "cannot bind $1 over $2"
  }
  # Required targets. A missing one is named, because "install.sh wrote to the
  # real /usr/src" is not a failure mode this is allowed to discover later.
  # mkdir is attempted first for the containers we have already tmpfs'd; on a
  # normal system every one of these already exists.
  bind_required(){
    [[ -d $2 ]] || mkdir -p "$2" 2>/dev/null
    [[ -d $2 ]] || die_inner "$2 does not exist on this system and could not be created — the sandbox cannot contain install.sh, so nothing was tested"
    mount --bind "$1" "$2" || die_inner "cannot bind $1 over $2"
  }
  bind_required "$SB/root/lib-modules" /lib/modules
  bind_required "$SB/root/usr-src"     /usr/src
  bind_required "$SB/root/etc-udev"    /etc/udev
  bind_required "$SB/root/sys"         /sys
  if [[ ! -d /var/lib/dkms ]]; then
    mount -t tmpfs none /var/lib || die_inner "cannot shadow /var/lib"
    mkdir -p /var/lib/dkms
  fi
  bind_required "$SB/root/var-lib-dkms" /var/lib/dkms

  # Shadow every directory install.sh searches for a real Howdy, so a machine
  # that actually has one cannot be written to.
  # ...and /etc/dkms, which install.sh reads to decide whether DKMS is set up to
  # sign what it builds. Leaving the host's real one visible would make the
  # signing scenarios depend on how the machine running the test is configured.
  mkdir -p "$SB/root/empty"
  for d in /usr/lib/howdy /usr/local/lib/howdy /lib/howdy \
           /usr/lib/security/howdy /usr/local/lib/security/howdy /etc/howdy \
           /etc/dkms; do
    bind "$SB/root/empty" "$d"
  done

  # Interlock 2: every mount that must exist, does. A missing one means
  # install.sh would write to the real path.
  # /lib is a symlink to usr/lib on Arch-family systems, so mountinfo records
  # the resolved path. Compare what the kernel recorded, not what we typed.
  for m in /lib/modules /usr/src /etc/udev /sys /var/lib/dkms; do
    r=$(readlink -f "$m")
    grep -qE " (${m}|${r}) " /proc/self/mountinfo \
      || die_inner "$m ($r) is not a mountpoint in this namespace"
  done
  for d in /usr/lib/howdy /etc/howdy /etc/dkms; do
    [[ ! -d $d ]] || [[ -z $(ls -A "$d" 2>/dev/null) ]] \
      || die_inner "$d is not shadowed — the host's own configuration is reachable"
  done

  # shellcheck source=/dev/null
  . "$SB/env"
  export PATH="$SB/shims:${BT_EXTRA_PATH:-}${BT_EXTRA_PATH:+:}$SB/sysbin"
  export BT_LOG="$SB/log" BT_SB="$SB"

  mapfile -t ARGS < "$SB/args"
  cd "$(cat "$SB/cwd")" || die_inner "cannot cd to the scenario's working directory"
  INV=$(cat "$SB/invoke")
  # An installer that cannot be executed at all fails every assertion, for a
  # reason that has nothing to do with what the scenario is testing. Refuse,
  # rather than let it look like the scenario caught something.
  [[ -x $INV ]] || die_inner "$INV is not executable — no scenario can mean anything"

  if [[ ${#ARGS[@]} -gt 0 ]]; then
    "$INV" "${ARGS[@]}" >"$SB/out" 2>&1
  else
    "$INV" >"$SB/out" 2>&1
  fi
  echo $? >"$SB/rc"

  # A second run, for the idempotence scenario. Its output is kept separately so
  # the assertions can say which run made which claim.
  if [[ ${BT_RUN_TWICE:-0} -eq 1 ]]; then
    cp "$SB/out" "$SB/out.first"; cp "$SB/rc" "$SB/rc.first"
    if [[ ${#ARGS[@]} -gt 0 ]]; then
      "$INV" "${ARGS[@]}" >"$SB/out" 2>&1
    else
      "$INV" >"$SB/out" 2>&1
    fi
    echo $? >"$SB/rc"
  fi

  # A third invocation through a symlink, from /, for the cwd scenario.
  if [[ ${BT_ALSO_SYMLINK:-0} -eq 1 ]]; then
    mkdir -p "$SB/elsewhere"
    ln -sf "$SB/pkg/install.sh" "$SB/elsewhere/ipu7-install"
    cd /
    "$SB/elsewhere/ipu7-install" >"$SB/out.symlink" 2>&1
    echo $? >"$SB/rc.symlink"
  fi

  # Record what the sandbox looks like afterwards, for filesystem assertions.
  find /usr/src /etc/udev/rules.d /lib/modules -maxdepth 6 2>/dev/null | sort >"$SB/tree-after"
  exit 0
fi

# ===========================================================================
# OUTER HALF
# ===========================================================================
say(){  printf '\n\033[1m==> %s\033[0m\n' "$*"; }
pass(){ printf '    \033[32m✓\033[0m %s\n' "$*"; }
fail(){ printf '    \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '      %s\n' "$*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ipu7-behaviour-XXXXXX") || exit 3
cleanup(){ [[ $KEEP -eq 1 ]] || rm -rf "$WORK"; }
trap cleanup EXIT

# --- can we sandbox at all? -------------------------------------------------
UNSHARE=""
if unshare --user --map-root-user --mount --propagation private true 2>/dev/null; then
  UNSHARE="unshare --user --map-root-user --mount --propagation private"
elif [[ $EUID -eq 0 ]] && unshare --mount --propagation private true 2>/dev/null; then
  UNSHARE="unshare --mount --propagation private"
else
  say "behaviour-test cannot run"
  fail "no usable sandbox: unprivileged user namespaces are unavailable and this is not root."
  info "Nothing was tested. This is exit 3, not a pass — the whole point of this"
  info "file is that a check which did not run must never look like one that did."
  info ""
  info "Fix it with ONE of:"
  info "  sudo sysctl -w kernel.unprivileged_userns_clone=1"
  info "  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0   (Ubuntu 24.04+)"
  info "  or re-run this script as root:  sudo $SELF"
  exit 3
fi

say "IPU7 fix-pack — installer behaviour test"
printf '    package : %s\n' "$ROOT"
printf '    sandbox : %s\n' "$UNSHARE"
printf '    work    : %s\n' "$WORK"

# ---------------------------------------------------------------------------
# --prove: break install.sh on purpose and require this file to notice.
#
# Each of the three mutants below is a regression this package has ALREADY
# shipped or previously reintroduced without CI noticing: all three passed
# tools/selftest.sh with 0 failures. If a mutant now passes here too, this
# harness is decoration and says so, loudly, instead of exiting 0.
#
# Every mutant is checked three ways, because a mutation that did not apply and
# a mutation that was caught look identical from the outside:
#   1. the edit really changed install.sh in the way it claims (and it parses)
#   2. the named scenario passes on the UNMUTATED copy   (else it fails on
#      everything, which proves nothing)
#   3. the named scenario FAILS on the mutated copy, with exit 1 specifically
#      -- exit 3 means the sandbox broke and NOTHING was tested
# ---------------------------------------------------------------------------
# A note on the regexes below: install.sh's shell variables are matched as
# [$]NAME rather than \$NAME. Both mean "a literal dollar" to sed and awk, but
# the second form makes selftest's unset-variable scanner read this file as
# using install.sh's variables -- a false failure on correct code, which is a
# check somebody eventually deletes. Bracket the dollar and the token is gone.
mutate_A(){ # the mutually-exclusive-flags no-op: both guards, and the summary
            # backstop, deleted -- so the flags cancel out and the run reaches
            # "Done" having done nothing.
  local f=$1
  sed -i '/^if \[\[ [$]SEEN_KERNEL_ONLY -eq 1 && [$]SEEN_HOWDY_ONLY -eq 1 \]\]; then$/,/^fi$/d' "$f"
  sed -i '/^# Belt and braces for any future flag that can zero a phase\.$/,/^fi$/d' "$f"
  sed -i '/^if \[\[ [$]DO_KERNEL -eq 0 && [$]DO_HOWDY -eq 0 \]\]; then$/,/^fi$/d' "$f"
  ! grep -q 'SEEN_KERNEL_ONLY -eq 1 && [$]SEEN_HOWDY_ONLY -eq 1' "$f" \
    && ! grep -q 'no phase was selected' "$f"
}
mutate_B(){ # every `dkms install` neutered: nothing is ever built
  local f=$1
  sed -i -e 's/if ! dkms install --force/if ! true dkms install --force/' \
         -e 's/if dkms install --force/if true dkms install --force/' "$f"
  [[ $(grep -c 'true dkms install --force' "$f") -ge 2 ]]
}
mutate_C(){ # an initramfs failure no longer sets RC: "REBOOT is required",
            # exit 0, after mkinitcpio failed
  local f=$1
  local t="$f.mut"
  awk '
    /bad "the initramfs was NOT regenerated [(][$]INITRAMFS_STATE[)]/ { skip=1;
      print "      : # (mutant C) the initramfs failure no longer affects the verdict"; next }
    skip == 1 && /^ *RC=1$/ { skip=0; next }
    { skip=0; print }
  ' "$f" >"$t" || return 1
  # Copy the CONTENT back rather than `mv` the file: mv would carry the temp
  # file's 0644 over the top of install.sh, and a non-executable installer fails
  # every scenario for a reason that has nothing to do with the mutation. That
  # is a mutant "caught" by accident, which is worth no more than one missed.
  cat "$t" >"$f" && rm -f "$t"
  ! grep -q 'bad "the initramfs was NOT regenerated' "$f"
}

if [[ $PROVE -eq 1 ]]; then
  say "Proving this harness can fail"
  P_FAIL=0
  # The control: an untouched copy, so "it rejects everything" is ruled out.
  CTRL="$WORK/control"
  cp -a "$ROOT" "$CTRL"; rm -rf "$CTRL/.git"
  for pair in "A:flags-mutually-exclusive" "B:full-success" "C:mkinitcpio-fails"; do
    mu=${pair%%:*}; sc=${pair#*:}
    if "$CTRL/tools/behaviour-test.sh" --only "$sc" >"$WORK/ctrl-$sc.log" 2>&1; then
      pass "control: $sc passes on an unmodified package"
    else
      fail "control: $sc FAILS on an unmodified package (exit $?) — it would 'catch' anything"
      sed 's/^/      /' "$WORK/ctrl-$sc.log" | tail -20
      P_FAIL=$((P_FAIL+1)); continue
    fi
    MUT="$WORK/mutant-$mu"
    cp -a "$ROOT" "$MUT"; rm -rf "$MUT/.git"
    if ! "mutate_$mu" "$MUT/install.sh"; then
      fail "mutant $mu could not be applied to this install.sh — the code it targets has moved."
      info "That is NOT a pass: nothing was proved. Update mutate_$mu in $SELF."
      P_FAIL=$((P_FAIL+1)); continue
    fi
    if ! bash -n "$MUT/install.sh" 2>"$WORK/mutant-$mu.parse"; then
      fail "mutant $mu does not parse, so it proves nothing"
      sed 's/^/      /' "$WORK/mutant-$mu.parse"
      P_FAIL=$((P_FAIL+1)); continue
    fi
    pass "mutant $mu applied and parses"
    "$MUT/tools/behaviour-test.sh" --only "$sc" >"$WORK/mutant-$mu.log" 2>&1
    mrc=$?
    case $mrc in
      1) pass "mutant $mu is REJECTED by $sc"
         grep -aE '✗' "$WORK/mutant-$mu.log" | head -6 | sed 's/^/      /' ;;
      0) fail "mutant $mu PASSED — $sc did not notice that install.sh is broken"
         P_FAIL=$((P_FAIL+1)) ;;
      3) fail "mutant $mu: the sandbox failed (exit 3), so nothing was tested"
         P_FAIL=$((P_FAIL+1)) ;;
      *) fail "mutant $mu: unexpected exit $mrc"
         P_FAIL=$((P_FAIL+1)) ;;
    esac
  done
  if [[ $P_FAIL -gt 0 ]]; then
    say "FAILED — this harness cannot be trusted to fail"
    KEEP=1
    exit 1
  fi
  say "All three mutants are caught"
  exit 0
fi

# ---------------------------------------------------------------------------
# World construction (host side)
# ---------------------------------------------------------------------------
write_shims(){
  local sb=$1 d="$1/shims"
  mkdir -p "$d"

  cat >"$d/_lib" <<'EOF'
# sourced by every shim
bt_log(){ printf '%s %s\n' "${0##*/}" "$*" >>"${BT_LOG:-/dev/null}"; }
bt_names_of(){ # $1 = /usr/src/<name>-<ver>
  sed -n 's/^BUILT_MODULE_NAME\[[0-9]*\]="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$1/dkms.conf" 2>/dev/null
}
bt_dests_of(){
  sed -n 's/^DEST_MODULE_LOCATION\[[0-9]*\]="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$1/dkms.conf" 2>/dev/null
}
bt_in_list(){ case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
EOF

  cat >"$d/uname" <<'EOF'
#!/bin/bash
case "${1:-}" in
  -r) echo "${BT_UNAME_R:-6.99.0-btA}" ;;
  -m) echo x86_64 ;;
  -s|"") echo Linux ;;
  *) exec "${BT_REAL_UNAME:-/usr/bin/uname}" "$@" ;;
esac
EOF

  cat >"$d/dkms" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"
bt_log "$@"
cmd=${1:-}; shift 2>/dev/null || true
case $cmd in
  status)
    [ -n "${BT_DKMS_STATUS:-}" ] && [ -f "$BT_DKMS_STATUS" ] && cat "$BT_DKMS_STATUS"
    exit 0 ;;
  add)
    exit "${BT_DKMS_ADD_RC:-0}" ;;
  remove)
    spec=${1:-}; name=${spec%%/*}; ver=${spec#*/}
    # A real `dkms remove` deletes the .ko that is working right now. Model
    # that faithfully: it is the whole reason install.sh avoids it.
    for k in /lib/modules/*/; do
      [ -d "$k" ] || continue
      for n in $(bt_names_of "/usr/src/$name-$ver") "$name"; do
        find "$k" -path '*/updates/*' -o -path '*/extra/*' -o -path '*/weak-updates/*' 2>/dev/null \
          | grep -E "/(${n}|${n//-/_})\.ko\$" | while read -r f; do rm -f "$f"; done
      done
    done
    exit "${BT_DKMS_REMOVE_RC:-0}" ;;
  install)
    spec=""; kern=""
    while [ $# -gt 0 ]; do
      case $1 in
        --force) ;;
        -k) kern=$2; shift ;;
        *) [ -z "$spec" ] && spec=$1 ;;
      esac
      shift
    done
    name=${spec%%/*}; ver=${spec#*/}
    src="/usr/src/$name-$ver"
    fail=0
    [ "${BT_DKMS_FAIL_ALL:-0}" = 1 ] && fail=1
    bt_in_list "$kern" "${BT_DKMS_FAIL_KERNELS:-}" && fail=1
    bt_in_list "$name" "${BT_DKMS_FAIL_MODULES:-}" && fail=1
    if [ "$fail" = 1 ]; then
      mkdir -p "/var/lib/dkms/$name/$ver/$kern/x86_64/log"
      {
        echo "DKMS make.log for $name-$ver for kernel $kern (x86_64)"
        echo "  CC [M]  ${name}.o"
        echo "error: this build was scripted to fail by behaviour-test.sh"
      } >"/var/lib/dkms/$name/$ver/$kern/x86_64/log/make.log"
      echo "Error! Bad return status for module build on kernel: $kern" >&2
      exit 1
    fi
    # dkms said yes but installed nothing: the case install.sh must catch by
    # looking at the disk rather than at this exit code.
    bt_in_list "$name" "${BT_DKMS_SILENT_MODULES:-}" && exit 0
    idx=0
    names=(); dests=()
    while IFS= read -r n; do names+=("$n"); done < <(bt_names_of "$src")
    while IFS= read -r n; do dests+=("$n"); done < <(bt_dests_of "$src")
    [ ${#names[@]} -gt 0 ] || names=("$name")
    for n in "${names[@]}"; do
      d=${dests[$idx]:-/updates}; d=${d#/}
      case $d in updates|extra|weak-updates) ;; *) d=updates ;; esac
      mkdir -p "/lib/modules/$kern/$d/dkms"
      printf 'fake %s built from %s for %s\n' "$n" "$src" "$kern" \
        >"/lib/modules/$kern/$d/dkms/${n}.ko"
      idx=$((idx+1))
    done
    exit 0 ;;
esac
exit 0
EOF

  cat >"$d/modinfo" <<'EOF'
#!/bin/bash
kern=${BT_UNAME_R:-6.99.0-btA}; name=""; want_path=0; field=""
while [ $# -gt 0 ]; do
  case $1 in
    -k) kern=$2; shift ;;
    -n) want_path=1 ;;
    -F) field=$2; shift ;;
    -*) ;;
    *) name=$1 ;;
  esac
  shift
done
[ -n "$name" ] || exit 1
# -F signer <path>: who signed this module file. Empty output means unsigned,
# which is the answer install.sh acts on, so it has to be producible.
if [ -n "$field" ]; then
  [ -f "$name" ] || exit 1
  [ "$field" = signer ] || exit 1
  if [ -n "${BT_KO_SIGNER:-}" ]; then echo "${BT_KO_SIGNER:-}"; exit 0; fi
  exit 1
fi
for d in updates extra weak-updates; do
  [ -d "/lib/modules/$kern/$d" ] || continue
  hit=$(find "/lib/modules/$kern/$d" -type f \
        \( -name "${name}.ko" -o -name "${name//-/_}.ko" \) 2>/dev/null | head -1)
  if [ -n "$hit" ]; then
    [ "$want_path" = 1 ] && echo "$hit"
    exit 0
  fi
done
exit 1
EOF

  cat >"$d/depmod" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"; bt_log "$@"; exit "${BT_DEPMOD_RC:-0}"
EOF

  cat >"$d/udevadm" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"; bt_log "$@"; exit 0
EOF

  cat >"$d/mkinitcpio" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"; bt_log "$@"
rc=${BT_MKINITCPIO_RC:-0}
if [ "$rc" = 0 ]; then
  echo "==> Building image for kernel ${BT_UNAME_R:-?}"
else
  echo "==> ERROR: file not found: '/boot/vmlinuz-fake'" >&2
fi
exit "$rc"
EOF
  cat >"$d/dracut" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"; bt_log "$@"; exit "${BT_DRACUT_RC:-0}"
EOF
  cat >"$d/update-initramfs" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"; bt_log "$@"; exit "${BT_UPDATE_INITRAMFS_RC:-0}"
EOF

  cat >"$d/mokutil" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --sb-state) echo "SecureBoot ${BT_SB_STATE:-disabled}" ;;
  --list-enrolled)
    if [ -n "${BT_MOK_ENROLLED:-}" ]; then
      echo "[key 1]"
      echo "        Subject: CN=${BT_MOK_ENROLLED:-}"
    else
      echo "MokListRT is empty"
    fi ;;
  *) exit 1 ;;
esac
exit 0
EOF

  for t in make clang ld.lld llvm-ar; do
    cat >"$d/$t" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"; bt_log "$@"; exit 0
EOF
  done

  # patch(1). The interesting modes are the ones a real patch can produce and a
  # stub cannot: a clean dry run followed by a FAILING apply that has already
  # written to the file. That is the state install.sh must undo.
  cat >"$d/patch" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"
bt_log "$@"
dry=0; dir=""; target=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a=${args[$i]}
  case $a in
    --dry-run) dry=1 ;;
    -d) i=$((i+1)); dir=${args[$i]} ;;
    -p*|--batch|--forward|--silent|--reverse) ;;
    -*) ;;
    *) target=$a ;;
  esac
  i=$((i+1))
done
cat >/dev/null 2>&1 || true          # consume the diff on stdin
if [ -n "$dir" ]; then
  target="$dir/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"
  marker='pm_runtime_resume_and_get'
  kind=psys
else
  marker='ir_reader'
  kind=howdy
fi
[ -f "$target" ] || { echo "patch: **** can't find file to patch: $target" >&2; exit 2; }

# Already applied? Real `patch --forward` exits non-zero and says so; install.sh
# relies on that, then confirms from the file itself.
if grep -q "$marker" "$target"; then
  echo "Reversed (or previously applied) patch detected!  Skipping patch." >&2
  exit 1
fi

mode=${BT_PATCH_MODE:-clean}
case "$kind:$mode" in
  psys:reject|howdy:reject)
    echo "Hunk #1 FAILED at 119." >&2
    echo "1 out of 1 hunk FAILED -- saving rejects to file ${target##*/}.rej" >&2
    exit 1 ;;
  psys:half)
    if [ "$dry" = 1 ]; then exit 0; fi
    # The dangerous shape: some hunks land, the rest reject, and what is left on
    # disk is a psys_suspend without its companion guards.
    printf '\n/* BT-HALF-HUNK: first hunk applied, the rest rejected */\n' >>"$target"
    echo "rejected hunk" >"$target.rej"
    echo "Hunk #2 FAILED at 214." >&2
    echo "1 out of 2 hunks FAILED -- saving rejects to file ${target##*/}.rej" >&2
    exit 1 ;;
esac
[ "$dry" = 1 ] && exit 0
printf '\n/* %s (applied by behaviour-test patch shim) */\n' "$marker" >>"$target"
exit 0
EOF

  chmod 0755 "$d"/*
  chmod 0644 "$d/_lib"
}

# A shim for install(1) that refuses exactly one destination, so the "a udev
# rule was not written" branch can be reached without a read-only /etc.
write_install_shim(){
  cat >"$1/shims/install" <<'EOF'
#!/bin/bash
. "${BT_SB}/shims/_lib"; bt_log "$@"
for a in "$@"; do
  case $a in
    /etc/udev/rules.d*) echo "install: cannot create regular file: Read-only file system" >&2; exit 1 ;;
  esac
done
exec "${BT_REAL_INSTALL:-/usr/bin/install}" "$@"
EOF
  chmod 0755 "$1/shims/install"
}

write_sysbin(){
  local sb=$1 d="$1/sysbin" p missing=()
  mkdir -p "$d"
  for p in "${SYSBIN[@]}"; do
    local real
    real=$(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v "$p" 2>/dev/null)
    if [[ -n $real ]]; then ln -sf "$real" "$d/$p"; else missing+=("$p"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "this system is missing programs the sandbox needs: ${missing[*]}"
    exit 3
  fi
}

fake_sysfs(){ # $1 = sandbox, $2 = supported|unsupported
  local s="$1/root/sys"
  mkdir -p "$s/bus/usb/devices" "$s/bus/i2c/devices" "$s/bus/acpi/devices" \
           "$s/bus/pci/devices" "$s/class/leds" "$s/bus/usb/drivers" \
           "$s/module/module/parameters" "$s/kernel/security"
  [[ $2 == supported ]] || return 0
  mkdir -p "$s/bus/usb/devices/3-9"
  echo 06cb >"$s/bus/usb/devices/3-9/idVendor"
  echo 0701 >"$s/bus/usb/devices/3-9/idProduct"
  mkdir -p "$s/bus/acpi/devices/INTC10E1:00" "$s/bus/acpi/devices/HIMX1092:00" \
           "$s/bus/acpi/devices/INT3472:05"
  mkdir -p "$s/bus/pci/devices/0000:00:05.0"
  echo 0x8086     >"$s/bus/pci/devices/0000:00:05.0/vendor"
  echo 0x048000   >"$s/bus/pci/devices/0000:00:05.0/class"
  echo 0xb05d     >"$s/bus/pci/devices/0000:00:05.0/device"
}

build_world(){ # $1 = sandbox dir
  local sb=$1 k
  mkdir -p "$sb/root/lib-modules" "$sb/root/usr-src" "$sb/root/etc-udev/rules.d" \
           "$sb/root/var-lib-dkms" "$sb/root/empty"

  cp -a "$ROOT" "$sb/pkg"
  rm -rf "$sb/pkg/.git"

  for k in "$KA" "$KB"; do
    mkdir -p "$sb/root/lib-modules/$k/build" "$sb/root/lib-modules/$k/kernel"
    : >"$sb/root/lib-modules/$k/modules.builtin"
    : >"$sb/root/lib-modules/$k/modules.dep"
  done

  # An ipu7-drivers tree that DKMS "has installed", with the real defer check in
  # it, so kernel/ipu7-psys-patches/fix-psys-defer.sh runs for real.
  local ipu="$sb/root/usr-src/ipu7-drivers-$IPUVER"
  mkdir -p "$ipu/drivers/media/pci/intel/ipu7/psys"
  cat >"$ipu/dkms.conf" <<EOF
PACKAGE_NAME="ipu7-drivers"
PACKAGE_VERSION="$IPUVER"
BUILT_MODULE_NAME[0]="intel-ipu7-psys"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
EOF
  cat >"$ipu/drivers/media/pci/intel/ipu7/psys/ipu-psys.c" <<'EOF'
// SPDX-License-Identifier: GPL-2.0
/* stand-in for the vendor psys source, carrying the two patterns the fix-pack
   looks for and nothing else. */
static int ipu7_psys_probe(struct auxiliary_device *auxdev,
			   const struct auxiliary_device_id *id)
{
	struct ipu7_device *isp = adev->isp;

	if (!isp->ipu7_bus_ready_to_probe)
		return -EPROBE_DEFER;

	return 0;
}
EOF
  cp "$ipu/drivers/media/pci/intel/ipu7/psys/ipu-psys.c" "$sb/pristine-ipu-psys.c"

  mkdir -p "$sb/root/var-lib-dkms/ipu7-drivers/$IPUVER"
  ln -sf "/usr/src/ipu7-drivers-$IPUVER" "$sb/root/var-lib-dkms/ipu7-drivers/$IPUVER/source"

  cat >"$sb/dkms-status" <<EOF
ipu7-drivers/$IPUVER, $KA, x86_64: installed
ipu7-drivers/$IPUVER, $KB, x86_64: installed
EOF

  fake_sysfs "$sb" supported
  write_shims "$sb"
  write_sysbin "$sb"

  # A Howdy install, reachable only through PATH (the directory is NOT called
  # bin/ or sbin/, which is how install.sh decides a howdy executable's
  # directory can host the recorders).
  mkdir -p "$sb/howdyroot/recorders"
  cat >"$sb/howdyroot/howdy" <<'EOF'
#!/bin/bash
echo "Howdy 3.0.0 (behaviour-test stand-in)"
EOF
  chmod 0755 "$sb/howdyroot/howdy"
  cat >"$sb/howdyroot/recorders/video_capture.py" <<'EOF'
class VideoCapture:
	def __init__(self, config):
		recording_plugin = config.get("video", "recording_plugin", fallback="opencv")
		if recording_plugin == "opencv":
			self.internal = opencv(config)
EOF
  chmod 0444 "$sb/howdyroot/recorders/video_capture.py"
  cat >"$sb/howdyroot/config.ini" <<'EOF'
[video]
recording_plugin = opencv
dark_threshold = 60
timeout = 4
device_path = /dev/video0
EOF

  : >"$sb/log"
  echo "$ROOT/install.sh" >"$sb/invoke"       # overwritten below with the copy
  echo "$sb/pkg/install.sh" >"$sb/invoke"
  echo "$sb/pkg" >"$sb/cwd"
  : >"$sb/args"
  {
    echo "export BT_UNAME_R='$KA'"
    echo "export BT_DKMS_STATUS='$sb/dkms-status'"
    echo "export BT_REAL_UNAME='$(command -v uname)'"
    echo "export BT_REAL_INSTALL='$(command -v install)'"
    echo "export BT_EXTRA_PATH='$sb/howdyroot'"
  } >"$sb/env"
}

setenv(){ printf "export %s=%q\n" "$1" "$2" >>"$SB/env"; }
setargs(){ printf '%s\n' "$@" >"$SB/args"; }

# ---------------------------------------------------------------------------
# Scenario worlds
# ---------------------------------------------------------------------------
world_flags_mutually_exclusive(){ setargs --kernel-only --howdy-only; }
world_unknown_flag(){ setargs --kernal-only; }
world_no_initramfs_generator(){
  rm -f "$SB/shims/mkinitcpio" "$SB/shims/dracut" "$SB/shims/update-initramfs"
}
world_hardware_not_supported(){ rm -rf "$SB/root/sys"; fake_sysfs "$SB" unsupported; }
world_package_missing_dkms_conf(){ rm -f "$SB/pkg/dkms/hm1092-1.0/dkms.conf"; }
world_running_kernel_no_build_tree(){
  mkdir -p "$SB/root/lib-modules/$KC"
  : >"$SB/root/lib-modules/$KC/modules.builtin"
  setenv BT_UNAME_R "$KC"
}
world_running_kernel_no_build_tree_force(){
  world_running_kernel_no_build_tree
  setargs --force
}
world_mkinitcpio_fails(){ setenv BT_MKINITCPIO_RC 1; }
world_dkms_all_builds_fail(){ setenv BT_DKMS_FAIL_ALL 1; }
world_dkms_fails_for_one_kernel(){ setenv BT_DKMS_FAIL_KERNELS "$KB"; }
world_dkms_lies_no_ko(){ setenv BT_DKMS_SILENT_MODULES "intel-cvs"; }
world_stale_registration_removed_then_build_fails(){
  # A registration pointing at a tree that is not the one we are about to
  # install: the ONE case where install.sh removes before installing.
  mkdir -p "$SB/root/usr-src/intel-cvs-stale" "$SB/root/var-lib-dkms/intel-cvs/1.0"
  ln -sf /usr/src/intel-cvs-stale "$SB/root/var-lib-dkms/intel-cvs/1.0/source"
  # ...and a working module on disk right now, which the remove will delete.
  local k
  for k in "$KA" "$KB"; do
    mkdir -p "$SB/root/lib-modules/$k/extra/dkms"
    echo "previously working intel_cvs" >"$SB/root/lib-modules/$k/extra/dkms/intel_cvs.ko"
  done
  setenv BT_DKMS_FAIL_MODULES "intel-cvs"
}
world_psys_rebuild_produces_no_ko(){ setenv BT_DKMS_SILENT_MODULES "ipu7-drivers"; }
world_psys_patch_half_applies(){ setenv BT_PATCH_MODE half; }
world_udev_rule_write_fails(){ write_install_shim "$SB"; }
world_howdy_only_without_howdy(){
  setargs --howdy-only
  setenv BT_EXTRA_PATH ""
}
enforce_sig(){ echo Y >"$SB/root/sys/module/module/parameters/sig_enforce"; }
world_secure_boot_not_enforced(){ setenv BT_SB_STATE enabled; }
world_secure_boot_enforced_unsigned(){ setenv BT_SB_STATE enabled; enforce_sig; }
world_secure_boot_lockdown_integrity(){
  # Secure Boot OFF and the modules still will not load. This is the case that
  # a "warn when Secure Boot is on" check gets exactly backwards.
  echo 'none [integrity] confidentiality' >"$SB/root/sys/kernel/security/lockdown"
}
world_secure_boot_enforced_signed_and_trusted(){
  setenv BT_SB_STATE enabled; enforce_sig
  setenv BT_KO_SIGNER "IPU7 behaviour-test signing key"
  setenv BT_MOK_ENROLLED "IPU7 behaviour-test signing key"
}
world_secure_boot_enforced_mok_asserted(){
  setenv BT_SB_STATE enabled; enforce_sig
  setargs --mok-enrolled
}
world_no_initramfs_flag(){ setargs --no-initramfs; }
world_dry_run_changes_nothing(){ setargs --dry-run; }
world_dry_run_predicts_signing_failure(){
  setargs --dry-run
  setenv BT_SB_STATE enabled; enforce_sig
}
# --- int3472 / ov05c10 : "optional" and "needed" are properties of the BOARD --
# Give the fake kernels an in-tree intel_skl_int3472_discrete that already
# registers the IR flood LED, plus the two readers tools/int3472-needed.sh uses
# to look inside a module. Nothing else in the world changes.
int3472_in_tree_has_ir_flood(){ # $1 = sandbox, rest = kernels
  local sb=$1; shift
  local k d
  for k in "$@"; do
    d="$sb/root/lib-modules/$k/kernel/drivers/platform/x86/intel/int3472"
    mkdir -p "$d"
    printf 'ELF stand-in\nir_flood\nskl_int3472_register_led\n' >"$d/intel_skl_int3472_discrete.ko"
  done
  # `strings` on a text file is `cat`; the real one is not in SYSBIN on purpose,
  # so this stays a state the scenario creates rather than one it inherits.
  printf '#!/bin/bash\ncat "$@"\n' >"$sb/shims/strings"
  chmod 0755 "$sb/shims/strings"
}
world_int3472_redundant_on_this_kernel(){
  int3472_in_tree_has_ir_flood "$SB" "$KA" "$KB"
}
world_int3472_shadow_from_an_earlier_run(){
  int3472_in_tree_has_ir_flood "$SB" "$KA" "$KB"
  # An earlier run of THIS installer already put ours in updates/ on the kernel
  # the user is running. That camera has no ir_flood LED right now.
  mkdir -p "$SB/root/lib-modules/$KA/updates/dkms"
  echo "shadowing copy from an earlier run" \
    >"$SB/root/lib-modules/$KA/updates/dkms/intel_skl_int3472_discrete.ko"
}
world_ov05c10_required_by_this_board(){
  # A PB14250-class board: the firmware declares OVTI05C1 instead of the
  # OV08F4, so ov05c10 is the ONLY RGB sensor driver this machine can use.
  mkdir -p "$SB/root/sys/bus/acpi/devices/OVTI05C1:00"
  setenv BT_DKMS_FAIL_MODULES "ov05c10"
}

world_full_success(){ :; }
world_full_success_rerun(){ setenv BT_RUN_TWICE 1; }
world_full_success_from_another_cwd(){
  echo / >"$SB/cwd"
  setenv BT_ALSO_SYMLINK 1
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
SC_FAILS=0
expect_rc(){
  local want=$1 got; got=$(cat "$SB/rc")
  if [[ $got == "$want" ]]; then pass "exit $got"
  else fail "exit $got, expected $want"; SC_FAILS=$((SC_FAILS+1)); fi
}
expect_rc_not(){
  local nope=$1 got; got=$(cat "$SB/rc")
  if [[ $got != "$nope" ]]; then pass "exit $got (non-zero as required)"
  else fail "exit $got — a run that did not achieve its goal reported success"; SC_FAILS=$((SC_FAILS+1)); fi
}
expect_say(){
  local re=$1 what=${2:-} f=${3:-$SB/out}
  if grep -qE -- "$re" "$f"; then pass "says: ${what:-$re}"
  else fail "never said: ${what:-$re}"; SC_FAILS=$((SC_FAILS+1)); fi
}
expect_silent(){
  local re=$1 what=${2:-} f=${3:-$SB/out}
  if grep -qE -- "$re" "$f"; then fail "must NOT say: ${what:-$re}"; SC_FAILS=$((SC_FAILS+1))
  else pass "does not say: ${what:-$re}"; fi
}
expect_file_gone(){
  if [[ -e $1 ]]; then fail "$1 still exists"; SC_FAILS=$((SC_FAILS+1)); else pass "gone: ${2:-$1}"; fi
}
expect_no_match_in_tree(){ # $1 = dir, $2 = pattern, $3 = what
  if grep -rqE -- "$2" "$1" 2>/dev/null; then
    fail "$3 — found '$2' under $1"; SC_FAILS=$((SC_FAILS+1))
  else pass "$3"; fi
}
expect_logged(){
  if grep -qE -- "$1" "$SB/log"; then pass "the installer really called: ${2:-$1}"
  else fail "never called: ${2:-$1}"; SC_FAILS=$((SC_FAILS+1)); fi
}

assert_flags_mutually_exclusive(){
  expect_rc 2
  expect_say 'mutually exclusive|no phase' "the flags cancel each other out"
  expect_silent '==> Done' "Done"
  expect_silent 'Summary' "a summary for a run that did nothing"
}
assert_unknown_flag(){
  expect_rc 2
  expect_say 'unknown option: --kernal-only' "the typo, verbatim"
  expect_silent 'Installing DKMS modules' "that it started installing anyway"
}
assert_no_initramfs_generator(){
  expect_rc 2
  expect_say 'no initramfs generator found' "which generators it looked for"
  expect_say 'mkinitcpio, dracut, update-initramfs' "the three names"
  expect_say 'Preflight failed' "that it stopped in preflight"
  expect_say 'nothing was changed' "that nothing was changed"
  expect_silent '==> Done' "Done"
}
assert_hardware_not_supported(){
  expect_rc 2
  expect_say 'no supported board found' "the hardware is the reason"
  expect_say 'Nothing was changed' "that nothing was changed"
  expect_silent '==> Done' "Done"
}
assert_package_missing_dkms_conf(){
  expect_rc 2
  expect_say "package is missing module 'hm1092'" "which module, by name"
  expect_say 'incomplete, re-download it' "what to do about it"
  expect_silent 'this does not look like the fix-pack directory' \
    "the wrong-directory accusation (three of four modules are right here)"
}
assert_running_kernel_no_build_tree(){
  expect_rc 2
  expect_say "RUNNING kernel \\($KC\\) has no build tree" "which kernel, by name"
  expect_say 'the reboot this installer asks for would change nothing' "why it matters"
  expect_silent '==> Done' "Done"
}
assert_running_kernel_no_build_tree_force(){
  expect_rc_not 0
  expect_say "nothing was built for the kernel you are running \\($KC\\)" "the running kernel got nothing"
  expect_say 'rebooting into it changes NOTHING' "what the reboot would achieve"
  expect_silent '==> Done' "Done"
}
assert_mkinitcpio_fails(){
  expect_rc_not 0
  expect_logged 'mkinitcpio -P' "mkinitcpio -P"
  expect_say 'mkinitcpio -P failed' "which command failed"
  expect_say 'the initramfs was NOT regenerated' "the consequence"
  expect_say 'this install is not in effect' "that the install is inert"
  expect_silent '==> Done' "Done"
  expect_silent 'REBOOT is required' "a reboot instruction for an install that is not in effect"
}
assert_dkms_all_builds_fail(){
  expect_rc_not 0
  expect_say 'NOTHING WAS INSTALLED' "that nothing was installed"
  expect_say 'Do not reboot expecting a change' "not to reboot"
  expect_silent '==> Done' "Done"
}
assert_dkms_fails_for_one_kernel(){
  expect_rc_not 0
  expect_say "build FAILED for $KB" "the failing kernel, by name"
  expect_say "Booting these kernels leaves the camera broken: .*$KB" "what booting B costs"
  expect_say "$KA" "the kernel that DID get the modules"
  expect_silent '==> Done' "Done"
}
assert_dkms_lies_no_ko(){
  expect_rc_not 0
  expect_say 'dkms reported success but' "that dkms's exit code was not believed"
  expect_say 'treat this as a FAILED install' "the verdict"
  expect_silent '==> Done' "Done"
}
assert_stale_registration_removed_then_build_fails(){
  expect_rc_not 0
  expect_logged '^dkms remove intel-cvs' "dkms remove"
  expect_say 'is NOT installed at all right now' "that the module is now absent"
  expect_say 'BEFORE rebooting' "the urgency"
  expect_no_match_in_tree "$SB/root/lib-modules" 'previously working intel_cvs' \
    "and it really is absent: no intel_cvs.ko is left on any kernel"
  expect_silent '==> Done' "Done"
}
assert_psys_rebuild_produces_no_ko(){
  expect_rc_not 0
  expect_say 'the patched psys source is NOT in what' "that psys is not what will load"
  expect_say 'ipu7-drivers did not produce a verified psys module' "the summary verdict"
  expect_silent '==> Done' "Done"
}
assert_psys_patch_half_applies(){
  expect_rc_not 0
  expect_say 'the suspend patch FAILED even though its dry run was clean' "the exact failure"
  expect_say 'was RESTORED from its pre-patch copy' "that the tree was put back"
  expect_no_match_in_tree "$SB/root/usr-src/ipu7-drivers-$IPUVER" 'BT-HALF-HUNK' \
    "no half-applied hunk was left in the vendor tree"
  expect_file_gone "$SB/root/usr-src/ipu7-drivers-$IPUVER/drivers/media/pci/intel/ipu7/psys/ipu-psys.c.rej" \
    "the .rej file"
  expect_silent '==> Done' "Done"
}
assert_udev_rule_write_fails(){
  expect_rc_not 0
  expect_say 'could not write /etc/udev/rules.d/' "which file could not be written"
  expect_say 'udev rule\(s\) were not installed' "the summary line"
  expect_say 'IR illuminator stays root-only' "what that costs the user"
  expect_silent '==> Done' "Done"
}
assert_howdy_only_without_howdy(){
  expect_rc_not 0
  expect_say 'Howdy is not installed' "that Howdy, not the camera, is missing"
  expect_say 'no Howdy step succeeded' "that the run achieved nothing"
  expect_silent '==> Done' "Done"
}
assert_secure_boot_not_enforced(){
  # Secure Boot ON is NOT by itself a reason to fail: Arch and CachyOS ship
  # kernels that load unsigned modules with it enabled, and failing here would
  # fail a large share of correct installs. Exit 0 is right — but only if the
  # run says which question it answered.
  expect_rc 0
  expect_say 'Secure Boot is ENABLED' "that Secure Boot is on"
  expect_say 'secure boot *: ENABLED' "the summary line"
  expect_say 'does not enforce module signatures' "the mechanism, not the assumption"
  expect_say 'module signing *: not enforced' "the summary line for signing"
  expect_say '==> Done' "Done"
}
assert_secure_boot_enforced_unsigned(){
  expect_rc_not 0
  expect_say 'are UNSIGNED and this kernel refuses unsigned modules \(sig_enforce=Y\)' \
    "both halves of the fact: unsigned, and refused"
  expect_say 'Key was rejected by service' "the message the user will actually see"
  expect_say 'on disk but NOT in effect' "that the install achieved nothing"
  expect_say 'Do not reboot expecting a working camera' "not to reboot"
  expect_say 'first unsigned: /lib/modules/' "which file it read"
  expect_silent '==> Done' "Done"
  # The trap this scenario exists for: everything else in the run succeeded.
  expect_say 'modules installed *: 5 / 5' "that all 5 modules did build and land"
}
assert_secure_boot_lockdown_integrity(){
  expect_rc_not 0
  expect_say 'lockdown is \[integrity\]' "the actual mechanism"
  expect_say 'secure boot *: disabled' "that Secure Boot is OFF and it failed anyway"
  expect_silent '==> Done' "Done"
}
assert_secure_boot_enforced_signed_and_trusted(){
  expect_rc 0
  expect_say 'signed by a key this machine already trusts' "that the key was checked"
  expect_say 'IPU7 behaviour-test signing key' "which key, by name"
  expect_say 'module signing *: ok' "the summary line"
  expect_say '==> Done' "Done"
  expect_silent '✗' "any failure line"
}
assert_secure_boot_enforced_mok_asserted(){
  expect_rc 0
  expect_say '--mok-enrolled was given' "that the user asserted it"
  expect_say 'this run assumes you sign them' "that it did NOT verify"
  expect_say 'did not verify that they are signed, because you told it not to' \
    "the same thing again in the actions list, where it is actionable"
  expect_say '==> Done' "Done"
}
assert_dry_run_predicts_signing_failure(){
  expect_rc_not 0
  expect_say 'a real run would install modules the kernel then refuses at boot' \
    "what a real run would do"
  expect_say 'a real run would install modules this kernel refuses to load' "the verdict"
  expect_silent '==> Done' "Done"
  if [[ -z $(find "$SB/root/lib-modules" -name '*.ko' -print -quit) ]]; then
    pass "and it predicted it without building anything"
  else fail "the dry run built modules"; SC_FAILS=$((SC_FAILS+1)); fi
}
assert_no_initramfs_flag(){
  expect_rc 0
  expect_say 'initramfs not regenerated \(--no-initramfs\)' "that it was skipped"
  expect_say 'The initramfs was NOT regenerated' "it in the Done block too"
  expect_say 'regenerate your initramfs yourself \(mkinitcpio -P\)' "the command to run"
  expect_silent 'The initramfs was regenerated above' "a claim it did the thing it skipped"
  expect_say '==> Done' "Done — the documented way to succeed without one"
}
assert_dry_run_changes_nothing(){
  expect_rc 0
  expect_say 'DRY RUN' "that it is a rehearsal"
  expect_say 'nothing on this system was changed' "that nothing changed"
  expect_silent '==> Done' "Done (a dry run has not done anything)"
  # The claim, checked against the filesystem it is a claim about.
  if [[ -z $(ls -A "$SB/root/etc-udev/rules.d") ]]; then pass "/etc/udev/rules.d is still empty"
  else fail "--dry-run wrote to /etc/udev/rules.d"; SC_FAILS=$((SC_FAILS+1)); fi
  if [[ -z $(ls -A "$SB/root/usr-src" | grep -v "^ipu7-drivers-") ]]; then
    pass "/usr/src has no module trees in it"
  else fail "--dry-run created trees under /usr/src"; SC_FAILS=$((SC_FAILS+1)); fi
  if [[ -z $(find "$SB/root/lib-modules" -name '*.ko' -print -quit) ]]; then
    pass "no .ko was built for any kernel"
  else fail "--dry-run built modules"; SC_FAILS=$((SC_FAILS+1)); fi
  if grep -qE '^dkms install' "$SB/log"; then
    fail "--dry-run called dkms install"; SC_FAILS=$((SC_FAILS+1))
  else pass "dkms install was never called"; fi
  if cmp -s "$SB/pristine-ipu-psys.c" \
       "$SB/root/usr-src/ipu7-drivers-$IPUVER/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"; then
    pass "the vendor psys source is byte-for-byte unchanged"
  else fail "--dry-run modified the vendor psys source"; SC_FAILS=$((SC_FAILS+1)); fi
}
assert_full_success(){
  expect_rc 0
  expect_say '==> Done' "Done"
  expect_say 'modules installed *: 5 / 5' "5 of 5 modules"
  expect_say 'initramfs *: regenerated' "the initramfs was regenerated"
  expect_say "$KA .* <- the kernel you are running now" "which kernel you are on"
  expect_say 'suspend patch applied' "the psys suspend patch"
  expect_say 'psys defer check neutralised' "the psys defer fix"
  expect_say 'patched video_capture.py' "the Howdy hook"
  expect_say 'recording_plugin=ir, dark_threshold=90, timeout=6' "the Howdy config"
  expect_silent 'NOT INSTALLED for any kernel' "any module missing"
  expect_silent '✗' "any failure line at all"
  # Claims checked against the disk they describe.
  local k n
  for k in "$KA" "$KB"; do
    for n in hm1092 intel_cvs intel_skl_int3472_discrete ipu-bridge ov05c10 intel-ipu7-psys; do
      if find "$SB/root/lib-modules/$k" -name "$n.ko" | grep -q .; then :
      else fail "$n.ko never landed for $k"; SC_FAILS=$((SC_FAILS+1)); fi
    done
  done
  pass "every promised .ko is on disk for both kernels"
  if [[ -f $SB/root/etc-udev/rules.d/99-hm1092-ir-led.rules \
     && -f $SB/root/etc-udev/rules.d/99-svp7500-no-autosuspend.rules ]]; then
    pass "both udev rules are installed"
  else fail "a udev rule is missing from /etc/udev/rules.d"; SC_FAILS=$((SC_FAILS+1)); fi
  if grep -q 'ir_reader' "$SB/howdyroot/recorders/video_capture.py"; then
    pass "video_capture.py really carries the ir hook"
  else fail "video_capture.py has no ir hook"; SC_FAILS=$((SC_FAILS+1)); fi
  if grep -q 'DKMS struct layout mismatch' \
      "$SB/root/usr-src/ipu7-drivers-$IPUVER/drivers/media/pci/intel/ipu7/psys/ipu-psys.c"; then
    pass "the psys defer check really is neutralised in the vendor tree"
  else fail "the psys source still has the defer check"; SC_FAILS=$((SC_FAILS+1)); fi
}
assert_full_success_rerun(){
  local first_rc; first_rc=$(cat "$SB/rc.first")
  if [[ $first_rc == 0 ]]; then pass "first run: exit 0"
  else fail "first run: exit $first_rc"; SC_FAILS=$((SC_FAILS+1)); fi
  expect_rc 0
  expect_say '==> Done' "Done on the second run too"
  expect_say 'modules installed *: 5 / 5' "5 of 5 again"
  # Honest about what it did NOT redo.
  expect_say 'suspend patch already applied' "that the suspend patch was already there"
  expect_say 'already applied' "the defer fix was a no-op"
  expect_say 'video_capture.py already has the ir plugin' "that Howdy was already hooked"
  expect_say 'moved aside to /usr/src/.*\.bak' "where the previous tree went"
  expect_silent '✗' "any failure line"
}
assert_int3472_redundant_on_this_kernel(){
  # Nothing failed, so the run succeeds -- but it must not claim to have
  # installed a module it deliberately did not install.
  expect_rc 0
  expect_say 'NOT installed' "that int3472-patched was not installed"
  expect_say 'REMOVE /sys/class/leds' "what installing it would have cost"
  expect_say 'not needed on:' "the kernels it was skipped for, in the summary"
  # The claim has to be true on disk, not merely printed: nothing named int3472
  # may have landed in an out-of-tree location, where depmod would prefer it
  # over the kernel's own copy. (kernel/ still holds the in-tree module this
  # scenario created -- that is the thing we are protecting.)
  # Match the FILE name, not the path: the sandbox directory is itself called
  # int3472-redundant-on-this-kernel, and grepping the path made every module
  # in the tree look like an int3472 module.
  local shadow d
  shadow=""
  for d in updates extra weak-updates; do
    shadow+=$(find "$SB/root/lib-modules" -type d -name "$d" \
              -exec find {} -name '*int3472*' \; 2>/dev/null)
  done
  if [[ -z $shadow ]]; then
    pass "and no int3472 module landed in updates/ or extra/ — the in-tree driver still wins"
  else
    fail "it said it did not install int3472-patched, and this landed anyway: $shadow"
    SC_FAILS=$((SC_FAILS+1))
  fi
}
assert_int3472_shadow_from_an_earlier_run(){
  # Everything else is green and the camera is still broken on that kernel.
  expect_rc 1
  expect_say 'an EARLIER run of this installer already put' "that ours is already shadowing the in-tree driver"
  expect_say 'dkms remove int3472-patched' "the one command that fixes it"
  expect_silent '==> Done' "Done on a run that leaves the illuminator dead"
}
assert_ov05c10_required_by_this_board(){
  expect_rc 1
  expect_say 'ov05c10 is REQUIRED here, not optional' "that the board's firmware decides this"
  expect_say 'required module\(s\) did not install' "ov05c10 counted as a failure, not a skip"
  expect_silent 'harmless unless your RGB sensor is OV05C10' \
    "the note that calls a dead RGB camera harmless"
  expect_silent '==> Done' "Done on a board left with no RGB driver"
}
assert_full_success_from_another_cwd(){
  expect_rc 0
  expect_say '==> Done' "Done when run from /"
  expect_say 'modules installed *: 5 / 5' "5 of 5 from /"
  local src; src=$(cat "$SB/rc.symlink")
  if [[ $src == 0 ]]; then pass "and exit 0 again through a symlink from /"
  else fail "through a symlink from /: exit $src"; SC_FAILS=$((SC_FAILS+1)); fi
  expect_silent 'does not look like the fix-pack directory' \
    "the wrong-directory accusation" "$SB/out.symlink"
}

# ---------------------------------------------------------------------------
TOTAL=0; FAILED=0
declare -a RESULTS=()
for name in "${SCENARIOS[@]}"; do
  [[ -z $ONLY || $ONLY == "$name" ]] || continue
  fn=${name//-/_}
  TOTAL=$((TOTAL+1))
  SB="$WORK/$name"
  mkdir -p "$SB"
  build_world "$SB"
  "world_$fn"
  readlink /proc/self/ns/mnt >"$SB/outer-mntns"

  say "$name"
  printf '    \033[2m%s\033[0m\n' "${RULE[$name]}"
  $UNSHARE -- bash "$SELF" --inner "$SB" >"$SB/inner-out" 2>&1
  irc=$?
  if [[ $irc -ne 0 ]]; then
    fail "the sandbox itself failed (exit $irc) — nothing was tested"
    sed 's/^/      /' "$SB/inner-out"
    FAILED=$((FAILED+1)); RESULTS+=("$name|SANDBOX-ERROR")
    continue
  fi

  SC_FAILS=0
  "assert_$fn"
  if [[ $VERBOSE -eq 1 ]]; then
    printf '      \033[2m--- install.sh output ---\033[0m\n'
    sed 's/^/      /' "$SB/out"
  fi
  if [[ $SC_FAILS -eq 0 ]]; then
    RESULTS+=("$name|ok")
  else
    FAILED=$((FAILED+1)); RESULTS+=("$name|FAILED ($SC_FAILS)")
    printf '      \033[2mfull output: %s/out\033[0m\n' "$SB"
    if [[ $VERBOSE -eq 0 ]]; then
      printf '      \033[2m--- install.sh output ---\033[0m\n'
      sed 's/^/      /' "$SB/out"
    fi
    KEEP=1
  fi
done

say "Behaviour test summary"
for r in "${RESULTS[@]}"; do
  n=${r%%|*}; v=${r#*|}
  if [[ $v == ok ]]; then printf '    \033[32m✓\033[0m %-46s %s\n' "$n" "$v"
  else printf '    \033[31m✗\033[0m %-46s %s\n' "$n" "$v"; fi
done
printf '\n    %d scenario(s), %d failed\n' "$TOTAL" "$FAILED"
if [[ $TOTAL -eq 0 ]]; then
  fail "no scenario ran — that is a failure, not a pass"
  exit 1
fi
if [[ $FAILED -gt 0 ]]; then
  say "FAILED"
  echo "    install.sh did not behave as specified above. Each ✗ names what was"
  echo "    expected and what happened. Sandboxes for the failing scenarios were"
  echo "    kept under $WORK"
  exit 1
fi
say "All scenarios behaved as specified"
exit 0
