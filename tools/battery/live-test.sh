#!/usr/bin/env bash
# iPhone 6s battery fuel gauge live test (docs/drivers/battery.md).
#
#   tools/battery/live-test.sh [--write] [MODDIR]
#
# Without --write: read-only checks, then loads the modules and the overlay but
# binds only a read-only SN2400 "peek" driver, so the charger is READ, never
# written. It prints what --write would write and stops.
# With --write: swaps the peek driver for the real SN2400 mux driver, which
# writes charger reg 0x1d (0x04 request / 0x06 charger master / 0x00 none, the
# values iOS uses, each read back and logged), and lets the gauge probe.
# Needs the user's approval for SN2400 writes (TESTING-RULES.md).
#
# MODDIR holds mux_core_v1.ko sn2400_peek_v1.ko sn2400_mux_v1.ko
# bq27xxx_hdq_uart_v2.ko built with testkit/kbuild.sh (see the doc).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
PH="$HERE/testkit/phone.sh"
WRITE=0
[ "${1:-}" = "--write" ] && { WRITE=1; shift; }
MOD="${1:-$HOME/Work/hoolock-iphone5s/linux/.claude/worktrees/battery/.6s-test}"
DTC="${DTC:-$HOME/Work/hoolock-iphone5s/linux/scripts/dtc/dtc}"
run() { "$PH" run "$1" "${2:-60}"; }
say() { printf '\n== %s\n' "$*"; }
loaded() { run "grep -q '^$1 ' /proc/modules && echo y || echo n" | tail -1; }

say "0. read-only checks"
"$PH" ping
run 'uname -r; echo oopses: $(dmesg | grep -ci oops)'
for l in serial5 i2c1 pinctrl_ap; do
	p=$(run "cat /proc/device-tree/__symbols__/$l 2>/dev/null" | tr -d '\0' | tail -1)
	[ -n "$p" ] || { echo "no __symbols__/$l: wrong base DT, stop"; exit 1; }
	echo "$l -> $p status=$(run "cat /proc/device-tree$p/status 2>/dev/null || echo okay" | tr -d '\0' | tail -1)"
done
if run 'ls -d /proc/device-tree/soc/i2c@20a111000/charger@75 2>/dev/null' | grep -q charger; then
	OVL=1; echo "overlay already applied"
else
	OVL=0
	s5=$(run 'p=$(cat /proc/device-tree/__symbols__/serial5); cat /proc/device-tree$p/status' | tr -d '\0' | tail -1)
	[ "$s5" = "okay" ] && { echo "serial5 already enabled by someone else, stop"; exit 1; }
fi
BUILTIN_MUX=$(run 'grep -c " mux_chip_register$" /proc/kallsyms' | tail -1)
echo "built-in mux core symbols: $BUILTIN_MUX"

say "1. modules + overlay (SN2400 read-only)"
if [ "$BUILTIN_MUX" = "0" ] && [ "$(loaded mux_core_v1)" = n ]; then "$PH" insmod "$MOD/mux_core_v1.ko" | tail -2; fi
[ "$(loaded bq27xxx_hdq_uart_v2)" = n ] && "$PH" insmod "$MOD/bq27xxx_hdq_uart_v2.ko" dyndbg=+p | tail -2
[ "$(loaded sn2400_mux_v1)" = n ] && [ "$(loaded sn2400_peek_v1)" = n ] && "$PH" insmod "$MOD/sn2400_peek_v1.ko" | tail -2
if [ "$OVL" = 0 ]; then
	"$DTC" -q -@ -I dts -O dtb -o /tmp/battery-labels.dtbo "$HERE/testkit/overlays/battery-labels.dtso"
	"$PH" overlay /tmp/battery-labels.dtbo | tail -8
fi
sleep 2
run 'dmesg | grep -E "sn2400|bq27xxx_hdq|20a0d4000|20a111000" | tail -15; echo deferred:; cat /sys/kernel/debug/devices_deferred'
R1D=$(run 'dmesg | grep -o "reg1d=0x[0-9a-f]*" | tail -1 | cut -d= -f2' | tail -1)
echo "SN2400 reg 0x1d at boot: ${R1D:-unknown}"

if [ -n "$R1D" ] && [ "$R1D" != "unknown" ]; then
	v=$((R1D))
	if (( v & 2 )); then idle="2 (charger master): write 0x04, poll bit5, write 0x06"
	elif (( v & 4 )); then idle="1 (host): write 0x04, poll bit5"
	else idle="0 (none): write 0x00"; fi
else idle="unknown (peek failed: check i2c1)"; fi
cat <<EOF
--write would, via sn2400_mux_v1:
  at registration : restore idle state $idle
  per gauge read  : write 0x1d=0x04, poll 0x1d until bit 5 (1 s), HDQ transfers,
                    then restore idle state $idle
  every write is read back and logged ("HDQ state N: control now 0x..")
EOF
[ "$WRITE" = 1 ] || { echo "stopping before any SN2400 write (rerun with --write)"; exit 0; }

say "2. SN2400 writes enabled"
if [ "$(loaded sn2400_peek_v1)" = y ]; then
	"$PH" lock 'for d in /sys/bus/i2c/drivers/sn2400_peek_v1/*-0075; do [ -e "$d" ] && echo $(basename $d) > /sys/bus/i2c/drivers/sn2400_peek_v1/unbind; done; echo unbound'
fi
[ "$(loaded sn2400_mux_v1)" = n ] && "$PH" insmod "$MOD/sn2400_mux_v1.ko" dyndbg=+p | tail -4
sleep 3
run 'dmesg | grep -E "sn2400|bq27xxx_hdq" | tail -40'
say "3. power_supply"
run 'for f in /sys/class/power_supply/*/uevent; do echo "# $f"; cat $f; done'
run 'dmesg | grep "HDQ state" | tail -1'
