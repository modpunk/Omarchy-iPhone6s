#!/bin/sh
# On-phone read-only probe for testkit/selftest.sh. POSIX sh (busybox ash on the
# ramdisk, bash on the Omarchy Phone userland) -- no bashisms.
#
# Prints one "SS:<section>:<key>:<value>" line per fact, then a free-form
# evidence block after a "---evidence---" marker. Never writes anything, never
# loads a module, never touches an overlay or a device tree. Safe to run any
# number of times, any number of times per boot, on any boot state.

kv() { printf 'SS:%s:%s:%s\n' "$1" "$2" "$3"; }

# ---------------------------------------------------------------- boot/kernel
rel="$(uname -r 2>/dev/null)"
kv boot release "${rel:-unknown}"
kv boot tainted "$(cat /proc/sys/kernel/tainted 2>/dev/null || echo '?')"
if [ -d /proc/device-tree/__symbols__ ]; then kv boot symbols yes; else kv boot symbols no; fi
# The printk ring buffer is finite (128 KiB here); after enough dyndbg-heavy module
# iterations the boot-time lines (including "Linux version", the DT probe errors this
# script greps for, and old firmware/patchram lines) scroll out. Flag it so the harness
# doesn't read an empty grep as a false PASS (badcell/oops) or false FAIL (bt/touch).
if dmesg 2>/dev/null | grep -q 'Linux version'; then kv boot dmesg_wrapped no; else kv boot dmesg_wrapped yes; fi
badcell=$(dmesg 2>/dev/null | grep -c 'Bad cell count')
kv boot badcell "$badcell"
oops=$(dmesg 2>/dev/null | grep -Ec 'Oops|Unable to handle kernel|Call trace|BUG:|Kernel panic')
kv boot oops "$oops"

# ------------------------------------------------------------------------ init
if [ -d /run/systemd/system ]; then
	kv init kind systemd
	state="$(systemctl is-system-running 2>/dev/null)"
	kv init state "${state:-unknown}"
	kv init failed_units "$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
else
	kv init kind ramdisk
	kv init comm1 "$(cat /proc/1/comm 2>/dev/null || echo '?')"
fi

# --------------------------------------------------------------------- battery
if grep -q '^mux_sn2400 ' /proc/modules 2>/dev/null; then kv battery mux_loaded yes; else kv battery mux_loaded no; fi
if grep -qE '^bq27xxx_battery_hdq_uart |^bq27xxx_hdq_uart_fix ' /proc/modules 2>/dev/null; then
	kv battery gauge_loaded yes
else
	kv battery gauge_loaded no
fi
bat_uevent=""
for f in /sys/class/power_supply/*/uevent; do
	[ -e "$f" ] || continue
	if grep -qE 'POWER_SUPPLY_VOLTAGE_NOW|POWER_SUPPLY_CAPACITY' "$f" 2>/dev/null; then
		bat_uevent="$f"
		break
	fi
done
if [ -n "$bat_uevent" ]; then
	kv battery supply_path "$bat_uevent"
	v=$(grep '^POWER_SUPPLY_VOLTAGE_NOW=' "$bat_uevent" | cut -d= -f2)
	c=$(grep '^POWER_SUPPLY_CAPACITY=' "$bat_uevent" | cut -d= -f2)
	kv battery voltage_uv "${v:-?}"
	kv battery capacity_pct "${c:-?}"
else
	kv battery supply_path none
fi

# ------------------------------------------------------------------- bluetooth
if grep -q '^gpio_apple_pmic ' /proc/modules 2>/dev/null; then kv bt pmic_loaded yes; else kv bt pmic_loaded no; fi
if [ -d /sys/class/bluetooth/hci0 ]; then kv bt hci0 yes; else kv bt hci0 no; fi
bcm_line="$(dmesg 2>/dev/null | grep -E 'BCM \([0-9.]+\) build [0-9a-fA-F]+' | tail -1)"
kv bt bcm_build_line "${bcm_line:-none}"

# ---------------------------------------------------------------- spi + touch
if [ -d /proc/device-tree/soc/spi@20a088000 ]; then kv touch spi2_node yes; else kv touch spi2_node no; fi
z2mod="$(grep -o '^apple_z2[a-z0-9_]*' /proc/modules 2>/dev/null | head -1)"
kv touch z2_module "${z2mod:-none}"
z2bound="$(readlink /sys/bus/spi/devices/spi0.0/driver 2>/dev/null)"
z2bound="${z2bound##*/}"
kv touch z2_bound "${z2bound:-none}"
if dmesg 2>/dev/null | grep -q 'firmware started at'; then kv touch fw_started yes; else kv touch fw_started no; fi
tdev="$(grep -l 'iPhone 6s Touchscreen' /sys/class/input/event*/device/name 2>/dev/null | head -1)"
kv touch input_dev "${tdev:-none}"
tclk_line="$(dmesg 2>/dev/null | grep 'touch_clk_t1:' | tail -1)"
kv touch tclk_last_line "${tclk_line:-none}"

# -------------------------------------------------------------------- display
fbsz="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
kv display fb0_size "${fbsz:-none}"
if [ -e /dev/dri/card0 ]; then kv display dri0 yes; else kv display dri0 no; fi

echo '---evidence---'
echo '# dmesg: Bad cell count'
dmesg 2>/dev/null | grep 'Bad cell count'
echo '# dmesg: oops/BUG candidates'
dmesg 2>/dev/null | grep -E 'Oops|Unable to handle kernel|Call trace|BUG:|Kernel panic'
echo '# dmesg: bluetooth patchram'
dmesg 2>/dev/null | grep -iE 'BCM4350|hci_uart_bcm|Patch'
echo '# dmesg: touch firmware/HBPP'
dmesg 2>/dev/null | grep -iE 'firmware started|HBPP|bootloader version'
echo '# power_supply uevents'
for f in /sys/class/power_supply/*/uevent; do [ -e "$f" ] && { echo "== $f"; cat "$f"; }; done
