// SPDX-License-Identifier: GPL-2.0-only
/*
 * Himax HM1092 IR camera sensor driver
 *
 * 1280x720 NIR (near-infrared) CMOS image sensor for face authentication.
 * 1-lane MIPI CSI-2, 10-bit mono output, 30fps.
 *
 * Register layout inferred from the HM11B1/HM2170 Himax sensor family
 * (same 16-bit address, 8-bit data architecture).
 *
 * Copyright (C) 2026 Contributors
 */

#include <linux/acpi.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>

#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-subdev.h>

/* Chip identification */
#define HM1092_CHIP_ID			0x1091	/* Silicon reports 0x1091, not 0x1092 */
#define HM1092_REG_CHIP_ID		0x0000	/* 16-bit, big-endian */

/* Mode control */
#define HM1092_REG_MODE_SELECT		0x0100
#define HM1092_MODE_STANDBY		0x00
#define HM1092_MODE_STREAMING		0x01

/* Command update — write 0x00 to apply grouped register changes */
#define HM1092_REG_COMMAND_UPDATE	0x0104

/* Exposure */
#define HM1092_REG_EXPOSURE		0x0202	/* 16-bit coarse integration time */
#define HM1092_EXPOSURE_MIN		2
#define HM1092_EXPOSURE_MAX		720
#define HM1092_EXPOSURE_DEFAULT		256
#define HM1092_EXPOSURE_STEP		1

/* Analog gain */
#define HM1092_REG_ANALOG_GAIN		0x0205	/* 8-bit */
#define HM1092_AGAIN_MIN		0
#define HM1092_AGAIN_MAX		0xff
#define HM1092_AGAIN_DEFAULT		0x10
#define HM1092_AGAIN_STEP		1

/* Digital gain */
#define HM1092_REG_DIGITAL_GAIN		0x0207	/* 16-bit, 8.8 fixed point */
#define HM1092_DGAIN_MIN		0x0100
#define HM1092_DGAIN_MAX		0x0fff
#define HM1092_DGAIN_DEFAULT		0x0100
#define HM1092_DGAIN_STEP		1

/* Test pattern */
#define HM1092_REG_TEST_PATTERN		0x0601
#define HM1092_TEST_PATTERN_OFF		0x00
#define HM1092_TEST_PATTERN_ON		0x01

/* Frame timing */
#define HM1092_REG_VTS			0x0340	/* 16-bit, vertical total size */
#define HM1092_REG_HTS			0x0342	/* 16-bit, horizontal total size */

/* Fixed output format */
#define HM1092_WIDTH			1280
#define HM1092_HEIGHT			720
/*
 * The sensor outputs 10-bit mono, but IPU7 ISYS only accepts Bayer formats.
 * Report as SGRBG10 — the mono IR data will be captured identically
 * (single-channel data interpreted as one Bayer color, which is fine).
 */
#define HM1092_MBUS_CODE		MEDIA_BUS_FMT_SGRBG10_1X10

/* MIPI CSI-2 */
#define HM1092_LANES			1
/* 19.2 MHz MCLK * 94 (PLL mult 0x5E) / 5 (PLL div 0x0A) = 360.96 MHz */
#define HM1092_LINK_FREQ_384MHZ		360960000ULL

/*
 * Minimal init sequence — just enough to configure the sensor for streaming.
 * The PLL, timing, and output format registers are based on the HM11B1 family.
 * If these don't work, we'll need to capture the actual init from Windows.
 */
struct hm1092_reg {
	u16 addr;
	u8 val;
};

/*
 * Init sequence extracted from Dell Windows driver hm1092.sys
 * (Intel-2D-Imaging-USB-IO-Vision-Driver-for-Camera, version 81.26100.0.13)
 * Binary at offset 0x26B34 in .rdata section, 16-byte entries.
 */
static const struct hm1092_reg hm1092_init_regs[] = {
	/*
	 * COMPLETE Windows sensor write sequence from tverhaeghe's
	 * windows_hello_unlock USBPcap capture (intel/vision-drivers#37,
	 * 2026-05-12). 240 register writes in EXACT Windows order.
	 *
	 * Includes all writes from initial standby through streaming
	 * through post-activation tweaks. Entry 240 puts sensor back
	 * to standby (0x0100=0x00) — hm1092_set_stream(1) explicitly
	 * writes 0x0100=0x01 AFTER this table, overriding the final
	 * standby, leaving sensor streaming. Net behavior matches
	 * Windows runtime state.
	 */
	{ 0x0100, 0x00 },
	{ 0x0103, 0x00 },
	{ 0x0000, 0x00 },
	{ 0x0101, 0x00 },
	{ 0x0202, 0x02 },
	{ 0x0203, 0xe5 },
	{ 0x0307, 0x00 },
	{ 0x0309, 0x01 },
	{ 0x030a, 0x05 },
	{ 0x030d, 0x0a },
	{ 0x030f, 0x5e },
	{ 0x0310, 0x00 },
	{ 0x0340, 0x03 },
	{ 0x0341, 0x1e },
	{ 0x0342, 0x05 },
	{ 0x0343, 0xe4 },
	{ 0x0350, 0x53 },
	{ 0x0387, 0x01 },
	{ 0x3110, 0x02 },
	{ 0x3735, 0xe2 },
	{ 0x3704, 0x04 },
	{ 0x4001, 0x00 },
	{ 0x4002, 0x2b },
	{ 0x4024, 0x40 },
	{ 0x4131, 0x01 },
	{ 0x4132, 0x20 },
	{ 0x4265, 0x02 },
	{ 0x4b04, 0x01 },
	{ 0x4b0e, 0x0e },
	{ 0x4b18, 0x00 },
	{ 0x4b20, 0x9e },
	{ 0x4b31, 0x06 },
	{ 0x4b3b, 0x02 },
	{ 0x4b3e, 0x00 },
	{ 0x4b44, 0x0c },
	{ 0x4b45, 0x01 },
	{ 0x4b47, 0x00 },
	{ 0x5004, 0x40 },
	{ 0x5005, 0x28 },
	{ 0x5006, 0x40 },
	{ 0x5007, 0x28 },
	{ 0x5010, 0x20 },
	{ 0x5011, 0x00 },
	{ 0x5013, 0x03 },
	{ 0x5015, 0xb3 },
	{ 0x501d, 0x4c },
	{ 0x5098, 0x00 },
	{ 0x5099, 0x11 },
	{ 0x509b, 0x03 },
	{ 0x50a0, 0x30 },
	{ 0x50a2, 0x0b },
	{ 0x50a6, 0x00 },
	{ 0x50a7, 0x00 },
	{ 0x50aa, 0x22 },
	{ 0x50ab, 0x07 },
	{ 0x50ac, 0x24 },
	{ 0x50ad, 0x07 },
	{ 0x50ae, 0x20 },
	{ 0x50af, 0x40 },
	{ 0x50b3, 0x04 },
	{ 0x50b4, 0x00 },
	{ 0x50b7, 0x00 },
	{ 0x50b8, 0x70 },
	{ 0x50b9, 0xff },
	{ 0x50ba, 0xff },
	{ 0x50bb, 0x14 },
	{ 0x50cb, 0x21 },
	{ 0x50d5, 0xe0 },
	{ 0x50d7, 0x12 },
	{ 0x50dd, 0x00 },
	{ 0x50e8, 0x00 },
	{ 0x50ea, 0x74 },
	{ 0x50fa, 0x02 },
	{ 0x5100, 0x03 },
	{ 0x5101, 0x13 },
	{ 0x5102, 0x23 },
	{ 0x5103, 0x33 },
	{ 0x5104, 0x43 },
	{ 0x5105, 0x42 },
	{ 0x5106, 0x40 },
	{ 0x5118, 0x00 },
	{ 0x5119, 0x00 },
	{ 0x511a, 0x00 },
	{ 0x511b, 0x00 },
	{ 0x511c, 0x00 },
	{ 0x511d, 0x00 },
	{ 0x511e, 0x00 },
	{ 0x5130, 0x13 },
	{ 0x5131, 0x23 },
	{ 0x5132, 0x33 },
	{ 0x5133, 0x43 },
	{ 0x5134, 0x42 },
	{ 0x5135, 0x40 },
	{ 0x5136, 0x40 },
	{ 0x5148, 0x01 },
	{ 0x5149, 0x01 },
	{ 0x514a, 0x01 },
	{ 0x514b, 0x01 },
	{ 0x514c, 0x01 },
	{ 0x514d, 0x01 },
	{ 0x514e, 0x01 },
	{ 0x51c0, 0x00 },
	{ 0x51c1, 0x81 },
	{ 0x51c2, 0xec },
	{ 0x51c3, 0x00 },
	{ 0x51c4, 0x55 },
	{ 0x51c5, 0x44 },
	{ 0x51c6, 0x00 },
	{ 0x51c7, 0x81 },
	{ 0x51c8, 0xec },
	{ 0x51c9, 0x00 },
	{ 0x51ca, 0x55 },
	{ 0x51cb, 0x24 },
	{ 0x51cc, 0x00 },
	{ 0x51cd, 0x81 },
	{ 0x51ce, 0xec },
	{ 0x51cf, 0x00 },
	{ 0x51d0, 0x54 },
	{ 0x51d1, 0x24 },
	{ 0x51d2, 0x00 },
	{ 0x51d3, 0x81 },
	{ 0x51d4, 0xec },
	{ 0x51d5, 0x00 },
	{ 0x51d6, 0x53 },
	{ 0x51d7, 0x14 },
	{ 0x51d8, 0x00 },
	{ 0x51d9, 0x81 },
	{ 0x51da, 0xec },
	{ 0x51db, 0x00 },
	{ 0x51dc, 0x53 },
	{ 0x51dd, 0x14 },
	{ 0x51e0, 0x09 },
	{ 0x51e1, 0x03 },
	{ 0x51e2, 0x04 },
	{ 0x51e3, 0x03 },
	{ 0x51e4, 0x08 },
	{ 0x51e5, 0x07 },
	{ 0x51e6, 0x08 },
	{ 0x51e7, 0x07 },
	{ 0x51e8, 0x04 },
	{ 0x51e9, 0x46 },
	{ 0x51ea, 0x43 },
	{ 0x51eb, 0x62 },
	{ 0x51ec, 0x61 },
	{ 0x51ed, 0x00 },
	{ 0x51ee, 0x00 },
	{ 0x5200, 0x60 },
	{ 0x5201, 0x80 },
	{ 0x5202, 0x00 },
	{ 0x5203, 0x01 },
	{ 0x5206, 0x80 },
	{ 0x5208, 0x0b },
	{ 0x5209, 0x0c },
	{ 0x520c, 0x15 },
	{ 0x520d, 0x40 },
	{ 0x5214, 0x28 },
	{ 0x5215, 0x04 },
	{ 0x5216, 0x02 },
	{ 0x5217, 0x01 },
	{ 0x5218, 0x07 },
	{ 0x521e, 0x01 },
	{ 0x5282, 0xff },
	{ 0x5283, 0x03 },
	{ 0x0202, 0x01 },
	{ 0x0203, 0x68 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe4 },
	{ 0x0342, 0x06 },
	{ 0x0343, 0x54 },
	{ 0x0344, 0x00 },
	{ 0x0345, 0x00 },
	{ 0x0346, 0x00 },
	{ 0x0347, 0x00 },
	{ 0x0348, 0x05 },
	{ 0x0349, 0x0d },
	{ 0x034a, 0x02 },
	{ 0x034b, 0xdd },
	{ 0x034c, 0x02 },
	{ 0x034d, 0x88 },
	{ 0x034e, 0x01 },
	{ 0x034f, 0x70 },
	{ 0x0383, 0x00 },
	{ 0x0387, 0x10 },
	{ 0x0390, 0x03 },
	{ 0x4800, 0xac },
	{ 0x0104, 0x01 },
	{ 0x0104, 0x00 },
	{ 0x4801, 0xae },
	{ 0x4b20, 0x9e },
	{ 0x0101, 0x03 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0xae },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0100, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0xa1 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0x85 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0x80 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0x91 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0340, 0x02 },
	{ 0x0341, 0xe5 },
	{ 0x0202, 0x00 },
	{ 0x0203, 0xb4 },
	{ 0x0205, 0x00 },
	{ 0x020e, 0x01 },
	{ 0x020f, 0x00 },
	{ 0x0104, 0x01 },
	{ 0x0100, 0x00 },
};

struct hm1092 {
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct v4l2_ctrl_handler ctrl_handler;

	struct v4l2_ctrl *exposure;
	struct v4l2_ctrl *analogue_gain;
	struct v4l2_ctrl *digital_gain;
	struct v4l2_ctrl *test_pattern;
	struct v4l2_ctrl *link_freq;
	struct v4l2_ctrl *pixel_rate;
	struct v4l2_ctrl *hblank;
	struct v4l2_ctrl *vblank;

	/* Power supplies from INT3472 */
	struct regulator *dvdd;
	struct regulator *avdd;
	struct regulator *dovdd;

	/* Reference clock from INT3472 GPIO clock */
	struct clk *extclk;

	/* IR flood LED — mapped by INT3472 type 0x02 as "ir-led" GPIO */
	struct gpio_desc *ir_led;

	bool streaming;
};

static inline struct hm1092 *to_hm1092(struct v4l2_subdev *sd)
{
	return container_of(sd, struct hm1092, sd);
}

/* --- I2C register access (16-bit addr, 8-bit data) --- */

static int hm1092_read_reg(struct i2c_client *client, u16 reg, u8 *val)
{
	u8 addr[2] = { reg >> 8, reg & 0xff };
	struct i2c_msg msgs[2] = {
		{ .addr = client->addr, .flags = 0,
		  .len = 2, .buf = addr },
		{ .addr = client->addr, .flags = I2C_M_RD,
		  .len = 1, .buf = val },
	};
	int ret;

	ret = i2c_transfer(client->adapter, msgs, 2);
	if (ret != 2) {
		dev_err(&client->dev, "read reg 0x%04x failed: %d\n", reg, ret);
		return ret < 0 ? ret : -EIO;
	}
	return 0;
}

static int hm1092_write_reg(struct i2c_client *client, u16 reg, u8 val)
{
	u8 buf[3] = { reg >> 8, reg & 0xff, val };
	struct i2c_msg msg = {
		.addr = client->addr, .flags = 0,
		.len = 3, .buf = buf,
	};
	int ret;

	ret = i2c_transfer(client->adapter, &msg, 1);
	if (ret != 1) {
		dev_err(&client->dev, "write reg 0x%04x=0x%02x failed: %d\n",
			reg, val, ret);
		return ret < 0 ? ret : -EIO;
	}
	return 0;
}

static int hm1092_read_reg16(struct i2c_client *client, u16 reg, u16 *val)
{
	u8 hi, lo;
	int ret;

	ret = hm1092_read_reg(client, reg, &hi);
	if (ret)
		return ret;
	ret = hm1092_read_reg(client, reg + 1, &lo);
	if (ret)
		return ret;
	*val = (hi << 8) | lo;
	return 0;
}

static int hm1092_write_reg16(struct i2c_client *client, u16 reg, u16 val)
{
	int ret;

	ret = hm1092_write_reg(client, reg, val >> 8);
	if (ret)
		return ret;
	return hm1092_write_reg(client, reg + 1, val & 0xff);
}

static int hm1092_write_reg_list(struct i2c_client *client,
				  const struct hm1092_reg *regs, int count)
{
	int i, ret;

	for (i = 0; i < count; i++) {
		ret = hm1092_write_reg(client, regs[i].addr, regs[i].val);
		if (ret)
			return ret;
	}
	return 0;
}

/* --- V4L2 subdev operations --- */

static int hm1092_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct hm1092 *hm = container_of(ctrl->handler, struct hm1092,
					  ctrl_handler);
	struct i2c_client *client = v4l2_get_subdevdata(&hm->sd);
	int ret = 0;

	if (!hm->streaming)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		ret = hm1092_write_reg16(client, HM1092_REG_EXPOSURE,
					  ctrl->val);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		ret = hm1092_write_reg(client, HM1092_REG_ANALOG_GAIN,
				       ctrl->val);
		break;
	case V4L2_CID_DIGITAL_GAIN:
		ret = hm1092_write_reg16(client, HM1092_REG_DIGITAL_GAIN,
					  ctrl->val);
		break;
	case V4L2_CID_TEST_PATTERN:
		ret = hm1092_write_reg(client, HM1092_REG_TEST_PATTERN,
				       ctrl->val);
		break;
	default:
		break;
	}
	return ret;
}

static const struct v4l2_ctrl_ops hm1092_ctrl_ops = {
	.s_ctrl = hm1092_set_ctrl,
};

static const s64 hm1092_link_freqs[] = {
	HM1092_LINK_FREQ_384MHZ,
};

static const char * const hm1092_test_pattern_menu[] = {
	"Disabled",
	"Solid Color",
};

static int hm1092_init_controls(struct hm1092 *hm)
{
	struct v4l2_ctrl_handler *handler = &hm->ctrl_handler;
	int ret;

	ret = v4l2_ctrl_handler_init(handler, 8);
	if (ret)
		return ret;

	/*
	 * HBLANK and VBLANK — required by libcamera's CameraSensor.
	 * Values are estimates for 1280x720 @ 30fps with 384MHz link freq.
	 * pixel_rate = 384M * 2 (DDR) * 1 lane / 10 bits = 76.8 Mpixels/sec
	 * HTS = pixel_rate / (VTS * fps) → with VTS=800: HTS=3200
	 * hblank = HTS - width = 3200 - 1280 = 1920
	 * vblank = VTS - height = 800 - 720 = 80
	 */
	hm->hblank = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
				       V4L2_CID_HBLANK, 1920, 1920, 1, 1920);
	if (hm->hblank)
		hm->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	hm->vblank = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
				       V4L2_CID_VBLANK, 80, 2000, 1, 80);

	hm->link_freq = v4l2_ctrl_new_int_menu(handler, &hm1092_ctrl_ops,
						V4L2_CID_LINK_FREQ,
						ARRAY_SIZE(hm1092_link_freqs) - 1,
						0, hm1092_link_freqs);
	if (hm->link_freq)
		hm->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	/* pixel_rate = link_freq * 2 (DDR) * lanes / bpp */
	hm->pixel_rate = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					    V4L2_CID_PIXEL_RATE, 0,
					    HM1092_LINK_FREQ_384MHZ * 2 * HM1092_LANES / 10,
					    1,
					    HM1092_LINK_FREQ_384MHZ * 2 * HM1092_LANES / 10);
	if (hm->pixel_rate)
		hm->pixel_rate->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	hm->exposure = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					  V4L2_CID_EXPOSURE,
					  HM1092_EXPOSURE_MIN,
					  HM1092_EXPOSURE_MAX,
					  HM1092_EXPOSURE_STEP,
					  HM1092_EXPOSURE_DEFAULT);

	hm->analogue_gain = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					       V4L2_CID_ANALOGUE_GAIN,
					       HM1092_AGAIN_MIN,
					       HM1092_AGAIN_MAX,
					       HM1092_AGAIN_STEP,
					       HM1092_AGAIN_DEFAULT);

	hm->digital_gain = v4l2_ctrl_new_std(handler, &hm1092_ctrl_ops,
					      V4L2_CID_DIGITAL_GAIN,
					      HM1092_DGAIN_MIN,
					      HM1092_DGAIN_MAX,
					      HM1092_DGAIN_STEP,
					      HM1092_DGAIN_DEFAULT);

	hm->test_pattern = v4l2_ctrl_new_std_menu_items(handler,
							 &hm1092_ctrl_ops,
							 V4L2_CID_TEST_PATTERN,
							 ARRAY_SIZE(hm1092_test_pattern_menu) - 1,
							 0, 0,
							 hm1092_test_pattern_menu);

	if (handler->error) {
		ret = handler->error;
		v4l2_ctrl_handler_free(handler);
		return ret;
	}

	hm->sd.ctrl_handler = handler;
	return 0;
}

static int hm1092_enum_mbus_code(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index > 0)
		return -EINVAL;

	code->code = HM1092_MBUS_CODE;
	return 0;
}

static int hm1092_enum_frame_size(struct v4l2_subdev *sd,
				   struct v4l2_subdev_state *state,
				   struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index > 0 || fse->code != HM1092_MBUS_CODE)
		return -EINVAL;

	fse->min_width = HM1092_WIDTH;
	fse->max_width = HM1092_WIDTH;
	fse->min_height = HM1092_HEIGHT;
	fse->max_height = HM1092_HEIGHT;
	return 0;
}

static int hm1092_set_format(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state,
			      struct v4l2_subdev_format *fmt)
{
	struct v4l2_mbus_framefmt *mf = &fmt->format;

	/* Fixed format — only 1280x720 Y10 */
	mf->width = HM1092_WIDTH;
	mf->height = HM1092_HEIGHT;
	mf->code = HM1092_MBUS_CODE;
	mf->field = V4L2_FIELD_NONE;
	mf->colorspace = V4L2_COLORSPACE_RAW;
	mf->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
	mf->quantization = V4L2_QUANTIZATION_DEFAULT;
	mf->xfer_func = V4L2_XFER_FUNC_NONE;

	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY)
		*v4l2_subdev_state_get_format(state, fmt->pad) = *mf;

	return 0;
}

static int hm1092_get_format(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state,
			      struct v4l2_subdev_format *fmt)
{
	struct v4l2_mbus_framefmt *mf;

	if (fmt->which == V4L2_SUBDEV_FORMAT_TRY) {
		mf = v4l2_subdev_state_get_format(state, fmt->pad);
		fmt->format = *mf;
	} else {
		fmt->format.width = HM1092_WIDTH;
		fmt->format.height = HM1092_HEIGHT;
		fmt->format.code = HM1092_MBUS_CODE;
		fmt->format.field = V4L2_FIELD_NONE;
		fmt->format.colorspace = V4L2_COLORSPACE_RAW;
		fmt->format.ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
		fmt->format.quantization = V4L2_QUANTIZATION_DEFAULT;
		fmt->format.xfer_func = V4L2_XFER_FUNC_NONE;
	}
	return 0;
}

static int hm1092_set_stream(struct v4l2_subdev *sd, int enable)
{
	struct hm1092 *hm = to_hm1092(sd);
	struct i2c_client *client = v4l2_get_subdevdata(sd);
	int ret;

	dev_info(&client->dev, "hm1092_set_stream: enable=%d ENTER\n", enable);

	if (enable) {
		ret = pm_runtime_resume_and_get(&client->dev);
		dev_info(&client->dev, "  pm_runtime_resume_and_get returned %d\n", ret);
		if (ret && ret != -EACCES)
			return ret;

		/* Write init sequence */
		dev_info(&client->dev, "  writing %zu-entry init sequence...\n",
			 ARRAY_SIZE(hm1092_init_regs));
		ret = hm1092_write_reg_list(client, hm1092_init_regs,
					     ARRAY_SIZE(hm1092_init_regs));
		if (ret) {
			dev_err(&client->dev, "init sequence failed: %d\n", ret);
			goto err_rpm;
		}
		dev_info(&client->dev, "  init sequence written OK\n");

		/* Apply controls */
		ret = __v4l2_ctrl_handler_setup(&hm->ctrl_handler);
		if (ret) {
			dev_err(&client->dev, "ctrl setup failed: %d\n", ret);
			goto err_rpm;
		}
		dev_info(&client->dev, "  v4l2 controls applied OK\n");

		/* Start streaming */
		dev_info(&client->dev, "  writing MODE_SELECT=0x01 (streaming)...\n");
		ret = hm1092_write_reg(client, HM1092_REG_MODE_SELECT,
				       HM1092_MODE_STREAMING);
		if (ret) {
			dev_err(&client->dev, "stream start failed: %d\n", ret);
			goto err_rpm;
		}
		dev_info(&client->dev, "  MODE_SELECT=0x01 ack'd by sensor\n");

		/* Lazy-enable IR LED only while streaming */
		if (hm->ir_led) {
			gpiod_set_value_cansleep(hm->ir_led, 1);
			dev_info(&client->dev, "  IR LED gpio set to 1\n");
		}

		hm->streaming = true;
		dev_info(&client->dev, "hm1092_set_stream(1) EXIT — sensor is now streaming\n");
	} else {
		hm->streaming = false;

		/* Turn off IR LED before sensor goes to standby */
		if (hm->ir_led) {
			gpiod_set_value_cansleep(hm->ir_led, 0);
			dev_info(&client->dev, "  IR LED gpio set to 0\n");
		}

		ret = hm1092_write_reg(client, HM1092_REG_MODE_SELECT,
				       HM1092_MODE_STANDBY);
		dev_info(&client->dev, "  MODE_SELECT=0x00 (standby) write returned %d\n", ret);
		pm_runtime_put_noidle(&client->dev);
		dev_info(&client->dev, "hm1092_set_stream(0) EXIT\n");
	}

	return 0;

err_rpm:
	pm_runtime_put(&client->dev);
	dev_info(&client->dev, "hm1092_set_stream EXIT with error %d\n", ret);
	return ret;
}

/*
 * sysfs `stream` attribute — manual hook to invoke hm1092_set_stream()
 * directly, bypassing the V4L2 pipeline's s_stream propagation. This is a
 * diagnostic tool: when v4l2-ctl STREAMON on /dev/video16 fails to walk up
 * to this sensor (because the ipu7-isys driver hands off to firmware and
 * never calls v4l2_subdev_call(sd, video, s_stream, 1)), we can drive the
 * sensor manually:
 *     echo 1 > /sys/bus/i2c/devices/i2c-HIMX1092:00/stream
 *     <run capture>
 *     echo 0 > /sys/bus/i2c/devices/i2c-HIMX1092:00/stream
 */
static ssize_t stream_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct hm1092 *hm = to_hm1092(sd);

	return sprintf(buf, "%d\n", hm->streaming ? 1 : 0);
}

static ssize_t stream_store(struct device *dev,
			    struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	int enable, ret;

	if (kstrtoint(buf, 0, &enable))
		return -EINVAL;

	ret = hm1092_set_stream(sd, !!enable);
	if (ret < 0)
		return ret;

	return count;
}
static DEVICE_ATTR_RW(stream);

static int hm1092_init_state(struct v4l2_subdev *sd,
			      struct v4l2_subdev_state *state)
{
	struct v4l2_subdev_format fmt = {
		.which = V4L2_SUBDEV_FORMAT_TRY,
		.pad = 0,
	};

	return hm1092_set_format(sd, state, &fmt);
}

static const struct v4l2_subdev_video_ops hm1092_video_ops = {
	.s_stream = hm1092_set_stream,
};

static const struct v4l2_subdev_pad_ops hm1092_pad_ops = {
	.enum_mbus_code = hm1092_enum_mbus_code,
	.enum_frame_size = hm1092_enum_frame_size,
	.get_fmt = hm1092_get_format,
	.set_fmt = hm1092_set_format,
};

static const struct v4l2_subdev_ops hm1092_subdev_ops = {
	.video = &hm1092_video_ops,
	.pad = &hm1092_pad_ops,
};

static const struct v4l2_subdev_internal_ops hm1092_internal_ops = {
	.init_state = hm1092_init_state,
};

/* --- Probe / Remove --- */

static int hm1092_check_chip_id(struct i2c_client *client)
{
	u16 chip_id;
	int ret;

	ret = hm1092_read_reg16(client, HM1092_REG_CHIP_ID, &chip_id);
	if (ret) {
		dev_err(&client->dev,
			"Failed to read chip ID (sensor may not be powered): %d\n",
			ret);
		/*
		 * Return -ENODEV for ANY I2C failure — never -ETIMEDOUT or
		 * -EPROBE_DEFER. The kernel retries deferred probes, and on
		 * this USBIO bridge, repeated I2C timeouts crash the USB bus
		 * and kill all devices on it (including the working RGB camera).
		 */
		return -ENODEV;
	}

	if (chip_id != HM1092_CHIP_ID) {
		dev_err(&client->dev,
			"Chip ID mismatch: expected 0x%04x, got 0x%04x\n",
			HM1092_CHIP_ID, chip_id);
		return -ENODEV;
	}

	dev_info(&client->dev, "HM1092 chip ID confirmed: 0x%04x\n", chip_id);
	return 0;
}

static int hm1092_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct hm1092 *hm;
	int ret;

	hm = devm_kzalloc(dev, sizeof(*hm), GFP_KERNEL);
	if (!hm)
		return -ENOMEM;

	v4l2_i2c_subdev_init(&hm->sd, client, &hm1092_subdev_ops);
	hm->sd.internal_ops = &hm1092_internal_ops;

	/*
	 * Request power supplies from INT3472. Use devm_regulator_get_optional
	 * so we don't block on missing regulators — not all supplies may exist.
	 */
	hm->dvdd = devm_regulator_get_optional(dev, "dvdd");
	if (IS_ERR(hm->dvdd)) {
		if (PTR_ERR(hm->dvdd) == -EPROBE_DEFER)
			return -ENODEV; /* Never defer */
		hm->dvdd = NULL;
	}

	hm->avdd = devm_regulator_get_optional(dev, "avdd");
	if (IS_ERR(hm->avdd)) {
		if (PTR_ERR(hm->avdd) == -EPROBE_DEFER)
			return -ENODEV;
		hm->avdd = NULL;
	}

	hm->dovdd = devm_regulator_get_optional(dev, "dovdd");
	if (IS_ERR(hm->dovdd)) {
		if (PTR_ERR(hm->dovdd) == -EPROBE_DEFER)
			return -ENODEV;
		hm->dovdd = NULL;
	}

	/* Enable whatever supplies we found */
	if (hm->dovdd) {
		ret = regulator_enable(hm->dovdd);
		if (ret)
			dev_warn(dev, "Failed to enable dovdd: %d\n", ret);
	}
	if (hm->avdd) {
		ret = regulator_enable(hm->avdd);
		if (ret)
			dev_warn(dev, "Failed to enable avdd: %d\n", ret);
	}
	if (hm->dvdd) {
		ret = regulator_enable(hm->dvdd);
		if (ret)
			dev_warn(dev, "Failed to enable dvdd: %d\n", ret);
	}

	/* Get and enable reference clock from INT3472 */
	hm->extclk = devm_clk_get_optional(dev, NULL);
	if (IS_ERR(hm->extclk)) {
		if (PTR_ERR(hm->extclk) == -EPROBE_DEFER)
			return -ENODEV;
		hm->extclk = NULL;
	}
	if (hm->extclk) {
		ret = clk_prepare_enable(hm->extclk);
		if (ret)
			dev_warn(dev, "Failed to enable extclk: %d\n", ret);
	}

	/*
	 * Get IR LED GPIO — mapped by INT3472 type 0x02 as "ir-led".
	 * Acquire OUT_LOW (off). Lazy-enable: LED turns on only when
	 * sensor enters streaming mode (hm1092_set_stream), turns off
	 * on stream stop or driver unload. Matches Windows behavior;
	 * avoids the IR-emitter-always-on power/eye-exposure issue.
	 */
	hm->ir_led = devm_gpiod_get_optional(dev, "ir-led", GPIOD_OUT_LOW);
	if (IS_ERR(hm->ir_led)) {
		if (PTR_ERR(hm->ir_led) == -EPROBE_DEFER)
			return -ENODEV;
		hm->ir_led = NULL;
	}

	dev_info(dev, "Power: dvdd=%s avdd=%s dovdd=%s clk=%s (%lu Hz) ir_led=%s\n",
		 hm->dvdd ? "found" : "none",
		 hm->avdd ? "found" : "none",
		 hm->dovdd ? "found" : "none",
		 hm->extclk ? "found" : "none",
		 hm->extclk ? clk_get_rate(hm->extclk) : 0,
		 hm->ir_led ? "found (off — lazy)" : "none");

	/* Give sensor time to boot after power-on */
	usleep_range(20000, 25000);

	/* Verify chip identity */
	ret = hm1092_check_chip_id(client);
	if (ret) {
		if (hm->dvdd)
			regulator_disable(hm->dvdd);
		if (hm->avdd)
			regulator_disable(hm->avdd);
		if (hm->dovdd)
			regulator_disable(hm->dovdd);
		return ret;
	}

	/* Put back to standby, keep power for later streaming */
	hm1092_write_reg(client, HM1092_REG_MODE_SELECT, HM1092_MODE_STANDBY);

	/* Initialize controls */
	ret = hm1092_init_controls(hm);
	if (ret) {
		dev_err(dev, "Failed to init controls: %d\n", ret);
		return ret;
	}

	/* Register media entity */
	hm->pad.flags = MEDIA_PAD_FL_SOURCE;
	hm->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	hm->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	ret = media_entity_pads_init(&hm->sd.entity, 1, &hm->pad);
	if (ret) {
		dev_err(dev, "Failed to init media entity: %d\n", ret);
		goto err_ctrl;
	}

	/* Register V4L2 subdevice */
	ret = v4l2_async_register_subdev_sensor(&hm->sd);
	if (ret) {
		dev_err(dev, "Failed to register v4l2 subdev: %d\n", ret);
		goto err_media;
	}

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);
	pm_runtime_idle(dev);

	/* Diagnostic: manual sensor-stream trigger. Non-fatal if it fails. */
	ret = device_create_file(dev, &dev_attr_stream);
	if (ret)
		dev_warn(dev, "Failed to create sysfs 'stream' attr: %d\n", ret);
	else
		dev_info(dev, "sysfs 'stream' attr ready at /sys/bus/i2c/devices/i2c-HIMX1092:00/stream\n");

	dev_info(dev, "HM1092 IR sensor driver probed successfully\n");
	return 0;

err_media:
	media_entity_cleanup(&hm->sd.entity);
err_ctrl:
	v4l2_ctrl_handler_free(&hm->ctrl_handler);
	return ret;
}

static void hm1092_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct hm1092 *hm = to_hm1092(sd);

	device_remove_file(&client->dev, &dev_attr_stream);

	/* Safety: ensure IR LED is off on driver unload */
	if (hm->ir_led)
		gpiod_set_value_cansleep(hm->ir_led, 0);

	v4l2_async_unregister_subdev(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(&hm->ctrl_handler);
	pm_runtime_disable(&client->dev);
}

static const struct acpi_device_id hm1092_acpi_ids[] = {
	{ "HIMX1092" },
	{ }
};
MODULE_DEVICE_TABLE(acpi, hm1092_acpi_ids);

static struct i2c_driver hm1092_i2c_driver = {
	.driver = {
		.name = "hm1092",
		.acpi_match_table = hm1092_acpi_ids,
	},
	.probe = hm1092_probe,
	.remove = hm1092_remove,
};
module_i2c_driver(hm1092_i2c_driver);

MODULE_AUTHOR("Contributors");
MODULE_DESCRIPTION("Himax HM1092 IR camera sensor driver");
MODULE_LICENSE("GPL");
