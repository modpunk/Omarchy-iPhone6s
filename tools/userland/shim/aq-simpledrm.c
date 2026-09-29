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
 * Second job: frames reached the panel 3 frames late (typing in foot showed
 * the key pressed 3 keys earlier). llvmpipe has no EGL_ANDROID_native_fence_sync,
 * so Hyprland's CHyprGLRenderer::endRender takes the implicit-sync path, which
 * only glFlush()es; llvmpipe then rasterizes on its worker threads while the
 * atomic commit goes in. simpledrm has no scanout DMA: its plane update copies
 * the dumb buffer into the firmware framebuffer during the commit, so it copied
 * the buffer's previous contents, i.e. the frame from one swapchain lap (3
 * buffers) ago. Hyprland already glFinish()es for software renderers, but it
 * detects them by the DRM driver name ("llvmpipe"), and here the driver is
 * simpledrm. So drmGetVersion() calls from the Hyprland executable itself
 * (render-backend detection in src/render/Renderer.cpp) see "simpledrm-llvmpipe",
 * which sets isSoftware() and makes endRender glFinish() before the commit.
 * (The only other caller there, openRenderNode, compares the name with "evdi".)
 * Proper fix (upstream): Hyprland should also treat a llvmpipe/softpipe
 * GL_RENDERER as software, or aquamarine should wait for rendering on
 * copy-on-commit drivers.
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
extern char *program_invocation_short_name; /* glibc */
extern unsigned long getauxval(unsigned long);
#define AT_ENTRY 9

static int from_aquamarine(const void *ra)
{
	Dl_info i;
	return dladdr(ra, &i) && i.dli_fname && strstr(i.dli_fname, "libaquamarine");
}

/* called from the Hyprland executable itself (not a library it loads) */
static int from_hyprland(const void *ra)
{
	Dl_info i, e;
	return program_invocation_short_name && !strcmp(program_invocation_short_name, "Hyprland") &&
	       dladdr(ra, &i) && dladdr((void *)getauxval(AT_ENTRY), &e) && i.dli_fbase == e.dli_fbase;
}

static void rename_version(drmVersion *v, const char *name)
{
	int l = 0;
	char *n;

	while (name[l])
		l++;
	if (!(n = malloc(l + 1)))
		return;
	for (int k = 0; k <= l; k++)
		n[k] = name[k];
	free(v->name); /* drmFreeVersion() frees name with free() */
	v->name = n;
	v->name_len = l;
}

__attribute__((visibility("default"))) drmVersion *drmGetVersion(int fd)
{
	static drmVersion *(*real)(int);
	const void *ra = __builtin_return_address(0);
	drmVersion *v;

	if (!real)
		real = (drmVersion * (*)(int)) dlsym(RTLD_NEXT, "drmGetVersion");
	if (!real)
		return 0;
	v = real(fd);
	if (!v || !v->name || strcmp(v->name, "simpledrm"))
		return v;
	if (from_aquamarine(ra))
		rename_version(v, "evdi");
	else if (from_hyprland(ra))
		rename_version(v, "simpledrm-llvmpipe");
	return v;
}
