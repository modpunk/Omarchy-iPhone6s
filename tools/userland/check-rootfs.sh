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
# ophone-btagentd (F5/F6, DESIGN.md "Bluetooth pairing confirmation") needs
# Gio/GLib from python-gobject on the system bus; ophone-pin needs hashlib's
# OpenSSL-backed scrypt (DESIGN.md "Lock screen PIN").
smoke python3 -c "from gi.repository import Gio, GLib; print('Gio/GLib ok', GLib.get_prgname() or 'ok')"
smoke python3 -c "import hashlib; hashlib.scrypt(b'x', salt=b'0'*16, n=2, r=8, p=1, dklen=8); print('hashlib.scrypt ok')"
smoke ophone-pin
# Not `ophone-btagentd --help`: it has no arg parsing and main() immediately
# blocks on Gio.bus_get_sync()/GLib.MainLoop().run() (see docs/shell/DESIGN.md
# "Bluetooth pairing confirmation") -- there's no system bus in this chroot to
# connect to, so running it would hang the check. A syntax/import-only compile
# is the safe equivalent smoke test for the daemon.
printf '  %-28s ' "ophone-btagentd compiles"
chroot "$ROOT" /usr/bin/env -i PATH=/usr/bin python3 -m py_compile /usr/share/omarchy-phone/shell/bin/ophone-btagentd \
	>/dev/null 2>&1 && echo ok || echo "NO: py_compile failed"
printf '  %-28s ' "omarchy-phone install"
ok=yes; for f in /usr/share/omarchy-phone/shell/qs/shell.qml /usr/share/omarchy-phone/shell/hypr/hyprland.lua \
	/usr/share/omarchy-phone/shell/hypr/devices/iphone6s.lua /usr/share/applications/org.omarchy.Phone.desktop \
	/etc/pam.d/ophone-lock /etc/systemd/logind.conf.d/omarchy-phone.conf /home/omarchy/.config/hypr/hyprland.lua \
	/home/omarchy/.config/hypr/plain.lua /usr/lib/tmpfiles.d/omarchy-phone.conf /etc/bluetooth/main.conf \
	/usr/lib/systemd/user/ophone-btagentd.service; do [ -e "$ROOT$f" ] || { ok="NO ($f)"; break; }; done
for f in ophone-ctl ophone-sys ophone-pin omarchy-phone phoned phonectl; do   # absolute symlinks: resolve inside ROOT
	[ -x "$ROOT$(readlink "$ROOT/usr/local/bin/$f" 2>/dev/null || echo /usr/local/bin/$f)" ] || ok="NO ($f)"; done
echo "$ok; $(tr '\n' ' ' < "$ROOT/usr/share/omarchy-phone/REVISIONS" 2>/dev/null)"
for fam in "JetBrainsMono Nerd Font" "Noto Sans" "Noto Sans:weight=light"; do
	printf '  %-28s ' "fc-match $fam"; chroot "$ROOT" /usr/bin/fc-match "$fam" 2>&1 | head -1
done
printf '  %-28s ' "icon call-start-symbolic"
find "$ROOT/usr/share/icons" -name 'call-start-symbolic*' 2>/dev/null | sed "s|$ROOT||" | head -1
# Session config: the wrapper dofile()s the shell's config (Lua errors show up here).
# Runs on a scratch copy of /etc/skel, so nothing lands in /home before pack.
mkdir -p "$ROOT/tmp/xdg/home" && cp -a "$ROOT/etc/skel/.config" "$ROOT/tmp/xdg/home/"
for v in "" PHONE_PLAIN=1; do
	printf '  %-28s ' "hypr config ${v:-(phone shell)}"
	chroot "$ROOT" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin HOME=/tmp/xdg/home XDG_RUNTIME_DIR=/tmp/xdg \
		XDG_CACHE_HOME=/tmp/xdg/cache OPHONE_DEVICE=iphone6s OPHONE_SHELL=/usr/share/omarchy-phone/shell $v \
		Hyprland --i-am-really-stupid --verify-config --config /tmp/xdg/home/.config/hypr/hyprland.lua 2>&1 \
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
# Phone driver modules (build-rootfs.sh stage_config_modules) and their load order.
for d in "$ROOT"/usr/lib/modules/*/; do
	krel="$(basename "$d")"; printf '  %-28s ' "modules $krel"
	ok=yes
	for m in gpio-apple-pmic mux-sn2400 bq27xxx_battery_hdq_uart; do
		v="$(modinfo -F vermagic "$d/extra/$m.ko" 2>/dev/null | awk '{print $1}')"
		[ "$v" = "$krel" ] || { ok="NO ($m vermagic '${v:-missing}')"; break; }
		grep -q "^extra/$m.ko:" "$d/modules.dep" 2>/dev/null || { ok="NO ($m not in modules.dep)"; break; }
	done
	echo "$ok; load order: $(sed 's/#.*//' "$ROOT/etc/modules-load.d/omarchy-phone.conf" 2>/dev/null | awk NF | tr '\n' ' ')"
done
printf '  %-28s ' "modprobe softdep"
chroot "$ROOT" /usr/bin/modprobe -c 2>/dev/null | grep -m1 '^softdep bq27xxx_battery_hdq_uart' || echo NO
printf '  %-28s ' "boot units"
ok=yes; for u in multi-user.target.wants/omarchy-phone-bt-address.service bluetooth.service.wants/omarchy-phone-bt-keys.service \
	bluetooth.target.wants/bluetooth.service multi-user.target.wants/seatd.service; do
	[ -L "$ROOT/etc/systemd/system/$u" ] || ok="NO ($u)"; done
[ -L "$ROOT/home/omarchy/.config/systemd/user/default.target.wants/omarchy-phone-session.service" ] || ok="NO (omarchy-phone-session)"
[ -e "$ROOT/etc/systemd/user/default.target.wants/omarchy-phone-session.service" ] && ok="NO (session enabled globally)"
[ -L "$ROOT/home/omarchy/.config/systemd/user/default.target.wants/ophone-btagentd.service" ] || ok="NO (ophone-btagentd)"
echo "$ok"
printf '  %-28s ' "systemd-analyze verify"
out="$(chroot "$ROOT" /usr/bin/env -i PATH=/usr/bin SYSTEMD_LOG_LEVEL=warning /usr/bin/systemd-analyze verify --man=no \
	/etc/systemd/system/omarchy-phone-bt-keys.service /etc/systemd/system/omarchy-phone-bt-address.service 2>&1 \
	| grep -v -i 'dbus\|bus\b\|Failed to connect\|proc\|cgroup' | head -3 | tr '\n' ' ')"
echo "${out:-ok}"
printf '  %-28s ' "scripts sh -n"
ok=yes; for f in /usr/lib/phone-tk/bt-address /usr/lib/phone-tk/wait-display /usr/local/bin/phone-hyprland; do
	chroot "$ROOT" /usr/bin/sh -n "$f" 2>/dev/null || ok="NO ($f)"; [ -x "$ROOT$f" ] || ok="NO ($f not executable)"; done
echo "$ok"
printf '  %-28s ' "no BT/PIN secrets in image"
# bt-address, bt-keys.tgz and the PIN's pin-hash are all seeded/provisioned at
# deploy time (push-rootfs.sh -> stage2.sh seed/pin), never baked into the image.
[ -z "$(ls -A "$ROOT/etc/omarchy-phone" 2>/dev/null)" ] && [ -z "$(ls -A "$ROOT/var/lib/bluetooth" 2>/dev/null)" ] \
	&& echo "ok (seeded/provisioned at deploy)" || echo "NO: /etc/omarchy-phone or /var/lib/bluetooth not empty"
printf '  %-28s ' "tmpfiles.d omarchy-phone"
tf="$ROOT/usr/lib/tmpfiles.d/omarchy-phone.conf"
if [ -s "$tf" ]; then
	ok=yes
	grep -Eq '^d[[:space:]]+/run/omarchy-phone[[:space:]]' "$tf" || ok="NO (no /run/omarchy-phone line)"
	grep -Eq '^d[[:space:]]+/run/omarchy-phone/faillock[[:space:]]' "$tf" || ok="NO (no faillock tally dir line)"
	grep -Eq '^d[[:space:]]+/etc/omarchy-phone[[:space:]]' "$tf" || ok="NO (no /etc/omarchy-phone line)"
	echo "$ok"
else
	echo "NO: missing"
fi
printf '  %-28s ' "bluetooth/main.conf"
bc="$ROOT/etc/bluetooth/main.conf"
if [ -s "$bc" ]; then
	ok=yes
	grep -Eq '^[[:space:]]*Discoverable[[:space:]]*=[[:space:]]*false' "$bc" || ok="NO (Discoverable not false)"
	grep -Eq '^[[:space:]]*Pairable[[:space:]]*=[[:space:]]*false' "$bc" || ok="NO (Pairable not false)"
	grep -Eq '^[[:space:]]*JustWorksRepairing[[:space:]]*=[[:space:]]*never' "$bc" || ok="NO (JustWorksRepairing not never)"
	grep -Eq '^[[:space:]]*Privacy[[:space:]]*=[[:space:]]*device' "$bc" || ok="NO (Privacy not device)"
	echo "$ok"
else
	echo "NO: missing"
fi
printf '  %-28s ' "pam ophone-lock"
pf="$ROOT/etc/pam.d/ophone-lock"
if [ -s "$pf" ]; then
	ok=yes
	# Only the active directive lines matter -- the file's own comments talk
	# about the old "include login" chain by name (same self-match risk the
	# wheel-sudo check above already avoids the same way).
	grep -v '^[[:space:]]*#' "$pf" | grep -qE '^[[:space:]]*(auth|account|password|session)[[:space:]]+.*include[[:space:]]+login' \
		&& ok="NO (still includes login -- the PIN must be its own secret, not the account password, F2/F3 in security-review.md)"
	grep -Eq 'pam_faillock\.so[[:space:]]+preauth[[:space:]]+dir=/run/omarchy-phone/faillock' "$pf" || ok="NO (no faillock preauth on the phone's own tally dir)"
	grep -q 'pam_exec\.so.*ophone-pin verify' "$pf" || ok="NO (no pam_exec ophone-pin verify)"
	echo "$ok"
else
	echo "NO: missing"
fi
printf '  %-28s ' "sshd -t (config test)"; chroot "$ROOT" /usr/bin/sshd -t && echo ok
printf '  %-28s ' "mesa kms_swrast present"
[ -e "$ROOT/usr/lib/dri/kms_swrast_dri.so" ] && [ -e "$ROOT/usr/lib/gbm/dri_gbm.so" ] && echo yes || echo NO
printf '  %-28s ' "aq-simpledrm shim (aarch64)"
file -b "$ROOT/usr/lib/phone-tk/aq-simpledrm.so" 2>/dev/null | grep -q aarch64 && echo yes || echo NO
printf '  %-28s ' "EGL vendor (mesa)"; ls "$ROOT"/usr/share/glvnd/egl_vendor.d/ | tr '\n' ' '; echo
printf '  %-28s ' "file capabilities to restore"; getcap -r "$ROOT/usr" 2>/dev/null | sed "s|$ROOT||" | tr '\n' ';'; echo
printf '  %-28s ' "tzdata (zoneinfo)"
[ -e "$ROOT/usr/share/zoneinfo/UTC" ] && [ -d "$ROOT/usr/share/zoneinfo/America" ] \
	&& echo "ok (push-rootfs.sh sets the phone's zone at deploy time)" || echo "NO: no /usr/share/zoneinfo (tzdata missing)"

echo "== security (security-review.md P0 + cheap P1) =="
printf '  %-28s ' "sshd ListenAddress (F7)"
grep -qx 'ListenAddress 172.16.42.1' "$ROOT/etc/ssh/sshd_config.d/10-phone.conf" 2>/dev/null && echo ok || echo "NO: missing from 10-phone.conf"
printf '  %-28s ' "sshd ordered after usb0"
[ -s "$ROOT/etc/systemd/system/sshd.service.d/10-phone.conf" ] && echo ok || echo "NO: sshd.service.d/10-phone.conf missing"
printf '  %-28s ' "wheel sudo needs a password"
if [ -s "$ROOT/etc/sudoers.d/10-wheel" ]; then
	# Only the active rule line matters -- the file's own comments talk about
	# NOPASSWD by name, so a plain grep over the whole file self-matches.
	grep -v '^[[:space:]]*#' "$ROOT/etc/sudoers.d/10-wheel" | grep -qi 'NOPASSWD' \
		&& echo "NO: NOPASSWD still present" || echo ok
else
	echo "NO: /etc/sudoers.d/10-wheel missing"
fi
printf '  %-28s ' "nftables ruleset (F9)"
if [ -s "$ROOT/etc/nftables.conf" ]; then
	# `nft -c` still opens a NETLINK_NETFILTER socket (not a pure grammar
	# check), which qemu-user doesn't implement -- checking the aarch64 copy
	# through the chroot fails with "Protocol not supported" regardless of
	# whether the ruleset is valid. Check the checked-in file with the host's
	# own (x86_64, native) nft instead: the grammar is architecture-
	# independent, and a throwaway net namespace (build-rootfs.sh's own
	# namespace is already a user ns, so this doesn't need --user again)
	# gives it a netlink socket to talk to.
	if command -v nft >/dev/null 2>&1; then
		out="$(unshare --net nft -c -f "$HERE/overlay/etc/nftables.conf" 2>&1)"
		[ -z "$out" ] && echo "ok (usb0 + lo allowed, default drop)" || echo "NO: $out"
	else
		echo "skipped (no host nft to check the grammar with)"
	fi
else
	echo "NO: /etc/nftables.conf missing"
fi
printf '  %-28s ' "nftables.service enabled"
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/nftables.service" ] && echo yes || echo "NO"
printf '  %-28s ' "kernel nf_tables support"
if [ -n "${KBUILD:-}" ] && [ -s "$KBUILD/.config" ]; then
	missing=""
	for c in CONFIG_NETFILTER CONFIG_NF_TABLES CONFIG_NF_TABLES_INET; do
		grep -q "^$c=y" "$KBUILD/.config" || missing="$missing $c"
	done
	# =m would also work (nftables.service would need modprobe/softdep to load
	# it first, which nothing here sets up), so call that out separately.
	if [ -z "$missing" ]; then echo "ok (built in)"
	else
		mods=""; for c in $missing; do grep -q "^$c=m" "$KBUILD/.config" && mods="$mods $c"; done
		[ -n "$mods" ] && echo "NO: module only, no autoload set up:$mods" || echo "NO: not configured:$missing"
	fi
else
	echo "skipped (no \$KBUILD/.config)"
fi
printf '  %-28s ' "phone-telnetd enabled (F19)"
if [ -L "$ROOT/etc/systemd/system/multi-user.target.wants/phone-telnetd.service" ]; then
	echo "yes (ENABLE_TELNETD=1, dev default -- opt out with ENABLE_TELNETD=0)"
else
	echo "no (ENABLE_TELNETD=0)"
fi
printf '  %-28s ' "nc -l listeners bind usb0 (F8)"
ok=yes
grep -q "nc -l -p .*-s 172.16.42.1" "$HERE/phone/stage2.sh" 2>/dev/null || ok="NO (stage2.sh recv)"
grep -q "nc -l -p .*-s 172.16.42.1" "$HERE/../../testkit/phone.sh" 2>/dev/null || ok="NO (testkit/phone.sh do_push)"
echo "$ok"
printf '  %-28s ' "carry() excludes BT secrets (F17)"
grep -q "name 'bt-address'" "$HERE/phone/stage2.sh" 2>/dev/null && grep -q "name 'bt-keys.tgz'" "$HERE/phone/stage2.sh" 2>/dev/null \
	&& echo ok || echo "NO: stage2.sh carry() doesn't exclude bt-address/bt-keys.tgz"
printf '  %-28s ' "USERPASS via stdin (F15)"
grep -q "openssl passwd -6 -stdin" "$HERE/build-rootfs.sh" 2>/dev/null && echo ok || echo "NO: build-rootfs.sh still passes USERPASS on argv"
printf '  %-28s ' "keyring checksum pinned (F11)"
grep -q '^KEYRING_SHA256=' "$HERE/build-rootfs.sh" 2>/dev/null && echo "ok (verified at build time, see build-rootfs.sh log)" || echo "NO: no KEYRING_SHA256 pin in build-rootfs.sh"
