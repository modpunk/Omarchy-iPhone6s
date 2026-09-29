// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Apple I2C PMIC GPIO driver
 *
 * The Dialog-designed PMICs found on Apple A7-A10X SoCs have a bank of
 * general purpose pins that iOS uses for things like the Bluetooth and
 * WLAN power enables (REG_ON), baseband power and several wake inputs.
 *
 * On "Antigua" (Dialog D2255, Apple A9) every pin n has a configuration
 * register at 0x900 + 2 * n. Configuration values with any of bits 7:6 set
 * are outputs and bit 0 is then the output level (0x80 = push-pull output,
 * low; 0x81 = high). The pad level of every pin can be read back from the
 * status registers at 0x186 + n / 8, bit n % 8.
 *
 * The rest of the configuration encoding (pulls, wake/IRQ modes, what bits
 * 3 and 4 do) is not known, so this driver deliberately never changes the
 * mode of a pin: it only drives pins that the boot firmware already set up
 * as outputs and only reads the others. That is enough for the consumers
 * we care about (e.g. hci_bcm "shutdown-gpios").
 *
 * Register layout recovered from the AppleD2255PMU kext in the iOS 15.8.8
 * kernelcache (_setGPIOFunction / _getGPIOFunction) and verified by reading
 * the registers on an iPhone 6s.
 */

#include <linux/bits.h>
#include <linux/gpio/driver.h>
#include <linux/i2c.h>
#include <linux/of.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/regmap.h>

#define APPLE_PMIC_GPIO_CFG_OUT_MASK	GENMASK(7, 6)
#define APPLE_PMIC_GPIO_CFG_LEVEL	BIT(0)

struct apple_pmic_gpio_hw {
	unsigned int cfg_base;
	unsigned int cfg_stride;
	unsigned int status_base;
	unsigned int ngpio;
};

struct apple_pmic_gpio {
	struct gpio_chip gc;
	struct regmap *map;
	const struct apple_pmic_gpio_hw *hw;
};

static unsigned int apple_pmic_gpio_cfg_reg(struct apple_pmic_gpio *pg,
					    unsigned int offset)
{
	return pg->hw->cfg_base + offset * pg->hw->cfg_stride;
}

static int apple_pmic_gpio_read_cfg(struct apple_pmic_gpio *pg,
				    unsigned int offset, unsigned int *cfg)
{
	return regmap_read(pg->map, apple_pmic_gpio_cfg_reg(pg, offset), cfg);
}

static int apple_pmic_gpio_get_direction(struct gpio_chip *gc,
					 unsigned int offset)
{
	struct apple_pmic_gpio *pg = gpiochip_get_data(gc);
	unsigned int cfg;
	int ret;

	ret = apple_pmic_gpio_read_cfg(pg, offset, &cfg);
	if (ret)
		return ret;

	return (cfg & APPLE_PMIC_GPIO_CFG_OUT_MASK) ? GPIO_LINE_DIRECTION_OUT :
						     GPIO_LINE_DIRECTION_IN;
}

static int apple_pmic_gpio_get(struct gpio_chip *gc, unsigned int offset)
{
	struct apple_pmic_gpio *pg = gpiochip_get_data(gc);
	unsigned int cfg, val;
	int ret;

	ret = apple_pmic_gpio_read_cfg(pg, offset, &cfg);
	if (ret)
		return ret;

	if (cfg & APPLE_PMIC_GPIO_CFG_OUT_MASK)
		return !!(cfg & APPLE_PMIC_GPIO_CFG_LEVEL);

	ret = regmap_read(pg->map, pg->hw->status_base + offset / 8, &val);
	if (ret)
		return ret;

	return !!(val & BIT(offset % 8));
}

static int apple_pmic_gpio_set(struct gpio_chip *gc, unsigned int offset,
			       int value)
{
	struct apple_pmic_gpio *pg = gpiochip_get_data(gc);

	if (apple_pmic_gpio_get_direction(gc, offset) != GPIO_LINE_DIRECTION_OUT)
		return -EOPNOTSUPP;

	return regmap_update_bits(pg->map, apple_pmic_gpio_cfg_reg(pg, offset),
				  APPLE_PMIC_GPIO_CFG_LEVEL,
				  value ? APPLE_PMIC_GPIO_CFG_LEVEL : 0);
}

static int apple_pmic_gpio_direction_output(struct gpio_chip *gc,
					    unsigned int offset, int value)
{
	/* Only pins the firmware configured as outputs can be driven. */
	return apple_pmic_gpio_set(gc, offset, value);
}

static int apple_pmic_gpio_direction_input(struct gpio_chip *gc,
					   unsigned int offset)
{
	int dir = apple_pmic_gpio_get_direction(gc, offset);

	if (dir < 0)
		return dir;

	return dir == GPIO_LINE_DIRECTION_IN ? 0 : -EOPNOTSUPP;
}

static int apple_pmic_gpio_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct apple_pmic_gpio *pg;

	pg = devm_kzalloc(dev, sizeof(*pg), GFP_KERNEL);
	if (!pg)
		return -ENOMEM;

	pg->hw = device_get_match_data(dev);
	if (!pg->hw)
		return -ENODEV;

	/*
	 * t1 live-test only: a node added by an overlay under the I2C PMIC gets
	 * no parent device (the PMIC is an i2c_client, not a platform device),
	 * so find the PMIC through the OF parent instead.
	 */
	if (dev->parent) {
		pg->map = dev_get_regmap(dev->parent, NULL);
	} else {
		struct device_node *pnp = of_get_parent(dev->of_node);
		struct i2c_client *client = pnp ? of_find_i2c_device_by_node(pnp) : NULL;

		of_node_put(pnp);
		if (client) {
			pg->map = dev_get_regmap(&client->dev, NULL);
			/* keep the client reference: this module never unloads */
		}
	}
	if (!pg->map)
		return dev_err_probe(dev, -ENODEV, "parent has no regmap\n");

	pg->gc.label = dev_name(dev);
	pg->gc.parent = dev;
	pg->gc.owner = THIS_MODULE;
	pg->gc.base = -1;
	pg->gc.ngpio = pg->hw->ngpio;
	pg->gc.can_sleep = true;
	pg->gc.get_direction = apple_pmic_gpio_get_direction;
	pg->gc.direction_input = apple_pmic_gpio_direction_input;
	pg->gc.direction_output = apple_pmic_gpio_direction_output;
	pg->gc.get = apple_pmic_gpio_get;
	pg->gc.set = apple_pmic_gpio_set;

	return devm_gpiochip_add_data(dev, &pg->gc, pg);
}

static const struct apple_pmic_gpio_hw apple_antigua_pmic_gpio_hw = {
	.cfg_base = 0x900,
	.cfg_stride = 2,
	.status_base = 0x186,
	.ngpio = 17,
};

static const struct of_device_id apple_pmic_gpio_of_match[] = {
	{ .compatible = "apple,antigua-pmic-gpio", .data = &apple_antigua_pmic_gpio_hw },
	{ }
};
MODULE_DEVICE_TABLE(of, apple_pmic_gpio_of_match);

static struct platform_driver apple_pmic_gpio_driver = {
	.driver = {
		.name = "apple-pmic-gpio-t1",
		.of_match_table = apple_pmic_gpio_of_match,
	},
	.probe = apple_pmic_gpio_probe,
};
module_platform_driver(apple_pmic_gpio_driver);

MODULE_DESCRIPTION("Apple I2C PMIC GPIO driver");
MODULE_LICENSE("Dual MIT/GPL");
