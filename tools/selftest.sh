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
#   ./tools/selftest.sh --prove  test the test: build a package with the exact
#                                layout mismatch that shipped, and assert this
#                                script rejects it. A check nobody has ever
#                                seen fail is not yet a check.
#
# Exit status: 0 = every check passed, 1 = at least one FAIL.
# WARN never changes the exit status: it marks things a stranger will trip
# over that do not stop the install.
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
# --prove: does the headline check actually fire?
# Builds two throwaway packages -- one laid out the way the broken installer
# assumed, one laid out correctly -- and asserts this script rejects the first
# and accepts the second. Nothing outside the temp directory is touched.
if [[ ${1:-} == --prove ]]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mk_pkg(){ # $1 dir, $2 = search path expression install.sh will use
    mkdir -p "$1/tools" "$1/dkms/demo-1.0"
    cat > "$1/install.sh" <<EOF
#!/usr/bin/env bash
# Tested on: kernels 1.0 through 2.0
set -euo pipefail
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
REQUIRED_MODULES=(demo)
find_src(){ local m=\$1 d; for d in $2; do [[ -d \$d && -f \$d/dkms.conf ]] && { echo "\${d%/}"; return 0; }; done; return 1; }
for m in "\${REQUIRED_MODULES[@]}"; do find_src "\$m" || echo "! \$m not in package, skipping"; done
echo "==> Done"
EOF
    printf 'PACKAGE_NAME="demo"\nPACKAGE_VERSION="1.0"\nBUILT_MODULE_NAME[0]="demo"\n' > "$1/dkms/demo-1.0/dkms.conf"
    printf 'obj-m += demo.o\n' > "$1/dkms/demo-1.0/Makefile"
    : > "$1/dkms/demo-1.0/demo.c"
    printf '# demo\nkernels 1.0 through 2.0\n' > "$1/README.md"
    chmod +x "$1/install.sh"
    cp "${BASH_SOURCE[0]}" "$1/tools/selftest.sh"; chmod +x "$1/tools/selftest.sh"
  }
  rc=0
  mk_pkg "$t/broken" '"$HERE/kernel/$m"'                                  # what shipped
  mk_pkg "$t/good"   '"$HERE"/dkms/"$m"-*/ "$HERE/dkms/$m" "$HERE/kernel/$m"'
  out_b=$(NO_COLOR=1 "$t/broken/tools/selftest.sh" 2>&1); eb=$?
  out_g=$(NO_COLOR=1 "$t/good/tools/selftest.sh"   2>&1)
  if grep -q "CANNOT FIND module 'demo'" <<<"$out_b" && [[ $eb -ne 0 ]]; then
    printf '  PASS  rejects the shipped layout mismatch (installer looks in kernel/, package ships dkms/)\n'
  else
    printf '  FAIL  did NOT reject the layout mismatch — the headline check is asleep\n'; rc=1
  fi
  if grep -q "CANNOT FIND" <<<"$out_g"; then
    printf '  FAIL  rejects a CORRECT package — false positive\n'; rc=1
  else
    printf '  PASS  accepts a correctly laid out package\n'
  fi
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
mapfile -t MOD_PATTERNS < <(grep -oE '"?\$HERE"?/[^ ;)]*\$\{?m\}?[^ ;)]*' "$INSTALL" | tr -d '"' | sort -u)

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
      e=${pat//\$HERE/$ROOT}; e=${e//\$\{m\}/$m}; e=${e//\$m/$m}
      tried+=("$(rel "$e")")
      for d in $e; do
        d=${d%/}
        [[ -d $d && -f $d/dkms.conf ]] && { found=$d; break 2; }
      done
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
fi

# the reverse: a module in the package that the installer never names is a
# module nobody receives -- the same silent no-op, one level up
for conf in "$ROOT"/dkms/*/dkms.conf; do
  [[ -f $conf ]] || continue
  nm=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
  known=0
  for m in "${ALL_M[@]:-}"; do [[ $m == "$nm" ]] && known=1; done
  [[ $known -eq 1 ]] || warn "dkms/$nm is shipped but install.sh never installs it" \
                             "installer knows: ${ALL_M[*]:-(none)}"
done

# ===========================================================================
section "dkms.conf is valid and matches the Makefile"
# A dkms.conf that lies about PACKAGE_NAME, or names a module the Makefile does
# not build, fails inside `dkms install` -- whose output install.sh sends to a
# log, so it surfaces as one terse per-kernel warning that reads like a build
# quirk rather than a packaging error.

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

  mk="$d/Makefile"
  if [[ ! -f $mk ]]; then
    fail "$(rel "$d"): no Makefile — dkms has nothing to run"
  else
    for bm in "${built[@]}"; do
      grep -qE "(^|[[:space:]])${bm//./\\.}\.o([[:space:]]|$)" "$mk" \
        || fail "$(rel "$mk") does not build $bm.o, but dkms.conf expects $bm.ko" \
                "dkms fails at its copy step; the user sees one line about one kernel"
      objs=$(sed -n "s/^${bm//./\\.}-y[[:space:]]*:=[[:space:]]*//p" "$mk")
      [[ -z $objs ]] && objs="$bm.o"
      for o in $objs; do
        [[ -f "$d/${o%.o}.c" ]] || fail "$(rel "$d"): missing source ${o%.o}.c (needed for $bm)" \
                                        "the module is listed but its code is not in the package"
      done
    done
  fi
done

# ===========================================================================
section "every path the scripts reference exists in the package"
# References are gathered from the scripts themselves: a script that resolves
# its own directory ($HERE=$(cd "$(dirname "$0")" ...)) has that variable name
# discovered, so new scripts are covered without editing anything here.
#
# Candidate lists are handled the way install.sh uses them -- `for c in A B` only
# needs one of A or B to exist -- so references are grouped by basename and a
# group passes when any member is present. The group's members are printed, so
# "1 of 3 present" is visible rather than assumed.

declare -A REFS=()
# add_ref <path> <strict>
#   strict=1  a real code path ($HERE/...): the file must be there, full stop.
#   strict=0  a path named in prose or a comment: required only when its parent
#             directory exists here, so documentation that quotes a path in some
#             OTHER tree (kernel/drivers/staging/..., /usr/lib/howdy/...) does
#             not masquerade as a missing package file.
add_ref(){
  local p=${1#/} strict=$2 b hit=0 req
  [[ -z $p || $p == . || $p == .. ]] && return 0
  [[ $p == .git* || $p == */.git* ]] && return 0
  b=$(basename "$p")
  case " ${REFS[$b]:-} " in *" $p|"*) return 0;; esac      # same path, said twice
  [[ -e $ROOT/$p ]] && hit=1
  req=$strict
  [[ $strict -eq 0 && -d $ROOT/$(dirname "$p") ]] && req=1
  REFS[$b]="${REFS[$b]:-} $p|$hit|$req"
}
sane_token(){ [[ -n $1 && $1 != *'$'* && $1 != *'*'* && $1 != *'{'* && $1 != *'}'* && $1 != *'<'* && $1 != *'('* ]]; }

KNOWN_TOP='tools|udev|howdy|dkms|kernel|scripts|docs|ipu7poke|usbio-patch'

for s in "${SCRIPTS[@]}"; do
  # a variable is this script's own root only if it is assigned from $0 / BASH_SOURCE
  mapfile -t rootvars < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*dirname.*(\$0|BASH_SOURCE)' "$s" \
                          | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | sort -u)
  rootvars+=(HERE)
  code=$(grep -vE '^[[:space:]]*#' "$s")
  for v in "${rootvars[@]}"; do
    while read -r tok; do
      tok=$(printf '%s' "$tok" | tr -d '"'"'")
      tok=${tok#\$\{$v\}/}; tok=${tok#\$$v/}
      tok=${tok%%[),\`]*}
      sane_token "$tok" && add_ref "$tok" 1
    done < <(grep -oE "\"?\\\$\{?$v\}?\"?/[^ ;)\`]*" <<<"$code")
  done
  while read -r tok; do
    tok=${tok#*)/}; tok=$(printf '%s' "$tok" | tr -d '"'"'")
    sane_token "$tok" && add_ref "$tok" 1
  done < <(grep -oE '\$\(dirname[^)]*\)/[A-Za-z0-9_./-]+' <<<"$code")
done

# repo-relative paths named in scripts, comments and docs ("run tools/verify.sh")
for f in "${SCRIPTS[@]}" "${DOCS[@]}"; do
  while read -r tok; do
    tok=${tok%%[\`,\"\']*}; tok=${tok%.}; tok=${tok%:}
    sane_token "$tok" || continue
    [[ $tok == */ && -d $ROOT/${tok%/} ]] && continue    # bare directory in prose
    add_ref "$tok" 0
  done < <(grep -hoE "(^|[^A-Za-z0-9_/.\$-])($KNOWN_TOP)/[A-Za-z0-9_./-]+" "$f" | sed -E 's@^[^A-Za-z]*@@')
done

for b in "${!REFS[@]}"; do
  present=0; total=0; required=0; detail=""; miss=""
  for e in ${REFS[$b]}; do
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
done

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
 KERNELRELEASE KERNEL_SRC KVER KBUILD MAKE CC LD DESTDIR '
CODE=$(mktemp); trap 'rm -f "$CODE"' EXIT
for s in "${SCRIPTS[@]}"; do
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*u|set -o nounset' "$s" || continue
  # Blank out whole-line comments, keeping the line count so reported line
  # numbers still match the real file. Prose about a variable is not a use of
  # it -- and this file's own comments discuss the very typos it hunts for.
  sed 's/^[[:space:]]*#.*//' "$s" > "$CODE"
  assigned=" $( {
      # NAME=, export/local/declare/readonly NAME=, NAME[key]=, NAME+=(
      grep -oE '(^|[[:space:]]|;|&|\|)(export|local|readonly|declare|typeset)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=' "$CODE" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*(\[|\+?=)' | sed -E 's/(\[|\+?=)$//'
      # bare declarations: local a b c / declare -A x
      grep -oE '(^|[[:space:]])(local|declare|typeset|readonly)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[A-Za-z0-9_ ]+' "$CODE" \
        | sed -E 's/.*(local|declare|typeset|readonly)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+//' | tr ' ' '\n'
      grep -oE '(^|[;&|][[:space:]]*|[[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$CODE" | awk '{print $NF}'
      # read [-flags] a b c  -- every name, not just the first
      grep -oE '(^|[[:space:]|;])read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[A-Za-z_][A-Za-z0-9_ ]*' "$CODE" \
        | sed -E 's/.*read[[:space:]]+//; s/(-[a-zA-Z]+[[:space:]]+)*//' | tr ' ' '\n'
      grep -oE 'mapfile[^|<]*[[:space:]][A-Za-z_][A-Za-z0-9_]*' "$CODE" | awk '{print $NF}'
      grep -oE 'printf[[:space:]]+-v[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$CODE" | awk '{print $NF}'
      grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?=' "$CODE" | tr -d '${:='
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
    pass "$(rel "$s"): no unset-variable exit"
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
section "no divergent duplicate copies"
# Two files with the same name and different contents is how a user ends up
# running the older one. The root verify.sh and tools/verify.sh drifted exactly
# this way: the copy at the root -- the one people reach for -- was the one
# missing the stale-module and psys-reason diagnostics.
declare -A SEEN=()
while read -r f; do
  b=$(basename "$f")
  if [[ -n ${SEEN[$b]:-} ]]; then
    if cmp -s "$f" "${SEEN[$b]}"; then
      pass "$b: $(rel "${SEEN[$b]}") and $(rel "$f") are identical copies"
    else
      warn "$b exists twice with DIFFERENT contents: $(rel "${SEEN[$b]}") vs $(rel "$f")" \
           "$(diff "${SEEN[$b]}" "$f" | grep -c '^[<>]') differing lines — which one the user runs is a coin flip"
    fi
  else
    SEEN[$b]=$f
  fi
done < <(printf '%s\n' "${SCRIPTS[@]}")

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
