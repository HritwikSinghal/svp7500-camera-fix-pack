// SPDX-License-Identifier: GPL-2.0
/* Author: Dan Scally <djrscally@gmail.com> */

#include <linux/acpi.h>
#include <linux/i2c.h>
#include <linux/platform_data/x86/int3472.h>
#include <linux/slab.h>

union acpi_object *skl_int3472_get_acpi_buffer(struct acpi_device *adev, char *id)
{
	struct acpi_buffer buffer = { ACPI_ALLOCATE_BUFFER, NULL };
	acpi_handle handle = adev->handle;
	union acpi_object *obj;
	acpi_status status;

	status = acpi_evaluate_object(handle, id, NULL, &buffer);
	if (ACPI_FAILURE(status))
		return ERR_PTR(-ENODEV);

	obj = buffer.pointer;
	if (!obj)
		return ERR_PTR(-ENODEV);

	if (obj->type != ACPI_TYPE_BUFFER) {
		acpi_handle_err(handle, "%s object is not an ACPI buffer\n", id);
		kfree(obj);
		return ERR_PTR(-EINVAL);
	}

	return obj;
}
EXPORT_SYMBOL_NS_GPL(skl_int3472_get_acpi_buffer, "INTEL_INT3472");

int skl_int3472_fill_cldb(struct acpi_device *adev, struct int3472_cldb *cldb)
{
	union acpi_object *obj;
	int ret;

	obj = skl_int3472_get_acpi_buffer(adev, "CLDB");
	if (IS_ERR(obj))
		return PTR_ERR(obj);

	if (obj->buffer.length > sizeof(*cldb)) {
		acpi_handle_err(adev->handle, "The CLDB buffer is too large\n");
		ret = -EINVAL;
		goto out_free_obj;
	}

	memcpy(cldb, obj->buffer.pointer, obj->buffer.length);
	ret = 0;

out_free_obj:
	kfree(obj);
	return ret;
}
EXPORT_SYMBOL_NS_GPL(skl_int3472_fill_cldb, "INTEL_INT3472");

/*
 * Fallback sensor lookup: when the ACPI device link method fails (e.g. because
 * _DEP references a non-existent I2C bus like \_SB.PC00.I2C2 on USBIO systems),
 * find the sensor by matching the control_logic_id in its SSDB against this
 * INT3472's control_logic_id from CLDB.
 *
 * Walk all I2C ACPI devices, evaluate their SSDB, and check if offset 0x5A
 * (controllogicid) matches our CLDB control_logic_id.
 */
struct sensor_search_ctx {
	u8 control_logic_id;
	struct acpi_device *found;
};

static acpi_status find_sensor_by_clid(acpi_handle handle, u32 level,
				       void *context, void **ret)
{
	struct sensor_search_ctx *ctx = context;
	struct acpi_device *adev;
	struct acpi_buffer buf = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *obj;
	acpi_status status;

	adev = acpi_fetch_acpi_dev(handle);
	if (!adev)
		return AE_OK;

	/* Only check devices that have an SSDB method */
	status = acpi_evaluate_object(handle, "SSDB", NULL, &buf);
	if (ACPI_FAILURE(status))
		return AE_OK;

	obj = buf.pointer;
	if (!obj || obj->type != ACPI_TYPE_BUFFER || obj->buffer.length < 0x5B) {
		kfree(obj);
		return AE_OK;
	}

	/* SSDB offset 0x5A = controllogicid */
	if (obj->buffer.pointer[0x5A] == ctx->control_logic_id) {
		ctx->found = adev;
		kfree(obj);
		return AE_CTRL_TERMINATE; /* Stop walking */
	}

	kfree(obj);
	return AE_OK;
}

static struct acpi_device *find_sensor_by_control_logic(struct device *dev, u8 clid)
{
	struct sensor_search_ctx ctx = { .control_logic_id = clid, .found = NULL };

	acpi_walk_namespace(ACPI_TYPE_DEVICE, ACPI_ROOT_OBJECT,
			    ACPI_UINT32_MAX, find_sensor_by_clid,
			    NULL, &ctx, NULL);

	if (ctx.found)
		dev_info(dev, "Found sensor %s via SSDB controllogicid=%d fallback\n",
			 acpi_dev_name(ctx.found), clid);

	return ctx.found;
}

/* sensor_adev_ret may be NULL, name_ret must not be NULL */
int skl_int3472_get_sensor_adev_and_name(struct device *dev,
					 struct acpi_device **sensor_adev_ret,
					 const char **name_ret)
{
	struct acpi_device *adev = ACPI_COMPANION(dev);
	struct acpi_device *sensor;
	int ret = 0;

	sensor = acpi_dev_get_next_consumer_dev(adev, NULL);
	if (!sensor) {
		/*
		 * ACPI device link lookup failed. This happens on USBIO-based
		 * platforms (e.g. Dell XPS Panther Lake) where the sensor's
		 * _DEP references \_SB.PC00.I2Cx which doesn't exist as an
		 * ACPI device (the real I2C bus is USB-backed USBIO).
		 *
		 * Fallback: find the sensor by matching SSDB controllogicid
		 * against our CLDB control_logic_id.
		 */
		struct int3472_cldb cldb;

		ret = skl_int3472_fill_cldb(adev, &cldb);
		if (ret) {
			dev_err(dev, "Failed to read CLDB: %d\n", ret);
			return -ENODEV;
		}

		dev_dbg(dev, "No ACPI device link consumers, trying SSDB "
			"controllogicid=%d fallback\n", cldb.control_logic_id);

		sensor = find_sensor_by_control_logic(dev, cldb.control_logic_id);
		if (!sensor) {
			dev_dbg(dev, "No sensor found for controllogicid=%d\n",
				cldb.control_logic_id);
			return -EPROBE_DEFER;
		}
	}

	dev_dbg(dev, "Sensor name %s\n", acpi_dev_name(sensor));

	*name_ret = devm_kasprintf(dev, GFP_KERNEL, I2C_DEV_NAME_FORMAT,
				   acpi_dev_name(sensor));
	if (!*name_ret)
		ret = -ENOMEM;

	if (ret == 0 && sensor_adev_ret)
		*sensor_adev_ret = sensor;
	else
		acpi_dev_put(sensor);

	return ret;
}
EXPORT_SYMBOL_NS_GPL(skl_int3472_get_sensor_adev_and_name, "INTEL_INT3472");

MODULE_DESCRIPTION("Intel SkyLake INT3472 ACPI Device Driver library");
MODULE_AUTHOR("Daniel Scally <djrscally@gmail.com>");
MODULE_LICENSE("GPL");
