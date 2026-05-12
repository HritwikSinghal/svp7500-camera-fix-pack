#!/bin/bash
# Dump CSI-2 receiver state for all 4 ports during RGB+IR stream attempts.
# Compares port 0 (working RGB) against port 2 (silent IR) at the same wall clock.
# If port 2 PHY hasn't powered up correctly, registers will differ from port 0
# in specific ways (PHY_LANE_STATUS bits, CLK_LANE_STATUS, etc).

set -u

# IS_IO_BASE = 0x280000
# Per port CSI2_ADPL_PORT_BASE(i) = IS_IO_BASE + 0x40800 + i*0x2000
# So port 0 = 0x2c0800, port 1 = 0x2c2800, port 2 = 0x2c4800, port 3 = 0x2c6800
#
# Per port offsets:
#   0x00 = CSI2_ADPL_INPUT_MODE
#   0x04 = CSI2_ADPL_CSI_RX_ERR_IRQ_CLEAR_EN
#   0x0c = CSI2_ADPL_CSI_RX_ERR_IRQ_STATUS
#   0xa4 = CSI2_ADPL_IRQ_CTL_COMMON_STATUS
#   0xbc = CSI2_ADPL_IRQ_CTL_FS_STATUS  (frame-start latch)
#
# Per-port GPREG (PHY status) at:
#   IS_IO_GPREGS_BASE = IS_IO_BASE + 0x0 (need to verify)
#   PHY_LANE_STATUS  ← bit set when PHY lanes are active

POKE=/sys/kernel/ipu7poke
peek() {
    local addr=$1
    echo "$addr" | sudo tee "$POKE/peek_addr" > /dev/null
    sudo cat "$POKE/peek_value"
}

dump_port() {
    local p=$1
    local base=$((0x280000 + 0x40800 + p * 0x2000))
    printf "  port %d  base=0x%06x:\n" $p $base
    printf "    INPUT_MODE         (+0x00) = %s\n" "$(peek $(printf '%x' $base))"
    printf "    RX_ERR_IRQ_STATUS  (+0x0c) = %s\n" "$(peek $(printf '%x' $((base + 0x0c))))"
    printf "    IRQ_COMMON_STATUS  (+0xa4) = %s\n" "$(peek $(printf '%x' $((base + 0xa4))))"
    printf "    FS_STATUS          (+0xbc) = %s\n" "$(peek $(printf '%x' $((base + 0xbc))))"
}

echo "=== baseline (no streams) ==="
for p in 0 1 2 3; do dump_port $p; done

echo
echo "=== start RGB on camera 1 (port 0) ==="
(timeout 30 cam --camera=1 --capture=400 > /tmp/rgb_log.txt 2>&1) &
RGB_PID=$!
sleep 4
F=$(grep -c 'fps' /tmp/rgb_log.txt 2>/dev/null | head -1)
echo "RGB frames so far: $F"

echo
echo "=== state with RGB streaming (port 0 should have FS_STATUS != 0) ==="
for p in 0 1 2 3; do dump_port $p; done

echo
echo "=== fire mipi-ir + replay-rgb-init + IR pipeline + STREAMON ==="
echo replay-rgb-init | sudo tee /sys/bus/i2c/devices/i2c-INTC10E1:00/cmd > /dev/null
sleep 0.3
sudo media-ctl -d /dev/media0 --links '"Intel IPU7 CSI2 2":1->"Intel IPU7 ISYS Capture 16":0[1]' > /dev/null 2>&1
sudo media-ctl -d /dev/media0 --set-v4l2 '"Intel IPU7 CSI2 2":0 [fmt:SGRBG10_1X10/1280x720]' > /dev/null 2>&1
sudo media-ctl -d /dev/media0 --set-v4l2 '"Intel IPU7 CSI2 2":1 [fmt:SGRBG10_1X10/1280x720]' > /dev/null 2>&1

(sudo timeout 6 v4l2-ctl -d /dev/video16 --set-fmt-video=width=1280,height=720,pixelformat=BA10 --stream-mmap --stream-count=10 --stream-to=/tmp/ir_x.raw > /tmp/v4l2.log 2>&1) &
IR_PID=$!
sleep 2

echo
echo "=== state DURING IR stream attempt — does port 2 show ANY change? ==="
for p in 0 1 2 3; do dump_port $p; done

wait $IR_PID 2>/dev/null
sudo kill $RGB_PID 2>/dev/null
wait $RGB_PID 2>/dev/null

echo
echo "=== state after teardown ==="
for p in 0 1 2 3; do dump_port $p; done

echo
echo "=== verdict ==="
echo "If port 0 FS_STATUS changed when RGB streamed, and port 2 FS_STATUS"
echo "stayed at 0 during the IR attempt → bridge is silent on port 2."
echo "If port 2 RX_ERR_IRQ_STATUS shows ANY bit set during IR attempt →"
echo "bridge IS sending data, but malformed — receiver rejects."
