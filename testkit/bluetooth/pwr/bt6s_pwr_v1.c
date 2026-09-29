// SPDX-License-Identifier: GPL-2.0
/*
 * bt6s_pwr_v1: live-test helper for iPhone 6s Bluetooth bring-up.
 *  1. Power on the uart1 PMGR domain (virtual genpd consumer, held forever:
 *     the running DT has no phandle on ps_uart1, so an overlay can't
 *     reference it).
 *  2. Assert BT REG_ON: D2255 PMU GPIO 8 (ADT /arm-io/uart1/bluetooth
 *     function-power_enable = <pmu GPIO 8 0x101>). Config register is
 *     0x900 + 2*8 = 0x910 (AppleD2255PMU::_setGPIOFunction); bit0 is the
 *     output level, 0x80 = push-pull output low. Only writes if the register
 *     reads exactly 0x80 (the value seen by bt6s_recon_v1); otherwise aborts.
 * Touches nothing else on the PMU. WLAN reg_on (GPIO 10, 0x914) untouched.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/regmap.h>
#include <linux/pm_domain.h>
#include <linux/pm_runtime.h>

#define PFX "bt6s_pwr_v1: "
#define PD_UART1 "/soc/power-management@20e000000/power-controller@801e0"
#define PMU_GPIO8_CFG 0x910

static void vdev_release(struct device *dev) { }

static int uart1_domain_on(void)
{
	struct of_phandle_args args = { .args_count = 0 };
	struct device *vdev;
	int ret;

	args.np = of_find_node_by_path(PD_UART1);
	if (!args.np)
		return -ENODEV;
	vdev = kzalloc(sizeof(*vdev), GFP_KERNEL);
	if (!vdev)
		return -ENOMEM;
	device_initialize(vdev);
	vdev->release = vdev_release;
	dev_set_name(vdev, "bt6s_pwr_v1_uart1pd");
	ret = device_add(vdev);
	if (ret)
		return ret;
	ret = of_genpd_add_device(&args, vdev);
	if (ret)
		return ret;
	pm_runtime_enable(vdev);
	return pm_runtime_resume_and_get(vdev);
}

static int __init pwr_init(void)
{
	struct device *dev;
	struct regmap *map;
	unsigned int v = 0, v2 = 0;
	int ret;

	ret = uart1_domain_on();
	pr_info(PFX "uart1 domain on: %d\n", ret);
	if (ret)
		return 0;

	dev = bus_find_device_by_name(&i2c_bus_type, NULL, "0-0074");
	if (!dev)
		return 0;
	map = dev_get_regmap(dev, NULL);
	if (!map)
		goto out;
	ret = regmap_read(map, PMU_GPIO8_CFG, &v);
	pr_info(PFX "pmu[0x910] before = %02x (%d)\n", v, ret);
	if (ret || v != 0x80) {
		pr_err(PFX "unexpected value, NOT writing\n");
		goto out;
	}
	ret = regmap_write(map, PMU_GPIO8_CFG, 0x81);
	msleep(50);
	regmap_read(map, PMU_GPIO8_CFG, &v2);
	regmap_read(map, 0x187, &v);
	pr_info(PFX "write %d; pmu[0x910] after = %02x, in[0x187] = %02x\n", ret, v2, v);
out:
	put_device(dev);
	return 0;
}
module_init(pwr_init);
MODULE_DESCRIPTION("iPhone 6s BT live-test power helper");
MODULE_LICENSE("GPL");
