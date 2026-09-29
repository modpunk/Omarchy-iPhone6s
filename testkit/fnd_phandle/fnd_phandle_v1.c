// SPDX-License-Identifier: GPL-2.0
/*
 * One-shot test helper for the iPhone 6s live-overlay workflow.
 *
 * The running DT has no __symbols__, and dtc only emits a phandle for nodes
 * that something references. ps_uart1..6 and ps_spi1..3 are unreferenced, so
 * overlays cannot point power-domains at them. This gives each of those PMGR
 * power-controller nodes a deterministic phandle,
 *     0xf000 + (pmgr_offset - 0x80000) / 8
 * (uart1 0xf03c, uart3 0xf03e, uart4 0xf03f, uart5 0xf040, uart6 0xf041,
 *  spi1 0xf038, spi2 0xf039, spi3 0xf03a), and a matching "phandle" property
 * so it shows up in /proc/device-tree. Nodes that already have a phandle, or
 * values already in use, are left alone. Touches only the in-memory DT.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/slab.h>

#define PMGR "/soc/power-management@20e000000/power-controller@"

static const unsigned int offs[] = {
	0x801c0, 0x801c8, 0x801d0,			/* spi1..3 */
	0x801e0, 0x801f0, 0x801f8, 0x80200, 0x80208,	/* uart1, 3..6 */
};

static int __init fnd_phandle_init(void)
{
	char path[96];
	int i;

	for (i = 0; i < ARRAY_SIZE(offs); i++) {
		phandle ph = 0xf000 + ((offs[i] - 0x80000) >> 3);
		struct device_node *np, *other;
		struct property *prop;
		__be32 *val;

		snprintf(path, sizeof(path), PMGR "%x", offs[i]);
		np = of_find_node_by_path(path);
		if (!np) {
			pr_info("fnd_phandle: %s: no node\n", path);
			continue;
		}
		if (np->phandle) {
			pr_info("fnd_phandle: %pOF already has phandle 0x%x\n", np, np->phandle);
			goto put;
		}
		other = of_find_node_by_phandle(ph);
		if (other) {
			pr_warn("fnd_phandle: 0x%x already used by %pOF, skipping %pOF\n", ph, other, np);
			of_node_put(other);
			goto put;
		}

		prop = kzalloc(sizeof(*prop) + sizeof(*val), GFP_KERNEL);
		if (!prop)
			goto put;
		val = (__be32 *)(prop + 1);
		*val = cpu_to_be32(ph);
		prop->name = kstrdup("phandle", GFP_KERNEL);
		prop->length = sizeof(*val);
		prop->value = val;

		np->phandle = ph;
		if (of_add_property(np, prop))
			pr_warn("fnd_phandle: %pOF: could not add phandle property\n", np);
		pr_info("fnd_phandle: %pOF (%s) -> phandle 0x%x\n", np,
			of_get_property(np, "label", NULL) ?: "?", ph);
put:
		of_node_put(np);
	}
	return 0;
}
module_init(fnd_phandle_init);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("iPhone 6s testkit: give unreferenced PMGR domains phandles");
