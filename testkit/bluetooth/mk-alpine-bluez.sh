#!/usr/bin/env bash
# Build a small aarch64 Alpine chroot with BlueZ (bluetoothd, bluetoothctl,
# btmgmt, hciconfig/hcitool) + D-Bus for the phone's RAM ramdisk, which has
# no Bluetooth user space. Runs as a normal user on an x86_64 host.
#   ./mk-alpine-bluez.sh [outdir]   ->  <outdir>/alp-bt.tgz  (~6 MB)
set -euo pipefail
OUT="$(realpath "${1:-.}")"; W="$OUT/alpine-bt"; M=https://dl-cdn.alpinelinux.org/alpine/v3.24
mkdir -p "$W" && cd "$W"
[ -x sbin/apk.static ] || { curl -sfLO "$M/main/x86_64/apk-tools-static-3.0.8-r0.apk" \
	&& tar -xzf apk-tools-static-3.0.8-r0.apk sbin/apk.static; }
rm -rf root
./sbin/apk.static --usermode --arch aarch64 -X "$M/main" -X "$M/community" -U \
	--allow-untrusted --root "$W/root" --initdb --no-scripts --no-cache \
	add musl busybox bluez bluez-deprecated bluez-btmgmt dbus || true  # rc 2 from --no-scripts
[ -x root/usr/lib/bluetooth/bluetoothd ] || { echo "apk install failed" >&2; exit 1; }
cd root
mkdir -p etc run/dbus var/lib/bluetooth tmp proc sys dev
printf 'root:x:0:0:root:/root:/bin/sh\nmessagebus:x:100:101:messagebus:/var/run/dbus:/sbin/nologin\n' > etc/passwd
printf 'root:x:0:\nmessagebus:x:101:messagebus\n' > etc/group
cat > bt-start.sh <<'EOS'
#!/bin/sh
# inside the chroot: D-Bus system bus + bluetoothd
/bin/busybox --install -s /bin
rm -f /run/dbus/pid /run/dbus/system_bus_socket
dbus-uuidgen --ensure
dbus-daemon --system --fork
sleep 1
/usr/lib/bluetooth/bluetoothd -n > /tmp/bluetoothd.log 2>&1 &
sleep 2
echo started
EOS
chmod +x bt-start.sh
tar -czf "$OUT/alp-bt.tgz" .
echo "$OUT/alp-bt.tgz"
