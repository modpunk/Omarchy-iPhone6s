#!/usr/bin/env bash
# Laptop side: stream the userland into the phone's RAM and (optionally) hand over.
#   tools/userland/push-rootfs.sh [rootfs.tar.xz]          push + unpack into /newroot
#   tools/userland/push-rootfs.sh --go [rootfs.tar.xz]     ... then switch_root and wait for ssh
# Uses testkit/phone.sh / phone.py and holds the shared phone lock while it
# talks to the phone (TESTING-RULES.md rule 3).
# Also, every run: sets the phone clock and timezone from this host (the phone
# has no RTC worth trusting -- it reads 2021 -- and no internet/NTP of its own
# yet, so the laptop, which is NTP-synced, is the clock source), and if
# present pushes the per-phone Bluetooth files into the new root's
# /etc/omarchy-phone/ (read at boot by omarchy-phone-bt-address/-bt-keys.service).
# They stay out of the image:
#   BT_ADDR_FILE (default ~/Work/hoolock-iphone5s/firmware/bt-bdaddr-omarchy.local)
#   BT_KEYS_TGZ  (default ~/Work/hoolock-iphone5s/firmware/bt-keys/var-lib-bluetooth.tgz,
#                 a tarball of /var/lib/bluetooth with members bluetooth/...)
#   NO_BT_SEED=1 skips them.
#   PHONE_TZ     override the timezone pushed to the phone (default: read off
#                this laptop, `timedatectl show -p Timezone --value` or the
#                /etc/localtime symlink target). PHONE_TZ=UTC leaves the image
#                default (UTC) alone.
# Also provisions the shell's lock-screen PIN (docs/shell/DESIGN.md "Lock
# screen PIN"), independent of the BT seed above: if set, it's pushed the same
# way (fixed name, private temp dir, 0600, never printed) and stage2.sh runs
# `ophone-pin set` inside /newroot with it before "go" -- see docs/userland.md
# "Lock screen PIN provisioning". Never baked into the image or committed:
#   PHONE_PIN_FILE (default ~/Work/hoolock-iphone5s/firmware/phone-pin.local,
#                   one line, 4-12 digits) used automatically if present.
#   PROMPT_PIN=1   prompt for it instead (twice, not echoed), when attached to
#                  a terminal and PHONE_PIN_FILE is missing/empty.
#   NO_PIN=1       skip PIN provisioning even if PHONE_PIN_FILE has content.
# Manual alternative, any time, no laptop-side file needed:
#   ssh omarchy@172.16.42.1 sudo ophone-pin set
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HOME/Work/hoolock-iphone5s/testkit}"
LOCK="$HOME/Work/hoolock-iphone5s/.phone.lock"
GO=0; [ "${1:-}" = "--go" ] && { GO=1; shift; }
TAR="${1:-$HOME/Work/hoolock-iphone5s/build/userland/rootfs.tar.xz}"
BT_ADDR_FILE="${BT_ADDR_FILE:-$HOME/Work/hoolock-iphone5s/firmware/bt-bdaddr-omarchy.local}"
BT_KEYS_TGZ="${BT_KEYS_TGZ:-$HOME/Work/hoolock-iphone5s/firmware/bt-keys/var-lib-bluetooth.tgz}"
PHONE_PIN_FILE="${PHONE_PIN_FILE:-$HOME/Work/hoolock-iphone5s/firmware/phone-pin.local}"
P() { python3 "$TK/phone.py" "$@"; }

[ -s "$TAR" ] || { echo "no $TAR (run tools/userland/build-rootfs.sh)" >&2; exit 1; }
"$TK/phone.sh" ping >/dev/null || { echo "phone unreachable" >&2; exit 3; }
"$TK/phone.sh" push "$HERE/phone/stage2.sh"
# Secrets: pushed under fixed names from a private temp dir, never printed.
# (phone.sh push takes the phone lock itself, so this runs before we hold it.)
seed="$(mktemp -d)"; trap 'rm -rf "$seed"' EXIT; chmod 700 "$seed"
if [ -z "${NO_BT_SEED:-}" ]; then
	if [ -s "$BT_ADDR_FILE" ]; then
		tr -d ' \t\r\n' < "$BT_ADDR_FILE" | grep -Eqx '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
			|| { echo "$BT_ADDR_FILE is not one XX:XX:XX:XX:XX:XX address" >&2; exit 1; }
		install -m 600 "$BT_ADDR_FILE" "$seed/bt-address"
	fi
	[ -s "$BT_KEYS_TGZ" ] && install -m 600 "$BT_KEYS_TGZ" "$seed/bt-keys.tgz"
fi
pin_pushed=0
if [ -z "${NO_PIN:-}" ]; then
	pin=""
	if [ -s "$PHONE_PIN_FILE" ]; then
		pin="$(tr -d ' \t\r\n' < "$PHONE_PIN_FILE")"
	elif [ -n "${PROMPT_PIN:-}" ]; then
		if [ -t 0 ]; then
			while :; do
				read -r -s -p "Phone lock-screen PIN (4-12 digits, not shown): " pin1; echo >&2
				read -r -s -p "Confirm PIN: " pin2; echo >&2
				if [ "$pin1" = "$pin2" ]; then pin="$pin1"; break; fi
				echo "PINs didn't match, try again" >&2
			done
			unset pin1 pin2
		else
			echo "PROMPT_PIN=1 but stdin isn't a terminal: skipping PIN provisioning" >&2
		fi
	fi
	if [ -n "$pin" ]; then
		if printf '%s' "$pin" | grep -Eqx '[0-9]{4,12}'; then
			install -m 600 /dev/null "$seed/phone-pin"
			printf '%s' "$pin" > "$seed/phone-pin"
			pin_pushed=1
		else
			echo "PIN must be 4-12 digits: skipping PIN provisioning" >&2
		fi
	fi
	unset pin
fi
if [ -z "$(ls -A "$seed" 2>/dev/null)" ]; then
	echo "no Bluetooth address/keys or PIN found: skipping the BT seed and PIN provisioning"
else
	for f in "$seed"/*; do
		"$TK/phone.sh" push "$f" >/dev/null 2>&1 || { echo "push of $(basename "$f") failed" >&2; exit 1; }
		[ "$(basename "$f")" = phone-pin ] && echo "pushed phone-pin (never printed)" || echo "pushed $(basename "$f")"
	done
fi
rm -f "$seed"/*

exec 9>"$LOCK"; flock -w 1800 9 || { echo "phone lock busy" >&2; exit 5; }
P 'sh /tmp/6s/stage2.sh prep' 30
port=$(( 20000 + RANDOM % 20000 ))
P "(sh /tmp/6s/stage2.sh recv $port > /tmp/6s/recv.log 2>&1 &) ; sleep 1" 20
echo "streaming $(du -h "$TAR" | cut -f1) to :$port (phone unxz is the bottleneck, allow a few minutes)"
python3 - "$TAR" "$port" <<'PY'
import socket, sys, time, os
path, port = sys.argv[1], int(sys.argv[2])
for i in range(20):
    try: s = socket.create_connection(("172.16.42.1", port), timeout=15); break
    except OSError: time.sleep(0.5)
else: sys.exit("could not connect to the phone's nc")
s.settimeout(600)
total, sent, t0 = os.path.getsize(path), 0, time.time()
with open(path, "rb") as f:
    while (b := f.read(1 << 20)):
        s.sendall(b); sent += len(b)
        print(f"\r  {sent>>20}/{total>>20} MiB  {sent/(time.time()-t0)/1e6:.1f} MB/s", end="", flush=True)
s.shutdown(socket.SHUT_WR)
try: s.recv(1)
except OSError: pass
s.close(); print()
PY
for _ in $(seq 1 180); do
	rc="$(P 'cat /tmp/6s/unpack.rc 2>/dev/null' 15 | tr -dc '0-9' || true)"
	[ -n "$rc" ] && break
	sleep 5
done
P 'sh /tmp/6s/stage2.sh status' 30
want="$(md5sum < "$TAR" | cut -d' ' -f1)"
got="$(P 'cat /tmp/6s/unpack.md5' 15 | tr -dc '0-9a-f')"
[ "$rc" = 0 ] && [ "$want" = "$got" ] || { echo "unpack FAILED (rc=${rc:-?}, md5 $got vs $want)" >&2; exit 1; }
echo "unpacked OK (md5 $want)"
[ -n "${NO_BT_SEED:-}" ] || P 'sh /tmp/6s/stage2.sh seed' 20
if [ "$pin_pushed" = 1 ]; then P 'sh /tmp/6s/stage2.sh pin' 30; fi
# The RTC reads 2021; the kernel clock survives switch_root.
P "date -u -s @$(date -u +%s) >/dev/null && echo \"phone clock: \$(date -u)\"" 20
if [ "${PHONE_TZ:-}" = "UTC" ]; then
	echo "PHONE_TZ=UTC: leaving the phone on the image default (UTC)"
else
	tz="${PHONE_TZ:-}"
	[ -n "$tz" ] || tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
	[ -n "$tz" ] || tz="$(readlink -f /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')"
	if [ -z "$tz" ]; then
		echo "no timezone detected on this laptop; phone stays on UTC (set PHONE_TZ=<zone> to force one)" >&2
	elif ! printf '%s' "$tz" | grep -Eq '^[A-Za-z0-9_+/-]+$'; then
		echo "timezone '$tz' has unexpected characters; phone stays on UTC (set PHONE_TZ=<zone> to force one)" >&2
	else
		P "sh /tmp/6s/stage2.sh timezone '$tz'" 15
	fi
fi
[ "$GO" = 1 ] || { echo "next: $TK/phone.sh lock 'sh /tmp/6s/stage2.sh go'   (or rerun with --go)"; exit 0; }

P 'sh /tmp/6s/stage2.sh go' 30 || true
flock -u 9
echo "waiting for sshd on 172.16.42.1 ..."
for _ in $(seq 1 60); do
	if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
		root@172.16.42.1 'cat /etc/omarchy-phone-release; systemctl is-system-running' 2>/dev/null; then
		exit 0
	fi
	sleep 3
done
echo "no ssh after 3 min: try kit/boot.sh shell (USB serial, autologin root) or phone.sh ping" >&2
exit 4
