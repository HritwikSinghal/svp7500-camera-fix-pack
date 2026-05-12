// SPDX-License-Identifier: GPL-2.0
/*
 * ipu7poke — diagnostic MMIO read/write for Intel IPU7 BAR0
 *
 * Two sysfs files in /sys/kernel/ipu7poke/:
 *   peek <hex_offset>           → returns the u32 value at BAR0+offset
 *   poke <hex_offset> <hex_val> → writes u32 val to BAR0+offset
 *
 * Diagnostic tool only. Used to enable the per-port MGC test pattern generator
 * on IPU7 ISYS to test whether CSI-2 receiver port 2 produces SOFs when fed
 * synthetic frames internally — independent of whether the bridge is sending
 * anything on the lanes. If TPG works → IPU7 receiver hardware OK, bridge is
 * the gap. If TPG also fails → deeper IPU7-side issue.
 */
#include <linux/init.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/device.h>

#define IPU7_VENDOR	0x8086
/* Per drivers/staging/media/ipu7/ipu7.c — Panther Lake IPU7 device IDs */
static const u16 ipu7_device_ids[] = {
	0x645d,  /* PTL / LNL / MTL family */
	0xb05d,
	0xd719,
	0,
};

static struct pci_dev *pdev;
static void __iomem *bar0;
static resource_size_t bar0_len;
static struct kobject *kobj;

static ssize_t peek_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sprintf(buf, "Usage: echo <hex_offset> > peek then read again to get value\n"
			    "Or:    cat /sys/kernel/ipu7poke/peek_value after a peek_addr write\n");
}

static unsigned long peek_addr;
static ssize_t peek_addr_store(struct kobject *k, struct kobj_attribute *a,
			       const char *buf, size_t count)
{
	int ret;
	ret = kstrtoul(buf, 16, &peek_addr);
	if (ret)
		return ret;
	return count;
}
static ssize_t peek_value_show(struct kobject *k, struct kobj_attribute *a,
			       char *buf)
{
	u32 v;
	if (peek_addr >= bar0_len)
		return sprintf(buf, "ERROR: addr 0x%lx >= bar0_len 0x%llx\n",
			       peek_addr, (u64)bar0_len);
	v = readl(bar0 + peek_addr);
	return sprintf(buf, "0x%08x\n", v);
}

static ssize_t poke_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sprintf(buf, "Usage: echo <hex_offset> <hex_val> > poke\n");
}
static ssize_t poke_store(struct kobject *k, struct kobj_attribute *a,
			  const char *buf, size_t count)
{
	unsigned long off, val;
	char *p, *end;
	char tmp[64];
	size_t n = min(count, sizeof(tmp) - 1);
	memcpy(tmp, buf, n);
	tmp[n] = 0;

	p = tmp;
	while (*p == ' ' || *p == '\t') p++;
	end = p;
	while (*end && *end != ' ' && *end != '\t') end++;
	if (!*end) return -EINVAL;
	*end = 0;
	if (kstrtoul(p, 16, &off)) return -EINVAL;
	p = end + 1;
	while (*p == ' ' || *p == '\t') p++;
	end = p;
	while (*end && *end != ' ' && *end != '\t' && *end != '\n') end++;
	*end = 0;
	if (kstrtoul(p, 16, &val)) return -EINVAL;

	if (off >= bar0_len) {
		pr_err("ipu7poke: addr 0x%lx >= bar0_len 0x%llx\n",
		       off, (u64)bar0_len);
		return -EINVAL;
	}
	pr_info("ipu7poke: poke 0x%08lx = 0x%08lx\n", off, val);
	writel((u32)val, bar0 + off);
	return count;
}

static struct kobj_attribute peek_attr = __ATTR_RO(peek);
static struct kobj_attribute peek_addr_attr = __ATTR(peek_addr, 0644, NULL, peek_addr_store);
static struct kobj_attribute peek_value_attr = __ATTR_RO(peek_value);
static struct kobj_attribute poke_attr = __ATTR(poke, 0644, poke_show, poke_store);

static struct attribute *attrs[] = {
	&peek_attr.attr,
	&peek_addr_attr.attr,
	&peek_value_attr.attr,
	&poke_attr.attr,
	NULL,
};
static struct attribute_group attr_grp = { .attrs = attrs };

static int __init ipu7poke_init(void)
{
	int i, ret;

	for (i = 0; ipu7_device_ids[i]; i++) {
		pdev = pci_get_device(IPU7_VENDOR, ipu7_device_ids[i], NULL);
		if (pdev) break;
	}
	if (!pdev) {
		pr_err("ipu7poke: no IPU7 PCI device found\n");
		return -ENODEV;
	}

	bar0 = pci_iomap(pdev, 0, 0);
	if (!bar0) {
		pr_err("ipu7poke: pci_iomap BAR0 failed\n");
		pci_dev_put(pdev);
		return -ENOMEM;
	}
	bar0_len = pci_resource_len(pdev, 0);

	kobj = kobject_create_and_add("ipu7poke", kernel_kobj);
	if (!kobj) {
		pci_iounmap(pdev, bar0);
		pci_dev_put(pdev);
		return -ENOMEM;
	}
	ret = sysfs_create_group(kobj, &attr_grp);
	if (ret) {
		kobject_put(kobj);
		pci_iounmap(pdev, bar0);
		pci_dev_put(pdev);
		return ret;
	}

	pr_info("ipu7poke: ready, BAR0 at %px len 0x%llx, sysfs at /sys/kernel/ipu7poke/\n",
		bar0, (u64)bar0_len);
	return 0;
}

static void __exit ipu7poke_exit(void)
{
	if (kobj) {
		sysfs_remove_group(kobj, &attr_grp);
		kobject_put(kobj);
	}
	if (bar0) pci_iounmap(pdev, bar0);
	if (pdev) pci_dev_put(pdev);
	pr_info("ipu7poke: unloaded\n");
}

module_init(ipu7poke_init);
module_exit(ipu7poke_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("svp7500-fix-pack");
MODULE_DESCRIPTION("IPU7 BAR0 diagnostic peek/poke");
