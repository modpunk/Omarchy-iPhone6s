// SPDX-License-Identifier: GPL-2.0
/*
 * bt6s_recon_v1: READ-ONLY look at the iPhone 6s Bluetooth power/pin state.
 *  - D2255 PMU (i2c0 0x74) GPIO config regs 0x900 + 2*n (n = 0..20), decoded
 *    from AppleD2255PMU::_setGPIOFunction; input status 0x186 + n/8.
 *    BT power_enable = PMU GPIO 8 (0x910), WLAN reg_on = PMU GPIO 10 (0x914).
 *  - AP GPIO pin config words for uart1 pins 24..27 and bt_wake 71.
 * No writes anywhere.
 */
#include <linux/module.h>
#include <linux/i2c.h>
#include <linux/regmap.h>
#include <linux/io.h>

#define PFX "bt6s_recon_v1: "

static int __init recon_init(void)
{
	static const int pins[] = { 24, 25, 26, 27, 71, 107 };
	struct device *dev;
	struct regmap *map;
	void __iomem *g;
	unsigned int v, r;
	int i, ret;

	g = ioremap(0x20f100000ULL, 0x1000);
	if (g) {
		for (i = 0; i < ARRAY_SIZE(pins); i++)
			pr_info(PFX "apgpio pin %3d cfg=%08x\n", pins[i], readl(g + pins[i] * 4));
		iounmap(g);
	}

	dev = bus_find_device_by_name(&i2c_bus_type, NULL, "0-0074");
	if (!dev) {
		pr_err(PFX "no 0-0074\n");
		return 0;
	}
	map = dev_get_regmap(dev, NULL);
	if (!map) {
		pr_err(PFX "no regmap on 0-0074\n");
		goto out;
	}
	for (r = 0x900; r < 0x92a; r++) {
		ret = regmap_read(map, r, &v);
		pr_info(PFX "pmu[%04x] = %02x (%d)\n", r, ret ? 0 : v, ret);
	}
	for (r = 0x186; r < 0x189; r++) {
		ret = regmap_read(map, r, &v);
		pr_info(PFX "pmu[%04x] = %02x (%d)\n", r, ret ? 0 : v, ret);
	}
out:
	put_device(dev);
	return 0;
}
module_init(recon_init);
MODULE_DESCRIPTION("iPhone 6s BT read-only recon");
MODULE_LICENSE("GPL");
