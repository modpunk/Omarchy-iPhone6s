// SPDX-License-Identifier: GPL-2.0
/*
 * Populate the fake PMIC subtrees from testkit/overlays/foundation-xlate.dtso exactly like
 * simple-mfd-i2c (of_platform_populate of the PMIC children) and
 * drivers/nvmem/layouts.c (of_device_make_bus_id on the nvmem-layout node),
 * log the resulting device names, then depopulate. Nothing binds "fnd,*",
 * so no hardware is touched.
 */
#include <linux/device.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

#define BUS "/soc/fnd-xlate-bus/"

static int child_name(struct device *dev, void *data)
{
	pr_info("fnd_xlate:   child device %s\n", dev_name(dev));
	return 0;
}

static void run(const char *pmic)
{
	struct device_node *np, *nv, *layout;
	struct platform_device *pdev;
	struct device *ld;
	char path[80];
	int ret;

	snprintf(path, sizeof(path), BUS "%s", pmic);
	np = of_find_node_by_path(path);
	if (!np) {
		pr_err("fnd_xlate: %s missing (overlay applied?)\n", path);
		return;
	}
	{
		u32 sc = 0;

		of_property_read_u32(np, "#size-cells", &sc);
		pr_info("fnd_xlate: ---- begin %pOF (#size-cells=%u) ----\n", np, sc);
	}

	/* Parent device standing in for the PMIC i2c client */
	pdev = platform_device_register_simple("fnd_xlate_parent", PLATFORM_DEVID_AUTO, NULL, 0);
	if (IS_ERR(pdev))
		goto out;
	ret = of_platform_populate(np, NULL, NULL, &pdev->dev);
	pr_info("fnd_xlate:   of_platform_populate = %d\n", ret);
	device_for_each_child(&pdev->dev, NULL, child_name);

	nv = of_get_child_by_name(np, "nvmem");
	layout = nv ? of_get_child_by_name(nv, "nvmem-layout") : NULL;
	ld = kzalloc(sizeof(*ld), GFP_KERNEL);
	if (layout && ld) {
		ld->of_node = layout;
		of_device_make_bus_id(ld);
		pr_info("fnd_xlate:   nvmem layout name %s\n", dev_name(ld));
		kfree_const(ld->kobj.name);
	}
	kfree(ld);
	of_node_put(layout);
	of_node_put(nv);

	of_platform_depopulate(&pdev->dev);
	platform_device_unregister(pdev);
out:
	pr_info("fnd_xlate: ---- end %pOF ----\n", np);
	of_node_put(np);
}

static int __init fnd_xlate_init(void)
{
	run("pmic@7e");	/* old: #size-cells = <1> */
	run("pmic@7f");	/* fixed: #size-cells = <0> */
	return 0;
}
module_init(fnd_xlate_init);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("iPhone 6s testkit: OF address translation repro for PMIC children");
