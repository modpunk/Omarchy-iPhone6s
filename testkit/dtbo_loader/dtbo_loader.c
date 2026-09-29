// SPDX-License-Identifier: GPL-2.0
/*
 * dtbo_loader: apply/remove device-tree overlays on a running kernel.
 *   cat foo.dtbo > /dev/dtbo              apply (id printed to dmesg, readable in last_id)
 *   echo <id> > /sys/class/misc/dtbo/remove
 */
#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>
#include <linux/mutex.h>

#define DTBO_MAX (1 << 20)

static DEFINE_MUTEX(dtbo_lock);
static int last_id = -1;

struct dtbo_buf { char *data; size_t len; };

static int dtbo_open(struct inode *inode, struct file *f)
{
	struct dtbo_buf *b = kzalloc(sizeof(*b), GFP_KERNEL);

	if (!b)
		return -ENOMEM;
	b->data = vmalloc(DTBO_MAX);
	if (!b->data) {
		kfree(b);
		return -ENOMEM;
	}
	f->private_data = b;
	return 0;
}

static ssize_t dtbo_write(struct file *f, const char __user *u, size_t n, loff_t *off)
{
	struct dtbo_buf *b = f->private_data;

	if (b->len + n > DTBO_MAX)
		return -EFBIG;
	if (copy_from_user(b->data + b->len, u, n))
		return -EFAULT;
	b->len += n;
	return n;
}

static int dtbo_release(struct inode *inode, struct file *f)
{
	struct dtbo_buf *b = f->private_data;
	int id = 0, ret = 0;

	if (b->len) {
		mutex_lock(&dtbo_lock);
		ret = of_overlay_fdt_apply(b->data, b->len, &id, NULL);
		if (ret)
			pr_err("dtbo_loader: apply failed: %d (id %d)\n", ret, id);
		else
			pr_info("dtbo_loader: applied overlay id %d (%zu bytes)\n", id, b->len);
		last_id = ret ? -1 : id;
		mutex_unlock(&dtbo_lock);
	}
	vfree(b->data);
	kfree(b);
	return ret;
}

static const struct file_operations dtbo_fops = {
	.owner = THIS_MODULE,
	.open = dtbo_open,
	.write = dtbo_write,
	.release = dtbo_release,
};

static ssize_t last_id_show(struct device *d, struct device_attribute *a, char *buf)
{
	return sysfs_emit(buf, "%d\n", last_id);
}
static DEVICE_ATTR_RO(last_id);

static ssize_t remove_store(struct device *d, struct device_attribute *a,
			    const char *buf, size_t n)
{
	int id, ret;

	ret = kstrtoint(buf, 0, &id);
	if (ret)
		return ret;
	mutex_lock(&dtbo_lock);
	ret = of_overlay_remove(&id);
	mutex_unlock(&dtbo_lock);
	pr_info("dtbo_loader: remove overlay: %d\n", ret);
	return ret ? ret : n;
}
static DEVICE_ATTR_WO(remove);

static struct attribute *dtbo_attrs[] = {
	&dev_attr_last_id.attr,
	&dev_attr_remove.attr,
	NULL,
};
ATTRIBUTE_GROUPS(dtbo);

static struct miscdevice dtbo_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "dtbo",
	.fops = &dtbo_fops,
	.groups = dtbo_groups,
};
module_misc_device(dtbo_misc);

MODULE_DESCRIPTION("Apply device-tree overlays from userspace (test kit)");
MODULE_LICENSE("GPL");
