#!/bin/sh
# Omarchy Phone stage 2, run ON THE PHONE from the HoolockLinux ramdisk shell
# (busybox). Pushed to /tmp/6s/stage2.sh by tools/userland/push-rootfs.sh.
#
#   stage2.sh prep            mount the tmpfs at /newroot (SIZE=1400m)
#   stage2.sh recv <port>     nc -l <port> (bound to 172.16.42.1, the USB address;
#                             see F8, security-review.md) | unxz | tar -x into
#                             /newroot (streamed, the compressed tarball never
#                             sits in RAM)
#   stage2.sh unpack <file>   same from a pushed file (deleted after unpacking)
#   stage2.sh status          progress / result of recv or unpack, RAM use
#   stage2.sh seed            move deploy-time files pushed to /tmp/6s (bt-address,
#                             bt-keys.tgz) into /newroot/etc/omarchy-phone (root, 0600)
#   stage2.sh pin             provision the lock-screen PIN: run "ophone-pin set" inside
#                             /newroot (chroot, /proc and /dev bind-mounted for the
#                             duration) from /tmp/6s/phone-pin, pushed by push-rootfs.sh;
#                             no-op (and prints why) if that file is missing. The pushed
#                             file is deleted either way, never carried over by carry()
#   stage2.sh timezone <zone> /newroot/etc/localtime -> /usr/share/zoneinfo/<zone>,
#                             and /newroot/etc/timezone (the phone has no RTC/NTP yet;
#                             push-rootfs.sh calls this with the laptop's zone)
#   stage2.sh go              hand over: switch_root into /newroot (needs the
#                             patched initramfs-userland.gz; PID 1 does the switch)
#   stage2.sh nsboot          EXPERIMENTAL, no reboot needed: boot systemd as PID 1
#                             of a new pid+mount namespace on the stock ramdisk
set -u
NEWROOT=/newroot
SIZE="${SIZE:-1400m}"
S=/tmp/6s
mkdir -p "$S"

prep() {
	if ! mountpoint -q "$NEWROOT"; then
		mkdir -p "$NEWROOT"
		mount -t tmpfs -o "size=$SIZE,mode=0755" userland "$NEWROOT" || exit 1
	fi
	echo "$NEWROOT" > /run/userland-newroot
}

unpack_from() { # $1 = source command
	rm -f "$S/unpack.rc" "$S/unpack.md5" "$S/unpack.fifo"
	mkfifo "$S/unpack.fifo"
	md5sum < "$S/unpack.fifo" | cut -d' ' -f1 > "$S/unpack.md5" &
	set -o pipefail 2>/dev/null
	echo "started $(date)" > "$S/unpack.log"
	sh -c "$1" | tee "$S/unpack.fifo" | unxz | tar -xpf - -C "$NEWROOT"
	rc=$?
	wait
	rm -f "$S/unpack.fifo"
	echo "finished $(date) rc=$rc" >> "$S/unpack.log"
	echo "$rc" > "$S/unpack.rc"
}

status() {
	echo "newroot: $(du -sm "$NEWROOT" 2>/dev/null | cut -f1) MiB"
	cat "$S/unpack.log" 2>/dev/null
	echo "rc=$(cat "$S/unpack.rc" 2>/dev/null || echo running) md5=$(cat "$S/unpack.md5" 2>/dev/null)"
	[ -e "$NEWROOT/etc/omarchy-phone-release" ] && cat "$NEWROOT/etc/omarchy-phone-release"
	free -m | head -2
}

check_root() {
	[ "$(cat "$S/unpack.rc" 2>/dev/null)" = 0 ] || { echo "unpack not finished or failed"; status; exit 1; }
	[ -x "$NEWROOT/usr/lib/systemd/systemd" ] && [ -e "$NEWROOT/etc/omarchy-phone-release" ] \
		|| { echo "$NEWROOT is not a complete userland"; exit 1; }
}

# Carry this boot's hand-pushed bits (BT firmware, test modules) into the new
# root: switch_root deletes the ramdisk and everything in /tmp/6s.
carry() {
	if [ -d /lib/firmware ]; then
		mkdir -p "$NEWROOT/usr/lib/firmware"
		cp -a /lib/firmware/. "$NEWROOT/usr/lib/firmware/" 2>/dev/null
	fi
	mkdir -p "$NEWROOT/var/lib/6s-testkit"
	# Exclude bt-address/bt-keys.tgz (F17, security-review.md) and phone-pin
	# (same reasoning: the PIN provisioning step below deletes it right after
	# use, but if that step never ran -- e.g. "go" without "pin" first -- it
	# must not end up world-readable under /var/lib/6s-testkit as a side
	# effect of carrying over test files).
	find "$S" -maxdepth 1 -type f -size -8192k ! -name 'unpack.*' ! -name '*.tar.*' \
		! -name 'bt-address' ! -name 'bt-keys.tgz' ! -name 'phone-pin' \
		-exec cp -a {} "$NEWROOT/var/lib/6s-testkit/" \;
	cp /HL_init.log "$NEWROOT/var/lib/6s-testkit/" 2>/dev/null
}

# Set the new root's timezone from the zone name push-rootfs.sh read off the
# laptop. Symlink, like a normal Arch install; also drop a plain-text
# /etc/timezone since some tools still look for it.
timezone() {
	[ -d "$NEWROOT/etc" ] || { echo "no userland in $NEWROOT"; exit 1; }
	zone="$1"
	[ -e "$NEWROOT/usr/share/zoneinfo/$zone" ] || {
		echo "timezone: no $NEWROOT/usr/share/zoneinfo/$zone (bad zone, or tzdata missing from the image)" >&2
		exit 1
	}
	ln -sf "/usr/share/zoneinfo/$zone" "$NEWROOT/etc/localtime"
	echo "$zone" > "$NEWROOT/etc/timezone"
	echo "timezone: set $zone"
}

# Per-phone files that must not be baked into the image. Moved, not copied, so
# carry() doesn't leave a second copy in /var/lib/6s-testkit.
seed() {
	[ -d "$NEWROOT/etc" ] || { echo "no userland in $NEWROOT"; exit 1; }
	mkdir -p "$NEWROOT/etc/omarchy-phone"; chmod 700 "$NEWROOT/etc/omarchy-phone"
	for f in bt-address bt-keys.tgz; do
		[ -f "$S/$f" ] || continue
		mv -f "$S/$f" "$NEWROOT/etc/omarchy-phone/$f"
		chown 0:0 "$NEWROOT/etc/omarchy-phone/$f"; chmod 600 "$NEWROOT/etc/omarchy-phone/$f"
		echo "seeded /etc/omarchy-phone/$f"
	done
}

# Provision the lock-screen PIN (shell/system/README.md, docs/shell/DESIGN.md
# "Lock screen PIN") before the phone ever boots this root: feed the PIN
# (twice, matching ophone-pin's "New PIN:"/"Confirm PIN:" prompts) on stdin to
# `ophone-pin set` run inside /newroot via chroot -- the same command
# "sudo ophone-pin set" over SSH runs post-boot, just done here so an
# unattended deploy can provision one non-interactively. /proc and /dev are
# bind-mounted only for the duration of the call (python3's hashlib.scrypt and
# os.urandom need neither in practice, but a stock python3 build can probe
# /proc; nothing here is required to already be running for it to work).
pin() {
	[ -d "$NEWROOT/etc" ] || { echo "no userland in $NEWROOT"; exit 1; }
	if [ ! -s "$S/phone-pin" ]; then
		echo "no $S/phone-pin: skipping PIN provisioning (later: ssh + sudo ophone-pin set)"
		return 0
	fi
	mountpoint -q "$NEWROOT/proc" || mount -t proc proc "$NEWROOT/proc"
	mountpoint -q "$NEWROOT/dev" || mount --bind /dev "$NEWROOT/dev"
	pin_value="$(cat "$S/phone-pin")"
	printf '%s\n%s\n' "$pin_value" "$pin_value" | chroot "$NEWROOT" /usr/bin/env -i \
		PATH=/usr/local/bin:/usr/bin HOME=/root OPHONE_USER=omarchy \
		/usr/share/omarchy-phone/shell/bin/ophone-pin set
	rc=$?
	unset pin_value
	umount "$NEWROOT/dev" 2>/dev/null
	umount "$NEWROOT/proc" 2>/dev/null
	rm -f "$S/phone-pin"
	if [ "$rc" = 0 ]; then echo "PIN provisioned in the new root"
	else echo "PIN provisioning FAILED (rc=$rc); provision later with: ssh + sudo ophone-pin set"; fi
	return "$rc"
}

case "${1:-}" in
prep) prep; df -m "$NEWROOT" | tail -1; free -m | head -2 ;;
recv)
	[ -n "${2:-}" ] || { echo "usage: stage2.sh recv <port>"; exit 1; }
	prep; unpack_from "nc -l -p $2 -s 172.16.42.1" ;;
unpack)
	[ -f "${2:-}" ] || { echo "usage: stage2.sh unpack <file.tar.xz>"; exit 1; }
	prep; unpack_from "cat '$2'"; rm -f "$2" ;;
status) status ;;
seed) seed ;;
pin) pin ;;
timezone)
	[ -n "${2:-}" ] || { echo "usage: stage2.sh timezone <zone>"; exit 1; }
	timezone "$2" ;;
go)
	check_root
	grep -q userland-go /init || { echo "this ramdisk's /init is not patched: boot initramfs-userland.gz (see docs/userland.md) or try 'stage2.sh nsboot'"; exit 1; }
	carry
	echo "switching in ~3 s: telnet drops; then ssh omarchy@172.16.42.1 (or phone.sh ping via phone-telnetd)"
	setsid sh -c 'sleep 2; touch /run/userland-go' </dev/null >/dev/null 2>&1 &
	;;
nsboot)
	check_root
	carry
	# udevd, networkd (DHCP server) and systemd's gettys replace these; the
	# ramdisk telnetd stays as a fallback, so the rootfs copy of it is masked.
	killall mdev unudhcpd getty 2>/dev/null
	ln -sf /dev/null "$NEWROOT/etc/systemd/system/phone-telnetd.service"
	echo "nsboot: systemd as PID 1 of a new pid namespace; ramdisk telnet stays up"
	setsid unshare -m -p -f sh -c "mount --make-rprivate / && cd '$NEWROOT' && mount --move . / && exec chroot . /usr/lib/systemd/systemd" \
		</dev/console >/dev/console 2>&1 &
	sleep 3; ps | grep -c '[s]ystemd' ;;
*) sed -n '2,20p' "$0"; exit 1 ;;
esac
