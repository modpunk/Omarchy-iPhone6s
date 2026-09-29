/* Test-only LD_PRELOAD for check-rootfs.sh: sysconf(_SC_PAGESIZE) reports
 * 16 KiB, as on the phone's 16K kernel. qemu-user always runs the guest on
 * 4K pages, so this is how the laptop checks allocators that compare the page
 * size with a build-time constant (jemalloc: "Unsupported system page size").
 * PAGESIZE16K_VALUE overrides the value (a 128 KiB run is the positive control).
 * Never installed in the image. */
/* No libc headers: the host's are x86_64 (and clang refuses their __float128). */
#define _SC_PAGESIZE 30	/* glibc */
char *getenv(const char *);
long atol(const char *);
long __sysconf(int);
long sysconf(int name)
{
	if (name == _SC_PAGESIZE) {
		const char *v = getenv("PAGESIZE16K_VALUE");
		return v ? atol(v) : 16384;
	}
	return __sysconf(name);
}
