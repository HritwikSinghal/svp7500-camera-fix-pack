// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (C) 2024 Intel Corporation.
 *
 */

#include <linux/intel_cvs.h>
#include "intel_cvs_update.h"

extern struct intel_cvs *cvs;

int cvs_write_i2c(u16 cmd, u8 *data, u32 len)
{
	struct intel_cvs *ctx = cvs;
	if (!ctx || !ctx->has_i2c)
		return -EOPNOTSUPP;
	struct i2c_client *client =
		container_of(cvs->dev, struct i2c_client, dev);
	int count;
	u16 cv_cmd = (((cmd) >> 8) & 0x00ff) | (((cmd) << 8) & 0xff00);
	u32 cv_host_identifier_size = sizeof(union cv_host_identifiers);

	switch (cmd) {
	case FW_LOADER_START:
		count = i2c_master_send(client, (const char *)&cv_cmd,
								sizeof(u16));
		if (count != sizeof(u16))
			return -EIO;
		break;
	case FW_LOADER_DATA:
		count = i2c_master_send(client, data, len);
		if (count != len)
			return -EIO;
		break;
	case FW_LOADER_END:
		count = i2c_master_send(client, (const char *)&cv_cmd,
								sizeof(u16));
		mdelay(GPIO_WRITE_DELAY_MS);
		if (count != sizeof(u16))
			return -EIO;
		break;
	case SET_HOST_IDENTIFIER:
		u8 *out_buff;
		union cv_host_identifiers host_identifiers;

		out_buff = devm_kzalloc(ctx->dev,
					cv_host_identifier_size + sizeof(cmd), GFP_KERNEL);
		if (!out_buff) {
			dev_err(cvs->dev, "%s:Buffer alloc failed", __func__);
			return -ENOMEM;
		}
		out_buff[0] = (cmd >> 8) & 0x00ff;
		out_buff[1] = cmd & 0x00ff;
		host_identifiers.field.vision_sensing = 0;
		host_identifiers.field.device_power_setting = 0;
		host_identifiers.field.privacy_led_host = 0;
		host_identifiers.field.rgbcamera_pwrup_host = 1;

		memcpy(&out_buff[2], &host_identifiers.value,
			   cv_host_identifier_size);

		count = i2c_master_send(client, (const char *)out_buff,
					sizeof(cmd) + cv_host_identifier_size);

		if (count != cv_host_identifier_size + sizeof(cmd))
			return -EIO;
		dev_dbg(cvs->dev, "%s:set_host_identifier cmd pass", __func__);
		break;
	case HOST_SET_MIPI_CONFIG: {
		/*
		 * Tri-mode HOST_SET_MIPI_CONFIG payload selection:
		 *
		 *   data != NULL && len > 0  -> caller bytes (legacy SSDB-style;
		 *                               used at probe to wake sensor
		 *                               power chain)
		 *   data == NULL && len == 0 -> RGB verbatim Windows bytes
		 *                               (from tverhaeghe long2 capture,
		 *                               OV08x40 / port 0)
		 *   data == NULL && len == 1 -> IR verbatim Windows bytes
		 *                               (from tverhaeghe hello_unlock
		 *                               capture, HM1092 / port 2)
		 *
		 * KEY DIFFS between RGB and IR payloads:
		 *   byte 0x0d: 0x02 (RGB) vs 0x01 (IR)         — port index?
		 *   byte 0x10-13: 88 07 40 04 (71 MHz)  vs
		 *                 10 0f 80 08 (143 MHz)         — IR is 1-lane @ 2x
		 *   byte 0x36-37: 01 01 (RGB has 2nd port desc) vs 00 00 (IR single)
		 *   byte 0xad-b1: 0x00904359 in BOTH             — device constant
		 */
		static const u8 windows_0x830_rgb_body[254] = {
			/* 0x02 */ 0xb0, 0x00, 0x00, 0x00, 0x3c, 0x6c, 0xb4, 0xef,
				   0x3c, 0x02, 0x00, 0x02, 0x00, 0x01, 0x88, 0x07,
			/* 0x12 */ 0x40, 0x04, 0x2b, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x22 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x32 */ 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x88, 0x07,
				   0x40, 0x04, 0x2b, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x42 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x52 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x62 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x72 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x82 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x92 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xa2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0x43, 0x59,
			/* 0xb2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xc2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xd2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xe2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xf2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		};
		static const u8 windows_0x830_ir_body[254] = {
			/* 0x02 */ 0xb0, 0x00, 0x00, 0x00, 0x3f, 0xd5, 0x55, 0xbe,
				   0x1e, 0x02, 0x00, 0x01, 0x00, 0x01, 0x10, 0x0f,
			/* 0x12 */ 0x80, 0x08, 0x2b, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x22 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x32 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x42 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x52 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x62 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x72 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x82 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0x92 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xa2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0x43, 0x59,
			/* 0xb2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xc2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xd2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xe2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			/* 0xf2 */ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
				   0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		};
		u8 *mipi_buf;
		const u32 total_size = 0x100; /* 256 bytes */
		const u8 *payload;
		const char *payload_label;

		mipi_buf = devm_kzalloc(ctx->dev, total_size, GFP_KERNEL);
		if (!mipi_buf)
			return -ENOMEM;

		mipi_buf[0] = (cmd >> 8) & 0xFF;
		mipi_buf[1] = cmd & 0xFF;

		BUILD_BUG_ON(sizeof(windows_0x830_rgb_body) != 254);
		BUILD_BUG_ON(sizeof(windows_0x830_ir_body) != 254);

		if (data == NULL && len == 1) {
			payload = windows_0x830_ir_body;
			payload_label = "Windows verbatim IR (port 2)";
		} else if (data == NULL || len == 0) {
			payload = windows_0x830_rgb_body;
			payload_label = "Windows verbatim RGB (port 0)";
		} else {
			payload = NULL;
			payload_label = "caller SSDB";
		}

		if (payload) {
			memcpy(&mipi_buf[2], payload, 254);
		} else {
			u32 copy_len = min_t(u32, len, 176);
			memcpy(&mipi_buf[2], data, copy_len);
		}

		/*
		 * 2026-05-12 — split into Windows-equivalent 52-byte chunks.
		 *
		 * USBPcap analysis of Windows shows 0x830 is sent as 5 separate
		 * I2C transactions of 52/52/52/52/48 bytes (matching the Lattice
		 * USBIO_QUIRK_I2C_MAX_RW_LEN_52 chunking pattern). Linux currently
		 * sends 256 bytes as ONE I2C transaction (it chunks at the USB
		 * layer but NOT at the I2C protocol layer — bridge sees a single
		 * 256-byte write).
		 *
		 * The bridge's HOST_SET_MIPI_CONFIG handler may be designed for
		 * the chunked-transaction pattern. We replicate Windows's wire
		 * behavior by issuing 5 separate i2c_master_send() calls. Each
		 * is a complete I2C START + 52 (or 48) bytes + STOP cycle.
		 *
		 * The first chunk carries the opcode (0x08 0x30) + payload
		 * length DWORD + checksum DWORD + the first 42 bytes of the
		 * 176-byte payload. Chunks 2-4 carry 52 bytes of payload each.
		 * Chunk 5 carries the final payload bytes + trailing zero-pad.
		 */
		{
			const u32 CHUNK = 52;
			u32 sent = 0;
			int chunk_count = 0;

			while (sent < total_size) {
				u32 chunklen = min(CHUNK, total_size - sent);
				count = i2c_master_send(client,
							(const char *)mipi_buf + sent,
							chunklen);
				chunk_count++;
				if (count != (int)chunklen) {
					dev_warn(cvs->dev,
						 "%s: chunk %d/%d (offset %u, %u bytes) send returned %d\n",
						 __func__, chunk_count, 5,
						 sent, chunklen, count);
					devm_kfree(ctx->dev, mipi_buf);
					return -EIO;
				}
				sent += chunklen;
			}

			dev_info(cvs->dev,
				 "%s: HOST_SET_MIPI_CONFIG sent %u/%d bytes as %d chunks of <= %u (%s payload)",
				 __func__, sent, total_size, chunk_count,
				 CHUNK, payload_label);
		}

		devm_kfree(ctx->dev, mipi_buf);
		break;
	}
	case HOST_SET_MIPI_CONFIG_AUX: {
		/*
		 * 0x833 — Auxiliary MIPI config sibling of 0x830.
		 * From Vision.sys reverse: dispatcher at 0x140004258 has
		 * cmd_idx=2 → 0x830 (176B), cmd_idx=3 → 0x833 (44B). Both
		 * take IOCTL buffer; Windows userland fills the 44B payload.
		 *
		 * We don't know the payload content. Experiment: send caller-
		 * provided buffer (possibly zero-filled) as a 44-byte write.
		 * Total packet: 2 cmd + 44 data = 46 bytes. No padding —
		 * unlike 0x830 which pads to 256 bytes.
		 */
		u8 aux_buf[46];
		u32 total_size = sizeof(aux_buf);

		memset(aux_buf, 0, total_size);
		aux_buf[0] = (cmd >> 8) & 0xFF;
		aux_buf[1] = cmd & 0xFF;
		if (data && len > 0) {
			u32 copy_len = min_t(u32, len, 44);
			memcpy(&aux_buf[2], data, copy_len);
		}

		count = i2c_master_send(client, (const char *)aux_buf,
					total_size);
		dev_info(cvs->dev,
			 "%s: HOST_SET_MIPI_CONFIG_AUX(0x833) sent %d/%d bytes",
			 __func__, count, total_size);
		if (count != (int)total_size)
			return -EIO;
		break;
	}
	default:
		dev_err(cvs->dev, "%s:Invalid command type", __func__);
		return -EINVAL;
	}

	return 0;
}

int cvs_get_device_state(u8 *cv_fw_state)
{
	if (!cvs)
		return -EINVAL;
	if (!cvs->has_i2c)
		return -EOPNOTSUPP;

	if (cvs_read_i2c(GET_DEVICE_STATE, cv_fw_state, sizeof(char)) <= 0) {
		dev_err(cvs->dev, "%s:cvs_read_i2c() failed", __func__);
		return -EIO;
	}

	if (!((*cv_fw_state) & DEVICE_ON_BIT_MASK)) {
		dev_err(cvs->dev, "%s:device_on bit not set", __func__);
		return -EINVAL;
	}

	dev_dbg(cvs->dev, "%s: fw_state:0x%x", __func__, *cv_fw_state);
	return 0;
}

int cvs_get_device_cap(struct cv_ver_capability *cv_fw_cap)
{
	if (!cvs)
		return -EINVAL;
	if (!cvs->has_i2c)
		return -EOPNOTSUPP;
	cvs->magic_num_support = true;

	if (cvs_read_i2c(GET_DEV_CAPABILITY, (char *)cv_fw_cap,
					 sizeof(struct cv_ver_capability)) <= 0) {
		dev_err(cvs->dev, "%s:Get device_capability cmd failed", __func__);
		return -EINVAL;
	}

	dev_info(cvs->dev, "%s:Device protocol is %d.%d", __func__,
			 cvs->cv_fw_capability.protocol_ver_major,
			 cvs->cv_fw_capability.protocol_ver_minor);
	dev_info(cvs->dev, "%s:Device capability is 0x%x", __func__,
			 cvs->cv_fw_capability.dev_capability);

	if (cvs->cv_fw_capability.protocol_ver_major > 2 ||
		(cvs->cv_fw_capability.protocol_ver_major == 2 &&
		cvs->cv_fw_capability.protocol_ver_minor >= 2)) {
		cvs->loader_cmd_size = CMD_SIZE;
	}

	return 0;
}

int cvs_find_magic_num_support(struct intel_cvs *ctx)
{
	if (!ctx || !ctx->has_i2c) {
		/* fall back to legacy protocol assumptions */
		if (ctx)
			ctx->magic_num_support = false;
		return 0;
	}
	struct i2c_client *i2c = container_of(ctx->dev, struct i2c_client, dev);
	int cnt;
	u16 cmd = GET_VID_PID;
	u16 cvs_cmd = cpu_to_be16(cmd);
	int cmd_response;

	cnt = i2c_master_send(i2c, (const char *)&cvs_cmd, sizeof(cvs_cmd));
	if (cnt != sizeof(cvs_cmd)) {
		dev_err(ctx->dev, "sending cmd:0x%x to device failed", cmd);
		return cnt < 0 ? cnt : -EIO;
	}

	cnt = i2c_master_recv(i2c, (char *)&cmd_response, CVMAGICNUMSIZE);
	if (cnt != CVMAGICNUMSIZE) {
		dev_err(ctx->dev, "failed to read back for cmd:0x%x", cmd);
		return cnt < 0 ? cnt : -EIO;
	}
	if (cmd_response != CVMAGICNUM) {
		dev_info(ctx->dev, "magic number in dev response not supported");
		dev_info(cvs->dev, "%s:Device protocol is 1.0", __func__);
		ctx->magic_num_support = false;
	} else {
		dev_info(ctx->dev, "magic number in dev response supported");
		ctx->magic_num_support = true;
	}

	return 0;
}

int cvs_wait_for_host_wake(u64 time_ms)
{
	int ret = -1;
	s64 timeout = 0;

	/* wait for HOST_WAKE signal, timeout in time_ms */
	timeout = msecs_to_jiffies(time_ms);
	ret = wait_event_interruptible_timeout(cvs->hostwake_event,
			cvs->hostwake_event_arg == 1, timeout);

	if (ret <= 0) {
		dev_err(cvs->dev, "%s:hostwake wait timeout", __func__);
		return -ETIMEDOUT;
	}

	cvs->hostwake_event_arg = 0;
	return 0;
}

int cvs_reset_cv_device(void)
{
	if (IS_ERR_OR_NULL(cvs))
		return -EINVAL;

	gpiod_set_value_cansleep(cvs->rst, 0);
	mdelay(GPIO_RESET_MS);
	gpiod_set_value_cansleep(cvs->rst, 1);
	return 0;
}

int cvs_dev_fw_dl_start(void)
{
	struct intel_cvs *ctx = cvs;
	u8 fw_state = 0;
	if (!ctx->has_i2c)
		return -EOPNOTSUPP;

	/* check CV FW state */
	if (cvs_get_device_state(&fw_state)) {
		dev_err(cvs->dev, "%s:cvs_get_device_state() failed", __func__);
		return -EIO;
	}
	if (cvs_write_i2c(FW_LOADER_START, NULL, 0)) {
		dev_err(cvs->dev, "%s:cvs_write_i2c() failed", __func__);
		return -EIO;
	}

	/* Wait for Host Wake */
	if (cvs_wait_for_host_wake(WAIT_HOST_WAKE_NORMAL_MS)) {
		dev_err(cvs->dev, "%s:Host wake timeout", __func__);
		return -ETIMEDOUT;
	}
	ctx->icvs_state = CV_FW_DOWNLOADING_STATE;
	/* check CV FW state */
	if (cvs_get_device_state(&fw_state)) {
		dev_err(cvs->dev, "%s:cvs_get_device_state() failed", __func__);
		return -EIO;
	}
	ctx->cv_fw_state = fw_state;
	if ((fw_state & DEVICE_DWNLD_STATE_MASK) != DEVICE_DWNLD_STATE_MASK) {
		dev_err(cvs->dev, "%s:fail to enter download state. fwstate:0x%x",
				__func__, fw_state);
		return -EIO;
	}
	return 0;
}

int cvs_dev_fw_dl_data(void)
{
	int status = 0;
	struct intel_cvs *ctx = cvs;
	if (!ctx->has_i2c)
		return -EOPNOTSUPP;
	u8 fw_state = DEVICE_DWNLD_STATE_MASK;
	u8 *fw_buff_ptr = NULL;
	u32 fw_size = 0;
	u8 *out_buf;
	u8 *out_buf_ptr;
	size_t buf_size = I2C_PKT_SIZE + cvs->loader_cmd_size;

	// Allocate memory for the buffer
	out_buf = kzalloc(buf_size, GFP_KERNEL);

	if (!out_buf) {
		dev_err(cvs->dev, "%s:No memory for fw_buffer packet", __func__);
		return -ENOMEM;
	}
	if (cvs->loader_cmd_size) {
		out_buf[0] = (FW_LOADER_DATA >> 8);
		out_buf[1] = (FW_LOADER_DATA & 0xFF);
	}
	out_buf_ptr = out_buf + cvs->loader_cmd_size;
	dev_info(cvs->dev, "%s:Enter", __func__);

	fw_buff_ptr = (u8 *)ctx->fw_buffer + FW_BIN_HDR_SIZE;
	fw_size = ctx->fw_buffer_size - FW_BIN_HDR_SIZE;

	while ((fw_size > 0) && (ctx->icvs_state != CV_STOPPING)) {
		int retry = FW_MAX_RETRY;

		if (ctx->close_fw_dl_task) {
			dev_err(cvs->dev, "%s:Received close_fw_dl_task true", __func__);
			status = -EPERM;
			goto err_exit;
		}

		do {
			if (ctx->close_fw_dl_task) {
				dev_info(cvs->dev, "%s:Received close_fw_dl_task", __func__);
				status = -EPERM;
				goto err_exit;
			}
			/* copy data to outbuf */
			memcpy(out_buf_ptr, fw_buff_ptr,
				   fw_size > I2C_PKT_SIZE ? I2C_PKT_SIZE : fw_size);
			wmb(); /* Flush WC buffers after writing out_buf */

			if (fw_state & DEVICE_DWNLD_STATE_MASK) {
				if (cvs_write_i2c(FW_LOADER_DATA, out_buf,
						I2C_PKT_SIZE + cvs->loader_cmd_size)) {
					dev_err(cvs->dev, "%s:fw_loader_data failed", __func__);
					fw_state = DEVICE_DWNLD_ERROR_MASK;
					goto i2c_packet_loop_end;
				}
			}

			/* Wait for Host Wake */
			if (cvs_wait_for_host_wake(WAIT_HOST_WAKE_NORMAL_MS)) {
				dev_err(cvs->dev, "%s:Host wake timeout", __func__);
				status = -EIO;
				goto err_exit;
			}

			/* Check device state */
			if (cvs_get_device_state(&fw_state)) {
				status = -EIO;
				goto err_exit;
			}

			if (!(fw_state & DEVICE_DWNLD_STATE_MASK)) {
				dev_err(cvs->dev, "%s:Device not in download_state",
						__func__);
				status = -EIO;
				goto err_exit;
			}

			if (fw_state & DEVICE_DWNLD_BUSY_MASK) {
				dev_err(cvs->dev, "%s:I2C is busy for too long! fw_state:0x%x",
						__func__, fw_state);
				status = -EIO;
				goto err_exit;
			}

			if (ctx->icvs_state == CV_STOPPING) {
				dev_err(cvs->dev, "%s:cv_state is CV_STOPPING", __func__);
				ctx->fw_update_retries = 0;
				break;
			}
i2c_packet_loop_end:
		} while (--retry && (fw_state & DEVICE_DWNLD_ERROR_MASK));

		if ((fw_state & DEVICE_DWNLD_BUSY_MASK) ||
			(fw_state & DEVICE_DWNLD_ERROR_MASK) ||
			ctx->icvs_state == CV_STOPPING || !fw_state) {
			dev_err(cvs->dev, "%s:Wrong fw_state:0x%x, cv_state:0x%x",
					__func__, fw_state, ctx->icvs_state);
			status = -EIO;
			goto err_exit;
		}
		ctx->info_fwupd.num_packets_sent++;
		fw_size -= I2C_PKT_SIZE;
		fw_buff_ptr += I2C_PKT_SIZE;
		ctx->cv_fw_state = fw_state;
	}

err_exit:
	dev_info(cvs->dev, "%s:Exit with status:0x%x, fw_st:0x%x, cv_st:0x%x",
			 __func__, status, fw_state, ctx->icvs_state);
	kfree(out_buf);
	out_buf_ptr = NULL;

	return status;
}

int cvs_dev_fw_dl_end(void)
{
	struct intel_cvs *ctx = cvs;
	u8 fw_state = 0;
	if (!ctx->has_i2c)
		return -EOPNOTSUPP;

	if (cvs_write_i2c(FW_LOADER_END, NULL, 0)) {
		dev_err(cvs->dev, "%s:fw_loader_end failed", __func__);
		return -EIO;
	}

	if (cvs_wait_for_host_wake(WAIT_HOST_WAKE_NORMAL_MS)) {
		dev_err(cvs->dev, "%s:Loader_end hostwake error", __func__);
		return -ETIMEDOUT;
	}
	ctx->icvs_state = CV_FW_FLASHING_STATE;

	/* check CV FW state */
	if (cvs_get_device_state(&fw_state)) {
		dev_err(cvs->dev, "%s:cvs_get_device_state() failed", __func__);
		return -EIO;
	}
	ctx->cv_fw_state = fw_state;
	return 0;
}

int cvs_dev_fw_dl(void)
{
	int status = 0;
	struct intel_cvs *ctx = cvs;
	if (!ctx->has_i2c)
		return -EOPNOTSUPP;
	u8 fw_state = 0;

	dev_info(cvs->dev, "%s:Enter", __func__);
	status = cvs_dev_fw_dl_start();
	if (status) {
		dev_err(cvs->dev, "%s:cvs_dev_fw_dl_start() fail", __func__);
	} else {
		status = cvs_dev_fw_dl_data();
		if (status)
			dev_err(cvs->dev, "%s:cvs_dev_fw_dl_data() fail", __func__);
	}

	/* End FW download, no matter if it's pass or fail */
	if (cvs_dev_fw_dl_end()) {
		dev_err(cvs->dev, "%s:cvs_dev_fw_dl_end() fail", __func__);
		return -EIO;
	}

	if (status)
		return status;

	if (cvs_wait_for_host_wake(ctx->max_flashtime_ms)) {
		dev_err(cvs->dev, "%s:Firmware flash hostwake error", __func__);
		return -ETIMEDOUT;
	}

	ctx->icvs_state = CV_INIT_STATE;
	if (cvs_get_device_state(&fw_state)) {
		dev_err(cvs->dev, "%s:cvs_get_device_state() failed", __func__);
		return -EIO;
	}
	ctx->cv_fw_state = fw_state;
	if (ctx->cv_fw_state & DEVICE_DWNLD_BUSY_MASK) {
		dev_err(cvs->dev, "%s: Device is still busy after flash", __func__);
		return -EBUSY;
	}

	if (!status && cvs->close_fw_dl_task) {
		status = -EINTR;
		dev_info(cvs->dev, "%s:Exit with status:0x%x", __func__, status);
		return status;
	}

	wait_event_interruptible(cvs->lvfs_fwdl_complete_event,
							 cvs->lvfs_fwdl_complete_event_arg == 1);
	cvs->lvfs_fwdl_complete_event_arg = 0;

	dev_info(cvs->dev, "%s:Exit with status:0x%x", __func__, status);
	return status;
}

int cvs_get_fwver_vid_pid(void)
{
	if (!cvs)
		return -EINVAL;
	if (!cvs->has_i2c)
		return -EOPNOTSUPP;

	if (cvs_read_i2c(GET_FW_VERSION, (char *)&cvs->ver,
					 sizeof(struct cvs_fw)) <= 0)
		return -EIO;

	if (cvs_read_i2c(GET_VID_PID, (char *)&cvs->id,
					 sizeof(struct cvs_id)) <= 0)
		return -EIO;

	return 0;
}

void cvs_fw_dl_thread(struct work_struct *arg)
{
	int status = 0;
	u8 fw_state = 0;
	u32 fw_size = 0;
	struct intel_cvs *ctx = cvs;
	if (ctx && !ctx->has_i2c) {
		/* Nothing to do, just mark finished */
		ctx->fw_dl_task_finished = true;
		return;
	}

	if (IS_ERR_OR_NULL(ctx)) {
		dev_err(cvs->dev, "%s:Invalid ctx. Exit firmware download", __func__);
		return;
	}

	fw_size = ctx->fw_buffer_size - FW_BIN_HDR_SIZE;
	ctx->info_fwupd.total_packets = fw_size / I2C_PKT_SIZE;
	ctx->info_fwupd.total_packets += (fw_size % I2C_PKT_SIZE) ? 1 : 0;
	ctx->icvs_state = CV_INIT_STATE;

	do {
		if (ctx->close_fw_dl_task) {
			dev_info(cvs->dev, "%s:Received close_fw_dl_task true", __func__);
			goto xit;
		}
		if (cvs_get_device_state(&fw_state)) {
			dev_err(cvs->dev, "%s:cvs_get_device_state() failed", __func__);
			goto xit;
		}
		status = cvs_dev_fw_dl();
		cvs->info_fwupd.fw_dl_status_code = status;
		if (ctx->close_fw_dl_task && status == -EINTR) {
			dev_info(cvs->dev, "%s:flash interrupted,fw reset to factory ver",
					 __func__);
		} else if (ctx->close_fw_dl_task) {
			dev_info(cvs->dev, "%s:cvs_dev_fw_dl cancelled", __func__);
		} else if (status) {
			dev_err(cvs->dev, "%s:cvs_dev_fw_dl fail", __func__);
		} else {
			dev_info(cvs->dev, "%s:cvs_dev_fw_dl pass", __func__);
			ctx->fw_update_retries--;
			break;
		}
	} while (--ctx->fw_update_retries);

xit:
	/* After FW download acquire sensor to keep sensor ownserhip
	 * with host(IPU) always.This makes IPU-Vision driver interface
	 * simple w/o need of IPU calling vision driver interface API's
	 */
	if (ctx->icvs_sensor_state != CV_SENSOR_VISION_ACQUIRED_STATE &&
		!ctx->cv_suspend) {
		if (cvs_write_i2c(SET_HOST_IDENTIFIER, NULL, 0))
			dev_err(cvs->dev, "%s:set_host_identifier cmd failed", __func__);
		if (cvs_acquire_camera_sensor_internal()) {
			dev_err(cvs->dev, "%s:Acquire sensor fail", __func__);
		} else {
			ctx->icvs_sensor_state = CV_SENSOR_VISION_ACQUIRED_STATE;
			dev_info(cvs->dev, "%s:Ownership transfer after fw_dl success",
					 __func__);
			if (cvs_get_device_cap(&cvs->cv_fw_capability))
				dev_err(cvs->dev, "%s:Device cap not supported", __func__);
		}
	} else {
		ctx->icvs_sensor_state = CV_SENSOR_VISION_ACQUIRED_STATE;
	}

	ctx->update_complete_event_arg = 1;
	wake_up_interruptible(&ctx->update_complete_event);
	ctx->fw_dl_task_finished = true;
	dev_info(cvs->dev, "%s:Exiting fw_dl thread", __func__);
}
