#!/usr/bin/env bash
# Build-host checks for the userland root (run by build-rootfs.sh, inside its
# namespace with /dev and /proc mounted and qemu-aarch64-static in the root).
#   1. 16K pages: every ELF PT_LOAD must be aligned >= 16 KiB, or the 16K
#      kernel refuses/garbles it. Also flag allocators that bake in the page
#      size at build time (jemalloc, tcmalloc) and who links them.
#   2. Every DT_NEEDED resolves inside the root (catches over-stripping).
#   3. Smoke: key binaries start under qemu-user and print a version.
# qemu-user always gives the guest the host's 4K pages, so (3) cannot catch a
# 16K-only failure; (1) is the static substitute. Real proof is on the phone.
set -uo pipefail
ROOT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$ROOT" <<'PY'
import os, struct, sys
root = sys.argv[1]
PT_LOAD, PT_DYNAMIC, DT_NEEDED, DT_STRTAB, DT_RPATH, DT_RUNPATH = 1, 2, 1, 5, 15, 29
bad_align, needed_by, missing, allocators = [], {}, [], {}
nelf = 0
libdirs = ["/usr/lib", "/usr/lib/pipewire-0.3", "/usr/lib/systemd", "/usr/lib/pulseaudio"]
sonames = set()
for d in libdirs:
    p = root + d
    if os.path.isdir(p):
        sonames.update(os.listdir(p))
def elf_info(path):
    with open(path, "rb") as f:
        h = f.read(64)
        if len(h) < 64 or h[:4] != b"\x7fELF" or h[4] != 2:
            return None
        e_type, e_machine = struct.unpack_from("<HH", h, 16)
        if e_machine != 183:  # aarch64
            return None
        phoff, = struct.unpack_from("<Q", h, 32)
        phentsize, phnum = struct.unpack_from("<HH", h, 54)
        f.seek(phoff); ph = f.read(phentsize * phnum)
        loads, dyn = [], None
        for i in range(phnum):
            p_type, p_flags, p_off, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
                struct.unpack_from("<IIQQQQQQ", ph, i * phentsize)
            if p_type == PT_LOAD: loads.append((p_off, p_vaddr, p_filesz, p_align))
            if p_type == PT_DYNAMIC: dyn = (p_off, p_filesz)
        needed, rpath = [], []
        if dyn:
            f.seek(dyn[0]); raw = f.read(dyn[1]); ents = []
            for i in range(0, len(raw) - 15, 16):
                tag, val = struct.unpack_from("<qQ", raw, i)
                if tag == 0: break
                ents.append((tag, val))
            strtab = next((v for t, v in ents if t == DT_STRTAB), None)
            if strtab is not None:
                off = next((o + strtab - va for o, va, fs, al in loads if va <= strtab < va + fs), None)
                def s(v):
                    f.seek(off + v); b = f.read(256); return b.split(b"\0")[0].decode(errors="replace")
                if off is not None:
                    needed = [s(v) for t, v in ents if t == DT_NEEDED]
                    rpath = [s(v) for t, v in ents if t in (DT_RPATH, DT_RUNPATH)]
        return loads, needed, rpath
for dp, dns, fns in os.walk(root):
    rel = dp[len(root):] or "/"
    if rel.startswith(("/proc", "/dev", "/sys", "/run")): dns[:] = []; continue
    for fn in fns:
        p = os.path.join(dp, fn)
        if os.path.islink(p) or not os.path.isfile(p): continue
        try: info = elf_info(p)
        except (OSError, struct.error): continue
        if not info: continue
        loads, needed, rpath = info
        nelf += 1
        r = p[len(root):]
        small = [al for o, va, fs, al in loads if al < 0x4000]
        if small: bad_align.append((r, min(small)))
        for n in needed:
            if "jemalloc" in n or "tcmalloc" in n: allocators.setdefault(n, []).append(r)
            if n.startswith("ld-linux"): continue
            ok = n in sonames or any(os.path.exists(root + rp.replace("$ORIGIN", os.path.dirname(r)) + "/" + n)
                                      for x in rpath for rp in x.split(":"))
            if not ok: missing.append((r, n))
        if r == "/usr/lib/libjemalloc.so.2" or "jemalloc" in fn: allocators.setdefault("(file) " + fn, [])
print("== 16K page check: PT_LOAD alignment < 0x4000 ==")
for r, al in sorted(bad_align): print(f"  BAD  {r}  align=0x{al:x}")
print(f"  {len(bad_align)} of {nelf} aarch64 ELF files have sub-16K segment alignment")
print("== page-size-baking allocators (jemalloc/tcmalloc) and their users ==")
if not allocators: print("  none linked")
for n, users in sorted(allocators.items()):
    print(f"  {n}: {len(users)} users" + ("".join(f"\n    {u}" for u in users[:20])))
print("== unresolved DT_NEEDED ==")
for r, n in sorted(missing): print(f"  MISSING {r} -> {n}")
print(f"  {len(missing)} unresolved")
PY
echo "== qemu smoke tests =="
smoke() { printf '  %-28s ' "$1"; out="$(chroot "$ROOT" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin LANG=C.UTF-8 XDG_RUNTIME_DIR=/tmp "$@" 2>&1 | grep -m1 .)"; echo "${out:-<no output>}"; }
smoke /usr/lib/systemd/systemd --version
smoke Hyprland --version
smoke foot --version
smoke /usr/bin/sshd -V
smoke /usr/lib/iwd/iwd --version
smoke /usr/lib/bluetooth/bluetoothd --version
smoke bluetoothctl --version
smoke pipewire --version
smoke wireplumber --version
smoke seatd -v
smoke busybox
smoke qs --version
smoke /usr/lib/upowerd --help
smoke brightnessctl --version
smoke python3 -c "import gi; gi.require_version('Gtk', '4.0'); gi.require_version('Adw', '1'); from gi.repository import Gtk, Adw; print('PyGObject', gi.__version__, 'GTK', Gtk.get_major_version(), Gtk.get_minor_version(), 'Adw', Adw.get_major_version(), Adw.get_minor_version())"
smoke env PYTHONPATH=/usr/share/omarchy-phone/apps/phone python3 -c "import omarchy_phone.ui, omarchy_phone.daemon, omarchy_phone.cli; print('Phone app modules import')"
smoke phonectl --help
printf '  %-28s ' "omarchy-phone install"
ok=yes; for f in /usr/share/omarchy-phone/shell/qs/shell.qml /usr/share/omarchy-phone/shell/hypr/hyprland.lua \
	/usr/share/omarchy-phone/shell/hypr/devices/iphone6s.lua /usr/share/applications/org.omarchy.Phone.desktop \
	/etc/pam.d/ophone-lock /etc/systemd/logind.conf.d/omarchy-phone.conf /home/omarchy/.config/hypr/hyprland.lua \
	/home/omarchy/.config/hypr/plain.lua; do [ -e "$ROOT$f" ] || { ok="NO ($f)"; break; }; done
for f in ophone-ctl ophone-sys omarchy-phone phoned phonectl; do   # absolute symlinks: resolve inside ROOT
	[ -x "$ROOT$(readlink "$ROOT/usr/local/bin/$f" 2>/dev/null || echo /usr/local/bin/$f)" ] || ok="NO ($f)"; done
echo "$ok; $(tr '\n' ' ' < "$ROOT/usr/share/omarchy-phone/REVISIONS" 2>/dev/null)"
for fam in "JetBrainsMono Nerd Font" "Noto Sans" "Noto Sans:weight=light"; do
	printf '  %-28s ' "fc-match $fam"; chroot "$ROOT" /usr/bin/fc-match "$fam" 2>&1 | head -1
done
printf '  %-28s ' "icon call-start-symbolic"
find "$ROOT/usr/share/icons" -name 'call-start-symbolic*' 2>/dev/null | sed "s|$ROOT||" | head -1
# Session config: the wrapper dofile()s the shell's config (Lua errors show up here).
mkdir -p "$ROOT/tmp/xdg"
for v in "" PHONE_PLAIN=1; do
	printf '  %-28s ' "hypr config ${v:-(phone shell)}"
	chroot "$ROOT" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin HOME=/home/omarchy XDG_RUNTIME_DIR=/tmp/xdg \
		OPHONE_DEVICE=iphone6s OPHONE_SHELL=/usr/share/omarchy-phone/shell $v \
		Hyprland --i-am-really-stupid --verify-config --config /home/omarchy/.config/hypr/hyprland.lua 2>&1 \
		| sed -n '/Config parsing result/,$p' | grep -v 'Config parsing result' | grep . | head -3 | tr '\n' ' '; echo
done
rm -rf "$ROOT/tmp/xdg"
printf '  %-28s ' "user dbus.socket"
[ -e "$ROOT/usr/lib/systemd/user/sockets.target.wants/dbus.socket" ] && echo enabled || echo NO
# 16K pages for jemalloc users (quickshell): report 16 KiB to them under qemu.
# Positive control first: a 128 KiB page must make jemalloc refuse to start.
if clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib -fuse-ld=lld \
	-o "$ROOT/tmp/pagesize16k.so" "$HERE/shim/pagesize16k.c" "$ROOT/usr/lib/libc.so.6" 2>/dev/null; then
	pg() { out="$(chroot "$ROOT" /usr/bin/env -i PATH=/usr/bin LANG=C.UTF-8 XDG_RUNTIME_DIR=/tmp \
		LD_PRELOAD=/tmp/pagesize16k.so "$@" 2>&1 | head -1)"; echo "${out:-<no output>}"; }
	printf '  %-28s ' "jemalloc @128K (control)"
	pg env PAGESIZE16K_VALUE=131072 LD_PRELOAD=/tmp/pagesize16k.so:/usr/lib/libjemalloc.so.2 /usr/bin/true
	printf '  %-28s ' "jemalloc @16K"
	pg env LD_PRELOAD=/tmp/pagesize16k.so:/usr/lib/libjemalloc.so.2 /usr/bin/echo ok
	printf '  %-28s ' "qs --version @16K"; pg qs --version
	rm -f "$ROOT/tmp/pagesize16k.so"
else
	echo "  (pagesize16k shim not built: needs host clang + lld)"
fi
printf '  %-28s ' "sshd -t (config test)"; chroot "$ROOT" /usr/bin/sshd -t && echo ok
printf '  %-28s ' "mesa kms_swrast present"
[ -e "$ROOT/usr/lib/dri/kms_swrast_dri.so" ] && [ -e "$ROOT/usr/lib/gbm/dri_gbm.so" ] && echo yes || echo NO
printf '  %-28s ' "aq-simpledrm shim (aarch64)"
file -b "$ROOT/usr/lib/phone-tk/aq-simpledrm.so" 2>/dev/null | grep -q aarch64 && echo yes || echo NO
printf '  %-28s ' "EGL vendor (mesa)"; ls "$ROOT"/usr/share/glvnd/egl_vendor.d/ | tr '\n' ' '; echo
printf '  %-28s ' "file capabilities to restore"; getcap -r "$ROOT/usr" 2>/dev/null | sed "s|$ROOT||" | tr '\n' ';'; echo
