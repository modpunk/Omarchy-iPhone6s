// SPDX-License-Identifier: GPL-2.0
/* Read-only dump of the AP GPIO pin config registers (6s touch bring-up). */
#include <linux/module.h>
#include <linux/io.h>
static int __init tpd_init(void)
{
	void __iomem *b = ioremap(0x20f100000ULL, 0x1000);
	int i;
	char line[160];
	int n = 0;
	if (!b)
		return -ENOMEM;
	for (i = 0; i < 208; i++) {
		u32 v = readl(b + 4 * i);
		n += scnprintf(line + n, sizeof(line) - n, " %3d:%08x", i, v);
		if ((i & 7) == 7) { pr_info("tpd%s\n", line); n = 0; }
	}
	iounmap(b);
	return 0;
}
module_init(tpd_init);
MODULE_LICENSE("GPL");
