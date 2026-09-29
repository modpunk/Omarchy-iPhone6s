#!/bin/sh
# Omarchy Phone stage 2, run ON THE PHONE from the HoolockLinux ramdisk shell
# (busybox). Pushed to /tmp/6s/stage2.sh by tools/userland/push-rootfs.sh.
#
#   stage2.sh prep            mount the tmpfs at /newroot (SIZE=1400m)
#   stage2.sh recv <port>     nc -l <port> | unxz | tar -x into /newroot (streamed,
#                             the compressed tarball never sits in RAM)
#   stage2.sh unpack <file>   same from a pushed file (deleted after unpacking)
#   stage2.sh status          progress / result of recv or unpack, RAM use
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
	find "$S" -maxdepth 1 -type f -size -8192k ! -name 'unpack.*' ! -name '*.tar.*' \
		-exec cp -a {} "$NEWROOT/var/lib/6s-testkit/" \;
	cp /HL_init.log "$NEWROOT/var/lib/6s-testkit/" 2>/dev/null
}

case "${1:-}" in
prep) prep; df -m "$NEWROOT" | tail -1; free -m | head -2 ;;
recv)
	[ -n "${2:-}" ] || { echo "usage: stage2.sh recv <port>"; exit 1; }
	prep; unpack_from "nc -l -p $2" ;;
unpack)
	[ -f "${2:-}" ] || { echo "usage: stage2.sh unpack <file.tar.xz>"; exit 1; }
	prep; unpack_from "cat '$2'"; rm -f "$2" ;;
status) status ;;
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
*) sed -n '2,14p' "$0"; exit 1 ;;
esac
