#!/usr/bin/env bash
# Laptop-only rehearsal of the PID 1 hand-over, no phone involved: the
# ramdisk's own busybox (aarch64, via qemu-user) runs as PID 1 of a
# user+pid+mount namespace whose / is a tmpfs, sources userland-switch.sh the
# way the patched /init does, and must reach a fake /usr/lib/systemd/systemd.
# A bug here would kill PID 1 on the phone (= kernel panic, DFU cycle).
#   tools/userland/test-switch-sim.sh [initramfs-userland.gz]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IRD="${1:-$HOME/Work/hoolock-iphone5s/build/userland/initramfs-userland.gz}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ird"; ( cd "$T/ird" && gzip -dc "$IRD" | cpio -idm --quiet 2>/dev/null || true )
# GNU cpio stops at the first TRAILER; take the patched files from the overlay.
cp "$HERE/phone/userland-switch.sh" "$T/ird/userland-switch.sh"

unshare --user --map-root-user --mount --pid --net --fork --kill-child bash -s "$T" <<'EOS'
set -euo pipefail
T="$1"; R="$T/sim"
mkdir -p "$R"; mount -t tmpfs sim "$R"
cp -a "$T/ird/." "$R/"
mkdir -p "$R/usr/bin" "$R/dev" "$R/proc" "$R/sys" "$R/run" "$R/newroot"
cp /usr/bin/qemu-aarch64-static "$R/usr/bin/"
mount -t tmpfs dev "$R/dev"
: > "$T/console.log"; : > "$T/kmsg.log"
for n in console kmsg null; do : > "$R/dev/$n"; done
mount --bind "$T/console.log" "$R/dev/console"; mount --bind "$T/kmsg.log" "$R/dev/kmsg"
mount --bind "$T/kmsg.log" "$R/dev/null"   # userns mounts are nodev; a sink file will do
mount -t proc proc "$R/proc"; mount -t sysfs sys "$R/sys"; mount -t tmpfs run "$R/run"
# fake userland: busybox + musl loader + an init that proves it was reached
mount -t tmpfs userland "$R/newroot"
N="$R/newroot"; mkdir -p "$N/bin" "$N/lib" "$N/usr/bin" "$N/usr/lib/systemd" "$N/etc"
cp "$R/bin/busybox" "$N/bin/"; cp "$R/lib/ld-musl-aarch64.so.1" "$N/lib/"; cp /usr/bin/qemu-aarch64-static "$N/usr/bin/"
ln -s busybox "$N/bin/sh"; echo "sim userland" > "$N/etc/omarchy-phone-release"
printf '#!/bin/sh\n/bin/busybox echo "INIT REACHED pid=$$"; /bin/busybox ls /proc/1/exe /dev/console /run/userland-newroot >/dev/null && /bin/busybox test -d /sys/kernel && /bin/busybox echo "MOUNTS MOVED"; /bin/busybox ls / | /bin/busybox tr "\\n" " "; /bin/busybox echo\n' > "$N/usr/lib/systemd/systemd"
chmod +x "$N/usr/lib/systemd/systemd"
echo /newroot > "$R/run/userland-newroot"
touch "$R/run/userland-go"
# PID 1 = busybox sh in the sim root, running the patched init's idle loop body
exec chroot "$R" /bin/busybox sh -c 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin; /bin/busybox --install -s; while true; do [ -e /run/userland-go ] && . /userland-switch.sh; echo "LOOP CONTINUED (no switch)"; exit 1; done'
EOS
echo "--- kmsg"; cat "$T/kmsg.log"; echo "--- console"; cat "$T/console.log"
grep -q "INIT REACHED pid=1" "$T/console.log" && grep -q "MOUNTS MOVED" "$T/console.log" \
	&& echo "PASS: PID 1 switched and the new init saw the moved mounts" || { echo FAIL; exit 1; }
