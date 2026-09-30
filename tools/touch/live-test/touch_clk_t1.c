// SPDX-License-Identifier: GPL-2.0
/*
 * touch_clk_t1: iPhone 6s touch reference clock (TCLK, 32.768 kHz) probe.
 *
 * Default (no parameters): READ-ONLY. Prints
 *   - PMGR 0x2_0e07_8000 / +4, decoded with the A10 touch-clock layout from
 *     Corellium's GPL clk-hx-pmgr.c (bit31 DISABLE, bit19 ENABLE, bit18 BUSY,
 *     bits 9:0 divider from 24 MHz). The address is inside the Apple DT
 *     pmgr reg[0] range (0x2_0e00_0000 + 0x100000). A9 placement unconfirmed.
 *   - D2255 0x219 / 0x319 (touch core switch), Chestnut 0x05 (touch analog)
 *   - AP pads 41-44 (SPI), 75 (reset), 142 (irq)
 *
 * enable=1 expect=0xXXXXXXXX: the ONE write, once approved. Done only if the
 * register still reads exactly `expect` AND that value fits the layout
 * (DISABLE set, ENABLE clear, no unknown bits). Sequence (as on A10):
 *   w1: expect & ~DISABLE
 *   w2: (w1 & ~DIV) | ENABLE | div   (div = 732: 24 MHz / 732 = 32787 Hz)
 *   poll BUSY clear (<= 50 ms), read back, print.
 * The clock is left running (the HBPP check needs it).
 *
 * restore=1 expect=<original value>: clears ENABLE, waits for BUSY, then
 * writes the original value back (only if ENABLE is currently set and
 * neither value has unknown bits).
 *
 * init always returns -ECANCELED so the same name can be loaded again.
 */
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/regmap.h>

#define PFX "touch_clk_t1: "
#define TCLK_PHYS	0x20e078000ULL
#define PINCTRL_AP	0x20f100000ULL

#define TCLK_DISABLE	BIT(31)
#define TCLK_ENABLE	BIT(19)
#define TCLK_BUSY	BIT(18)
#define TCLK_DIV	GENMASK(9, 0)
#define TCLK_KNOWN	(TCLK_DISABLE | TCLK_ENABLE | TCLK_BUSY | TCLK_DIV)

static bool enable;
module_param(enable, bool, 0444);
static bool restore;
module_param(restore, bool, 0444);
static uint expect;
module_param(expect, uint, 0444);
static uint div = 732;
module_param(div, uint, 0444);

static void decode(const char *tag, u32 v)
{
	unsigned long d = FIELD_GET(TCLK_DIV, v);

	pr_info(PFX "%-8s %08x: disable %u enable %u busy %u div %lu (%lu Hz from 24 MHz) unknown-bits %08lx\n",
		tag, v, !!(v & TCLK_DISABLE), !!(v & TCLK_ENABLE),
		!!(v & TCLK_BUSY), d, d ? 24000000UL / d : 0,
		(unsigned long)(v & ~TCLK_KNOWN));
}

static void power_regs(void)
{
	struct i2c_adapter *adap;
	struct device *dev;
	unsigned int a = 0xee, b = 0xee;

	dev = bus_find_device_by_name(&i2c_bus_type, NULL, "0-0074");
	if (dev) {
		struct regmap *map = dev_get_regmap(dev, NULL);

		if (map) {
			regmap_read(map, 0x219, &a);
			regmap_read(map, 0x319, &b);
		}
		put_device(dev);
	}
	pr_info(PFX "d2255 [0x219]=%02x [0x319]=%02x\n", a, b);

	adap = i2c_get_adapter(0);
	if (adap) {
		struct i2c_client *cn = i2c_new_dummy_device(adap, 0x27);

		if (!IS_ERR(cn)) {
			pr_info(PFX "chestnut [0x05]=%02x\n",
				i2c_smbus_read_byte_data(cn, 0x05) & 0xff);
			i2c_unregister_device(cn);
		}
		i2c_put_adapter(adap);
	}
}

static void pads(void)
{
	static const int pins[] = { 41, 42, 43, 44, 75, 142 };
	void __iomem *g = ioremap(PINCTRL_AP, 0x1000);
	char buf[128];
	int i, n = 0;

	if (!g)
		return;
	for (i = 0; i < ARRAY_SIZE(pins); i++) {
		u32 v = readl(g + 4 * pins[i]);

		n += scnprintf(buf + n, sizeof(buf) - n, " %d:%08x/%u",
			       pins[i], v, v & 1);
	}
	iounmap(g);
	pr_info(PFX "pads%s\n", buf);
}

static bool fits_idle(u32 v)
{
	return !(v & ~TCLK_KNOWN) && (v & TCLK_DISABLE) && !(v & TCLK_ENABLE);
}

static void wait_idle(void __iomem *r)
{
	int i;

	for (i = 0; i < 5000 && (readl(r) & TCLK_BUSY); i++)
		udelay(10);
	if (i == 5000)
		pr_err(PFX "BUSY did not clear\n");
}

static int __init t1_init(void)
{
	void __iomem *r = ioremap(TCLK_PHYS, 8);
	u32 v, w;

	if (!r)
		return -ENOMEM;

	v = readl(r);
	decode("tclk", v);
	pr_info(PFX "tclk+4   %08x\n", readl(r + 4));
	power_regs();
	pads();

	if (enable && restore) {
		pr_err(PFX "enable and restore are exclusive\n");
	} else if (enable) {
		if (v != expect || !fits_idle(v) || !div || div > 1023) {
			pr_err(PFX "REFUSED: read %08x, expect %08x, fits_idle %d, div %u\n",
			       v, expect, fits_idle(v), div);
		} else {
			w = v & ~TCLK_DISABLE;
			writel(w, r);
			pr_info(PFX "WRITE 1  %08x -> read %08x\n", w, readl(r));
			w = (w & ~TCLK_DIV) | TCLK_ENABLE | FIELD_PREP(TCLK_DIV, div);
			writel(w, r);
			pr_info(PFX "WRITE 2  %08x\n", w);
			wait_idle(r);
			decode("after", readl(r));
			msleep(5);
			pads();
		}
	} else if (restore) {
		if (!(v & TCLK_ENABLE) || (v & ~TCLK_KNOWN) || (expect & ~TCLK_KNOWN)) {
			pr_err(PFX "REFUSED restore: read %08x, restore %08x\n", v, expect);
		} else {
			writel(v & ~TCLK_ENABLE, r);
			wait_idle(r);
			writel(expect, r);
			decode("restored", readl(r));
		}
	}

	iounmap(r);
	pr_info(PFX "done (returning -ECANCELED so the name can be reused)\n");
	return -ECANCELED;
}
module_init(t1_init);
MODULE_DESCRIPTION("iPhone 6s touch reference clock probe");
MODULE_LICENSE("GPL");
