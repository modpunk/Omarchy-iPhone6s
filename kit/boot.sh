#!/usr/bin/env bash
# Tethered HoolockLinux boot for the iPhone 6s (Apple A9: s8000-n71 Samsung / s8003-n71m TSMC).
# checkm8 -> pongoOS -> m1n1 -> Linux, RAM only. Follows HoolockLinux/docs SETUP.md + SETUP_pongoOS.md.
#
#   ./boot.sh kernel   build Image.gz + iPhone 6s device trees (16K pages)
#   ./boot.sh blob     pack m1n1 + bootargs + dtbs + kernel + initramfs
#   ./boot.sh pongo    checkm8 the phone and load pongoOS (phone must be in DFU)
#   ./boot.sh linux    send the blob to pongoOS and boot it
#   ./boot.sh shell    open the phone's USB serial shell (telnet 172.16.42.1 also works)
#
# Paths are env-overridable; the defaults assume a work dir laid out like:
#   $HOOLOCK/linux                    HoolockLinux/linux checkout, 16K-page config
#   $HOOLOCK/m1n1/m1n1.bin            HoolockLinux m1n1
#   $HOOLOCK/bin/{palera1n,Pongo.bin,pongoterm}
#   $HOOLOCK/initramfs/initramfs.gz   HoolockLinux test ramdisk
set -euo pipefail

HOOLOCK="${HOOLOCK:-$HOME/Work/hoolock-iphone5s}"
KSRC="${KSRC:-$HOOLOCK/linux}"
OUT="${OUT:-$HOOLOCK/out}"
M1N1="${M1N1:-$HOOLOCK/m1n1/m1n1.bin}"
BIN="${BIN:-$HOOLOCK/bin}"
INITRAMFS="${INITRAMFS:-$HOOLOCK/initramfs/initramfs.gz}"
# The ramdisk release archive unpacks as initramfs.gz/initramfs.gz.
[ -d "$INITRAMFS" ] && INITRAMFS="$INITRAMFS/initramfs.gz"
BOOTARGS="${BOOTARGS:-console=tty0 hl_rd=shell}"
# iPhone 6s (A9): s8000-n71 (Samsung), s8003-n71m (TSMC).
DTBS=(s8000-n71.dtb s8003-n71m.dtb)

case "${1:-}" in
kernel)
	make -C "$KSRC" -j"$(nproc)" LLVM=1 ARCH=arm64 olddefconfig
	make -C "$KSRC" -j"$(nproc)" LLVM=1 ARCH=arm64 Image.gz "${DTBS[@]/#/apple/}"
	;;
blob)
	mkdir -p "$OUT"
	# m1n1 picks the device tree matching the phone, so both A9 foundry variants go in.
	cat "$M1N1" \
		<(printf 'chosen.bootargs=%s\n' "$BOOTARGS") \
		"${DTBS[@]/#/$KSRC/arch/arm64/boot/dts/apple/}" \
		"$KSRC/arch/arm64/boot/Image.gz" \
		"$INITRAMFS" \
		>"$OUT/m1n1-linux.bin"
	ls -la "$OUT/m1n1-linux.bin"
	;;
pongo)
	# May sit at "Booting pongoOS..." even though the phone shows pongoOS; Ctrl+C is fine then.
	sudo env PALERA1N_BYPASS_PASSCODE_CHECK=1 "$BIN/palera1n" -l -p -k "$BIN/Pongo.bin"
	;;
linux)
	# Ctrl+C once the phone visibly starts m1n1.
	printf '/send %s\nbootm\n' "$OUT/m1n1-linux.bin" | sudo "$BIN/pongoterm"
	;;
shell)
	dev="$(ls /dev/ttyACM* 2>/dev/null | head -1)"
	[ -n "$dev" ] || { echo "No /dev/ttyACM* yet; wait for Linux to finish booting."; exit 1; }
	sudo picocom -b 115200 "$dev"
	;;
*)
	sed -n '2,9p' "$0"
	exit 1
	;;
esac
