#!/usr/bin/env bash
# Laptop side: stream the userland into the phone's RAM and (optionally) hand over.
#   tools/userland/push-rootfs.sh [rootfs.tar.xz]          push + unpack into /newroot
#   tools/userland/push-rootfs.sh --go [rootfs.tar.xz]     ... then switch_root and wait for ssh
# Uses testkit/phone.sh / phone.py and holds the shared phone lock while it
# talks to the phone (TESTING-RULES.md rule 3).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TK="${TK:-$HOME/Work/hoolock-iphone5s/testkit}"
LOCK="$HOME/Work/hoolock-iphone5s/.phone.lock"
GO=0; [ "${1:-}" = "--go" ] && { GO=1; shift; }
TAR="${1:-$HOME/Work/hoolock-iphone5s/build/userland/rootfs.tar.xz}"
P() { python3 "$TK/phone.py" "$@"; }

[ -s "$TAR" ] || { echo "no $TAR (run tools/userland/build-rootfs.sh)" >&2; exit 1; }
"$TK/phone.sh" ping >/dev/null || { echo "phone unreachable" >&2; exit 3; }
"$TK/phone.sh" push "$HERE/phone/stage2.sh"

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
