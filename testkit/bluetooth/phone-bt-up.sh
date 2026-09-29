#!/bin/sh
# Run ON THE PHONE (as root) after the bluetooth overlay bound hci0.
#   sh phone-bt-up.sh /tmp/6s/alp-bt.tgz [AA:BB:CC:DD:EE:FF]
# The address argument is optional: without it the controller keeps the
# Broadcom default 43:50:C5:00:1F:AC (patched kernels mark that invalid and
# leave hci0 unconfigured until an address is set). Use your phone's own
# address (Apple DT /arm-io/uart1/bluetooth local-mac-address, readable from
# /dev/mtd1ro with tools/adt2.py) - never publish it.
set -e
R=/tmp/alp
mkdir -p $R && cd $R && tar -xzf "$1"
for d in proc sys dev; do mountpoint -q $R/$d || mount --bind /$d $R/$d; done
mountpoint -q $R/run || mount -t tmpfs tmpfs $R/run
mkdir -p $R/run/dbus
[ -n "$2" ] && chroot $R btmgmt --index 0 public-addr "$2" && sleep 3
chroot $R btmgmt --index 0 power on
chroot $R btmgmt --index 0 le on
chroot $R btmgmt --index 0 ssp on
chroot $R /bt-start.sh
chroot $R hciconfig -a hci0
