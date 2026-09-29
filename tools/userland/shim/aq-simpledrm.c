/*
 * aq-simpledrm.so: LD_PRELOAD shim for Hyprland on simpledrm (no render node).
 *
 * aquamarine 0.15 wants an EGL "device platform" renderer on every DRM GPU it
 * drives. Mesa exposes no EGL device for a KMS-only node (only the software
 * device, which has no DRM file), so CDRMRenderer::attempt fails, and since
 * CDRMOutput::commitState calls updateSecondaryRendererState -> initMgpu()
 * again on every commit, each frame reopens the DRM node, creates a new GBM
 * device and fails again: ~100 ms of CPU and 7 log lines per frame on the 6s.
 * Hyprland itself renders fine through EGL on GBM (kms_swrast), so the
 * renderer isn't needed. aquamarine already skips it for evdi (KMS without
 * an EGL renderer): this shim reports simpledrm as "evdi" to drmGetVersion()
 * calls made from libaquamarine only. Nothing else sees the change.
 *
 * Proper fix (upstream): in aquamarine src/backend/drm/DRM.cpp, treat
 * simpledrm like evdi (rendererRequired = false).
 *
 * Built without libc headers (the phone rootfs has /usr/include stripped):
 *   clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib \
 *         -fuse-ld=lld -o aq-simpledrm.so aq-simpledrm.c $ROOT/usr/lib/libc.so.6
 */
typedef unsigned long size_t;

typedef struct {
	int version_major, version_minor, version_patchlevel;
	int name_len;
	char *name;
	int date_len;
	char *date;
	int desc_len;
	char *desc;
} drmVersion; /* libdrm xf86drm.h _drmVersion */

typedef struct {
	const char *dli_fname;
	void *dli_fbase;
	const char *dli_sname;
	void *dli_saddr;
} Dl_info;

#define RTLD_NEXT ((void *)-1l)

extern void *dlsym(void *, const char *);
extern int dladdr(const void *, Dl_info *);
extern void *malloc(size_t);
extern void free(void *);
extern int strcmp(const char *, const char *);
extern char *strstr(const char *, const char *);

static int from_aquamarine(const void *ra)
{
	Dl_info i;
	return dladdr(ra, &i) && i.dli_fname && strstr(i.dli_fname, "libaquamarine");
}

__attribute__((visibility("default"))) drmVersion *drmGetVersion(int fd)
{
	static drmVersion *(*real)(int);
	drmVersion *v;
	char *n;

	if (!real)
		real = (drmVersion * (*)(int)) dlsym(RTLD_NEXT, "drmGetVersion");
	if (!real)
		return 0;
	v = real(fd);
	if (v && v->name && !strcmp(v->name, "simpledrm") &&
	    from_aquamarine(__builtin_return_address(0)) && (n = malloc(5))) {
		n[0] = 'e'; n[1] = 'v'; n[2] = 'd'; n[3] = 'i'; n[4] = 0;
		free(v->name); /* drmFreeVersion() frees name with free() */
		v->name = n;
		v->name_len = 4;
	}
	return v;
}
