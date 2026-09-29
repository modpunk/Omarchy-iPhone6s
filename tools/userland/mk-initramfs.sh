#!/usr/bin/env bash
# Build initramfs-userland.gz: the stock HoolockLinux test ramdisk, unchanged,
# plus a second cpio archive that overrides /init with a copy whose idle loop
# can hand PID 1 over to the userland (switch_root needs PID 1; a telnet shell
# can't do it). Without /run/userland-go the ramdisk behaves exactly as before.
#
#   tools/userland/mk-initramfs.sh [stock-initramfs.gz] [out.gz]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IN="${1:-$HOME/Work/hoolock-iphone5s/initramfs/initramfs.gz}"
[ -d "$IN" ] && IN="$IN/initramfs.gz"
OUTF="${2:-$HOME/Work/hoolock-iphone5s/build/userland/initramfs-userland.gz}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

gzip -dc "$IN" > "$T/stock.cpio"
mkdir "$T/ov"
( cd "$T/ov" && cpio -i --quiet init < "$T/stock.cpio" )
[ -s "$T/ov/init" ] || { echo "no /init in $IN" >&2; exit 1; }
# Both idle loops (shell mode, failed test mode) learn to hand over.
sed -i 's|while true; do sleep 255; done|while true; do [ -e /run/userland-go ] \&\& [ -f /userland-switch.sh ] \&\& . /userland-switch.sh; sleep 1; done|' "$T/ov/init"
n="$(grep -c 'userland-switch.sh' "$T/ov/init" || true)"
[ "$n" -ge 1 ] || { echo "idle loop not found in /init; HoolockLinux changed it" >&2; exit 1; }
install -m 644 "$HERE/phone/userland-switch.sh" "$T/ov/userland-switch.sh"
chmod 755 "$T/ov/init"
( cd "$T/ov" && printf 'init\nuserland-switch.sh\n' | cpio -o --quiet -H newc -R 0:0 > "$T/ov.cpio" )
# The kernel unpacks concatenated cpio archives in order; later entries win.
# One gzip stream, so m1n1 sees a single initramfs payload.
mkdir -p "$(dirname "$OUTF")"
cat "$T/stock.cpio" "$T/ov.cpio" | gzip -9n > "$OUTF"
echo "patched $n idle loop(s); $(ls -l "$OUTF" | awk '{print $5}') bytes -> $OUTF"
