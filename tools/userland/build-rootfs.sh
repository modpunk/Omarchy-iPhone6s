#!/usr/bin/env bash
# Build the Omarchy Phone RAM userland: Arch Linux ARM (aarch64) + systemd,
# sshd, iwd, BlueZ, PipeWire, seatd, Mesa llvmpipe, Hyprland, foot, plus the
# Omarchy Phone shell (QuickShell) and Phone app (GTK4/libadwaita, Python).
# Runs as a normal user on an x86_64 Arch host: re-execs itself in a user +
# mount + pid namespace (unshare --map-auto, needs /etc/subuid) and runs
# package scriptlets through qemu-aarch64-static via binfmt_misc.
#
#   tools/userland/build-rootfs.sh            full build -> $OUT/rootfs.tar.xz
#   STAGES="config strip check pack" tools/userland/build-rootfs.sh   redo later stages
#
# Env: OUT (default ~/Work/hoolock-iphone5s/build/userland), USERNAME (omarchy),
#      USERPASS (omarchy), SSH_PUBKEYS (default: ~/.ssh/*.pub),
#      FW_DIR (BT firmware; default ~/Work/hoolock-iphone5s/firmware/brcm),
#      PHONE_SRC (omarchy-phone git repo; default ~/Work/omarchy-phone),
#      SHELL_REV / APP_REV (commits of its shell/ and apps/phone/ to install),
#      KBUILD (kernel build tree with the out-of-tree phone drivers; default
#      ~/Work/hoolock-iphone5s/build/integration), KREL (its kernel release),
#      ENABLE_TELNETD (default 1: enable phone-telnetd, root telnet on the USB
#      link with no auth, so testkit/phone.sh keeps working after
#      switch_root -- set 0 for anything beyond bench dev, see docs/userland.md).
# Artifacts stay out of git: they carry Broadcom firmware and your SSH keys.
# The root dir is owned by subuids; delete it with
#   unshare --user --map-auto --map-root-user rm -rf "$OUT/root"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HOME/Work/hoolock-iphone5s/build/userland}"
ROOT="$OUT/root"
CONF="$HERE/pacman-alarm.conf"
USERNAME="${USERNAME:-omarchy}"
USERPASS="${USERPASS:-omarchy}"
FW_DIR="${FW_DIR:-$HOME/Work/hoolock-iphone5s/firmware/brcm}"
STAGES="${STAGES:-install config strip check pack}"
PHONE_SRC="${PHONE_SRC:-$HOME/Work/omarchy-phone}"
# Pinned so a rebuild installs the same shell/app; bump when deploying newer ones.
SHELL_REV="${SHELL_REV:-d84d3ad34803010ceceb4bc0b6b90aeff80a7349}"   # branch shell: PIN/idle-lock/BT agent
APP_REV="${APP_REV:-127478931f2f683f10830310948da31fab96b254}"       # branch phone-app
# archlinuxarm-keyring is the trust root for every later package signature
# (SigLevel = Required in pacman-alarm.conf), but it's TOFU: fetched from a
# plaintext-HTTP mirror with no signature to check yet (F11, security-review.md;
# ALARM's mirror network has no working per-mirror HTTPS -- verified, geo
# mirrors either refuse the connection or serve a cert for a different name,
# so pinning the content is the control, not the transport). Update this pin
# (and KEYRING_SIG_FPR, best-effort informational) after checking a new
# archlinuxarm-keyring release out-of-band, e.g. against the ALARM wiki or a
# second independent mirror, before bumping.
KEYRING_SHA256="${KEYRING_SHA256:-3cb36869edfe413672a6e932cc55d7f8386e1a9d3b38663cfb3bc6fe0d146e21}"  # archlinuxarm-keyring-20240419-2-any.pkg.tar.xz
KEYRING_SIG_FPR="${KEYRING_SIG_FPR:-68B3537F39A313B3E574D06777193F152BDBE6A6}"  # ALARM Build System signing key
# Fonts the shell names (Theme.qml). The packages are 232 + 107 MB; only these
# faces are extracted from the cached packages (not pacman-tracked).
FONT_PKGS="ttf-jetbrains-mono-nerd noto-fonts"
FONT_FILES="JetBrainsMonoNerdFont-Regular.ttf JetBrainsMonoNerdFont-Bold.ttf
	NotoSans-Light.ttf NotoSans-Regular.ttf NotoSans-Medium.ttf NotoSans-Bold.ttf"
KBUILD="${KBUILD:-$HOME/Work/hoolock-iphone5s/build/integration}"
# Drivers the phone needs that aren't built in, in load order (modules-load.d).
KMODS="drivers/gpio/gpio-apple-pmic.ko drivers/mux/mux-sn2400.ko
	drivers/power/supply/bq27xxx_battery_hdq_uart.ko"
QEMU=/usr/bin/qemu-aarch64-static

log() { printf '\033[1m[userland]\033[0m %s\n' "$*"; }
die() { printf '[userland] ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" != 0 ]; then
	command -v clang >/dev/null && command -v ld.lld >/dev/null || die "need clang and lld (pacman -S clang lld)"
	[ -x "$QEMU" ] || die "need $QEMU (pacman -S qemu-user-static qemu-user-static-binfmt)"
	[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "binfmt_misc qemu-aarch64 not registered"
	grep -q "^$(id -un):" /etc/subuid || die "no /etc/subuid range for $(id -un)"
	mkdir -p "$OUT"
	# Collect SSH keys as the real user before entering the namespace.
	if [ -z "${SSH_PUBKEYS:-}" ]; then
		cat "$HOME"/.ssh/*.pub > "$OUT/authorized_keys" 2>/dev/null || : > "$OUT/authorized_keys"
	else
		cat "$SSH_PUBKEYS" > "$OUT/authorized_keys"
	fi
	# Omarchy Phone sources, from git (not a worktree), before entering the namespace.
	case " $STAGES " in *" config "*)
		git -C "$PHONE_SRC" rev-parse -q --verify "$SHELL_REV^{commit}" >/dev/null \
			&& git -C "$PHONE_SRC" rev-parse -q --verify "$APP_REV^{commit}" >/dev/null \
			|| die "need $PHONE_SRC with commits $SHELL_REV and $APP_REV (PHONE_SRC/SHELL_REV/APP_REV)"
		git -C "$PHONE_SRC" archive -o "$OUT/ophone-shell.tar" "$SHELL_REV" shell
		git -C "$PHONE_SRC" archive -o "$OUT/ophone-app.tar" "$APP_REV" apps/phone
		printf 'shell %s\nphone-app %s\n' "$(git -C "$PHONE_SRC" rev-parse --short=12 "$SHELL_REV")" \
			"$(git -C "$PHONE_SRC" rev-parse --short=12 "$APP_REV")" > "$OUT/ophone-revs"
	esac
	# Phone driver modules must match the kernel that boots (vermagic).
	case " $STAGES " in *" config "*)
		KREL="${KREL:-$(cat "$KBUILD/include/config/kernel.release" 2>/dev/null)}"
		[ -n "$KREL" ] || die "no kernel release: set KBUILD (or KREL)"
		for m in $KMODS; do
			[ -s "$KBUILD/$m" ] || die "missing $KBUILD/$m (build the phone drivers, or set KBUILD)"
			v="$(modinfo -F vermagic "$KBUILD/$m" | awk '{print $1}')"
			[ "$v" = "$KREL" ] || die "$m is built for $v, not $KREL"
		done
		export KREL
	esac
	exec unshare --user --map-auto --map-root-user --mount --pid --fork --kill-child \
		env HOME="$HOME" OUT="$OUT" STAGES="$STAGES" KBUILD="$KBUILD" KREL="${KREL:-}" "$0" "$@"
fi

# ---- inside the namespace: uid 0 maps to the calling user -----------------
pkgs() { sed 's/#.*//' "$HERE/$1" | awk 'NF {print $1}'; }

mount_chroot() {
	mkdir -p "$ROOT"/{dev,proc,sys,run,tmp,usr/bin}
	# Private /dev with just the basic nodes, so scriptlets (systemd-tmpfiles)
	# never try to chown the host's device nodes. No /sys: nothing needs it.
	if ! mountpoint -q "$ROOT/dev"; then
		mount -t tmpfs -o mode=755 dev "$ROOT/dev"
		for n in null zero full random urandom tty; do
			touch "$ROOT/dev/$n"; mount --bind "/dev/$n" "$ROOT/dev/$n"
		done
		ln -s /proc/self/fd "$ROOT/dev/fd"; mkdir "$ROOT/dev/shm" "$ROOT/dev/pts"
	fi
	mountpoint -q "$ROOT/proc" || mount -t proc proc "$ROOT/proc"
	mountpoint -q "$ROOT/run" || mount -t tmpfs run "$ROOT/run"
	# binfmt has no F flag here: the interpreter must exist inside the chroot.
	cp "$QEMU" "$ROOT/usr/bin/qemu-aarch64-static"
}
umount_chroot() {
	for m in run proc dev; do
		mountpoint -q "$ROOT/$m" && { umount -R "$ROOT/$m" 2>/dev/null || umount -l "$ROOT/$m"; }
	done
	rm -f "$ROOT/usr/bin/qemu-aarch64-static"
}
in_root() { chroot "$ROOT" /usr/bin/env -i PATH=/usr/bin HOME=/root LANG=C.UTF-8 "$@"; }

stage_install() {
	if [ ! -s "$OUT/gnupg/pubring.kbx" ] && [ ! -s "$OUT/gnupg/pubring.gpg" ]; then
		log "keyring (archlinuxarm-keyring into $OUT/gnupg)"
		local kr url got
		mkdir -p "$OUT/cache" "$OUT/dbroot/var/lib/pacman" "$OUT/keyring"
		pacman --root "$OUT/dbroot" --config "$CONF" -Sy >/dev/null
		url="$(pacman --root "$OUT/dbroot" --config "$CONF" -Sp archlinuxarm-keyring | tail -1)"
		kr="$OUT/cache/$(basename "$url")"
		[ -s "$kr" ] || curl -sfL -o "$kr" "$url"
		# F11: this package becomes the trust root for every later pacman
		# signature check, so verify it against the pin above before it's
		# extracted and populated -- don't trust the plaintext-HTTP mirror.
		got="$(sha256sum "$kr" | cut -d' ' -f1)"
		[ "$got" = "$KEYRING_SHA256" ] || die "archlinuxarm-keyring ($kr) sha256 $got != pinned $KEYRING_SHA256 -- refusing to use it as a trust root. If this is a legitimate upstream update, verify the new package out-of-band and bump KEYRING_SHA256/KEYRING_SIG_FPR in build-rootfs.sh"
		log "keyring checksum verified against pin ($KEYRING_SHA256)"
		bsdtar -xf "$kr" -C "$OUT/keyring" usr/share/pacman/keyrings
		pacman-key --gpgdir "$OUT/gnupg" --init >/dev/null 2>&1
		pacman-key --gpgdir "$OUT/gnupg" --populate-from "$OUT/keyring/usr/share/pacman/keyrings" \
			--populate archlinuxarm
	fi
	log "pacman -> $ROOT"
	mkdir -p "$ROOT/var/lib/pacman" "$OUT/cache"
	mount_chroot
	local assume=()
	for p in $(pkgs assume-installed.txt); do assume+=(--assume-installed "$p"); done
	# shellcheck disable=SC2046
	pacman --root "$ROOT" --config "$CONF" --gpgdir "$OUT/gnupg" --cachedir "$OUT/cache" \
		--noconfirm --needed -Sy "${assume[@]}" $(pkgs packages.txt)
	# shellcheck disable=SC2086
	pacman --root "$ROOT" --config "$CONF" --gpgdir "$OUT/gnupg" --cachedir "$OUT/cache" \
		--noconfirm -Sw $FONT_PKGS
	umount_chroot
}

stage_config() {
	log "configure"
	mount_chroot
	cp -a "$HERE/overlay/." "$ROOT/"
	# Overlay files arrive owned by the building user (= ns uid 0 already).
	chown -R 0:0 "$ROOT/etc/systemd" "$ROOT/etc/ssh" "$ROOT/etc/sudoers.d" "$ROOT/etc/iwd" \
		"$ROOT/etc/xdg" "$ROOT/etc/skel" "$ROOT/usr/local" "$ROOT/usr/lib/phone-tk" \
		"$ROOT/etc/modules-load.d" "$ROOT/etc/modprobe.d" "$ROOT/etc/sysctl.d"
	stage_config_phone
	stage_config_modules
	# No predictable interface renames: usb0 must stay usb0 (it carries our IP).
	ln -sf /dev/null "$ROOT/etc/systemd/network/99-default.link"
	ln -sf /usr/share/zoneinfo/UTC "$ROOT/etc/localtime"
	[ -s "$ROOT/etc/machine-id" ] || tr -d '-' < /proc/sys/kernel/random/uuid > "$ROOT/etc/machine-id"
	# systemd never sets the clock earlier than this file's mtime (the RTC reads 2021).
	touch "$ROOT/usr/lib/clock-epoch"
	# busybox applets that Arch lacks (phone.sh push needs nc).
	mkdir -p "$ROOT/usr/lib/phone-tk/bin"
	for a in nc microcom xxd; do ln -sf /usr/bin/busybox "$ROOT/usr/lib/phone-tk/bin/$a"; done
	# LD_PRELOAD shim for Hyprland on simpledrm (see shim/aq-simpledrm.c), cross-built
	# with the host clang against the rootfs libc (the rootfs has no compiler).
	clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib -fuse-ld=lld -Wall \
		-o "$ROOT/usr/lib/phone-tk/aq-simpledrm.so" "$HERE/shim/aq-simpledrm.c" "$ROOT/usr/lib/libc.so.6" \
		|| die "building shim/aq-simpledrm.c needs host clang + lld"
	in_root /usr/bin/busybox telnetd --help 2>&1 | grep -qi telnet || die "ALARM busybox lacks telnetd"
	in_root /usr/bin/busybox nc --help 2>&1 | grep -qi 'nc\|netcat' || die "ALARM busybox lacks nc"

	log "users"
	if ! grep -q "^$USERNAME:" "$ROOT/etc/passwd"; then
		useradd -R "$ROOT" -m -U -G wheel,seat,video,input,audio,render -s /bin/bash "$USERNAME"
	fi
	# -e (pre-hashed) keeps chpasswd away from the host's PAM stack.
	# USERPASS goes to openssl over stdin, not argv (F15, security-review.md):
	# a process argv is visible to any other local user on the build host via
	# ps for the life of the call; stdin isn't.
	printf '%s:%s\n' "$USERNAME" "$(printf '%s' "$USERPASS" | openssl passwd -6 -stdin)" | chpasswd -e -R "$ROOT"
	local uid gid
	uid="$(awk -F: -v u="$USERNAME" '$1==u {print $3}' "$ROOT/etc/passwd")"
	gid="$(awk -F: -v u="$USERNAME" '$1==u {print $4}' "$ROOT/etc/passwd")"
	install -d -m 700 -o 0 -g 0 "$ROOT/root/.ssh"
	install -m 600 -o 0 -g 0 "$OUT/authorized_keys" "$ROOT/root/.ssh/authorized_keys"
	install -d -m 700 "$ROOT/home/$USERNAME/.ssh"
	install -m 600 "$OUT/authorized_keys" "$ROOT/home/$USERNAME/.ssh/authorized_keys"
	mkdir -p "$ROOT/home/$USERNAME/.config"
	cp -a "$ROOT/etc/skel/.config/." "$ROOT/home/$USERNAME/.config/"
	chown -R "$uid:$gid" "$ROOT/home/$USERNAME"
	# Linger (= loginctl enable-linger): user@.service, /run/user/UID and the
	# PipeWire user units outlive the SSH command that starts phone-hyprland.
	install -d -m 755 "$ROOT/var/lib/systemd/linger"; : > "$ROOT/var/lib/systemd/linger/$USERNAME"

	log "ssh host keys (kept in $OUT/ssh-hostkeys so fingerprints survive rebuilds)"
	if [ ! -s "$OUT/ssh-hostkeys/etc/ssh/ssh_host_ed25519_key" ]; then
		mkdir -p "$OUT/ssh-hostkeys/etc/ssh"
		ssh-keygen -A -f "$OUT/ssh-hostkeys" >/dev/null
	fi
	cp -a "$OUT/ssh-hostkeys/etc/ssh/." "$ROOT/etc/ssh/"
	chown 0:0 "$ROOT"/etc/ssh/ssh_host_*

	log "pacman keyring for on-device use"
	rm -rf "$ROOT/etc/pacman.d/gnupg"
	cp -a "$OUT/gnupg" "$ROOT/etc/pacman.d/gnupg"
	rm -f "$ROOT"/etc/pacman.d/gnupg/S.*

	if ls "$FW_DIR"/*.hcd >/dev/null 2>&1; then
		log "BT firmware from $FW_DIR (local artifact only, never commit)"
		local hcd; hcd="$(ls "$FW_DIR"/*.hcd | head -1)"
		install -D -m 644 "$hcd" "$ROOT/usr/lib/firmware/brcm/BCM.apple,n71.hcd"
		install -D -m 644 "$hcd" "$ROOT/usr/lib/firmware/brcm/BCM4350C5.apple,n71.hcd"
	fi

	log "units"
	systemctl --root="$ROOT" enable systemd-networkd.service sshd.service bluetooth.service \
		seatd.service iwd.service getty@tty1.service nftables.service \
		serial-getty@ttyGS0.service omarchy-phone-bt-keys.service omarchy-phone-bt-address.service
	# Root telnet on the USB link (F19/Authentication, security-review.md):
	# opt-in, defaulting on because testkit/phone.sh (phone.py) still talks to
	# it after switch_root. Off: ENABLE_TELNETD=0 tools/userland/build-rootfs.sh
	if [ "${ENABLE_TELNETD:-1}" = 1 ]; then
		systemctl --root="$ROOT" enable phone-telnetd.service
	else
		systemctl --root="$ROOT" disable phone-telnetd.service 2>/dev/null || true
	fi
	systemctl --root="$ROOT" mask systemd-networkd-wait-online.service systemd-firstboot.service
	systemctl --root="$ROOT" --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
	# The phone session starts at boot for $USERNAME only (not --global: root's
	# user manager from an SSH login must not start a second Hyprland).
	# Disable on the phone: systemctl --user disable --now omarchy-phone-session
	install -d -m 755 -o "$uid" -g "$gid" "$ROOT/home/$USERNAME/.config/systemd" \
		"$ROOT/home/$USERNAME/.config/systemd/user" "$ROOT/home/$USERNAME/.config/systemd/user/default.target.wants"
	ln -sfn /etc/systemd/user/omarchy-phone-session.service \
		"$ROOT/home/$USERNAME/.config/systemd/user/default.target.wants/omarchy-phone-session.service"
	chown -h "$uid:$gid" "$ROOT/home/$USERNAME/.config/systemd/user/default.target.wants/omarchy-phone-session.service"
	# ophone-btagentd (F5/F6, shell/system/README.md): "systemctl --user enable"
	# equivalent, done by hand the same way omarchy-phone-session is above --
	# there's no running user manager in this build namespace to enable it with.
	ln -sfn /usr/lib/systemd/user/ophone-btagentd.service \
		"$ROOT/home/$USERNAME/.config/systemd/user/default.target.wants/ophone-btagentd.service"
	chown -h "$uid:$gid" "$ROOT/home/$USERNAME/.config/systemd/user/default.target.wants/ophone-btagentd.service"
	# Filled at deploy time (push-rootfs.sh -> stage2.sh seed): bt-address, bt-keys.tgz.
	install -d -m 700 -o 0 -g 0 "$ROOT/etc/omarchy-phone"
	{ printf 'omarchy-phone userland %s (built on %s)\n' "$(date -u +%Y%m%dT%H%MZ)" "$(uname -n)"
	  cat "$OUT/ophone-revs"; } > "$ROOT/etc/omarchy-phone-release"
	umount_chroot
}

# Omarchy Phone shell + Phone app -> /usr/share/omarchy-phone/{shell,apps/phone}.
stage_config_phone() {
	log "omarchy-phone shell + Phone app ($(tr '\n' ' ' < "$OUT/ophone-revs"))"
	local d="$ROOT/usr/share/omarchy-phone" f pkg
	rm -rf "$d"; mkdir -p "$d"
	tar --no-same-owner -xf "$OUT/ophone-shell.tar" -C "$d" --exclude=shell/preview
	tar --no-same-owner -xf "$OUT/ophone-app.tar" -C "$d" \
		--exclude=apps/phone/tests --exclude=apps/phone/scripts --exclude=apps/phone/.gitignore
	cp "$OUT/ophone-revs" "$d/REVISIONS"
	# Launchers resolve their tree with readlink -f, so symlinks work.
	for f in ophone-ctl ophone-sys ophone-pin; do ln -sf "/usr/share/omarchy-phone/shell/bin/$f" "$ROOT/usr/local/bin/$f"; done
	for f in omarchy-phone phoned phonectl; do ln -sf "/usr/share/omarchy-phone/apps/phone/bin/$f" "$ROOT/usr/local/bin/$f"; done
	install -D -m 644 "$d/apps/phone/data/org.omarchy.Phone.desktop" "$ROOT/usr/share/applications/org.omarchy.Phone.desktop"
	# System files the shell needs from the image (shell/system/README.md).
	install -D -m 644 "$d/shell/system/logind-ophone.conf" "$ROOT/etc/systemd/logind.conf.d/omarchy-phone.conf"
	install -D -m 644 "$d/shell/system/pam/ophone-lock" "$ROOT/etc/pam.d/ophone-lock"
	# /run/omarchy-phone/faillock (pam_faillock's tally dir) and /etc/omarchy-phone
	# (pin-hash) must exist before the first lock-screen unlock attempt or
	# pam_faillock silently fails open (see shell/system/README.md, DESIGN.md
	# "Throttling: pam_faillock"). /usr/lib/tmpfiles.d is scanned by
	# systemd-tmpfiles-setup.service, part of sysinit.target's default
	# dependencies (no explicit enable needed, and it completes long before
	# any user session starts), so dropping the file there is enough.
	install -D -m 644 "$d/shell/system/tmpfiles.d/omarchy-phone.conf" "$ROOT/usr/lib/tmpfiles.d/omarchy-phone.conf"
	# bluetoothd defaults: not discoverable/pairable at rest, no Just-Works
	# re-pairing, resolvable LE address (F5, security-review.md).
	install -D -m 644 "$d/shell/system/bluetooth/main.conf" "$ROOT/etc/bluetooth/main.conf"
	# Real BlueZ pairing agent (on-screen Pair/Reject), replacing bluetoothd's
	# auto-accept fallback agent (F5/F6). Enabled for $USERNAME below, once its
	# uid/gid are known ("units").
	install -D -m 644 "$d/shell/system/systemd/ophone-btagentd.service" "$ROOT/usr/lib/systemd/user/ophone-btagentd.service"
	chown -R 0:0 "$d"
	in_root python3 -m compileall -q /usr/share/omarchy-phone/apps/phone/omarchy_phone >/dev/null \
		|| die "python3 compileall of the Phone app failed"
	# Font subset (see FONT_FILES).
	mkdir -p "$ROOT/usr/share/fonts/omarchy-phone"
	for pkg in $FONT_PKGS; do
		f="$(ls "$OUT"/cache/"$pkg"-[0-9]*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | sort -V | tail -1)"
		[ -n "$f" ] || die "font package $pkg not in $OUT/cache (run the install stage)"
		bsdtar -xf "$f" -C "$ROOT/usr/share/fonts/omarchy-phone" --strip-components 4 \
			$(for x in $FONT_FILES; do bsdtar -tf "$f" | grep "/$x\$"; done)
	done
	for x in $FONT_FILES; do [ -s "$ROOT/usr/share/fonts/omarchy-phone/$x" ] || die "font $x missing"; done
	chown -R 0:0 "$ROOT/usr/share/fonts/omarchy-phone"
	in_root fc-cache -s >/dev/null 2>&1 || log "fc-cache failed (fontconfig rebuilds its cache at runtime)"
}

# Out-of-tree phone drivers -> /lib/modules/$KREL/extra (+ depmod). Load order:
# overlay/etc/modules-load.d/omarchy-phone.conf, softdep in modprobe.d.
stage_config_modules() {
	log "kernel modules for $KREL: $(for m in $KMODS; do basename "$m" .ko; done | tr '\n' ' ')"
	local d="$ROOT/usr/lib/modules/$KREL" m f
	rm -rf "$d"; mkdir -p "$d/extra"
	for m in $KMODS; do install -m 644 "$KBUILD/$m" "$d/extra/"; done
	# So modprobe knows what is built in (hci_uart, btbcm, ...), and depmod doesn't warn.
	for f in modules.builtin modules.builtin.modinfo; do
		[ -e "$KBUILD/$f" ] && install -m 644 "$KBUILD/$f" "$d/"
	done
	: > "$d/modules.order"   # the kernel's lists in-tree .ko paths that aren't shipped
	local map=(); [ -e "$KBUILD/System.map" ] && map=(-F "$KBUILD/System.map")
	depmod -b "$ROOT" "${map[@]}" "$KREL" || die "depmod for $KREL failed"
	grep -q gpio-apple-pmic "$d/modules.dep" || die "depmod wrote no modules.dep entries"
	chown -R 0:0 "$d"
}

stage_strip() {
	log "strip docs, locales, headers, caches"
	( cd "$ROOT"
	  rm -rf usr/share/doc usr/share/man usr/share/info usr/share/gtk-doc usr/share/help \
		usr/include usr/share/i18n usr/share/gir-1.0 usr/lib/libteflon.so
	  rm -rf var/cache/pacman/pkg/* var/lib/pacman/sync/*
	  find usr/share/locale -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || :
	  find usr/lib -name '*.a' -type f -delete
	  # Default Hyprland wallpapers (config sets force_default_wallpaper = 0).
	  rm -f usr/share/hypr/wall*.png
	  # Python: test suite, IDLE, Tk (no libtk), pip wheels, and the -O/-OO
	  # bytecode (24 MB; only used with python -O).
	  for py in usr/lib/python3.*; do
		rm -rf "$py"/test "$py"/idlelib "$py"/tkinter "$py"/turtledemo "$py"/ensurepip "$py"/lib-dynload/_tkinter*
		find "$py" -name '*.opt-[12].pyc' -delete
	  done
	  # Qt: build-time data and developer tools (the shell runs from QML source).
	  rm -rf usr/lib/qt6/mkspecs usr/lib/qt6/metatypes usr/lib/qt6/modules usr/lib/qt6/sbom usr/lib/cmake
	  # Qt: the rest of the SDK (moc/uic/rcc/qmlcachegen/...), Qt Creator's
	  # qmllint/qmlls/qmltooling plugins, and QML's own test module -- none of
	  # it runs when Quickshell loads QML at runtime (~21 MB).
	  rm -rf usr/lib/qt6/bin usr/lib/qt6/moc usr/lib/qt6/uic usr/lib/qt6/rcc \
		usr/lib/qt6/qmlcachegen usr/lib/qt6/qmlimportscanner usr/lib/qt6/qmltyperegistrar \
		usr/lib/qt6/qmlaotstats usr/lib/qt6/cmake_automoc_parser usr/lib/qt6/qlalr \
		usr/lib/qt6/qmljsrootgen usr/lib/qt6/qtwaylandscanner usr/lib/qt6/qvkgen \
		usr/lib/qt6/syncqt usr/lib/qt6/tracegen usr/lib/qt6/tracepointgen \
		usr/lib/qt6/qt-cmake-private* usr/lib/qt6/qt-cmake-standalone-test \
		usr/lib/qt6/qt-internal-configure-* usr/lib/qt6/qt_cyclonedx_generator.py \
		usr/lib/qt6/qt-android-runner.py usr/lib/qt6/qml/QmlTime usr/lib/qt6/qml/QtTest \
		usr/lib/qt6/plugins/qmllint usr/lib/qt6/plugins/qmlls usr/lib/qt6/plugins/qmltooling
	  # Qt platform/QPA plugins for backends this image never selects
	  # (QT_QPA_PLATFORM=wayland, hypr/hyprland.lua) or features nothing here
	  # uses (printing, Qt SQL, X11, eglfs/linuxfb, an input-method framework,
	  # TLS/network-info -- no QML here touches Qt Network) (~13 MB).
	  rm -rf usr/lib/qt6/plugins/printsupport usr/lib/qt6/plugins/sqldrivers \
		usr/lib/qt6/plugins/networkinformation usr/lib/qt6/plugins/platformthemes \
		usr/lib/qt6/plugins/xcbglintegrations usr/lib/qt6/plugins/egldeviceintegrations \
		usr/lib/qt6/plugins/generic usr/lib/qt6/plugins/platforminputcontexts \
		usr/lib/qt6/plugins/tls
	  find usr/lib/qt6/plugins/platforms -type f ! -name 'libqwayland.so' -delete 2>/dev/null || :
	  # gettext: keep gettext/ngettext/envsubst/gettext.sh (scripts use these);
	  # xgettext and the msg* PO tool chain are translation-authoring tools,
	  # never run on the device (~15.5 MB, xgettext alone is 14 MB).
	  rm -f usr/bin/xgettext usr/bin/msg* usr/bin/autopoint usr/bin/gettextize \
		usr/bin/recode-sr-latin usr/bin/spit usr/bin/po-fetch \
		usr/bin/printf_gettext usr/bin/printf_ngettext
	  # gtk4's icon-encoder and librsvg's standalone CLI are build-time tools;
	  # nothing in the shell or Phone app shells out to either (~18 MB).
	  rm -f usr/bin/gtk4-encode-symbolic-svg usr/bin/rsvg-convert
	  # sqlite's analysis/debug CLIs (sqldiff, showdb, showwal, dbdump, dbhash,
	  # index_usage, sqlite3_expert, sqlite3_rsync); the Phone app uses
	  # Python's sqlite3 module, not these. Keep the sqlite3 CLI itself for
	  # on-device debugging over ssh (~12.8 MB).
	  rm -f usr/bin/sqldiff usr/bin/showdb usr/bin/showwal usr/bin/showjournal \
		usr/bin/showstat4 usr/bin/dbdump usr/bin/dbhash usr/bin/index_usage \
		usr/bin/sqlite3_expert usr/bin/sqlite3_rsync
	  # libcap's process-capability-tree viewer, a debug tool nothing here
	  # calls; getcap/setcap stay (docs/userland.md references them) (~2 MB).
	  rm -f usr/bin/captree )
}

stage_check() {
	log "checks (qemu smoke + 16K page scan)"
	mount_chroot
	"$HERE/check-rootfs.sh" "$ROOT" 2>&1 | tee "$OUT/check-report.txt"
	umount_chroot
}

stage_pack() {
	log "pack"
	umount_chroot
	pacman --root "$ROOT" --config "$CONF" -Q > "$OUT/rootfs.packages.txt"
	du -sb "$ROOT" | awk '{printf "unpacked %.0f MiB\n", $1/1048576}' | tee "$OUT/rootfs.size.txt"
	# --numeric-owner: the phone's busybox tar must not map names through the
	# ramdisk's /etc/passwd. crc32: always supported by xz-embedded (busybox unxz).
	tar --numeric-owner --format=gnu -C "$ROOT" -cf - . \
		| xz -T0 -9 --check=crc32 -c > "$OUT/rootfs.tar.xz.part"
	mv "$OUT/rootfs.tar.xz.part" "$OUT/rootfs.tar.xz"
	md5sum < "$OUT/rootfs.tar.xz" | cut -d' ' -f1 > "$OUT/rootfs.tar.xz.md5"
	ls -l "$OUT/rootfs.tar.xz" | tee -a "$OUT/rootfs.size.txt"
}

for s in $STAGES; do "stage_$s"; done
log "done: stages [$STAGES] in $OUT"
