# `ipu7poke` — diagnostic MMIO peek/poke for IPU7 BAR0

Pure diagnostic kernel module. **Not installed by default by `install.sh`** — only built and loaded when explicitly used, since it can do arbitrary MMIO writes to the IPU7 hardware (dangerous if you don't know what you're doing).

## Use case

When investigating IR streaming gap or other CSI-2 receiver behavior, you want to read IPU7 receiver hardware state directly — e.g., did port 2's frame-start register ever latch? Did any error bits get set? Linux's IPU7 staging driver doesn't expose these via debugfs.

## Build + load

```bash
cd ipu7poke
make
sudo /lib/modules/$(uname -r)/build/scripts/sign-file sha256 \
    /var/lib/dkms/mok.key /var/lib/dkms/mok.pub ipu7poke.ko
sudo insmod ipu7poke.ko
```

After load:
```
/sys/kernel/ipu7poke/peek_addr     ← echo hex offset here
/sys/kernel/ipu7poke/peek_value    ← cat returns u32 at that offset
/sys/kernel/ipu7poke/poke          ← echo "hex_offset hex_value" to write
```

## CSI-2 receiver diagnostic — find out where the actual gap is

`test-csi2-state-dump.sh` walks the per-port CSI2 ADPL registers across all 4 IPU7 receivers during simulated RGB stream + IR stream attempts. Compares behavior side-by-side.

Useful register offsets (per `drivers/staging/media/ipu7/ipu7-isys-csi2-regs.h`):

```
IS_IO_BASE              = 0x280000
IS_IO_CSI2_ADPL_PORT(i) = IS_IO_BASE + 0x40800 + i*0x2000

Per port:
  +0x00  CSI2_ADPL_INPUT_MODE
  +0x04  CSI2_ADPL_CSI_RX_ERR_IRQ_CLEAR_EN
  +0x0c  CSI2_ADPL_CSI_RX_ERR_IRQ_STATUS
  +0xa4  CSI2_ADPL_IRQ_CTL_COMMON_STATUS
  +0xbc  CSI2_ADPL_IRQ_CTL_FS_STATUS   ← latches 1 on every Frame Start
```

A port reading `0xffffffff` on all offsets is **powered down / unmapped**.
A port reading `0x0` on those + `FS_STATUS=0x1` is **active and receiving frames**.
A port reading `0x0` everywhere is **active but receiving nothing** — the diagnostic case for "bridge is silent on this lane."

## Unload

```bash
sudo rmmod ipu7poke
```

## DO NOT poke arbitrary registers without source-reading first

This module gives you raw `writel(val, BAR0+offset)`. The IPU7 has registers that, when written incorrectly, can wedge the entire ISYS subsystem (only recoverable by reboot) or worse, the entire PCI device (only recoverable by power cycle). **Read the IPU7 staging driver source for context on what's safe.** The peek path (read-only) is always safe.
