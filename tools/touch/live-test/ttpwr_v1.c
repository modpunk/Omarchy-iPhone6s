// SPDX-License-Identifier: GPL-2.0
/*
 * ttpwr_v1: iPhone 6s touch bring-up helper (live test only).
 *  1. Power on the spi2 PMGR domain (ps_spi2 @0x801c8 has no phandle in the
 *     running DT, so the overlay cannot reference it). Held forever.
 *  2. READ-ONLY report of the touch power rails:
 *       D2255 PMU ldo26 (ADT function-power_ldo, AppleD2255PMU LDO table
 *       index 0x19): enable register 0x319 bit0
 *       Chestnut display PMU (i2c0 0x27, function-power_ana select 2):
 *       register 0x05 bit4
 *  Writes nothing to any PMIC.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/i2c.h>
#include <linux/regmap.h>
#include <linux/pm_domain.h>
#include <linux/pm_runtime.h>

#define PFX "ttpwr_v1: "
#define PD_SPI2 "/soc/power-management@20e000000/power-controller@801c8"

static void vdev_release(struct device *dev) { }

static int spi2_domain_on(void)
{
	struct of_phandle_args args = { .args_count = 0 };
	struct device *vdev;
	int ret;

	args.np = of_find_node_by_path(PD_SPI2);
	if (!args.np)
		return -ENODEV;
	vdev = kzalloc(sizeof(*vdev), GFP_KERNEL);
	if (!vdev)
		return -ENOMEM;
	device_initialize(vdev);
	vdev->release = vdev_release;
	dev_set_name(vdev, "ttpwr_v1_spi2pd");
	ret = device_add(vdev);
	if (ret)
		return ret;
	ret = of_genpd_add_device(&args, vdev);
	if (ret)
		return ret;
	pm_runtime_enable(vdev);
	return pm_runtime_resume_and_get(vdev);
}

static int __init ttpwr_init(void)
{
	struct i2c_adapter *adap;
	struct i2c_client *cn;
	struct device *dev;
	struct regmap *map;
	unsigned int v = 0;
	int ret;

	ret = spi2_domain_on();
	pr_info(PFX "spi2 domain on: %d\n", ret);

	dev = bus_find_device_by_name(&i2c_bus_type, NULL, "0-0074");
	if (dev) {
		map = dev_get_regmap(dev, NULL);
		if (map) {
			ret = regmap_read(map, 0x319, &v);
			pr_info(PFX "d2255[0x319] (touch ldo26 en) = %02x (%d)\n", v, ret);
			ret = regmap_read(map, 0x318, &v);
			pr_info(PFX "d2255[0x318] (ldo25 en) = %02x (%d)\n", v, ret);
		}
		put_device(dev);
	}

	adap = i2c_get_adapter(0);
	if (adap) {
		cn = i2c_new_dummy_device(adap, 0x27);
		if (!IS_ERR(cn)) {
			ret = i2c_smbus_read_byte_data(cn, 0x05);
			pr_info(PFX "chestnut[0x05] (bit4 = touch ana) = %02x\n", ret);
			i2c_unregister_device(cn);
		} else {
			pr_info(PFX "chestnut dummy client: %ld\n", PTR_ERR(cn));
		}
		i2c_put_adapter(adap);
	}
	return 0;
}
module_init(ttpwr_init);
MODULE_DESCRIPTION("iPhone 6s touch live-test power probe");
MODULE_LICENSE("GPL");
