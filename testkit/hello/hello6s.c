// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
static int __init hello_init(void) { pr_info("hello6s: vermagic ok\n"); return 0; }
module_init(hello_init);
MODULE_LICENSE("GPL");
