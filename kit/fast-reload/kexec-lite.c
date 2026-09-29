// SPDX-License-Identifier: GPL-2.0-only
/*
 * kexec-lite: minimal arm64 kexec loader for the iPhone 6s ramdisk.
 *
 * No libc, no kexec-tools: the laptop (kit/reload.sh) decides where every
 * segment goes and builds the final device tree; this tool only checks the
 * Image header, loads the segments with kexec_load(2) plus a 40-byte
 * purgatory that sets x0 = dtb and jumps to the kernel, and triggers the
 * reboot.
 *
 *   kexec-lite load KERNEL@ADDR INITRD@ADDR DTB@ADDR PURGATORY_ADDR
 *   kexec-lite exec          reboot(LINUX_REBOOT_CMD_KEXEC)
 *   kexec-lite unload
 *
 * Addresses are physical, hex (0x...). Every address must be 64 KiB aligned
 * (covers 4K/16K/64K kernels); the kernel address must also be 2 MiB aligned
 * after subtracting the Image text_offset (arm64 boot protocol).
 *
 * Build: kit/fast-reload/build.sh (clang, static, freestanding).
 */
typedef unsigned long u64;
typedef unsigned int u32;
typedef long s64;

#define SZ_64K		0x10000UL
#define SZ_2M		0x200000UL
#define ALIGN_UP(x, a)	(((x) + (a) - 1) & ~((a) - 1))

#define __NR_openat	56
#define __NR_close	57
#define __NR_lseek	62
#define __NR_read	63
#define __NR_write	64
#define __NR_sync	81
#define __NR_exit	93
#define __NR_kexec_load	104
#define __NR_reboot	142
#define __NR_mmap	222

#define AT_FDCWD	-100
#define O_RDONLY	0
#define SEEK_SET	0
#define SEEK_END	2
#define PROT_RW		3
#define MAP_PRIV_ANON	0x22

#define LINUX_REBOOT_MAGIC1	0xfee1deadUL
#define LINUX_REBOOT_MAGIC2	672274793UL
#define LINUX_REBOOT_CMD_KEXEC	0x45584543UL

struct kexec_segment {
	const void *buf;
	u64 bufsz;
	u64 mem;
	u64 memsz;
};

static s64 sys6(s64 n, s64 a, s64 b, s64 c, s64 d, s64 e, s64 f)
{
	register s64 x8 __asm__("x8") = n;
	register s64 x0 __asm__("x0") = a;
	register s64 x1 __asm__("x1") = b;
	register s64 x2 __asm__("x2") = c;
	register s64 x3 __asm__("x3") = d;
	register s64 x4 __asm__("x4") = e;
	register s64 x5 __asm__("x5") = f;

	__asm__ volatile("svc #0"
			 : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
			 : "memory");
	return x0;
}
#define sys(n, a, b, c, d) sys6(n, (s64)(a), (s64)(b), (s64)(c), (s64)(d), 0, 0)

void *memset(void *d, int c, u64 n)
{
	unsigned char *p = d;

	while (n--)
		*p++ = (unsigned char)c;
	return d;
}

void *memcpy(void *d, const void *s, u64 n)
{
	unsigned char *p = d;
	const unsigned char *q = s;

	while (n--)
		*p++ = *q++;
	return d;
}

static u64 slen(const char *s)
{
	u64 n = 0;

	while (s[n])
		n++;
	return n;
}

static void out(const char *s)
{
	sys(__NR_write, 2, s, slen(s), 0);
}

static void outhex(u64 v)
{
	char b[19];
	int i;

	b[0] = '0';
	b[1] = 'x';
	for (i = 0; i < 16; i++)
		b[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 0xf];
	b[18] = 0;
	out(b);
}

static __attribute__((noreturn)) void die(const char *msg, s64 err)
{
	out("kexec-lite: ");
	out(msg);
	if (err) {
		out(" (errno ");
		outhex((u64)-err);
		out(")");
	}
	out("\n");
	sys(__NR_exit, 1, 0, 0, 0);
	__builtin_unreachable();
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static u64 parse_hex(const char *s)
{
	u64 v = 0;

	if (s[0] != '0' || (s[1] != 'x' && s[1] != 'X'))
		die("address must be 0x-prefixed hex", 0);
	s += 2;
	if (!*s)
		die("empty address", 0);
	for (; *s; s++) {
		int c = *s, d;

		if (c >= '0' && c <= '9')
			d = c - '0';
		else if (c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			die("bad hex digit in address", 0);
		v = (v << 4) | (u64)d;
	}
	return v;
}

/* Split "path@0xaddr" in place. */
static const char *split_at(char *arg, u64 *addr)
{
	char *at = 0, *p;

	for (p = arg; *p; p++)
		if (*p == '@')
			at = p;
	if (!at)
		die("expected FILE@0xADDR", 0);
	*at = 0;
	*addr = parse_hex(at + 1);
	return arg;
}

static void *slurp(const char *path, u64 *size)
{
	s64 fd, n, len;
	u64 got = 0;
	char *buf;

	fd = sys6(__NR_openat, AT_FDCWD, (s64)path, O_RDONLY, 0, 0, 0);
	if (fd < 0) {
		out(path);
		out(": ");
		die("open failed", fd);
	}
	len = sys(__NR_lseek, fd, 0, SEEK_END, 0);
	if (len <= 0)
		die("empty or unseekable file", len);
	sys(__NR_lseek, fd, 0, SEEK_SET, 0);
	buf = (char *)sys6(__NR_mmap, 0, (s64)ALIGN_UP((u64)len, SZ_64K), PROT_RW,
			   MAP_PRIV_ANON, -1, 0);
	if ((s64)buf < 0 && (s64)buf > -4096)
		die("mmap failed", (s64)buf);
	while (got < (u64)len) {
		n = sys(__NR_read, fd, buf + got, (u64)len - got, 0);
		if (n <= 0)
			die("read failed", n);
		got += (u64)n;
	}
	sys(__NR_close, fd, 0, 0, 0);
	*size = (u64)len;
	return buf;
}

static void check_aligned(const char *what, u64 addr)
{
	if (addr & (SZ_64K - 1)) {
		out(what);
		out(" at ");
		outhex(addr);
		die(" is not 64 KiB aligned", 0);
	}
}

/*
 * purgatory: ldr x0, dtb; ldr x4, kernel; mov x1..x3, xzr; br x4
 * Entered with the MMU off at EL1 from arm64_relocate_new_kernel.
 */
static u32 purgatory[10] __attribute__((aligned(8))) = {
	0x580000c0,	/* ldr  x0, #24  (dtb)    */
	0x580000e4,	/* ldr  x4, #28  (kernel) */
	0xaa1f03e1,	/* mov  x1, xzr           */
	0xaa1f03e2,	/* mov  x2, xzr           */
	0xaa1f03e3,	/* mov  x3, xzr           */
	0xd61f0080,	/* br   x4                */
	0, 0,		/* .quad dtb              */
	0, 0,		/* .quad kernel           */
};

static int cmd_load(int argc, char **argv)
{
	static const char *names[] = { "kernel   ", "initrd   ", "dtb      ", "purgatory" };
	struct kexec_segment seg[4];
	u64 kaddr, iaddr, daddr, paddr, ksz, isz, dsz, text_off, image_size;
	const unsigned char *k, *d;
	const char *kf, *inf, *df;
	void *kbuf, *ibuf, *dbuf;
	s64 ret;
	int i, j;

	if (argc != 6)
		die("usage: load KERNEL@ADDR INITRD@ADDR DTB@ADDR PURGATORY_ADDR", 0);

	kf = split_at(argv[2], &kaddr);
	inf = split_at(argv[3], &iaddr);
	df = split_at(argv[4], &daddr);
	paddr = parse_hex(argv[5]);

	kbuf = slurp(kf, &ksz);
	ibuf = slurp(inf, &isz);
	dbuf = slurp(df, &dsz);

	/* arm64 Image header: text_offset @8, image_size @16, magic "ARM\x64" @56 */
	k = kbuf;
	if (ksz < 64 || k[56] != 'A' || k[57] != 'R' || k[58] != 'M' || k[59] != 0x64)
		die("kernel is not an arm64 Image (Image.gz must be gunzipped)", 0);
	text_off = *(const u64 *)(k + 8);
	image_size = *(const u64 *)(k + 16);
	if (!image_size)
		image_size = ksz;
	if ((kaddr - text_off) & (SZ_2M - 1))
		die("kernel address minus text_offset is not 2 MiB aligned", 0);

	d = dbuf;
	if (dsz < 40 || d[0] != 0xd0 || d[1] != 0x0d || d[2] != 0xfe || d[3] != 0xed)
		die("dtb has no FDT magic", 0);
	if (dsz > SZ_2M)
		die("dtb larger than 2 MiB", 0);

	check_aligned("kernel", kaddr);
	check_aligned("initrd", iaddr);
	check_aligned("dtb", daddr);
	check_aligned("purgatory", paddr);

	purgatory[6] = (u32)daddr;
	purgatory[7] = (u32)(daddr >> 32);
	purgatory[8] = (u32)kaddr;
	purgatory[9] = (u32)(kaddr >> 32);

	seg[0] = (struct kexec_segment){ kbuf, ksz, kaddr,
		ALIGN_UP(image_size > ksz ? image_size : ksz, SZ_64K) };
	seg[1] = (struct kexec_segment){ ibuf, isz, iaddr, ALIGN_UP(isz, SZ_64K) };
	seg[2] = (struct kexec_segment){ dbuf, dsz, daddr, ALIGN_UP(dsz, SZ_64K) };
	seg[3] = (struct kexec_segment){ purgatory, sizeof(purgatory), paddr, SZ_64K };

	for (i = 0; i < 4; i++)
		for (j = i + 1; j < 4; j++)
			if (seg[i].mem < seg[j].mem + seg[j].memsz &&
			    seg[j].mem < seg[i].mem + seg[i].memsz)
				die("segments overlap", 0);

	for (i = 0; i < 4; i++) {
		out(names[i]);
		out(" ");
		outhex(seg[i].mem);
		out(" + ");
		outhex(seg[i].memsz);
		out("\n");
	}

	/* Replace any image loaded before. */
	sys(__NR_kexec_load, 0, 0, 0, 0);
	ret = sys(__NR_kexec_load, paddr, 4, seg, 0);
	if (ret < 0)
		die("kexec_load failed (0x10 = EBUSY: CPUs stuck in the kernel, park patch missing?)",
		    ret);
	out("kexec-lite: loaded, entry ");
	outhex(paddr);
	out("\n");
	return 0;
}

int cmain(long *sp)
{
	int argc = (int)sp[0];
	char **argv = (char **)(sp + 1);
	s64 ret;

	if (argc >= 2 && streq(argv[1], "load"))
		return cmd_load(argc, argv);
	if (argc == 2 && streq(argv[1], "unload")) {
		ret = sys(__NR_kexec_load, 0, 0, 0, 0);
		if (ret < 0)
			die("unload failed", ret);
		return 0;
	}
	if (argc == 2 && streq(argv[1], "exec")) {
		sys(__NR_sync, 0, 0, 0, 0);
		ret = sys(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
			  LINUX_REBOOT_CMD_KEXEC, 0);
		die("reboot(KEXEC) returned: nothing loaded?", ret);
	}
	out("usage: kexec-lite load KERNEL@ADDR INITRD@ADDR DTB@ADDR PURGATORY_ADDR\n"
	    "       kexec-lite exec | unload\n");
	return 2;
}

__attribute__((naked, noreturn)) void _start(void)
{
	__asm__ volatile("mov x0, sp\n"
			 "bl cmain\n"
			 "mov x8, #93\n"
			 "svc #0\n");
}
