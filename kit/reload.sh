#!/usr/bin/env bash
# Fast kernel reload for the iPhone 6s: kexec a new Image + DTB from the running Linux.
# No DFU, no checkm8, no buttons. Needs the running kernel to carry the spin-table park
# patch (patches/fast-reload/); boot one such kernel the slow way first. See docs/fast-reload.md.
#
#   kit/reload.sh                 build dir $BUILD (default $HOOLOCK/build/fast-reload)
#   kit/reload.sh -n              dry run: pull the phone's DT, merge, place, print; change nothing
#   kit/reload.sh --load-only     load the image but don't jump to it
#   kit/reload.sh --no-quiesce    jump with the USB gadget still bound (the old behaviour)
#
# Options:  --build DIR  --kernel Image  --dtb FILE  --initrd FILE  --base FILE
#           --cmdline "..." (replace bootargs)  --append "..." (add to bootargs)
#           --running FILE --park ADDR:SIZE (offline dry run without the phone)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOLOCK="${HOOLOCK:-$HOME/Work/hoolock-iphone5s}"
OUT="${OUT:-$HOOLOCK/out}"
BUILD="${BUILD:-$HOOLOCK/build/fast-reload}"
INITRAMFS="${INITRAMFS:-$HOOLOCK/initramfs/initramfs.gz}"
[ -d "$INITRAMFS" ] && INITRAMFS="$INITRAMFS/initramfs.gz"
PH="${PHONE_SH:-$REPO/testkit/phone.sh}"
FR="$HERE/fast-reload"
STATE="$OUT/fast-reload"
MERGE=(python3 "$FR/fdtmerge.py")

DRY=0 LOADONLY=0 QUIESCE=1 KIMAGE="" DTB="" BASE="" CMDLINE="" APPEND="" RUNNING="" PARK=""
while [ $# -gt 0 ]; do
	case "$1" in
	-n | --dry-run) DRY=1 ;;
	--load-only) LOADONLY=1 ;;
	--build) BUILD="$2"; shift ;;
	--kernel) KIMAGE="$2"; shift ;;
	--dtb) DTB="$2"; shift ;;
	--initrd) INITRAMFS="$2"; shift ;;
	--base) BASE="$2"; shift ;;
	--cmdline) CMDLINE="$2"; shift ;;
	--append) APPEND="$2"; shift ;;
	--running) RUNNING="$2"; shift ;;
	--park) PARK="$2"; shift ;;
	--no-quiesce) QUIESCE=0 ;;
	-h | --help) sed -n '2,15p' "$0"; exit 0 ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift
done
KIMAGE="${KIMAGE:-$BUILD/arch/arm64/boot/Image}"
die() { echo "reload: $*" >&2; exit 1; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
t0=$(date +%s)

for f in "$KIMAGE" "$INITRAMFS"; do [ -f "$f" ] || die "missing $f"; done
mkdir -p "$STATE/stage"

# kexec-lite: static aarch64, rebuilt when the source changes.
KL="$STATE/kexec-lite"
if [ ! -x "$KL" ] || [ "$FR/kexec-lite.c" -nt "$KL" ]; then
	"$FR/build.sh" "$STATE" >/dev/null
fi

# 1. What is the phone running?
if [ -z "$RUNNING" ]; then
	"$PH" ping >/dev/null || die "phone not reachable (telnet 172.16.42.1)"
	say "probing the phone"
	probe="$("$PH" run 'grep -i "spin-table park" /proc/iomem; echo "CMDLINE=$(cat /proc/cmdline)"; echo "KEXEC=$(cat /sys/kernel/kexec_loaded 2>/dev/null || echo none)"; echo "ONLINE=$(cat /sys/devices/system/cpu/online)"; echo "UNAME=$(uname -rv)"; echo "PID1=$(cat /proc/1/comm)"; for u in $(awk "\$3 == \"configfs\" { print \$2 }" /proc/mounts); do for g in $u/usb_gadget/*/UDC; do [ -e $g ] && echo "UDC $g=$(cat $g)"; done; done; true')"
	echo "$probe" | sed 's/^/    /'
	cmdline="$(echo "$probe" | sed -n 's/^CMDLINE=//p')"
	[ "$(echo "$probe" | sed -n 's/^KEXEC=//p')" != none ] || die "running kernel has no kexec (CONFIG_KEXEC)"
	case " $cmdline " in
	*" nosmp "* | *" nr_cpus="* | *" maxcpus=0 "*)
		die "running kernel was booted with nosmp/nr_cpus=: CPU1 may still sit in m1n1's spin loop (memory Linux reuses); kexec is unsafe. Boot without it." ;;
	esac
	if [ -z "$PARK" ]; then
		range="$(echo "$probe" | awk -F' : ' '/spin-table park/ {gsub(/ /, "", $1); print $1; exit}')"
		[ -n "$range" ] || die "running kernel has no spin-table park (patches/fast-reload missing).
  Boot a fast-reload kernel once the slow way:
    BUILD=$BUILD kit/boot.sh blob && kit/boot.sh pongo && kit/boot.sh linux   (DFU)"
		ps=$((16#${range%-*})) pe=$((16#${range#*-}))
		PARK="$(printf '0x%x:0x%x' "$ps" $((pe - ps + 1)))"
	fi

	say "pulling /sys/firmware/fdt"
	RUNNING="$STATE/running.dtb"
	"$PH" run 'md5sum /sys/firmware/fdt; echo HEX:; if od -An -v -tx1 /dev/null >/dev/null 2>&1; then od -An -v -tx1 /sys/firmware/fdt; else hexdump -v -e "16/1 \"%02x \" \"\n\"" /sys/firmware/fdt; fi' 180 >"$STATE/running.hex"
	python3 - "$STATE/running.hex" "$RUNNING" <<-'EOF'
		import hashlib, re, sys
		text = open(sys.argv[1]).read()
		want = text.split()[0]
		body = text.split("HEX:", 1)[1]
		data = bytes(int(t, 16) for t in re.findall(r"\b[0-9a-f]{2}\b", body))
		if hashlib.md5(data).hexdigest() != want:
		    sys.exit(f"fdt pull corrupt: md5 {hashlib.md5(data).hexdigest()} != {want}")
		open(sys.argv[2], "wb").write(data)
	EOF
else
	[ -n "$PARK" ] || die "--running needs --park ADDR:SIZE"
	cmdline="$("${MERGE[@]}" get "$RUNNING" /chosen bootargs)"
fi

# 2. Base = the .dtb the running boot started from (m1n1's changes = running - base).
if [ -z "$BASE" ]; then
	sha="$("${MERGE[@]}" get "$RUNNING" /chosen fast-reload,base)"
	if [ -n "$sha" ] && [ -f "$STATE/base-$sha.dtb" ]; then
		BASE="$STATE/base-$sha.dtb"
	elif [ -n "$sha" ]; then
		die "phone was kexec'd from a DT this laptop has no copy of (base-$sha.dtb); pass --base"
	elif [ -d "$OUT/blob-dtbs" ]; then
		BASE="$("${MERGE[@]}" pick "$OUT/blob-dtbs" "$RUNNING")" || die "no matching base in $OUT/blob-dtbs; pass --base"
	else
		die "don't know which .dtb the phone booted with; pass --base FILE (the dtb inside the m1n1 blob)"
	fi
fi
[ -n "$DTB" ] || DTB="$("${MERGE[@]}" pick "$BUILD/arch/arm64/boot/dts/apple" "$RUNNING")" || die "no matching dtb in $BUILD"

args=(merge --base "$BASE" --running "$RUNNING" --new "$DTB" --kernel "$KIMAGE"
	--initrd "$INITRAMFS" --park "$PARK" --out "$STATE/stage/fr.dtb")
if [ -n "$CMDLINE$APPEND" ]; then
	args+=(--cmdline "$(echo "${CMDLINE:-$cmdline} $APPEND" | sed 's/^ *//; s/ *$//')")
fi
say "building the DT (base $(basename "$BASE"), new $(basename "$DTB"), park $PARK)"
vars="$("${MERGE[@]}" "${args[@]}")"
eval "$vars"
cp "$DTB" "$STATE/base-$BASE_SHA.dtb"
printf '    kernel %s  initrd %s  dtb %s  purgatory %s\n' "$KERNEL_ADDR" "$INITRD_ADDR" "$DTB_ADDR" "$PURG_ADDR"
if [ "$DRY" = 1 ]; then
	echo "dry run: $STATE/stage/fr.dtb (dtc -I dtb -O dts to inspect); nothing sent"
	exit 0
fi

# 3. Send and load.
cp "$KIMAGE" "$STATE/stage/fr-Image"
cp "$INITRAMFS" "$STATE/stage/fr-initrd"
cp "$KL" "$STATE/stage/kexec-lite"
cp "$FR/kexec-jump.sh" "$STATE/stage/kexec-jump.sh"
say "pushing kernel, initrd, dtb, kexec-lite, kexec-jump.sh"
for f in kexec-lite kexec-jump.sh fr.dtb fr-initrd fr-Image; do "$PH" push "$STATE/stage/$f" >/dev/null; done
say "kexec_load"
"$PH" lock "chmod +x /tmp/6s/kexec-lite && /tmp/6s/kexec-lite load /tmp/6s/fr-Image@$KERNEL_ADDR /tmp/6s/fr-initrd@$INITRD_ADDR /tmp/6s/fr.dtb@$DTB_ADDR $PURG_ADDR; rc=\$?; rm -f /tmp/6s/fr-Image; echo loaded=\$(cat /sys/kernel/kexec_loaded); (exit \$rc)" 120 ||
	die "kexec_load failed (see above; dmesg on the phone has details). Nothing changed."
if [ "$LOADONLY" = 1 ]; then
	echo "loaded; jump with: testkit/phone.sh lock 'sh /tmp/6s/kexec-jump.sh'"
	exit 0
fi

# 4. Jump. kexec-jump.sh detaches (a systemd transient unit on the Arch userland),
#    unbinds the configfs gadget so dwc2 is stopped cleanly, then kexecs. The telnet
#    session used to prove the unbind by dying; a fast reload can instead bring the
#    new kernel's USB back up inside a single polling interval, so "the phone
#    answers" is no longer proof of anything by itself. Read
#    /proc/sys/kernel/random/boot_id before the jump and require it to change: a
#    reachable phone still reporting the old id means the jump never started (fail
#    fast), a changed id means the new kernel is up, and an unreachable phone is the
#    normal in-between (keep waiting, up to the timeout below for a real failure).
old_bootid="$("$PH" run 'cat /proc/sys/kernel/random/boot_id' 10)" || die "phone not reachable before the jump"
old_bootid="$(printf '%s' "$old_bootid" | tr -d '[:space:]')"
[ -n "$old_bootid" ] || die "could not read the phone's boot_id before the jump; not jumping"
jumpargs=""
[ "$QUIESCE" = 1 ] || jumpargs=--no-quiesce
say "kexec (USB gadget $([ "$QUIESCE" = 1 ] && echo "unbound first" || echo "left bound"))"
"$PH" lock "sh /tmp/6s/kexec-jump.sh $jumpargs" 40
say "waiting for the new kernel"
i=0
for _ in $(seq 1 75); do
	i=$((i + 1))
	new_bootid="$(python3 "$REPO/testkit/phone.py" 'cat /proc/sys/kernel/random/boot_id' 5 2>/dev/null)" || new_bootid=""
	new_bootid="$(printf '%s' "$new_bootid" | tr -d '[:space:]')"
	if [ -n "$new_bootid" ] && [ "$new_bootid" != "$old_bootid" ]; then
		"$PH" run 'uname -rv; echo "cpus online: $(cat /sys/devices/system/cpu/online)"; dmesg | grep -iE "spin-table park|smp: Brought up|CPU1: " | tail -4'
		echo "reload done in $(( $(date +%s) - t0 )) s"
		exit 0
	fi
	# Well past the jump script's own ~3 s detach+unbind delay: still seeing the old
	# id here means the jump did not start at all, not that it's still in flight.
	if [ -n "$new_bootid" ] && [ "$i" -ge 10 ]; then
		die "phone still answers on the old kernel (boot_id unchanged) after $((i * 2)) s: the jump did not start (check dmesg | grep fast-reload; journalctl -u 'fast-reload-jump-*')"
	fi
	sleep 2
done
die "new kernel not reachable after ~3 min (boot_id never changed from $old_bootid, phone unreachable). Look at the phone screen (fbcon), then recover the slow way:
  kit/boot.sh pongo && kit/boot.sh linux   (DFU)"
