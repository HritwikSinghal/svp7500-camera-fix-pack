#!/usr/bin/env bash
# ===========================================================================
# selftest.sh — is this PACKAGE internally consistent?
#
# Hardware-free, root-free, side-effect-free. It does not touch /usr/src,
# /lib/modules, /etc or /boot, does not run dkms, and does not load a module.
# It answers one question: if a stranger downloaded this repo right now and ran
# install.sh, would the installer find everything it is about to install?
#
# It exists because of a specific failure. install.sh looked for modules in
# kernel/<name>/ while the published package ships dkms/<name>-<version>/. It
# found none of them, printed "! <name> not in package, skipping" four times,
# then printed "==> Done" and exited 0. It had installed nothing, for every
# user who ever ran it, and nothing in the repo noticed.
#
# So the rule this file enforces is: a step that did not happen must not be
# able to report success. Every check below is a thing that was silently
# skipped, or could be. It is deliberately paranoid about the package, and
# says nothing whatsoever about whether any camera works -- it cannot, and it
# never claims to.
#
#   ./tools/selftest.sh          human output
#   ./tools/selftest.sh -q       only failures and the summary
#   ./tools/selftest.sh --prove  test the test: build one correct throwaway
#                                package and nine broken ones -- each carrying a
#                                bug that shipped or nearly did -- and assert
#                                this script accepts the first and rejects every
#                                other. A check nobody has ever seen fail is not
#                                yet a check.
#
# Exit status: 0 = every check passed, 1 = at least one FAIL.
# WARN never changes the exit status, so it is reserved for things that are
# true today and could rot tomorrow (two byte-identical copies of one script).
# Anything that means an instruction in this package cannot work -- a path that
# is not there, two files with one name, a module nobody installs -- is a FAIL.
# A warning that CI ignores is how the verify.sh split shipped.
# ===========================================================================
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL="$ROOT/install.sh"
README="$ROOT/README.md"
QUIET=0
[[ ${1:-} == -q || ${1:-} == --quiet ]] && QUIET=1

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=; C_R=; C_Y=; C_B=; C_0=
fi

n_pass=0; n_fail=0; n_warn=0
declare -a FAILS=() WARNS=()

section(){ [[ $QUIET -eq 1 ]] || printf '\n%s== %s%s\n' "$C_B" "$*" "$C_0"; }
info(){ [[ $QUIET -eq 1 ]] || printf '       %s\n' "$*"; }
pass(){ n_pass=$((n_pass+1)); [[ $QUIET -eq 1 ]] || printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$*"; }
fail(){ n_fail=$((n_fail+1)); FAILS+=("$1"); printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"
        shift; local l; for l in "$@"; do printf '       %s\n' "$l"; done; }
warn(){ n_warn=$((n_warn+1)); WARNS+=("$1")
        [[ $QUIET -eq 1 ]] && return 0
        printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$1"
        shift; local l; for l in "$@"; do printf '       %s\n' "$l"; done; }

rel(){ printf '%s' "${1#"$ROOT"/}"; }

# ---------------------------------------------------------------------------
# A shell script as LOGICAL lines: backslash continuations joined, whole-line
# comments dropped, and every line tagged CAND or PLAIN.
#
# CAND marks a first-match-wins candidate list --
#     for c in "$HERE/dkms/x.patch" "$HERE/kernel/x.patch"; do
#       [[ -f $c ]] && { P=$c; break; }
#     done
# -- where only ONE of the paths has to exist. A for-loop with no break (and no
# `return 0`) is an assert-EACH loop, like preflight's "package is missing $f"
# check: every path in it is independently required.
#
# The distinction matters because the reference checker used to group by
# basename and pass a group when any member existed. That is correct for a real
# candidate list and wrong for everything else: it is how `git rm verify.sh`
# still passed while install.sh's last screen told every user to run it.
logical_lines(){
  awk '
    /^[[:space:]]*#/ { next }
    { line=$0
      while (line ~ /\\$/) { sub(/\\[[:space:]]*$/,"",line); if ((getline nxt)<=0) break; line=line " " nxt }
      L[++n]=line }
    END {
      for (i=1;i<=n;i++) {
        tag="PLAIN"
        if (L[i] ~ /(^|[;&|{}][[:space:]]*|[[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]].*;[[:space:]]*do([[:space:]]|$)/) {
          for (j=i;j<=n;j++) {
            if (j>i && L[j] ~ /^[[:space:]]*done([[:space:]]|;|$)/) break
            if (L[j] ~ /(^|[^A-Za-z0-9_])break([^A-Za-z0-9_]|$)/ ||
                L[j] ~ /(^|[^A-Za-z0-9_])return[[:space:]]+0([^0-9]|$)/) { tag="CAND"; break }
          }
        }
        print tag "\t" L[i]
      }
    }' "$1"
}

# ---------------------------------------------------------------------------
# --prove: do these checks actually fire?
#
# Builds throwaway packages in a temp directory -- one correct, then one copy per
# regression, each carrying exactly one real bug that has shipped or nearly did --
# and asserts this script rejects each of them and accepts the correct one. A
# check nobody has watched fail is not yet a check, and every one of these was a
# WARN or a blind spot the day the package went out. Nothing outside the temp
# directory is touched: no dkms, no modules, no root.
if [[ ${1:-} == --prove ]]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mk_pkg(){ # $1 dir, $2 = search path expression install.sh will use
    mkdir -p "$1/tools" "$1/dkms/demo-1.0" "$1/udev" "$1/howdy"
    cat > "$1/install.sh" <<EOF
#!/usr/bin/env bash
# Tested on: kernels 1.0 through 2.0
set -euo pipefail
HERE="\$(cd "\$(dirname "\$(readlink -f "\$0")")" && pwd)"
REQUIRED_MODULES=(demo)
find_src(){ local m=\$1 d; for d in $2; do [[ -d \$d && -f \$d/dkms.conf ]] && { echo "\${d%/}"; return 0; }; done; return 1; }
for m in "\${REQUIRED_MODULES[@]}"; do find_src "\$m" || echo "! \$m not in package, skipping"; done
install -m 0644 "\$HERE/udev/99-hm1092-ir-led.rules" /etc/udev/rules.d/
install -m 0444 "\$HERE/howdy/ir_reader.py" /usr/lib/howdy/recorders/ir_reader.py
patch -p0 -d / < "\$HERE/howdy/video_capture.patch"
echo "==> Done"
echo "   sudo \$HERE/verify.sh   check the whole stack"
bad "package is missing module 'x' — this clone/tarball is incomplete, re-download it"
EOF
    printf 'PACKAGE_NAME="demo"\nPACKAGE_VERSION="1.0"\nBUILT_MODULE_NAME[0]="demo"\n' > "$1/dkms/demo-1.0/dkms.conf"
    printf 'MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"\n' \
      >> "$1/dkms/demo-1.0/dkms.conf"
    printf 'obj-m += demo.o\n' > "$1/dkms/demo-1.0/Makefile"
    : > "$1/dkms/demo-1.0/demo.c"
    { printf '# demo\nkernels 1.0 through 2.0\n\nAfter the reboot:\n\n    sudo ./tools/verify.sh\n'
      printf '\n| line | meaning |\n|---|---|\n'
      printf '| `✗ package is missing module '"'"'<name>'"'"' — this clone/tarball is incomplete, re-download it` | packaging bug |\n'
    } > "$1/README.md"
    printf 'ACTION=="add", KERNEL=="flash*", MODE="0660"\n' > "$1/udev/99-hm1092-ir-led.rules"
    printf 'class ir_reader:\n    pass\n' > "$1/howdy/ir_reader.py"
    printf -- '--- a/video_capture.py\n+++ b/video_capture.py\n' > "$1/howdy/video_capture.patch"
    printf '#!/bin/bash\necho "verification, canonical copy"\n' > "$1/tools/verify.sh"
    ln -s tools/verify.sh "$1/verify.sh"
    chmod +x "$1/install.sh" "$1/tools/verify.sh"
    cp "${BASH_SOURCE[0]}" "$1/tools/selftest.sh"; chmod +x "$1/tools/selftest.sh"
  }
  GOOD_SEARCH='"$HERE"/dkms/"$m"-*/ "$HERE/dkms/$m" "$HERE/kernel/$m"'
  rc=0
  # mutate <name> -- a copy of the good package for the caller to break
  mutate(){ cp -a "$t/good" "$t/$1"; printf '%s' "$t/$1"; }
  # expect_fail <dir> <substring> <what it is>
  expect_fail(){
    local d=$1 want=$2 label=$3 out e
    out=$(NO_COLOR=1 "$d/tools/selftest.sh" 2>&1); e=$?
    if [[ $e -ne 0 ]] && grep -qF "$want" <<<"$out"; then
      printf '  PASS  rejects %s\n' "$label"
    elif [[ $e -eq 0 ]]; then
      printf '  FAIL  %s exits 0 — %s ships green\n' "$(basename "$d")" "$label"; rc=1
    else
      printf '  FAIL  %s failed for the WRONG reason (no "%s" in the output)\n' "$(basename "$d")" "$want"; rc=1
    fi
  }

  mk_pkg "$t/good" "$GOOD_SEARCH"
  out_g=$(NO_COLOR=1 "$t/good/tools/selftest.sh" 2>&1); eg=$?
  if [[ $eg -eq 0 ]]; then
    printf '  PASS  accepts a correctly laid out package\n'
  else
    printf '  FAIL  rejects a CORRECT package — false positive, every proof below is meaningless\n'
    printf '%s\n' "$out_g" | sed -n 's/^  FAIL/        FAIL/p'; rc=1
  fi

  # 1. THE bug: the installer looks where the package does not put the modules.
  mk_pkg "$t/layout" '"$HERE/kernel/$m"'
  expect_fail "$t/layout" "CANNOT FIND module 'demo'" \
    "the shipped layout mismatch (installer looks in kernel/, package ships dkms/)"

  # 2. The same mistake one function later: a module path built outside the
  #    candidate list. install.sh catches this at runtime; the package test did not.
  d=$(mutate copy-step-wrong-layout)
  printf 'cp -r "$HERE/kernel/$m/." /tmp/staging\n' >> "$d/install.sh"
  expect_fail "$d" "outside its candidate list" "a module path expression that resolves for no module"

  # 3. Divergent duplicate: the verify.sh split that shipped. install.sh points
  #    at the root copy, the README at tools/ — and they are different files.
  d=$(mutate divergent-verify)
  rm "$d/verify.sh"; cp "$d/tools/verify.sh" "$d/verify.sh"
  printf 'echo "STALE COPY: no stale-module check here"\n' >> "$d/verify.sh"
  expect_fail "$d" "exists twice with DIFFERENT contents" "two verify.sh files with different contents"
  expect_fail "$d" "point at DIFFERENT files named verify.sh" \
    "install.sh and the README sending users to different files"

  # 4. Either half of the pair deleted. Grouping by basename used to pass both
  #    of these at "1 of 2 candidate paths present".
  d=$(mutate tools-verify-deleted); rm "$d/tools/verify.sh"
  expect_fail "$d" "DANGLING symlink" "the canonical copy deleted out from under the root name"
  d=$(mutate root-verify-deleted); rm "$d/verify.sh"
  expect_fail "$d" "referenced but MISSING from the package: verify.sh" \
    "install.sh's own next-steps command pointing at a file that is not shipped"

  # 5. A documented root-level command that does not exist. The reference
  #    checker only knew subdirectory paths, so the README's entry point --
  #    the first thing a stranger types -- was the one path nothing checked.
  d=$(mutate readme-phantom-command)
  printf '\nQuick start:\n\n    sudo ./setup-ir.sh --all\n' >> "$d/README.md"
  expect_fail "$d" "referenced but MISSING from the package: setup-ir.sh" \
    "a README quick-start naming a script that was never committed"

  # 6. A module shipped but never wired into install.sh: a maintainer adds a
  #    sensor driver for someone else's board and forgets the *_MODULES line.
  d=$(mutate module-not-wired); mkdir -p "$d/dkms/extra-1.0"
  printf 'PACKAGE_NAME="extra"\nPACKAGE_VERSION="1.0"\nBUILT_MODULE_NAME[0]="extra"\n' > "$d/dkms/extra-1.0/dkms.conf"
  printf 'MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"\n' \
    >> "$d/dkms/extra-1.0/dkms.conf"
  printf 'obj-m += extra.o\n' > "$d/dkms/extra-1.0/Makefile"; : > "$d/dkms/extra-1.0/extra.c"
  expect_fail "$d" "dkms/extra is shipped but install.sh never installs it" \
    "a module directory the installer never names"

  # 7. MAKE[0] building in a directory the package does not contain: dkms fails
  #    per kernel, inside a log file, worded like a build quirk.
  d=$(mutate make-line-bogus)
  sed -i 's|/build modules|/build/src modules|' "$d/dkms/demo-1.0/dkms.conf"
  expect_fail "$d" "is not in this package" "a MAKE[0] M= path that does not exist in the package"

  # 8. The README's decode table quoting a message the installer does not print.
  #    That table is the user's only key for telling a real install from a no-op,
  #    and it shipped quoting three strings install.sh never produced: you
  #    Ctrl-F the README's wording, find nothing, and cannot tell which row you
  #    are in. Reword the installer and this must fail on the next push.
  d=$(mutate readme-quotes-drifted)
  sed -i 's|this clone/tarball is incomplete, re-download it|this download is incomplete, get it again|' "$d/install.sh"
  expect_fail "$d" "installer output that install.sh never prints" \
    "a README decode table quoting a message the installer does not print"

  exit $rc
fi

[[ -f $INSTALL ]] || { printf 'selftest: no install.sh at %s\n' "$INSTALL" >&2; exit 1; }

mapfile -t SCRIPTS < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.sh' -type f -print | sort)
mapfile -t DOCS    < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.md' -type f -print | sort)

# ===========================================================================
section "install.sh can locate every DKMS module it installs"
# ---------------------------------------------------------------------------
# THE check, and the reason this file exists.
#
# Both halves are read out of install.sh itself -- the module names it iterates
# and the directory patterns it searches -- so this can never drift away from
# the installer. Rewrite install.sh's layout assumption and this fails on the
# next push, which is exactly what did not happen the morning the installer
# shipped searching kernel/<name>/ for modules published as dkms/<name>-<ver>/.

# module names: from `*_MODULES=(a b c)` arrays and from literal `for m in a b c`
mapfile -t REQUIRED_M < <(sed -n 's/^[[:space:]]*REQUIRED_MODULES=(\([^)]*\)).*/\1/p' "$INSTALL" | tr ' ' '\n' | grep -v '^$')
mapfile -t OPTIONAL_M < <(sed -n 's/^[[:space:]]*OPTIONAL_MODULES=(\([^)]*\)).*/\1/p' "$INSTALL" | tr ' ' '\n' | grep -v '^$')
mapfile -t LOOP_M     < <(sed -n 's/^[[:space:]]*for m in \([^;"$]*\);[[:space:]]*do.*/\1/p' "$INSTALL" | tr ' ' '\n' | grep -v '^$')
ALL_M=("${REQUIRED_M[@]}" "${OPTIONAL_M[@]}" "${LOOP_M[@]}")
mapfile -t ALL_M < <(printf '%s\n' "${ALL_M[@]:-}" | grep -v '^$' | sort -u)

# search patterns: every "$HERE/...$m..." path expression in install.sh
MOD_PAT_RE='"?\$HERE"?/[^ ;)]*\$\{?m\}?[^ ;)]*'
mapfile -t MOD_PATTERNS < <(grep -oE "$MOD_PAT_RE" "$INSTALL" | tr -d '"' | sort -u)
# ...and the subset written OUTSIDE a first-match candidate list. Inside one,
# a pattern that resolves for nothing is a harmless fallback; outside one it is
# a path the installer will actually use, so it has to work for every module.
mapfile -t MOD_PAT_PLAIN < <(logical_lines "$INSTALL" | grep '^PLAIN' \
                             | grep -oE "$MOD_PAT_RE" | tr -d '"' | sort -u)

mod_expand(){ local e=${1//\$HERE/$ROOT}; e=${e//\$\{m\}/$2}; printf '%s' "${e//\$m/$2}"; }
mod_hit(){ # <pattern> <module> -> prints the source dir it resolves to, or fails
  local e d; e=$(mod_expand "$1" "$2")
  for d in $e; do d=${d%/}; d=${d%/.}
    [[ -d $d && -f $d/dkms.conf ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

if [[ ${#ALL_M[@]} -eq 0 ]]; then
  fail "cannot determine which modules install.sh installs" \
       "expected REQUIRED_MODULES=(...) or a literal 'for m in ...; do'" \
       "an unknowable module list is an unverifiable installer"
elif [[ ${#MOD_PATTERNS[@]} -eq 0 ]]; then
  fail "install.sh contains no \$HERE/...\$m path — cannot tell where it looks for modules" \
       "if it looks in the wrong place every module is skipped and the run still exits 0"
else
  info "installer searches: ${MOD_PATTERNS[*]}"
  for m in "${ALL_M[@]}"; do
    found=""; tried=()
    for pat in "${MOD_PATTERNS[@]}"; do
      tried+=("$(rel "$(mod_expand "$pat" "$m")")")
      found=$(mod_hit "$pat" "$m") && break
      found=""
    done
    optional=0
    for o in "${OPTIONAL_M[@]:-}"; do [[ $o == "$m" ]] && optional=1; done
    if [[ -n $found ]]; then
      pass "$m -> $(rel "$found")/dkms.conf"
    elif [[ $optional -eq 1 && -z $(ls -d "$ROOT"/dkms/"$m"* "$ROOT"/kernel/"$m"* 2>/dev/null) ]]; then
      warn "optional module '$m' is named by install.sh but not shipped at all" \
           "boards that need it get nothing; install.sh will skip it by design"
    else
      shipped=$(cd "$ROOT" && ls -d dkms/"$m"* kernel/"$m"* 2>/dev/null | tr '\n' ' ')
      fail "install.sh CANNOT FIND module '$m' — it would skip it and still report success" \
           "searched: ${tried[*]}" \
           "shipped:  ${shipped:-(nothing matching)}"
    fi
  done

  # Every module path expression written OUTSIDE the candidate list must work
  # for EVERY module the installer names. find_src()'s list may contain a
  # fallback that matches nothing in the published layout -- that is what a
  # fallback is for -- but a path built anywhere else (the copy step, a backup,
  # a dkms add) is used directly, and one wrong layout assumption there skips
  # the module exactly the way the shipped bug did, one function later.
  for pat in "${MOD_PAT_PLAIN[@]:-}"; do
    [[ -z $pat ]] && continue
    misses=(); for m in "${ALL_M[@]}"; do mod_hit "$pat" "$m" >/dev/null || misses+=("$m"); done
    if [[ ${#misses[@]} -eq ${#ALL_M[@]} ]]; then
      fail "install.sh uses the path '$pat' outside its candidate list, and it resolves for NO module" \
           "expanded for ${ALL_M[0]}: $(rel "$(mod_expand "$pat" "${ALL_M[0]}")")" \
           "this is the shipped bug's shape: the module is looked for where the package does not put it"
    elif [[ ${#misses[@]} -gt 0 ]]; then
      fail "install.sh uses the path '$pat' outside its candidate list; it resolves for ${#ALL_M[@]} modules minus: ${misses[*]}" \
           "that step is skipped for those modules while the rest of the run reports success"
    else
      pass "direct path '$pat' resolves for all ${#ALL_M[@]} module(s)"
    fi
  done
fi

# the reverse: a module in the package that the installer never names is a
# module nobody receives -- the same silent no-op, one level up. This is a
# FAILURE, not a warning: a maintainer adding a sensor driver for one of the
# reporters' boards and forgetting the *_MODULES line ships a package that
# delivers nothing for that board and says Done. If a tree is meant to be inert
# for now, name it in OPTIONAL_MODULES so the intent is recorded in install.sh
# instead of inferred from silence.
for conf in "$ROOT"/dkms/*/dkms.conf; do
  [[ -f $conf ]] || continue
  nm=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
  known=0
  for m in "${ALL_M[@]:-}"; do [[ $m == "$nm" ]] && known=1; done
  [[ $known -eq 1 ]] || fail "dkms/$nm is shipped but install.sh never installs it" \
                             "installer knows: ${ALL_M[*]:-(none)}" \
                             "add it to REQUIRED_MODULES/OPTIONAL_MODULES in install.sh, or drop the directory"
done

# ===========================================================================
section "dkms.conf is valid and matches the Makefile"
# A dkms.conf that lies about PACKAGE_NAME, or names a module the Makefile does
# not build, fails inside `dkms install` -- whose output install.sh sends to a
# log, so it surfaces as one terse per-kernel warning that reads like a build
# quirk rather than a packaging error.

CLANG_YES=(); CLANG_NO=()
for conf in "$ROOT"/dkms/*/dkms.conf; do
  [[ -f $conf ]] || continue
  d=$(dirname "$conf"); b=$(basename "$d")
  name=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
  ver=$(sed -n 's/^PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
  mapfile -t built < <(sed -n 's/^BUILT_MODULE_NAME\[[0-9]*\]="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf")

  [[ -n $name ]] || fail "$(rel "$conf"): no PACKAGE_NAME"
  [[ -n $ver  ]] || fail "$(rel "$conf"): no PACKAGE_VERSION"
  [[ ${#built[@]} -gt 0 ]] || fail "$(rel "$conf"): no BUILT_MODULE_NAME — dkms would build and install nothing"
  [[ -n $name && -n $ver && ${#built[@]} -gt 0 ]] && \
    pass "$(rel "$conf"): $name/$ver, builds ${built[*]}"

  # the directory must carry the same version: install.sh copies the tree to
  # /usr/src/<name>-<PACKAGE_VERSION> and dkms reads the conf back from there
  if [[ $b == *-* && -n $ver && -n $name ]]; then
    [[ $b == "$name-$ver" ]] || fail "directory $(rel "$d") does not match $name-$ver from its own dkms.conf" \
        "install.sh installs to /usr/src/$name-$ver — a mismatch is how a stale tree gets built instead"
  fi

  # MAKE[0] is the other half of the build contract, and it is the half that
  # fails per-kernel inside a log file. `M=` names the directory dkms builds in;
  # dkms copies THIS package directory there, so any trailing subpath must exist
  # here too. A stale `M=.../build/src` compiles nothing and reports it once per
  # kernel, worded like a build quirk.
  mkline=$(sed -n 's/^MAKE\[0\]=//p' "$conf" | head -1); mkline=${mkline%\"}; mkline=${mkline#\"}
  mk="$d/Makefile"
  if [[ -z $mkline ]]; then
    warn "$(rel "$conf"): no MAKE[0] — dkms falls back to its own default build command"
  else
    if grep -q 'CC=clang' <<<"$mkline"; then CLANG_YES+=("$b"); else CLANG_NO+=("$b"); fi
    grep -qE '[$]\{?kernel_source_dir\}?' <<<"$mkline" \
      || fail "$(rel "$conf"): MAKE[0] never mentions kernel_source_dir" \
              "dkms would build against whatever kernel make picks, not the one being installed for"
    mval=$(grep -oE '(^|[[:space:]])M=[^[:space:]"]+' <<<"$mkline" | head -1); mval=${mval#" "}; mval=${mval#M=}
    if [[ -z $mval ]]; then
      fail "$(rel "$conf"): MAKE[0] has no M= build directory" "$mkline"
    else
      exp=$mval
      exp=${exp//'${dkms_tree}'/@T@};       exp=${exp//'$dkms_tree'/@T@}
      exp=${exp//'${PACKAGE_NAME}'/$name};    exp=${exp//'$PACKAGE_NAME'/$name}
      exp=${exp//'${PACKAGE_VERSION}'/$ver};  exp=${exp//'$PACKAGE_VERSION'/$ver}
      pre="@T@/$name/$ver/build"
      if [[ $exp == "$pre" || $exp == "$pre"/* ]]; then
        sub=${exp#"$pre"}; sub=${sub#/}
        tgt="$d${sub:+/$sub}"
        if [[ -d $tgt ]]; then
          mk="$tgt/Makefile"
          [[ -f $mk ]] || fail "$(rel "$conf"): MAKE[0] builds in M=$mval but $(rel "$tgt") has no Makefile"
          [[ -z $sub ]] || pass "$(rel "$conf"): MAKE[0] builds in $sub/, which the package ships"
        else
          fail "$(rel "$conf"): MAKE[0] builds in M=$mval — '$sub' is not in this package" \
               "dkms runs make in a directory that does not exist and every kernel's build fails in a log"
        fi
      else
        fail "$(rel "$conf"): MAKE[0]'s M=$mval is not the dkms build directory for $name/$ver" \
             "expected \${dkms_tree}/$name/$ver/build[/subdir] — anything else builds a tree dkms did not stage"
      fi
    fi
  fi

  if [[ ! -f $mk ]]; then
    [[ -f $d/Makefile ]] || fail "$(rel "$d"): no Makefile — dkms has nothing to run"
  else
    for bm in "${built[@]}"; do
      grep -qE "(^|[[:space:]])${bm//./\\.}\.o([[:space:]]|$)" "$mk" \
        || fail "$(rel "$mk") does not build $bm.o, but dkms.conf expects $bm.ko" \
                "dkms fails at its copy step; the user sees one line about one kernel"
      objs=$(sed -n "s/^${bm//./\\.}-y[[:space:]]*:=[[:space:]]*//p" "$mk")
      [[ -z $objs ]] && objs="$bm.o"
      for o in $objs; do
        [[ -f "${mk%/Makefile}/${o%.o}.c" ]] || fail "$(rel "${mk%/Makefile}"): missing source ${o%.o}.c (needed for $bm)" \
                                        "the module is listed but its code is not in the package"
      done
    done
  fi
done

# These trees are built with clang against clang-built kernels. One conf losing
# CC=clang while its siblings keep it builds that module with a different
# toolchain than the kernel it loads into -- which surfaces as a load failure,
# not a build failure, long after the installer said Done.
if [[ ${#CLANG_YES[@]} -gt 0 && ${#CLANG_NO[@]} -gt 0 ]]; then
  warn "MAKE[0] toolchain is inconsistent: ${CLANG_NO[*]} build without CC=clang, ${CLANG_YES[*]} with it" \
       "if that is deliberate, say so in the dkms.conf; if not, the odd one out will not load"
elif [[ ${#CLANG_YES[@]} -gt 0 ]]; then
  pass "all ${#CLANG_YES[@]} dkms.conf MAKE[0] lines use the same toolchain (CC=clang)"
fi

# ===========================================================================
section "every path the scripts reference exists in the package"
# References are gathered from the scripts themselves: a script that resolves
# its own directory ($HERE=$(cd "$(dirname "$0")" ...)) has that variable name
# discovered, so new scripts are covered without editing anything here.
#
# Every reference must resolve ON ITS OWN. The single exception is a real
# first-match-wins candidate list -- `for c in A B; do [[ -f $c ]] && break` --
# where the code itself only needs one of the paths; those, and only those, are
# grouped, and the group prints "1 of 2 present" so the tolerance is visible.
#
# This used to group by BASENAME instead, which quietly merged unrelated
# references: install.sh's `$HERE/verify.sh` and the README's `tools/verify.sh`
# became one group, and deleting either file still passed at "1 of 2 candidate
# paths present" while one of the two documented commands no longer existed.

declare -A GRP=()
declare -a REFLOG=()
# add_ref <path> <strict> <group-id> <origin>
#   strict=1  a real code path ($HERE/...): the file must be there, full stop.
#   strict=0  a path named in prose or a comment: required only when its parent
#             directory exists here, so documentation that quotes a path in some
#             OTHER tree (kernel/drivers/staging/..., /usr/lib/howdy/...) does
#             not masquerade as a missing package file.
#   group-id  paths sharing one id satisfy each other (candidate lists only).
#             Everything else uses "path:<p>", so the same path mentioned in ten
#             places is one check and two different paths are two checks.
add_ref(){
  local p=${1#/} strict=$2 gid=$3 origin=${4:-} hit=0 req
  [[ -z $p || $p == . || $p == .. ]] && return 0
  [[ $p == .git* || $p == */.git* ]] && return 0
  [[ $p == ../* || $p == */../* ]] && return 0             # outside the package
  [[ -e $ROOT/$p ]] && hit=1
  req=$strict
  [[ $strict -eq 0 && -d $ROOT/$(dirname "$p") ]] && req=1
  REFLOG+=("$origin|$(basename "$p")|$p|$hit")
  case " ${GRP[$gid]:-} " in *" $p|"*) return 0;; esac      # same path, said twice
  GRP[$gid]="${GRP[$gid]:-} $p|$hit|$req"
}
sane_token(){ [[ -n $1 && $1 != *'$'* && $1 != *'*'* && $1 != *'{'* && $1 != *'}'* && $1 != *'<'* && $1 != *'('* ]]; }

KNOWN_TOP='tools|udev|howdy|dkms|kernel|scripts|docs|ipu7poke|usbio-patch'

for s in "${SCRIPTS[@]}"; do
  rs=$(rel "$s")
  # a variable is this script's own root only if it is assigned from $0 / BASH_SOURCE
  mapfile -t rootvars < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*dirname.*(\$0|BASH_SOURCE)' "$s" \
                          | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | sort -u)
  rootvars+=(HERE)
  ln=0
  while IFS=$'\t' read -r tag line; do
    ln=$((ln+1))
    toks=()
    for v in "${rootvars[@]}"; do
      while read -r tok; do
        tok=$(printf '%s' "$tok" | tr -d '"'"'")
        tok=${tok#\$\{$v\}/}; tok=${tok#\$$v/}
        tok=${tok%%[),\`]*}
        sane_token "$tok" && toks+=("$tok")
      done < <(grep -oE "\"?\\\$\{?$v\}?\"?/[^ ;)\`]*" <<<"$line")
    done
    # $(dirname ...)/x is only a PACKAGE path when the dirname is of this
    # script itself. `$(dirname "$HOWDY_BIN")/recorders` is a path on the user's
    # machine, and demanding the package ship a "recorders" file is a false
    # accusation of the kind this whole package exists to stop making.
    while read -r tok; do
      tok=${tok#*)/}; tok=$(printf '%s' "$tok" | tr -d '"'"'")
      sane_token "$tok" && toks+=("$tok")
    done < <(grep -oE '\$\(dirname[^)]*(\$0|BASH_SOURCE)[^)]*\)/[A-Za-z0-9_./-]+' <<<"$line")
    [[ ${#toks[@]} -eq 0 ]] && continue
    if [[ $tag == CAND && ${#toks[@]} -gt 1 ]]; then
      for t in "${toks[@]}"; do add_ref "$t" 1 "cand:$rs:$ln" "$rs"; done
    else
      for t in "${toks[@]}"; do add_ref "$t" 1 "path:$t" "$rs"; done
    fi
  done < <(logical_lines "$s")
done

# Paths named in scripts, comments and docs: repo-relative ("run tools/verify.sh")
# and root-level ("sudo ./install.sh"). The root-level form used to be invisible
# here -- the pattern only knew the subdirectory names -- so the README's own
# entry point, the thing every stranger types first, was the one path nothing
# checked. A quick-start block naming a script that was never committed passed.
for f in "${SCRIPTS[@]}" "${DOCS[@]}"; do
  rf=$(rel "$f"); fdir=$(dirname "$rf"); [[ $fdir == . ]] && fdir=""
  # This file is the checker, not documentation: its comments quote paths and
  # commands as EVIDENCE (the fixtures --prove builds, the scripts whose past
  # bugs each check exists for). Treating those as instructions to the user
  # would make every explanation a maintenance burden.
  [[ $f == "${BASH_SOURCE[0]}" || $rf == tools/selftest.sh ]] && continue
  while read -r kind tok; do
    tok=${tok%%[\`,\"\']*}; tok=${tok%.}; tok=${tok%:}
    sane_token "$tok" || continue
    [[ $tok == */ && -d $ROOT/${tok%/} ]] && continue    # bare directory in prose
    # prose that merely reads like a path -- "a kernel/udev concern" -- is not a
    # reference. Require a filename (something.ext) unless the path is real.
    [[ ${tok##*/} == *.* || -e $ROOT/$tok ]] || continue
    if [[ $kind == DOT && $tok != */* && -n $fdir ]]; then
      # a bare dot-slash command in a file that lives in a subdirectory is
      # ambiguous: a script's own usage line means "beside me", a README-style
      # quick start means "from the repo root". Either resolving is enough;
      # neither resolving is a documented command that cannot be typed.
      add_ref "$fdir/$tok" 0 "dot:$rf:$tok" "$rf"
      add_ref "$tok"       0 "dot:$rf:$tok" "$rf"
    else
      add_ref "$tok" 0 "path:$tok" "$rf"
    fi
  done < <( { grep -hoE "(^|[^A-Za-z0-9_/.\$-])($KNOWN_TOP)/[A-Za-z0-9_./-]+" "$f" | sed -E 's@^[^A-Za-z]*@@; s@^@REL @'
              grep -hoE "(^|[^A-Za-z0-9_/-])\./[A-Za-z0-9_./-]+\.(sh|py)" "$f" | sed -E 's@^[^.]*\./@@; s@^@DOT @'
            } )
done

while read -r gid; do
  present=0; total=0; required=0; detail=""; miss=""
  for e in ${GRP[$gid]}; do
    total=$((total+1))
    IFS='|' read -r epath ehit ereq <<<"$e"
    [[ $ereq == 1 ]] && required=1
    if [[ $ehit == 1 ]]; then present=$((present+1)); detail=$epath; else miss+=" $epath"; fi
  done
  if [[ $present -gt 0 ]]; then
    if [[ $total -gt 1 ]]; then pass "$detail  ($present of $total candidate paths present)"
    else pass "$detail"; fi
  elif [[ $required -eq 1 ]]; then
    fail "referenced but MISSING from the package:$miss" \
         "a script or doc points at a file that is not here; whatever uses it gets skipped"
  fi
done < <(printf '%s\n' "${!GRP[@]}" | sort)

# install.sh's last screen and the README must send the user to the SAME file.
# They did not: install.sh said `sudo $HERE/verify.sh`, the README said
# `sudo ./tools/verify.sh`, and the two were 37 lines apart -- the installer
# recommending the copy that could not detect the failure it had just warned
# about. Comparing resolved paths (so a symlink counts as the same file) makes
# that divergence impossible to ship again.
declare -A IREF=() RREF=()
for r in "${REFLOG[@]}"; do
  IFS='|' read -r org rb rp rhit <<<"$r"
  [[ $rhit == 1 ]] || continue
  real=$(readlink -f "$ROOT/$rp")
  case $org in
    install.sh) IREF[$rb]="${IREF[$rb]:-} $real" ;;
    README.md)  RREF[$rb]="${RREF[$rb]:-} $real" ;;
  esac
done
while read -r rb; do
  [[ -z $rb || -z ${RREF[$rb]:-} ]] && continue
  # They agree if some file is named by both. install.sh listing two candidates
  # for one file is fine; naming a DIFFERENT file than the README is not.
  common=""
  for x in ${IREF[$rb]}; do
    for y in ${RREF[$rb]}; do [[ $x == "$y" ]] && common=$x; done
  done
  if [[ -z $common ]]; then
    mapfile -t u < <(printf '%s\n' ${IREF[$rb]} ${RREF[$rb]} | sort -u)
    fail "install.sh and README.md point at DIFFERENT files named $rb" \
         "install.sh: $(for x in ${IREF[$rb]}; do printf '%s ' "$(rel "$x")"; done)" \
         "README.md:  $(for x in ${RREF[$rb]}; do printf '%s ' "$(rel "$x")"; done)" \
         "one of the two instructions is the stale one and the user cannot tell which"
  else
    pass "install.sh and README.md agree on $rb -> $(rel "$common")"
  fi
done < <(printf '%s\n' "${!IREF[@]}" | sort)

# ===========================================================================
section "installer assets install.sh copies verbatim"
# Payload, not code. If one is absent the installer skips a whole feature --
# illuminator permissions, the Howdy recorder -- and the user ends up with a
# camera that streams and an authentication that never works.
for want in udev/99-hm1092-ir-led.rules howdy/ir_reader.py howdy/video_capture.patch; do
  if [[ -e $ROOT/$want ]]; then
    grep -q "$(basename "$want")" "$INSTALL" \
      && pass "$want present and referenced by install.sh" \
      || warn "$want is in the package but install.sh never mentions it"
  else
    fail "$want MISSING — install.sh installs this file"
  fi
done

# the patch and the recorder are a contract: the patch imports a name that must
# exist in the recorder shipped beside it
if [[ -f $ROOT/howdy/video_capture.patch && -f $ROOT/howdy/ir_reader.py ]]; then
  while read -r sym; do
    [[ -z $sym ]] && continue
    grep -qE "^(class|def) ${sym}\b" "$ROOT/howdy/ir_reader.py" \
      && pass "video_capture.patch imports '$sym' and ir_reader.py defines it" \
      || fail "video_capture.patch imports '$sym', howdy/ir_reader.py does not define it" \
              "Howdy raises ImportError during authentication, inside a PAM stack, where nobody sees it"
  done < <(grep -oE 'from recorders\.ir_reader import [A-Za-z_][A-Za-z0-9_]*' "$ROOT/howdy/video_capture.patch" \
           | awk '{print $NF}' | sort -u)
fi

# ===========================================================================
section "scripts are runnable"
for s in "${SCRIPTS[@]}"; do
  r=$(rel "$s"); ok=1
  head -1 "$s" | grep -q '^#!' || { fail "$r: no shebang"; ok=0; }
  sh_bin=bash; head -1 "$s" | grep -qE '^#!.*/(da|a)?sh$' && sh_bin=sh
  if ! err=$("$sh_bin" -n "$s" 2>&1); then
    fail "$r: syntax error ($sh_bin -n)" "$err"; ok=0
  fi
  [[ -x $s ]] || { fail "$r: not executable" "documented as './$r' — a stranger gets 'Permission denied'"; ok=0; }
  if git -C "$ROOT" rev-parse >/dev/null 2>&1 && git -C "$ROOT" ls-files --error-unmatch "$s" >/dev/null 2>&1; then
    mode=$(git -C "$ROOT" ls-files -s -- "$s" | awk '{print $1}')
    [[ $mode == 100755 ]] || {
      fail "$r: git mode $mode, not 100755" \
           "the exec bit is local to this working tree; every clone and tarball gets a non-executable script"; ok=0; }
  fi
  [[ $ok -eq 1 ]] && pass "$r: shebang, $sh_bin -n clean, executable, mode 100755"
done

if command -v python3 >/dev/null 2>&1; then
  while read -r py; do
    if err=$(python3 -m py_compile "$py" 2>&1); then pass "$(rel "$py"): compiles"
    else fail "$(rel "$py"): python syntax error" "$err"; fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.py' -type f -print | sort)
  find "$ROOT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
else
  warn "python3 not available — skipped the syntax check of the Howdy recorder"
fi

# ===========================================================================
section "no script dies on an unset variable"
# Under `set -u` a variable that is read but never assigned aborts the script at
# that line. It presents as "the tool printed two lines and stopped", with no
# error the user can connect to a typo. tools/find-ir-node.sh did exactly this:
# an `awk -v s="$SD_ENT"` typo killed the subshell, the script fell back to a
# hardcoded CSI-2 port, and printed "(auto-detected)" next to the wrong answer.
#
# shellcheck cannot cover this: SC2154 deliberately ignores ALL-CAPS names,
# assuming they come from the environment, and these are all ALL-CAPS.
AWK_BUILTINS=' NF NR FS OFS ORS RS FILENAME FNR SUBSEP RSTART RLENGTH CONVFMT OFMT ENVIRON '
SHELL_ENV=' HOME PATH USER LOGNAME EUID UID PWD OLDPWD IFS SHELL TERM LANG LC_ALL HOSTNAME
 RANDOM SECONDS LINENO BASH BASH_SOURCE BASH_VERSION BASH_REMATCH FUNCNAME PIPESTATUS REPLY
 OPTARG OPTIND CDPATH TMPDIR SUDO_USER SUDO_UID DISPLAY XDG_RUNTIME_DIR EDITOR NO_COLOR
 KERNELRELEASE KERNEL_SRC KVER KBUILD MAKE CC LD DESTDIR
 dkms_tree kernel_source_dir PACKAGE_NAME PACKAGE_VERSION '
# A script that SOURCES another file in this package inherits its variables, so
# reading one of them is not an unset read. verify.sh and find-ir-node.sh get
# every LD_* name from tools/lib-detect.sh this way, and install.sh gets the
# HW_* names from tools/check-hardware.sh. Without this the check would demand
# that a library's callers redeclare its interface -- a false failure, which is
# how a useful check gets deleted.
sourced_files(){
  grep -oE '(^|[[:space:]])(\.|source)[[:space:]]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/[A-Za-z0-9_./-]+' "$1" \
    | sed -E 's@.*\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/@@' \
    | while read -r p; do [[ -f $ROOT/$p ]] && printf '%s\n' "$ROOT/$p"; done
}

CODE=$(mktemp); CODEA=$(mktemp); trap 'rm -f "$CODE" "$CODEA"' EXIT
for s in "${SCRIPTS[@]}"; do
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*u|set -o nounset' "$s" || continue
  # Blank out whole-line comments, keeping the line count so reported line
  # numbers still match the real file. Prose about a variable is not a use of
  # it -- and this file's own comments discuss the very typos it hunts for.
  sed 's/^[[:space:]]*#.*//' "$s" > "$CODE"
  # $CODE  = this script alone, for the USES and the line numbers.
  # $CODEA = this script plus whatever it sources, for the ASSIGNMENTS.
  cp "$CODE" "$CODEA"; inherited=""
  while read -r sf; do
    [[ -n $sf ]] || continue
    sed 's/^[[:space:]]*#.*//' "$sf" >> "$CODEA"
    inherited+=" $(rel "$sf")"
  done < <(sourced_files "$s")
  assigned=" $( {
      # NAME=, export/local/declare/readonly NAME=, NAME[key]=, NAME+=(
      grep -oE '(^|[[:space:]]|;|&|\|)(export|local|readonly|declare|typeset)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=' "$CODEA" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*(\[|\+?=)' | sed -E 's/(\[|\+?=)$//'
      # bare declarations: local a b c / declare -A x
      grep -oE '(^|[[:space:]])(local|declare|typeset|readonly)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[A-Za-z0-9_ ]+' "$CODEA" \
        | sed -E 's/.*(local|declare|typeset|readonly)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+//' | tr ' ' '\n'
      grep -oE '(^|[;&|][[:space:]]*|[[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$CODEA" | awk '{print $NF}'
      # read [-flags] a b c  -- every name, not just the first
      grep -oE '(^|[[:space:]|;])read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[A-Za-z_][A-Za-z0-9_ ]*' "$CODEA" \
        | sed -E 's/.*read[[:space:]]+//; s/(-[a-zA-Z]+[[:space:]]+)*//' | tr ' ' '\n'
      grep -oE 'mapfile[^|<]*[[:space:]][A-Za-z_][A-Za-z0-9_]*' "$CODEA" | awk '{print $NF}'
      grep -oE 'printf[[:space:]]+-v[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$CODEA" | awk '{print $NF}'
      grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?=' "$CODEA" | tr -d '${:='
      # function parameters are positional, never named
    } | sort -u | tr '\n' ' ' ) "
  bad=""; lines=""
  while read -r v; do
    [[ -z $v ]] && continue
    [[ $assigned    == *" $v "* ]] && continue
    [[ $AWK_BUILTINS == *" $v "* ]] && continue
    [[ $SHELL_ENV    == *" $v "* ]] && continue
    total=$(grep -oE "\\\$\{?$v([^A-Za-z0-9_]|$)" "$CODE" | wc -l)
    prot=$(grep -oE "\\\$\{$v:?[-+=?]" "$CODE" | wc -l)
    [[ $total -le $prot ]] && continue         # every use has a default -- safe
    bad+=" $v"
    lines+="$(grep -nE "\\\$\{?$v([^A-Za-z0-9_]|$)" "$CODE" | grep -vE "\\\$\{$v:?[-+=?]" | head -1)"$'\n'
  done < <(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' "$CODE" | tr -d '${' | sort -u)
  if [[ -n $bad ]]; then
    fail "$(rel "$s"): reads unset variable(s):$bad — under 'set -u' the script aborts there" "${lines%$'\n'}"
  else
    pass "$(rel "$s"): no unset-variable exit${inherited:+ (inherits:$inherited)}"
  fi
done

# ===========================================================================
section "README and install.sh agree"
kern_ranges(){ grep -ohE '[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?[[:space:]]+(through|to)[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?' "$1" \
               | sed -E 's/[[:space:]]+(through|to)[[:space:]]+/../' | sort -u; }
i_range=$(kern_ranges "$INSTALL"); r_range=$(kern_ranges "$README")
if [[ -z $i_range && -z $r_range ]]; then
  warn "neither README nor install.sh states a supported kernel range" \
       "a stranger cannot tell whether their kernel is in scope"
elif [[ -z $i_range ]]; then
  warn "README claims kernels $(tr '\n' ' ' <<<"$r_range")but install.sh's header states no range"
elif [[ -z $r_range ]]; then
  fail "install.sh claims kernels $i_range but the README states no range"
elif grep -qxF "$i_range" <<<"$r_range"; then
  pass "supported kernels agree: $i_range"
else
  fail "README and install.sh disagree about supported kernels" \
       "install.sh: $(tr '\n' ' ' <<<"$i_range")" \
       "README:     $(tr '\n' ' ' <<<"$r_range")"
fi

# The README's recovery block must name the modules and versions the installer
# actually creates. A `dkms remove` for a version that is not the shipped one
# prints nothing and removes nothing -- a user backing out a broken install is
# told it worked while every module stays exactly where it was.
if grep -q 'dkms remove' "$README"; then
  # names: literal `-m NAME`, plus a `for m in a b c` loop feeding `-m $m`
  covered=" $( { grep -oE 'dkms remove -m [A-Za-z0-9_-]+' "$README" | awk '{print $NF}'
                 grep -q 'dkms remove -m \$m' "$README" && \
                   sed -n 's/^[[:space:]]*for m in \([^;]*\);[[:space:]]*do.*/\1/p' "$README" | tr ' ' '\n'
               } | grep -v '^\$' | sort -u | tr '\n' ' ') "
  for m in "${ALL_M[@]:-}"; do
    [[ -z $m ]] && continue
    if [[ $covered != *" $m "* ]]; then
      warn "install.sh installs '$m' but the README recovery block never removes it" \
           "a user backing the pack out is left with $m still installed"
      continue
    fi
    conf=$(ls -d "$ROOT"/dkms/"$m"-*/dkms.conf "$ROOT"/dkms/"$m"/dkms.conf 2>/dev/null | head -1)
    [[ -n $conf ]] || continue
    real=$(sed -n 's/^PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
    docver=$(grep -oE "dkms remove -m (\\\$m|$m) -v [0-9][^ ]*" "$README" | awk '{print $NF}' | sort -u | head -1)
    srcver=$(grep -oE "/usr/src/$m-[0-9][A-Za-z0-9._-]*" "$README" | sed "s|.*/$m-||" | sort -u | head -1)
    okver=1
    for dv in $docver $srcver; do
      [[ $dv == "$real" ]] || { fail "README recovery uses $m version '$dv' but the package ships $m/$real" \
                                     "that dkms remove / rm -rf matches nothing and reports nothing"; okver=0; }
    done
    [[ $okver -eq 1 ]] && pass "README recovery covers $m at the shipped version ($real)"
  done
else
  warn "README has no 'dkms remove' recovery block" \
       "a stranger who breaks their camera has no documented way back"
fi

# ===========================================================================
section "the README quotes the installer's REAL output"
# The README's "what to expect" table is the only key a user has for telling a
# real install from a no-op, and it used to quote three lines install.sh never
# prints -- e.g. "! <module> not found in package (looked in dkms/ and kernel/)"
# against an installer that actually says "package is missing module 'hm1092'
# ... this clone/tarball is incomplete, re-download it". Ctrl-F finds nothing
# and the reader cannot tell which row of the table they are in.
#
# Every README string that starts with one of the installer's own glyphs is
# checked here. <placeholders> are cut out, and each remaining literal run has
# to appear verbatim in install.sh. Reword a message and this fails on the next
# push, which is the only thing that keeps a decode table honest.
#
# Two kinds of quotation, held to two standards:
#   TPL    — a backtick-quoted message TEMPLATE, i.e. a row of the decode table.
#            Every literal run between <placeholders> must be in install.sh.
#            This is the one that shipped wrong, so a mismatch is a FAIL.
#   SAMPLE — a line inside a fenced transcript. It carries one machine's real
#            kernel and module names, so it cannot match verbatim; it only has
#            to share SOME run of words with install.sh, or it is a transcript
#            of a program this package does not contain.
sq(){ tr -s ' \t' ' ' ; }                       # whitespace-insensitive compare
INSTALL_SQ=$(mktemp); sq < "$INSTALL" > "$INSTALL_SQ"
n_quoted=0
while IFS='|' read -r kind q; do
  [[ -z ${q:-} ]] && continue
  n_quoted=$((n_quoted+1))
  bare=$(printf '%s' "$q" | sed -E 's/^[[:space:]]*(✓|✗|!|·)[[:space:]]+//')
  short=$(printf '%s' "$q" | cut -c1-58)
  if [[ $kind == TPL ]]; then
    missing=(); checked=0
    while IFS= read -r seg; do
      seg=$(printf '%s' "$seg" | sq); seg=${seg#" "}; seg=${seg%" "}
      [[ ${#seg} -ge 8 ]] || continue
      checked=$((checked+1))
      grep -qF -- "$seg" "$INSTALL_SQ" || missing+=("$seg")
      # printf '%s\n', not '%s': without the trailing newline `read` returns
      # non-zero on the final segment and the loop body never runs for it. Every
      # quote made of ONE literal run -- which is every exact message in the
      # table -- then scored checked=0 and was reported as "all placeholders,
      # nothing to check". The drift check that exists to keep the README honest
      # was checking nothing, and saying so as a warning.
    done < <(printf '%s\n' "$bare" | sed -E 's/<[^>]*>/\n/g')
    if [[ $checked -eq 0 ]]; then
      warn "README quotes '$short' but every part of it is a <placeholder>" \
           "nothing in that row can be checked against install.sh, so it can drift freely"
    elif [[ ${#missing[@]} -gt 0 ]]; then
      fail "README quotes installer output that install.sh never prints: '$q'" \
           "not found in install.sh: $(printf "'%s' " "${missing[@]}")" \
           "a reader who Ctrl-Fs the README's wording finds nothing and cannot tell which case they are in"
    else
      pass "README's '$short' matches install.sh"
    fi
  else
    # the longest run of consecutive words that install.sh also contains
    read -ra W <<<"$bare"
    hit=""; len=${#W[@]}
    while [[ $len -gt 0 && -z $hit ]]; do
      i=0
      while [[ $((i + len)) -le ${#W[@]} ]]; do
        cand="${W[*]:i:len}"
        if [[ ${#cand} -ge 10 ]] && grep -qF -- "$cand" "$INSTALL_SQ"; then hit=$cand; break; fi
        i=$((i+1))
      done
      len=$((len-1))
    done
    if [[ -n $hit ]]; then
      pass "README sample '$short' shares wording with install.sh"
    else
      warn "README shows a sample line install.sh has nothing in common with: '$q'" \
           "either the installer was reworded or this transcript came from another program"
    fi
  fi
done < <( {
    # backtick-quoted spans starting with an installer glyph = TEMPLATES
    grep -oE '`[[:space:]]*(✓|✗|!|·) [^`]*`' "$README" | sed -E 's/^`//; s/`$//; s/^/TPL|/'
    # the same lines inside a fenced code block = one machine's TRANSCRIPT
    awk '/^```/{f=!f; next} f && /^[[:space:]]*(✓|✗|!|·) /{print "SAMPLE|" $0}' "$README"
  } | sort -u )
rm -f "$INSTALL_SQ"
if [[ $n_quoted -eq 0 ]]; then
  warn "the README quotes no installer output at all" \
       "a user has nothing to compare their run against, which is how a no-op passed for a success"
else
  info "$n_quoted quoted installer line(s) checked against install.sh"
fi

# ===========================================================================
section "one canonical copy of every script"
# Two files with the same name and different contents is how a user ends up
# running the older one. verify.sh drifted exactly this way: install.sh's last
# screen said `sudo $HERE/verify.sh` (the root copy) while the README said
# `sudo ./tools/verify.sh`, and the root copy was 37 lines behind -- missing the
# stale-module and psys-reason diagnostics, i.e. unable to detect the failure
# install.sh had warned about eight lines earlier. That shipped because this
# check was a WARN and CI stayed green. It is a FAIL now.
#
# Symlinks are scanned too: one file under two names is the fix, and it only
# works if the link resolves inside the package.
mapfile -t NODES < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.sh' \( -type f -o -type l \) -print | sort)
declare -A SEEN=()
for f in "${NODES[@]}"; do
  b=$(basename "$f"); rf=$(rel "$f")
  if [[ -L $f ]]; then
    tgt=$(readlink -f "$f")
    if [[ -z $tgt || ! -e $tgt ]]; then
      fail "$rf is a DANGLING symlink -> $(readlink "$f")" \
           "anyone following an instruction that names it gets 'No such file or directory'"
      continue
    fi
    case $tgt in
      "$ROOT"/*) ;;
      *) fail "$rf points OUTSIDE the package -> $tgt" \
              "it resolves on the author's machine and nowhere else"; continue ;;
    esac
  fi
  if [[ -n ${SEEN[$b]:-} ]]; then
    o=${SEEN[$b]}
    if [[ $(readlink -f "$f") == "$(readlink -f "$o")" ]]; then
      pass "$b: $(rel "$o") and $rf are the same file — they cannot drift"
    elif cmp -s "$f" "$o"; then
      warn "$b is shipped twice as two separate files: $(rel "$o") and $rf" \
           "byte-identical today, and nothing keeps them that way — make one a symlink to the other"
    else
      fail "$b exists twice with DIFFERENT contents: $(rel "$o") vs $rf" \
           "$(diff "$o" "$f" | grep -c '^[<>]') differing lines — whichever the user was told to run, the other is stale" \
           "keep one file and point every reference at it (a symlink counts)"
    fi
  else
    SEEN[$b]=$f
  fi
done

# ===========================================================================
printf '\n%s──────── selftest summary ────────%s\n' "$C_B" "$C_0"
printf '  %spassed %d%s   %swarnings %d%s   %sfailed %d%s\n' \
  "$C_G" "$n_pass" "$C_0" "$C_Y" "$n_warn" "$C_0" "$C_R" "$n_fail" "$C_0"
if [[ $n_warn -gt 0 ]]; then
  printf '\n  %swarnings%s (not fatal, but a stranger will hit them):\n' "$C_Y" "$C_0"
  for w in "${WARNS[@]}"; do printf '    - %s\n' "$w"; done
fi
if [[ $n_fail -gt 0 ]]; then
  printf '\n  %sfailures%s:\n' "$C_R" "$C_0"
  for f in "${FAILS[@]}"; do printf '    - %s\n' "$f"; done
  printf '\n  %sFAIL%s — as shipped, this package would not install what it claims to.\n' "$C_R" "$C_0"
  exit 1
fi
printf '\n  %sPASS%s — the package is internally consistent.\n' "$C_G" "$C_0"
printf '  This says nothing about whether any camera works: no hardware was\n'
printf '  touched and none can be. It says the installer will find everything\n'
printf '  it is about to install.\n'
exit 0
