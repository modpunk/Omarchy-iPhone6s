// SPDX-License-Identifier: GPL-2.0
/*
 * tz2probe_v1: read-only-ish liveness probe for the iPhone 6s multitouch
 * controller (ADT /arm-io/spi2/multi-touch, iOS class AppleMultitouchN1SPI,
 * Z2Compliant). Mirrors what iOS AppleMultitouchZ2SPI does before it loads
 * firmware:
 *   - "ensuring S_CLK is high": 16 byte dummy transfer 1a a1 18 e1 x7
 *   - deassert reset, wait reset-deassert-delay (15 ms)
 *   - "checking if in HBPP": same 16 byte transfer, response words 0/1
 *     (big endian) must be HBPP codes 0x18e1/0x1aa1/0x1f01/0x4879/0x4969/
 *     0x4ad1/0x4bc1
 *   - "performing HBPP ATN_ACK": send 1a a1, read 2 bytes
 * No firmware is sent and nothing is written to the device's memory. Reset
 * is re-asserted at the end unless leave_on=1.
 */
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/spi/spi.h>
#include <linux/unaligned.h>

static bool leave_on;
module_param(leave_on, bool, 0444);

static const u16 hbpp_codes[] = { 0x18e1, 0x1aa1, 0x1f01, 0x4879, 0x4969,
				  0x4ad1, 0x4bc1 };

static bool is_hbpp(u16 w)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(hbpp_codes); i++)
		if (hbpp_codes[i] == w)
			return true;
	return false;
}

static int xfer(struct spi_device *spi, const u8 *tx, u8 *rx, int len)
{
	struct spi_transfer t = { .tx_buf = tx, .rx_buf = rx, .len = len };

	return spi_sync_transfer(spi, &t, 1);
}

static void check_pkt(u8 *tx)
{
	int i;

	tx[0] = 0x1a;
	tx[1] = 0xa1;
	for (i = 2; i < 16; i += 2) {
		tx[i] = 0x18;
		tx[i + 1] = 0xe1;
	}
}

/* HBPP MemRead (1c 73 addr cksum) + long ATN (1a a1 18 e1 x3); value in rx[2..5] */
static int hbpp_read(struct spi_device *spi, u8 *tx, u8 *rx, u32 addr, u32 *val)
{
	int ret, i;
	u16 sum = 0;

	tx[0] = 0x1c; tx[1] = 0x73;
	put_unaligned_be16(addr & 0xffff, tx + 2);
	put_unaligned_be16(addr >> 16, tx + 4);
	for (i = 2; i < 6; i++)
		sum += tx[i];
	put_unaligned_be16(sum, tx + 6);
	ret = xfer(spi, tx, rx, 8);
	if (ret)
		return ret;
	tx[0] = 0x1a; tx[1] = 0xa1;
	for (i = 2; i < 8; i += 2) {
		tx[i] = 0x18;
		tx[i + 1] = 0xe1;
	}
	memset(rx, 0xaa, 8);
	ret = xfer(spi, tx, rx, 8);
	if (ret)
		return ret;
	pr_info("tz2probe: memread 0x%08x raw %*ph\n", addr, 8, rx);
	*val = get_unaligned_be16(rx + 2) | (get_unaligned_be16(rx + 4) << 16);
	return 0;
}

static int tz2_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	struct gpio_desc *reset, *irq;
	u8 *tx, *rx;
	ktime_t t0;
	s64 us;
	int ret, i, last, lvl;

	tx = devm_kzalloc(dev, 4096, GFP_KERNEL);
	rx = devm_kzalloc(dev, 4096, GFP_KERNEL);
	if (!tx || !rx)
		return -ENOMEM;

	spi->mode = SPI_MODE_3;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	dev_info(dev, "spi_setup mode3 %u Hz: %d\n", spi->max_speed_hz, ret);
	if (ret)
		return ret;

	/* Reset is active low and currently asserted by iBoot: keep it so. */
	reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(reset))
		return dev_err_probe(dev, PTR_ERR(reset), "reset gpio\n");
	irq = devm_gpiod_get(dev, "irq", GPIOD_IN);
	if (IS_ERR(irq))
		return dev_err_probe(dev, PTR_ERR(irq), "irq gpio\n");
	dev_info(dev, "in reset: irq line raw=%d\n", gpiod_get_raw_value(irq));

	/* Bus timing: 1024 bytes of 0xff while the device is held in reset. */
	memset(tx, 0xff, 1024);
	t0 = ktime_get();
	ret = xfer(spi, tx, rx, 1024);
	us = ktime_us_delta(ktime_get(), t0);
	dev_info(dev, "1024B xfer: %d in %lld us (~%lld kHz SCK incl. overhead)\n",
		 ret, us, us ? 8192000LL / us : 0);
	dev_info(dev, "rx while in reset: %*ph\n", 16, rx);

	/* "ensuring S_CLK is high" */
	check_pkt(tx);
	ret = xfer(spi, tx, rx, 16);
	dev_info(dev, "dummy: %d rx %*ph\n", ret, 16, rx);

	/* Deassert reset, watch the irq line for 50 ms */
	gpiod_set_value(reset, 0);
	last = gpiod_get_raw_value(irq);
	dev_info(dev, "reset deasserted, irq raw=%d\n", last);
	for (i = 0; i < 500; i++) {
		udelay(100);
		lvl = gpiod_get_raw_value(irq);
		if (lvl != last) {
			dev_info(dev, "irq -> %d at %d us\n", lvl, (i + 1) * 100);
			last = lvl;
		}
	}

	for (i = 0; i < 3; i++) {
		check_pkt(tx);
		memset(rx, 0xaa, 16);
		ret = xfer(spi, tx, rx, 16);
		dev_info(dev, "HBPP check %d: %d rx %*ph -> %s (irq raw=%d)\n",
			 i, ret, 16, rx,
			 is_hbpp(get_unaligned_be16(rx)) &&
			 is_hbpp(get_unaligned_be16(rx + 2)) ? "IN HBPP" : "no",
			 gpiod_get_raw_value(irq));
		msleep(5);
	}

	tx[0] = 0x1a;
	tx[1] = 0xa1;
	memset(rx, 0xaa, 2);
	ret = xfer(spi, tx, rx, 2);
	dev_info(dev, "ATN_ACK: %d rx %*ph (irq raw=%d)\n", ret, 2, rx,
		 gpiod_get_raw_value(irq));

	/* Read-only bootloader register reads (iOS N1 performCalibSeq) */
	{
		u32 v = 0;

		ret = hbpp_read(spi, tx, rx, 0x10008ffc, &v);
		dev_info(dev, "N1 version reg 0x10008ffc: %d -> 0x%08x\n", ret, v);
		ret = hbpp_read(spi, tx, rx, 0x10003800, &v);
		dev_info(dev, "SPI_APU_EN 0x10003800: %d -> 0x%08x\n", ret, v);
	}

	if (!leave_on) {
		gpiod_set_value(reset, 1);
		dev_info(dev, "reset re-asserted\n");
	}
	return 0;
}

static const struct of_device_id tz2_of[] = {
	{ .compatible = "hoolock,z2probe-v1" },
	{ }
};
MODULE_DEVICE_TABLE(of, tz2_of);

static const struct spi_device_id tz2_id[] = {
	{ "z2probe-v1" },
	{ }
};
MODULE_DEVICE_TABLE(spi, tz2_id);

static struct spi_driver tz2_driver = {
	.driver = { .name = "tz2probe-v1", .of_match_table = tz2_of },
	.id_table = tz2_id,
	.probe = tz2_probe,
};
module_spi_driver(tz2_driver);
MODULE_LICENSE("GPL");
