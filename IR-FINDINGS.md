# HM1092 / SVP7500 on Intel IPU7 — reverse-engineering findings

## 1. Root cause: LINK_FREQ unit mismatch

`hm1092.sys` (Windows) carries a per-mode descriptor array. For 648x368@30:

| field | value |
|---|---|
| line_length_pck (LLP) | 1620 |
| frame_length_lines (FLL) | 740 |
| fps | 30 |
| declared pixel_rate | 36,000,000 |
| declared link | 360,960,000 |

`1620 * 740 * 30 = 35,964,000` matches the declared pixel_rate, so
`1620 * 740 * 30 * 10bpp = 359,640,000` is the **per-lane bit rate**, matching
the declared "link" field. `V4L2_CID_LINK_FREQ` is defined as the **DDR clock**,
i.e. half the bit rate: **180,480,000**.

Publishing the bit rate made `ipu7-isys` program the D-PHY at `mbps 721` against
a sensor transmitting at ~361 Mbps. A CSI-2 receiver clocked 2x fast still sees
clock-lane transitions but never validates a packet -> clock lane active, data
lane parked, zero SOF.

## 2. Windows driver structure (all four Dell builds byte-identical)

Register tables in `.rdata`, 16-byte records `{u32 op, u32 reg, u32 val, u32 pad}`;
op 1..4 = write N bytes, op 0x20 = delay(ms), op 0xffff = end. Six tables:

* stream-off `0x0100=0x00` (1 entry)
* stream-on `0x0100=0x01` (1 entry)
* common init (162 entries)
* mode 1296x736@30 (11), mode 648x368@60 (25), mode 648x368@30 (25)

Our 238-entry Linux table == stream-off + init(162) + mode(25) + two conditional
RMWs + AE groups, matched position for position.

Notable negatives:
* No writes to register pages `0x20xx` / `0x2fxx` anywhere (the sibling HM1246's
  `SBC_CTRL 0x2003` / `POLARITY_CTRL 0x2f20` / `PCLK_CTRL 0x2f24` do not apply).
* Nothing is written to I2C after `0x0100=0x01`.
* No `0x0100=0x02` (HM1246's STOP value) exists.
* One pixel-format path; no mono/Y10 vs Bayer distinction.
* Both conditional RMWs are no-ops on this silicon (`0x4b20 &= ~0x60` on a base
  of 0x9e; `0x0101 ^= 0x03` yielding 0x03, which we already write).

## 3. USB capture decode (7 captures, USBIO framing confirmed against
   mainline `include/linux/usb/usbio.h`)

* Only three I2C addresses exist on the bridge-tunnelled bus: `0x24` (IR),
  `0x36` (RGB), `0x76`. No hidden address.
* **Windows never sends an IR `HOST_SET_MIPI_CONFIG` (0x0830).** All nine
  0x0830 buffers across all captures carry RGB geometry; a 648x368 pair appears
  in no USB payload at all. Our driver sends one; Windows does not. (Tested both
  ways — not the blocker, but dropped for fidelity.)
* The bridge exposes two bulk endpoints and **no isochronous endpoint**, so no
  image data crosses USB; IR frames necessarily travel over MIPI.
* Ordering divergence: Windows arms at init entry 198 of 238 and writes the
  trailing 40 (AE groups) while already streaming. Terminal register state is
  identical either way; exposed as the `arm_at_entry` module parameter.

## 4. Measurement technique

`ipu7-isys` reads `PHY_STOPSTATE` exactly once, ~29 us **before** the sensor's
`s_stream(1)`, so the value in dmesg always reads "idle" and is useless. To get
a real reading, arm the sensor standalone first:

```
echo 1 > /sys/bus/i2c/devices/i2c-HIMX1092:00/stream
sleep 2
# then start the capture; the driver's single read now lands while lanes are live
```

Registers: port N base `0x2c0000 + N*0x4000`; `+0x44 DPHY_RSTZ`,
`+0x48 PHY_RX`, `+0x4c PHY_STOPSTATE`. Enable only
`file drivers/staging/media/ipu7/ipu7-isys-csi2.c +p` — never whole-module isys
dyndbg, which logs every MMIO access.

Reading the registers from userspace via the PCI BAR is **not** possible while
the driver holds it (strict iomem makes the `resource0` mmap fail EINVAL).

## 5. Frame layout

648x368, `V4L2_PIX_FMT_SGRBG10` ('BA10'), **bytesperline 1344** — 672 px of
stride for 648 active, 16-bit little-endian containers holding 10-bit values.
The sensor is physically monochrome; treat the data as greyscale (`>>2` for
8-bit) rather than debayering it.

The IR flood illuminator is a LED class device, `HIMX1092_00::ir_flood_led`
(GPIO 55). INT3472 claims that GPIO, which is why the sensor driver reports
`ir_led=none` and cannot drive it — the consumer must.
