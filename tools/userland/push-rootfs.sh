#!/usr/bin/env bash
# Laptop side: stream the userland into the phone's RAM and (optionally) hand over.
#   tools/userland/push-rootfs.sh [rootfs.tar.xz]          push + unpack into /newroot
#   tools/userland/push-rootfs.sh --go [rootfs.tar.xz]     ... then switch_root and wait for ssh
# Uses testkit/phone.sh / phone.py and holds the shared phone lock while it
# talks to the phone (TESTING-RULES.md rule 3).
# Also, every run: sets the phone clock from this host, and if present pushes
# the per-phone Bluetooth files into the new root's /etc/omarchy-phone/ (read at
# boot by omarchy-phone-bt-address/-bt-keys.service). They stay out of the image:
#   BT_ADDR_FILE (default ~/Work/hoolock-iphone5s/firmware/bt-bdaddr-omarchy.local)
#   BT_KEYS_TGZ  (default ~/Work/hoolock-iphone5s/firmware/bt-keys/var-lib-bluetooth.tgz,
#                 a tarball of /var/lib/bluetooth with members bluetooth/...)
#   NO_BT_SEED=1 skips them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HOME/Work/hoolock-iphone5s/testkit}"
LOCK="$HOME/Work/hoolock-iphone5s/.phone.lock"
GO=0; [ "${1:-}" = "--go" ] && { GO=1; shift; }
TAR="${1:-$HOME/Work/hoolock-iphone5s/build/userland/rootfs.tar.xz}"
BT_ADDR_FILE="${BT_ADDR_FILE:-$HOME/Work/hoolock-iphone5s/firmware/bt-bdaddr-omarchy.local}"
BT_KEYS_TGZ="${BT_KEYS_TGZ:-$HOME/Work/hoolock-iphone5s/firmware/bt-keys/var-lib-bluetooth.tgz}"
P() { python3 "$TK/phone.py" "$@"; }

[ -s "$TAR" ] || { echo "no $TAR (run tools/userland/build-rootfs.sh)" >&2; exit 1; }
"$TK/phone.sh" ping >/dev/null || { echo "phone unreachable" >&2; exit 3; }
"$TK/phone.sh" push "$HERE/phone/stage2.sh"
# Secrets: pushed under fixed names from a private temp dir, never printed.
# (phone.sh push takes the phone lock itself, so this runs before we hold it.)
if [ -z "${NO_BT_SEED:-}" ]; then
	seed="$(mktemp -d)"; trap 'rm -rf "$seed"' EXIT; chmod 700 "$seed"
	if [ -s "$BT_ADDR_FILE" ]; then
		tr -d ' \t\r\n' < "$BT_ADDR_FILE" | grep -Eqx '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
			|| { echo "$BT_ADDR_FILE is not one XX:XX:XX:XX:XX:XX address" >&2; exit 1; }
		install -m 600 "$BT_ADDR_FILE" "$seed/bt-address"
	fi
	[ -s "$BT_KEYS_TGZ" ] && install -m 600 "$BT_KEYS_TGZ" "$seed/bt-keys.tgz"
	for f in "$seed"/*; do
		[ -e "$f" ] || { echo "no Bluetooth address/keys found: skipping the BT seed"; break; }
		"$TK/phone.sh" push "$f" >/dev/null 2>&1 || { echo "push of $(basename "$f") failed" >&2; exit 1; }
		echo "pushed $(basename "$f")"
	done
fi

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
# The RTC reads 2021; the kernel clock survives switch_root.
P "date -u -s @$(date -u +%s) >/dev/null && echo \"phone clock: \$(date -u)\"" 20
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
