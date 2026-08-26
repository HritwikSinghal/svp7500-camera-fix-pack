# Howdy integration

The HM1092 is a **monochrome** sensor that the driver tags `SGRBG10` (Bayer
GRBG), because that is what the Windows driver and the IPU graph settings
declare. Anything that honours the tag -- OpenCV, libcamera's SoftwareIsp, and
therefore PipeWire -- debayers mono data and produces mush. The Intel IPU7 ISYS
capture node offers no monochrome pixel format at all (only Bayer, YUV and RGB),
so there is no way to fix this by selecting a different format: the consumer has
to know that the payload is really 10-bit greyscale.

`ir_reader.py` is that consumer. It reads the V4L2 node directly, shifts the
10-bit values down to 8-bit grey, and keeps the sensor's native 648x368.

## Which patch to use

| File | Applies to | Use it |
|---|---|---|
| `ir-recorder-video_capture.patch` | stock upstream Howdy | **yes** |
| `ir-recorder-meson.patch` | stock upstream Howdy | when building from source |
| `video_capture.patch` | a locally modified Howdy | no -- see below |

`video_capture.patch` is inherited from upstream and does **not** apply to stock
Howdy: alongside the `ir` branch it rewrites a `pipewire` recording plugin that
upstream Howdy has never had, so the context never matches. It is kept for
reference only.

The two `ir-recorder-*` patches are minimal and verified to apply, with `-p1`
from the Howdy source root, to both:

- `howdy-git` 2.6.1.r273 (what Arch installs), and
- Howdy 3.0.0 / `d3ab993` (what nixpkgs packages).

Their `_create_reader` bodies are byte-identical, which is why one patch covers
both.

`ir-recorder-meson.patch` is only needed when Howdy is built from source, which
is the case on NixOS. Howdy's `meson.build` lists installed Python files
explicitly, so a recorder that is merely copied into the source tree never
reaches the install prefix. Distributions that drop the file straight into an
already-installed tree (as the Arch role does) do not need it.

## Installing

Source build (NixOS and similar):

1. apply both `ir-recorder-*` patches
2. copy `ir_reader.py` to `howdy/src/recorders/`
3. point `media-ctl` at an absolute path -- the reader shells out to it to
   enable the CSI-2 link, and PAM runs Howdy with a minimal environment

Then set `recording_plugin = ir` in `config.ini`, along with
`dark_threshold = 90` and `timeout = 6`.

## Note on the illuminator

Since the `devm_led_get` change to `hm1092` (tag `nixos-pin-2026-08-27`), the
sensor driver drives the IR flood illuminator itself around streaming. The
reader still sets it, which is now a harmless double-write, and it remains
necessary on any kernel without that change.
