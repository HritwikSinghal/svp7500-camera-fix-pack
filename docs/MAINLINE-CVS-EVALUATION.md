# Can mainline `drivers/media/i2c/cvs` replace our out-of-tree `intel_cvs`?

**No — not as either driver stands today.** Tested 2026-07-26 on a Dell XPS 16
(DA16260, Panther Lake, Synaptics SVP7500, kernel 7.2.0-rc4).

The blocker is a **topology disagreement**, not a defect in either driver.

---

## Result

Mainline `cvs` loads, recognises the hardware, and then defers forever:

```
intel_cvs i2c-INTC10E1:00: Quirks: 0x7a (VID:0x06cb PID:0x0701)     x13 retries
i2c i2c-INTC10E1:00: deferred probe pending: intel_cvs: CSI init failed
```

The bridge is left **unbound**, and the RGB camera disappears entirely —
`cam -l` lists only `hm1092`. The IR sensor still probes, because `hm1092`
guards its bridge call behind a weak symbol:

```
hm1092 i2c-HIMX1092:00: intel_cvs symbol unavailable; port-2 forwarding NOT configured
```

## Why

Mainline `cvs` places itself **inside the media graph**. `cvs_csi_init()`
registers a `MEDIA_ENT_F_VID_IF_BRIDGE` subdev with a sink pad and a source pad,
and `cvs_csi_parse_firmware()` then requires two fwnode graph endpoints *on the
bridge device itself*:

```c
sink_ep   = fwnode_graph_get_endpoint_by_id(dev_fwnode(dev), 0, 0, 0);  /* from sensor */
source_ep = fwnode_graph_get_endpoint_by_id(dev_fwnode(dev), 1, 0, 0);  /* to IPU     */
...
v4l2_async_nf_add_fwnode_remote(&ctx->notifier, sink_ep, ...);
v4l2_async_nf_register(&ctx->notifier);
```

On this platform the bridge's ACPI device carries no graph ports at all:

```
$ ls /sys/bus/i2c/devices/i2c-INTC10E1:00/
firmware_node  modalias  name  power  subsystem  uevent  waiting_for_supplier
```

so the async notifier never completes and probe returns `-EPROBE_DEFER`
indefinitely.

### The two models

```
mainline cvs    sensor --> [ CVS subdev ] --> IPU7        bridge is IN the data graph
ours            sensor ------------------> IPU7           bridge is control-plane only
                          [ intel_cvs ]  <-- I2C ownership + MIPI config, out of graph
```

`ipu-bridge` is what builds the swnode graph, and it wires sensors **directly**
to the IPU. For mainline `cvs` to bind, `ipu_bridge` would have to construct a
three-node graph that interposes the CVS bridge — which it does not do for any
platform today.

## What this implies for upstreaming

1. **Our `ipu-bridge` HIMX1092 patch is necessary either way.** A stock kernel
   cannot build a graph for this sensor at all. (Sent to linux-media.)

2. **One of two things has to give**, and this is a maintainer's call, not ours:
   - `ipu_bridge` grows the ability to interpose an in-graph vision bridge for
     SVP7500-class platforms, so mainline `cvs` can bind as designed; **or**
   - mainline `cvs` grows a control-plane-only mode for platforms whose firmware
     exposes no graph ports on the bridge.

3. **`intel_cvs` cannot simply be dropped** in favour of the in-tree driver.
   Anyone assuming 7.2-rc1's `cvs` supersedes it will lose the RGB camera.

## Reproducing

```bash
tools/try-mainline-cvs.sh            # arm  (needs BUILD=<dir with cvs.ko>)
tools/try-mainline-cvs.sh --status
tools/try-mainline-cvs.sh --revert
```

### Testing note that cost four reboots

`modprobe.d` alone **cannot** keep `intel_cvs` out of the way on this machine:

| attempt | method | outcome |
|---|---|---|
| 1 | `blacklist intel_cvs` | loaded anyway — as a dependency of `hm1092` |
| 2 | `install intel_cvs /bin/false` | would abort loading `hm1092` too (`modules.dep`) |
| 3 | `install intel_cvs /bin/true` | still loaded, via `softdep intel_ipu7 pre: ... intel_cvs` and `alias symbol:cvs_send_mipi_ir_config intel_cvs` |
| 4 | **move `intel_cvs.ko` out of the module search path** | works |

Every one of the first three presented as *"mainline cvs does not work"* — the
camera kept working and face unlock kept succeeding, because **our** driver had
quietly won the race. That is a uniquely convincing false negative: the test
appears to fail in exactly the way a real failure would look. Always confirm
`intel_cvs` is absent from `lsmod` before believing any result, and read the
driver name in the log prefix (`Intel CVS driver` = ours, `intel_cvs` = mainline).
