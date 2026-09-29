/*
 * aq-commit-probe.so: debug-only LD_PRELOAD probe (not shipped in the image).
 *
 * Answers one question: is the buffer Hyprland hands to KMS finished when the
 * atomic commit goes in? simpledrm has no scanout DMA; its plane update copies
 * the committed dumb buffer into the firmware framebuffer during the commit.
 * If llvmpipe is still rasterizing into that buffer, the panel gets the old
 * contents.
 *
 * For every drmModeAtomicCommit that sets a plane FB_ID it checksums the FB's
 * pixels right before the commit and again PROBE_DELAY_MS (default 50) after
 * it returns, and appends one line to $AQ_PROBE_LOG (default /tmp/aq-probe.log):
 *   fb <id> before <sum> after <sum> <same|CHANGED>
 * CHANGED means the renderer was still writing the buffer after KMS took it.
 * The delay blocks the calling thread (aquamarine's commit thread), so frame
 * pacing is off while probing; use it only to diagnose.
 *
 * Build (no libc headers in the rootfs):
 *   clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib -fuse-ld=lld \
 *         -o aq-commit-probe.so aq-commit-probe.c $ROOT/usr/lib/libc.so.6
 * Use: LD_PRELOAD=/tmp/6s/aq-commit-probe.so:/usr/lib/phone-tk/aq-simpledrm.so
 */
typedef unsigned long size_t;
typedef unsigned int u32;
typedef unsigned long long u64;

typedef struct { u32 object_id, property_id; u64 value; u32 cursor; } req_item; /* libdrm */
typedef struct { u32 cursor, size_items; req_item *items; } atomic_req;
typedef struct { u32 prop_id, flags; char name[32]; } prop_head;       /* drmModePropertyRes prefix */
typedef struct {
	u32 fb_id, width, height, pixel_format;
	u64 modifier;
	u32 flags, handles[4], pitches[4], offsets[4];
} fb2;
struct map_dumb { u32 handle, pad; u64 offset; };

#define RTLD_NEXT ((void *)-1l)
#define RTLD_DEFAULT ((void *)0)
#define DRM_IOCTL_MODE_MAP_DUMB 0xC01064B3ul
#define DRM_IOCTL_GEM_CLOSE 0x40086409ul

extern void *dlsym(void *, const char *);
extern int ioctl(int, unsigned long, ...);
extern void *mmap(void *, size_t, int, int, int, long);
extern int munmap(void *, size_t);
extern int usleep(unsigned);
extern int open(const char *, int, ...);
extern long write(int, const void *, size_t);
extern int snprintf(char *, size_t, const char *, ...);
extern char *getenv(const char *);
extern int atoi(const char *);
extern int strcmp(const char *, const char *);

static int logfd = -1;
static u32 fbprop;

static u64 sum_fb(int fd, u32 fb_id)
{
	static fb2 *(*getfb2)(int, u32);
	static void (*freefb2)(fb2 *);
	struct map_dumb md = {0};
	u64 s = 0;
	fb2 *f;

	if (!getfb2) {
		getfb2 = (fb2 * (*)(int, u32)) dlsym(RTLD_DEFAULT, "drmModeGetFB2");
		freefb2 = (void (*)(fb2 *))dlsym(RTLD_DEFAULT, "drmModeFreeFB2");
	}
	if (!getfb2 || !(f = getfb2(fd, fb_id)))
		return 0;
	md.handle = f->handles[0];
	if (md.handle && !ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
		size_t len = (size_t)f->pitches[0] * f->height + f->offsets[0];
		u32 *p = mmap(0, len, 1 /* PROT_READ */, 1 /* MAP_SHARED */, fd, (long)md.offset);
		if (p != (void *)-1l) {
			for (size_t i = 0; i < len / 4; i++)
				s = s * 31 + p[i];
			munmap(p, len);
		}
	}
	if (md.handle) {
		u32 h[2] = {md.handle, 0};
		ioctl(fd, DRM_IOCTL_GEM_CLOSE, h);
	}
	if (freefb2)
		freefb2(f);
	return s;
}

__attribute__((visibility("default"))) int drmModeAtomicCommit(int fd, atomic_req *req, u32 flags, void *user)
{
	static int (*real)(int, atomic_req *, u32, void *);
	static prop_head *(*getprop)(int, u32);
	static void (*freeprop)(prop_head *);
	static int delay = -1;
	u32 fb = 0;
	u64 before = 0, after;
	int r;
	char line[128];

	if (!real) {
		real = (int (*)(int, atomic_req *, u32, void *))dlsym(RTLD_NEXT, "drmModeAtomicCommit");
		getprop = (prop_head * (*)(int, u32)) dlsym(RTLD_DEFAULT, "drmModeGetProperty");
		freeprop = (void (*)(prop_head *))dlsym(RTLD_DEFAULT, "drmModeFreeProperty");
		delay = getenv("PROBE_DELAY_MS") ? atoi(getenv("PROBE_DELAY_MS")) : 50;
		logfd = open(getenv("AQ_PROBE_LOG") ? getenv("AQ_PROBE_LOG") : "/tmp/aq-probe.log",
			     02101 /* O_WRONLY|O_CREAT|O_APPEND */, 0644);
	}
	/* flags & DRM_MODE_ATOMIC_TEST_ONLY (0x100): nothing reaches the panel */
	for (u32 i = 0; req && !(flags & 0x100) && i < req->cursor; i++) {
		req_item *it = &req->items[i];
		if (!fbprop && getprop) {
			prop_head *p = getprop(fd, it->property_id);
			if (p && !strcmp(p->name, "FB_ID"))
				fbprop = it->property_id;
			if (p && freeprop)
				freeprop(p);
		}
		if (fbprop && it->property_id == fbprop && it->value)
			fb = (u32)it->value;
	}
	if (fb)
		before = sum_fb(fd, fb);
	r = real(fd, req, flags, user);
	if (fb && logfd >= 0) {
		usleep((unsigned)delay * 1000);
		after = sum_fb(fd, fb);
		int n = snprintf(line, sizeof line, "fb %u before %llx after %llx %s r=%d\n", fb, before,
				 after, before == after ? "same" : "CHANGED", r);
		if (n > 0)
			write(logfd, line, (size_t)n);
	}
	return r;
}
