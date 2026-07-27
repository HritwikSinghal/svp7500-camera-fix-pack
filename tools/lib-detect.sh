#!/bin/bash
# ===========================================================================
# lib-detect.sh — where the camera actually IS on this machine.
#
# Sourced by tools/verify.sh and tools/find-ir-node.sh so there is exactly ONE
# implementation of "which media device, which sensor, which CSI-2 port".
#
# It exists because there were two. find-ir-node.sh followed the sensor's own
# link in the media graph; verify.sh carried a copy with the port hardcoded to
# `Intel IPU7 CSI2 2` in five places. On @acmodeu's Dell Pro 14 the sensor is on
# port 1, so verify.sh configured the wrong entity, streamed nothing, and
# printed `SOF on csi2-2  0 <-- NO FRAMES`: a hard BROKEN verdict manufactured
# entirely by the tool's own wrong assumption, on a machine that was fine.
#
# Nothing in here changes anything. Every function reads the media graph and
# prints what it found, or prints nothing when it could not tell -- which is the
# other half of the contract: a check that did not happen must not report a
# result, in either direction.
#
# Run it directly for a summary of what it detects.
# ===========================================================================

# Everything this library sets. Declared up front so a caller running under
# `set -u` can read any of them before ld_detect() has been called.
LD_MEDIA=""        # /dev/mediaN carrying the camera graph
LD_GRAPH=""        # that device's `media-ctl -p` output
LD_IR_SENS=""      # IR sensor ENTITY name, e.g. "hm1092 12-0024"
LD_IR_SD=""        # its /dev/v4l-subdevN
LD_CSI=""          # CSI-2 receiver entity the IR sensor links to
LD_CSI_PORT=""     # just the port number from that name (1, 2, ...)
LD_CAP=""          # ISYS capture entity fed by that CSI-2 receiver
LD_NODE=""         # /dev/videoN of that capture entity
LD_RGB_SENS=""     # RGB sensor entity name, if the graph has one
LD_RGB_DRV=""      # module name implied by that entity (ov05c10 / ov08x40)
LD_WHY=""          # why detection came up empty, in a sentence

ld_have(){ command -v "$1" >/dev/null 2>&1; }

# Every /dev/media* on the machine. There is no guarantee the camera is media0:
# hardcoding it is the same class of mistake as hardcoding the CSI-2 port.
ld_media_devices(){
  local d
  for d in /dev/media*; do [ -e "$d" ] && printf '%s\n' "$d"; done
}

# First entity in $LD_GRAPH whose name matches (case-insensitive) the regex.
# media-ctl prints `- entity 12: hm1092 12-0024 (1 pad, 1 link)`; the trailing
# "(N pads...)" is not part of the name and the i2c bus number in the middle
# varies per machine, which is why nothing may ever match on a literal.
ld_entity(){
  printf '%s\n' "$LD_GRAPH" | awk -v re="$1" '
    /^- entity [0-9]+: / {
      n=$0
      sub(/^- entity [0-9]+: /,"",n)
      sub(/[[:space:]]*\(.*$/,"",n)
      if (tolower(n) ~ re) { print n; exit }
    }'
}

# Follow one entity's outgoing links and print the first target matching the
# regex. This is the step that replaces guessing the CSI-2 port.
ld_link_to(){
  printf '%s\n' "$LD_GRAPH" | awk -v s="$1" -v re="$2" '
    index($0, ": " s " ") && /^- entity [0-9]+: / { f=1; next }
    f && /^- entity [0-9]+: / { f=0 }
    f && /-> "/ {
      t=$0; sub(/.*-> "/,"",t); sub(/":.*/,"",t)
      if (tolower(t) ~ re) { print t; exit }
    }'
}

# The /dev node an entity owns, if it has one.
ld_node_of(){
  printf '%s\n' "$LD_GRAPH" | awk -v s="$1" '
    index($0, ": " s " ") && /^- entity [0-9]+: / { f=1 }
    f && /device node name/ { print $NF; exit }'
}

# Populate everything above. Returns 0 if a camera graph was found at all,
# 1 if there is nothing to look at -- and sets LD_WHY either way, so a caller
# can say what was missing instead of reporting a failure it never tested for.
ld_detect(){
  local d g best="" bestg="" any="" anyg=""
  LD_MEDIA=""; LD_GRAPH=""; LD_IR_SENS=""; LD_IR_SD=""; LD_CSI=""
  LD_CSI_PORT=""; LD_CAP=""; LD_NODE=""; LD_RGB_SENS=""; LD_RGB_DRV=""; LD_WHY=""

  if ! ld_have media-ctl; then
    LD_WHY="media-ctl is not installed (package: v4l-utils) — nothing can be resolved from the media graph"
    return 1
  fi
  if [ -z "$(ld_media_devices)" ]; then
    LD_WHY="no /dev/media* device exists — the IPU never registered a media controller"
    return 1
  fi

  for d in $(ld_media_devices); do
    g=$(media-ctl -d "$d" -p 2>/dev/null || true)
    [ -n "$g" ] || continue
    [ -n "$any" ] || { any=$d; anyg=$g; }
    LD_GRAPH=$g
    if [ -n "$(ld_entity 'hm1092')" ]; then best=$d; bestg=$g; break; fi
    if [ -z "$best" ] && [ -n "$(ld_entity 'ov05c10|ov08x40|ov08f4')" ]; then best=$d; bestg=$g; fi
  done

  if [ -n "$best" ]; then LD_MEDIA=$best; LD_GRAPH=$bestg
  elif [ -n "$any" ]; then LD_MEDIA=$any; LD_GRAPH=$anyg
  else
    LD_GRAPH=""
    LD_WHY="every /dev/media* refused 'media-ctl -p' (run as root?)"
    return 1
  fi

  LD_RGB_SENS=$(ld_entity 'ov05c10|ov08x40|ov08f4')
  case $LD_RGB_SENS in
    ov05c10*) LD_RGB_DRV=ov05c10 ;;
    ov08*)    LD_RGB_DRV=ov08x40 ;;
  esac

  LD_IR_SENS=$(ld_entity 'hm1092')
  if [ -z "$LD_IR_SENS" ]; then
    LD_WHY="no hm1092 entity in ${LD_MEDIA}'s media graph — this board has no IR sensor, or its driver did not bind"
    return 0
  fi
  LD_IR_SD=$(ld_node_of "$LD_IR_SENS")
  LD_CSI=$(ld_link_to "$LD_IR_SENS" 'csi2')
  if [ -z "$LD_CSI" ]; then
    LD_WHY="the hm1092 entity has no link to a CSI-2 receiver in ${LD_MEDIA}'s graph — the port cannot be determined, and guessing one is how a working camera gets reported as broken"
    return 0
  fi
  LD_CSI_PORT=$(printf '%s' "$LD_CSI" | grep -oE '[0-9]+$' || true)
  LD_CAP=$(ld_link_to "$LD_CSI" 'capture')
  [ -n "$LD_CAP" ] && LD_NODE=$(ld_node_of "$LD_CAP")
  [ -n "$LD_NODE" ] || LD_WHY="followed the sensor to $LD_CSI but found no ISYS capture node behind it"
  return 0
}

# Run directly: print what it detects and nothing else.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  ld_detect || true
  printf 'media device   : %s\n' "${LD_MEDIA:-NOT FOUND}"
  printf 'RGB sensor     : %s\n' "${LD_RGB_SENS:-none in the graph}"
  printf 'IR sensor      : %s\n' "${LD_IR_SENS:-none in the graph}"
  printf 'IR subdev      : %s\n' "${LD_IR_SD:-?}"
  printf 'CSI-2 receiver : %s\n' "${LD_CSI:-UNDETECTED}"
  printf 'CSI-2 port     : %s\n' "${LD_CSI_PORT:-UNDETECTED}"
  printf 'capture entity : %s\n' "${LD_CAP:-?}"
  printf 'IR video node  : %s\n' "${LD_NODE:-UNDETECTED}"
  [ -n "$LD_WHY" ] && printf 'note           : %s\n' "$LD_WHY"
  exit 0
fi
