#!/bin/sh
# Runs ON THE PHONE (busybox ramdisk or the Arch userland). Pushed to /tmp/6s by
# kit/reload.sh after a successful `kexec-lite load`.
#
#   sh /tmp/6s/kexec-jump.sh            detach, then quiesce USB and kexec (prints "jumping")
#   sh /tmp/6s/kexec-jump.sh --no-quiesce   same, but jump with the gadget still bound
#   sh /tmp/6s/kexec-jump.sh --rehearse     unbind the gadget, wait 3 s, rebind it; no kexec
#                                           (USB drops for ~5 s, telnet then works again)
#
# The jump used to be a bare reboot(LINUX_REBOOT_CMD_KEXEC) with the USB gadget
# still bound. The only cleanup was dwc2's minimal .shutdown (interrupts masked,
# PHY powered down): no soft disconnect, no core reset, endpoints and DMA still
# armed in the core the next kernel inherits. Here the configfs gadget is
# unbound first. That runs the gadget
# stack's own teardown (pull-up off, endpoints disabled, udc_stop -> PHY powered
# down), the same path the ramdisk init takes every boot when it adds ACM.
#
# The telnet session that started this dies as soon as the UDC is unbound, so
# everything after "jumping" runs detached. Under systemd it runs as a
# transient unit, outside phone-telnetd.service's cgroup: if telnetd exited
# and systemd restarted it, the cgroup kill would stop this script halfway,
# with USB already gone (a DFU). Logs go to /dev/kmsg (fbcon shows them).
S="$(cd "$(dirname "$0")" && pwd)"
QUIESCE=1 REHEARSE=0
case "${1:-}" in
--no-quiesce) QUIESCE=0 ;;
--rehearse) REHEARSE=1 ;;
"") ;;
*) sed -n '5,8p' "$0"; exit 2 ;;
esac

log() { { echo "fast-reload: $*" > /dev/kmsg; } 2>/dev/null; }

jump() {
	bound="" rc=0
	sleep 1 # let the telnet reply reach the laptop
	if [ "$QUIESCE" = 1 ]; then
		cfs="${FAST_RELOAD_CONFIGFS:-$(awk '$3 == "configfs" { print $2; exit }' /proc/mounts)}"
		if [ -z "$cfs" ]; then
			# The Arch userland can't see the ramdisk's /config after switch_root;
			# configfs is one instance, so a fresh mount shows the same gadget.
			mkdir -p "$S/cfs" && mount -t configfs configfs "$S/cfs" && cfs="$S/cfs"
		fi
		for u in "$cfs"/usb_gadget/*/UDC; do
			[ -e "$u" ] || continue
			udc="$(cat "$u" 2>/dev/null)"
			[ -n "$udc" ] || continue
			log "unbinding ${u%/UDC} from $udc"
			if echo "" > "$u"; then bound="$bound $u=$udc"; else log "unbind of $u failed"; fi
		done
		# pull-up off -> host disconnect; endpoints and DMA idle; PHY down
		sleep 2
	fi
	if [ "$REHEARSE" = 1 ]; then
		sleep 1
		log "rehearsal: rebinding USB"
	else
		sync
		log "reboot(KEXEC)"
		"$S/kexec-lite" exec
		# Only reached if the kernel refused the jump: give USB back so the phone
		# stays reachable on the old kernel instead of needing a DFU.
		log "kexec did not happen, rebinding USB"
		rc=1
	fi
	for b in $bound; do echo "${b#*=}" > "${b%%=*}"; done
	return $rc
}

if [ "${FAST_RELOAD_DETACHED:-}" = 1 ]; then
	jump
	exit $?
fi

if [ "$REHEARSE" = 0 ]; then
	[ "$(cat /sys/kernel/kexec_loaded 2>/dev/null)" = 1 ] || { echo "kexec-jump: nothing loaded (kexec-lite load first)"; exit 1; }
	[ -x "$S/kexec-lite" ] || { echo "kexec-jump: $S/kexec-lite missing"; exit 1; }
fi

args="${1:-}"
to=""
command -v timeout >/dev/null 2>&1 && to="timeout 10"
if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1 &&
	$to systemd-run --quiet --collect --no-block --unit="fast-reload-jump-$$" \
		--setenv=FAST_RELOAD_DETACHED=1 /bin/sh "$S/kexec-jump.sh" ${args:+"$args"}; then
	echo "jumping (systemd unit fast-reload-jump-$$)"
else
	(trap '' HUP; export FAST_RELOAD_DETACHED=1; exec setsid /bin/sh "$S/kexec-jump.sh" ${args:+"$args"}) \
		</dev/null >/dev/null 2>&1 &
	echo "jumping"
fi
