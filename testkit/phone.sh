#!/usr/bin/env bash
# Shared 6s test helper. The phone is ONE tethered device on a RAM ramdisk:
# a crash costs the user a DFU cycle. Rules live in TESTING-RULES.md.
#
#   phone.sh run  '<cmd>' [timeout]   read-only command (no lock)
#   phone.sh push <file>              copy to /tmp/6s/<basename> on the phone (locked)
#   phone.sh insmod <file.ko> [args]  push + insmod (locked)
#   phone.sh overlay <file.dtbo>      push + apply via /dev/dtbo, prints overlay id (locked)
#   phone.sh ping                     is the phone alive?
#   phone.sh lock '<cmd>'             run a state-changing command under the lock
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCK="${PHONE_LOCK:-${HOOLOCK:-$HOME/Work/hoolock-iphone5s}/.phone.lock}"
P() { python3 "$HERE/phone.py" "$@"; }

locked() { exec 9>"$LOCK"; flock -w 1800 9 || { echo "phone lock busy >30min" >&2; exit 5; }; "$@"; }

ensure_loader() {
	P 'test -e /dev/dtbo' >/dev/null 2>&1 && return 0
	do_push "$HERE/dtbo_loader/dtbo_loader.ko"
	P 'insmod /tmp/6s/dtbo_loader.ko && ls -l /dev/dtbo'
}

do_push() {
	# ufw blocks inbound on the laptop, so the phone listens and we connect out.
	local f="$1" b port
	b="$(basename "$f")"
	port=$(( 20000 + RANDOM % 20000 ))
	# -s binds the listener to the USB address only (F8, security-review.md):
	# it must not start answering on Wi-Fi once a driver brings up another
	# interface.
	P "mkdir -p /tmp/6s && rm -f /tmp/6s/$b && (nc -l -p $port -s 172.16.42.1 > /tmp/6s/$b &) ; sleep 0.3" 15
	python3 -c 'import os,socket,sys; s=socket.create_connection((os.environ.get("PHONE_HOST","172.16.42.1"),int(sys.argv[2])),timeout=15); s.sendall(open(sys.argv[1],"rb").read()); s.shutdown(socket.SHUT_WR); s.recv(1); s.close()' "$f" "$port"
	sleep 0.5
	local want got
	want="$(md5sum < "$f" | cut -d' ' -f1)"
	got="$(P "md5sum /tmp/6s/$b" 15 | awk '{print $1}' | tail -1)"
	[ "$want" = "$got" ] || { echo "push of $b failed (md5 $got != $want)" >&2; return 1; }
	echo "pushed /tmp/6s/$b"
}

do_insmod() {
	local f="$1"; shift
	do_push "$f" && P "insmod /tmp/6s/$(basename "$f") $*; echo rc=\$?; dmesg | tail -25" 120
}

do_overlay() {
	ensure_loader
	do_push "$1" && P "cat /tmp/6s/$(basename "$1") > /dev/dtbo; echo rc=\$?; echo id=\$(cat /sys/class/misc/dtbo/last_id); dmesg | tail -15" 60
}

case "${1:-}" in
ping) P 'echo alive; uptime' 10 ;;
run) P "$2" "${3:-60}" ;;
push) locked do_push "$2" ;;
insmod) f="$2"; shift 2; locked do_insmod "$f" "$@" ;;
overlay) locked do_overlay "$2" ;;
lock) locked P "$2" "${3:-120}" ;;
*) sed -n '2,12p' "$0"; exit 1 ;;
esac
