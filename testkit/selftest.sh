#!/usr/bin/env bash
# Post-boot self-test for the iPhone 6s: bring up (optionally) and check every
# driver known to work, print a PASS/FAIL summary table, and exit non-zero on
# any regression. Read `TESTING-RULES.md` before touching --write.
#
#   testkit/selftest.sh                read-only: probe whatever this boot already has up
#   testkit/selftest.sh --write        also perform the approved loads/writes for anything
#                                      not already up (see "Approved writes" below), then probe
#   testkit/selftest.sh --only touch,bluetooth   run a subset (comma list; see --list)
#   testkit/selftest.sh --list         list check names and exit
#
# Every run is idempotent-ish: before loading a module or applying an overlay it checks
# whether the state is already there (module in /proc/modules, DT node present) and skips
# the load if so -- CONFIG_MODULE_UNLOAD is off on this phone (TESTING-RULES #4), so a second
# insmod of the same name fails, and overlays that bind a live UART/genpd node must never be
# removed (TESTING-RULES #11). Steps that load a module or apply an overlay are tagged
# "load" in the table; steps that need a state that only a fresh boot gives you (e.g. no z2
# driver bound yet) are tagged "fresh-boot" when that applies.
#
# Approved writes under --write (see docs/selftest.md "Write-gated steps and why"):
#   - SN2400 HDQ line-switch register (mux-sn2400 driver init)         -- battery
#   - PMIC GPIO 8 / BT REG_ON (gpio-apple-pmic driver init)            -- bluetooth
#   - PMGR touch clock (TCLK) enable, guarded read-verify-write        -- touch (touch_clk_t1)
# NOT performed even under --write: the Chestnut display-PMU analog LDO enable and any
# D2255 core-switch write for touch power-up. Those are raw register pokes that
# docs/drivers/touch.md flags as needing a fresh human/coordinator OK each time; this script
# only reads and reports their state. Set TOUCH_SUPPLY_CMD to a `phone.sh lock` command line
# of your own (already approved this session) to have --write run it before the touch modules.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PH="$HERE/phone.sh"
HOOLOCK="${HOOLOCK:-$HOME/Work/hoolock-iphone5s}"
DTC="${DTC:-$HOOLOCK/linux/scripts/dtc/dtc}"
DTC_FLAGS=(${DTC_FLAGS:--@})
LOGDIR="${SELFTEST_LOGDIR:-$HOOLOCK/build/selftest-logs}"
EXPECT_RELEASE="${EXPECT_RELEASE:-7.3.0-rc1-g6831bc701a6c}"

# --- resolvable build artifacts (override with env vars) --------------------
KINT="$HOOLOCK/build/integration/drivers"
MUX_KO="${MUX_KO:-$KINT/mux/mux-sn2400.ko}"
GAUGE_KO="${GAUGE_KO:-$KINT/power/supply/bq27xxx_battery_hdq_uart.ko}"
PMIC_GPIO_KO="${PMIC_GPIO_KO:-$KINT/gpio/gpio-apple-pmic.ko}"
SPI_KO="${SPI_KO:-$KINT/spi/spi-apple-s5l.ko}"
FND_PHANDLE_KO="${FND_PHANDLE_KO:-$HOOLOCK/build/fnd-test/phandle/fnd_phandle_v1.ko}"
BT_FIRMWARE="${BT_FIRMWARE:-/lib/firmware/brcm/BCM.apple,n71.hcd}"

TCLK_KO="${TCLK_KO:-$HOOLOCK/build/touch-next-mods-integ/tclk/touch_clk_t1.ko}"
# Latest apple_z2_nN.ko by directory version, unless Z2_KO is set explicitly.
resolve_z2() {
	[ -n "${Z2_KO:-}" ] && { echo "$Z2_KO"; return; }
	local d
	d="$(find "$HOOLOCK/build/touch-next-mods-integ" -maxdepth 1 -type d -name 'z2n*' 2>/dev/null | sort -V | tail -1)"
	[ -n "$d" ] && find "$d" -maxdepth 1 -name '*.ko' | head -1
}
Z2_KO="$(resolve_z2)"

BATTERY_OVERLAY="${BATTERY_OVERLAY:-$HERE/overlays/battery.dtso}"
BLUETOOTH_OVERLAY="${BLUETOOTH_OVERLAY:-$HERE/overlays/bluetooth-uart1.dtso}"
TOUCH_OVERLAY="${TOUCH_OVERLAY:-$HERE/overlays/touch-spi2-v1.dtso}"
TOUCH_SUPPLY_CMD="${TOUCH_SUPPLY_CMD:-}"

# --- args ---------------------------------------------------------------
WRITE=0
ONLY=""
CHECKS=(kernel_boot init battery bluetooth touch display usb_net_telnet)
while [ $# -gt 0 ]; do
	case "$1" in
	--write) WRITE=1 ;;
	--only) ONLY="$2"; shift ;;
	--list) printf '%s\n' "${CHECKS[@]}"; exit 0 ;;
	-h | --help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift
done

mkdir -p "$LOGDIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOGFILE="$LOGDIR/selftest-$TS.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "# iPhone 6s self-test $TS (write=$WRITE) -- log: $LOGFILE"

say() { echo "-- $*"; }
die() { echo "selftest: $*" >&2; exit "${2:-1}"; }

declare -A RESULT EVIDENCE TAGS
ORDER=()
record() { # name status evidence [tag]
	RESULT["$1"]="$2"; EVIDENCE["$1"]="$3"; TAGS["$1"]="${4:-}"; ORDER+=("$1")
}

run_if() {
	# run_if <check-name> : true if $ONLY is empty or lists this check
	[ -z "$ONLY" ] && return 0
	[[ ",$ONLY," == *",$1,"* ]]
}

# --- phone reachability (precondition; rule 8: stop, don't retry) -----------
if ! "$PH" ping >/dev/null 2>&1; then
	echo "PHONE UNREACHABLE -- stopping (TESTING-RULES #8: don't retry in a loop)."
	echo "Last thing this script tried to do: nothing yet (failed at the initial ping)."
	exit 3
fi

# ------------------------------------------------------------- write helpers
loaded() { # module name as it appears in /proc/modules (underscored)
	"$PH" run "grep -q '^$1 ' /proc/modules && echo yes || echo no" 10 2>/dev/null | tail -1 | tr -d '\r'
}
node_present() { # /proc/device-tree path
	"$PH" run "test -e '$1' && echo yes || echo no" 10 2>/dev/null | tail -1 | tr -d '\r'
}
phandle_of() { # power-controller path -> hex phandle or empty
	"$PH" run "od -An -tx1 '$1/phandle' 2>/dev/null | tr -d ' \n'" 10 2>/dev/null | tail -1 | tr -d '\r'
}
build_overlay() { # dtso -> dtbo path (host-side dtc build)
	local src="$1" out="${2:-${1%.dtso}.dtbo}"
	[ -x "$DTC" ] || die "dtc not found at $DTC (set DTC=)"
	"$DTC" "${DTC_FLAGS[@]}" -I dts -O dtb -o "$out" "$src" 2>&1 | sed 's/^/   dtc: /'
	echo "$out"
}
ensure_fnd_phandle() {
	if [ "$(loaded fnd_phandle_v1)" = yes ]; then
		say "fnd_phandle_v1 already loaded"
	else
		[ -f "$FND_PHANDLE_KO" ] || { echo "   fnd_phandle_v1.ko not found at $FND_PHANDLE_KO, skipping"; return 1; }
		say "insmod fnd_phandle_v1 (gives the off PMGR domains a phandle, in-memory DT only)"
		"$PH" insmod "$FND_PHANDLE_KO" | sed 's/^/   /'
	fi
}

write_battery() {
	echo "== battery: approved writes (mux-sn2400 HDQ line switch, SN2400 reg 0x1d)"
	[ "$(node_present /proc/device-tree/soc/serial@20a0d4000)" = yes ] && { echo "   serial5/gas-gauge node already present, nothing to apply"; } || {
		ensure_fnd_phandle
		local dtbo; dtbo="$(build_overlay "$BATTERY_OVERLAY")" || return 1
		say "applying battery overlay (once, never removed -- TESTING-RULES #11)"
		"$PH" overlay "$dtbo" | sed 's/^/   /'
	}
	if [ "$(loaded mux_sn2400)" = yes ]; then echo "   mux_sn2400 already loaded, skipping insmod"
	else [ -f "$MUX_KO" ] && { say "insmod mux-sn2400"; "$PH" insmod "$MUX_KO" | sed 's/^/   /'; } || echo "   $MUX_KO missing, skipping"; fi
	if [ "$(loaded bq27xxx_battery_hdq_uart)" = yes ] || [ "$(loaded bq27xxx_hdq_uart_fix)" = yes ]; then
		echo "   gauge module already loaded, skipping insmod"
	else [ -f "$GAUGE_KO" ] && { say "insmod bq27xxx_battery_hdq_uart"; "$PH" insmod "$GAUGE_KO" | sed 's/^/   /'; } || echo "   $GAUGE_KO missing, skipping"; fi
}

write_bluetooth() {
	echo "== bluetooth: approved write (PMIC GPIO 8 / REG_ON via gpio-apple-pmic)"
	if [ "$(loaded gpio_apple_pmic)" = yes ]; then echo "   gpio_apple_pmic already loaded, skipping insmod"
	else [ -f "$PMIC_GPIO_KO" ] && { say "insmod gpio-apple-pmic"; "$PH" insmod "$PMIC_GPIO_KO" | sed 's/^/   /'; } || echo "   $PMIC_GPIO_KO missing, skipping"; fi
	if [ "$("$PH" run "test -e '$BT_FIRMWARE' && echo yes || echo no" 10 | tail -1 | tr -d '\r')" != yes ]; then
		echo "   firmware not present at $BT_FIRMWARE on the phone -- push it per docs/drivers/bluetooth.md"
		echo "   'Firmware' section (never committed to git); not attempting it here."
	fi
	[ "$(node_present /proc/device-tree/soc/serial@20a0c4000)" = yes ] && { echo "   serial1/bluetooth node already present, nothing to apply"; } || {
		ensure_fnd_phandle
		local dtbo; dtbo="$(build_overlay "$BLUETOOTH_OVERLAY")" || return 1
		say "applying bluetooth overlay (once, never removed -- TESTING-RULES #11)"
		"$PH" overlay "$dtbo" | sed 's/^/   /'
	}
}

write_touch() {
	echo "== touch: approved write (PMGR touch clock, guarded read-verify-write); Chestnut/D2255"
	echo "   supply writes are NOT performed here (see header) unless TOUCH_SUPPLY_CMD is set."
	if [ -n "$TOUCH_SUPPLY_CMD" ]; then
		say "running TOUCH_SUPPLY_CMD (operator-supplied, already approved this session)"
		"$PH" lock "$TOUCH_SUPPLY_CMD" | sed 's/^/   /'
	fi
	[ "$(node_present /proc/device-tree/soc/spi@20a088000)" = yes ] && { echo "   spi2 node already present, nothing to apply"; } || {
		ensure_fnd_phandle
		if [ "$(loaded spi_apple_s5l)" = yes ]; then echo "   spi_apple_s5l already loaded"
		else [ -f "$SPI_KO" ] && { say "insmod spi-apple-s5l"; "$PH" insmod "$SPI_KO" | sed 's/^/   /'; } || echo "   $SPI_KO missing, skipping"; fi
		local dtbo; dtbo="$(build_overlay "$TOUCH_OVERLAY")" || return 1
		say "applying touch spi2 overlay (once, never removed -- TESTING-RULES #11)"
		"$PH" overlay "$dtbo" | sed 's/^/   /'
	}
	if [ -f "$TCLK_KO" ]; then
		# touch_clk_t1's init always returns -ECANCELED (see the .c), so the same
		# module name loads fine every time -- read pass first, then the approved write.
		say "insmod touch_clk_t1 (read pass)"
		"$PH" insmod "$TCLK_KO" | sed 's/^/   /'
		local val
		# decode("tclk", v) prints "tclk     <8-hex reg value>: disable ... unknown-bits <8-hex>"
		# -- take the FIRST 8-hex token (the register value), not the trailing unknown-bits one.
		val="$("$PH" run "dmesg | grep 'touch_clk_t1: tclk ' | tail -1" 10 | grep -oE '[0-9a-f]{8}' | head -1)"
		if [ -n "$val" ]; then
			# module_param(expect, uint) parses with base 0: it MUST have the 0x prefix
			# or "800002dc" reads as a bad decimal literal and insmod silently no-ops.
			say "insmod touch_clk_t1 enable=1 expect=0x$val (the approved clock write)"
			"$PH" insmod "$TCLK_KO" "enable=1 expect=0x$val" | sed 's/^/   /'
		else
			echo "   could not parse the current TCLK register value from dmesg; not writing it"
		fi
	else
		echo "   $TCLK_KO missing, skipping the clock step"
	fi
	if [ -n "$Z2_KO" ] && [ -f "$Z2_KO" ]; then
		local z2name; z2name="$(basename "$Z2_KO" .ko)"
		local bound; bound="$("$PH" run "readlink /sys/bus/spi/devices/spi0.0/driver 2>/dev/null" 10 | tail -1 | tr -d '\r')"
		bound="${bound##*/}"
		if [ "$bound" = "${z2name//_/-}" ] || [ "$bound" = "$z2name" ]; then
			echo "   $z2name already bound to spi0.0"
		elif [ -n "$bound" ] && [ "$bound" != none ]; then
			echo "   spi0.0 is bound to a different driver ($bound); not unbinding automatically"
			echo "   (CONFIG_MODULE_UNLOAD is off -- see docs/drivers/touch.md step 5b/5e to force a swap by hand)"
		else
			if [ "$(loaded "$z2name")" = yes ]; then echo "   $z2name already loaded"
			else say "insmod $z2name"; "$PH" insmod "$Z2_KO" | sed 's/^/   /'; fi
			say "binding $z2name to spi0.0 (driver_override + drivers_probe)"
			"$PH" lock "echo ${z2name//_/-} > /sys/bus/spi/devices/spi0.0/driver_override; echo spi0.0 > /sys/bus/spi/drivers_probe; sleep 3; dmesg | tail -30" 30 | sed 's/^/   /'
		fi
	else
		echo "   no apple_z2_n*.ko found under $HOOLOCK/build/touch-next-mods-integ, skipping"
	fi
}

if [ "$WRITE" = 1 ]; then
	run_if battery && write_battery
	run_if bluetooth && write_bluetooth
	run_if touch && write_touch
fi

# ---------------------------------------------------------------- read-only probe
say "pushing and running the on-phone read-only probe"
"$PH" push "$HERE/selftest-phone.sh" >/dev/null || die "could not push selftest-phone.sh"
PROBE_OUT="$("$PH" run 'sh /tmp/6s/selftest-phone.sh' 30)"
rc=$?
if [ $rc -eq 3 ]; then
	echo "PHONE WENT UNREACHABLE mid-run -- stopping (TESTING-RULES #8)."
	exit 3
fi
if [ $rc -eq 4 ]; then
	echo "PROBE TIMED OUT -- output below is partial, the table would be built on incomplete"
	echo "evidence. Not trusting it: re-run (a busy phone or a wedged shell, not a driver fact)."
	echo "$PROBE_OUT" | sed 's/^/   probe (partial): /'
	echo "log: $LOGFILE"
	exit 4
fi
echo "$PROBE_OUT" | sed 's/^/   probe: /'

get() { # section key
	printf '%s\n' "$PROBE_OUT" | sed -n "s/^SS:$1:$2://p" | head -1
}

# ------------------------------------------------------------------ checks
check_kernel_boot() {
	local rel symbols badcell oops tainted wrapped ok=1 msg="" tag=""
	rel=$(get boot release); symbols=$(get boot symbols); badcell=$(get boot badcell)
	oops=$(get boot oops); tainted=$(get boot tainted); wrapped=$(get boot dmesg_wrapped)
	[ "$rel" = "$EXPECT_RELEASE" ] || { ok=0; msg+="release '$rel' != expected '$EXPECT_RELEASE'; "; }
	[ "$symbols" = yes ] || { ok=0; msg+="no __symbols__; "; }
	local badcell_evid="$badcell" oops_evid="$oops"
	if [ "$wrapped" = yes ]; then
		# The printk ring buffer no longer holds "Linux version": boot-time lines (Bad
		# cell count, early oops) may have scrolled out already. A count of 0 here does
		# NOT mean it never happened -- don't let it read as a false PASS or false FAIL.
		badcell_evid="n/a (dmesg wrapped)"; oops_evid="n/a (dmesg wrapped)"
		tag="dmesg-wrapped"
	else
		[ "${badcell:-1}" = 0 ] || { ok=0; msg+="Bad cell count x$badcell; "; }
		[ "${oops:-1}" = 0 ] || { ok=0; msg+="oops/BUG lines=$oops; "; }
	fi
	local evid="release=$rel symbols=$symbols badcell=$badcell_evid oops=$oops_evid tainted=$tainted"
	[ $ok = 1 ] && record kernel_boot PASS "$evid" "$tag" || record kernel_boot FAIL "$evid -- $msg" "$tag"
}

check_init() {
	local kind; kind=$(get init kind)
	if [ "$kind" = systemd ]; then
		local state failed; state=$(get init state); failed=$(get init failed_units)
		if [ "$state" = running ] || [ "$state" = degraded ]; then
			record init PASS "systemd is-system-running=$state failed_units=${failed:-0}"
		else
			record init FAIL "systemd is-system-running=$state failed_units=${failed:-0}"
		fi
	elif [ "$kind" = ramdisk ]; then
		record init PASS "ramdisk, pid1=$(get init comm1)"
	else
		record init FAIL "could not classify init (probe output: kind='$kind')"
	fi
}

check_battery() {
	local mux gauge path v c
	mux=$(get battery mux_loaded); gauge=$(get battery gauge_loaded)
	path=$(get battery supply_path); v=$(get battery voltage_uv); c=$(get battery capacity_pct)
	local tag=""; [ "$mux" != yes ] || [ "$gauge" != yes ] || tag="load"
	if [ "$path" = none ] || [ -z "$path" ]; then
		record battery FAIL "mux_loaded=$mux gauge_loaded=$gauge no power_supply uevent found" "$tag"
		return
	fi
	local ok=1
	[[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 2500000 ] && [ "$v" -le 4500000 ] || ok=0
	[[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 0 ] && [ "$c" -le 100 ] || ok=0
	local evid="mux_loaded=$mux gauge_loaded=$gauge supply=$path voltage_uv=$v capacity_pct=$c"
	[ $ok = 1 ] && record battery PASS "$evid" "$tag" || record battery FAIL "$evid (implausible reading)" "$tag"
}

check_bluetooth() {
	local pmic hci0 bcm wrapped; pmic=$(get bt pmic_loaded); hci0=$(get bt hci0)
	bcm=$(get bt bcm_build_line); wrapped=$(get boot dmesg_wrapped)
	local tag=""; [ "$pmic" != yes ] || tag="load"
	# bcm_build_line comes from dmesg: a wrapped buffer can hide it even though hci0 is
	# genuinely up (patchram ran earlier this boot). hci0's own presence (sysfs, not
	# dmesg) still decides PASS/FAIL; the tag just tells you why the line might be gone.
	[ "$wrapped" = yes ] && tag="${tag:+$tag,}dmesg-wrapped"
	if [ "$hci0" = yes ] && [ -n "$bcm" ] && [ "$bcm" != none ] && [[ "$bcm" != *"build 0000"* ]]; then
		record bluetooth PASS "pmic_loaded=$pmic hci0=$hci0 $bcm" "$tag"
	else
		record bluetooth FAIL "pmic_loaded=$pmic hci0=$hci0 bcm_line=${bcm:-none}" "$tag"
	fi
}

check_touch() {
	local spi2 z2mod z2bound fw indev wrapped
	spi2=$(get touch spi2_node); z2mod=$(get touch z2_module); z2bound=$(get touch z2_bound)
	fw=$(get touch fw_started); indev=$(get touch input_dev); wrapped=$(get boot dmesg_wrapped)
	# touch always needs a load this boot (no auto-load path exists yet), tag it as such.
	# fw_started is dmesg-derived too: same wrap caveat as bluetooth's bcm_build_line.
	local tag="load"; [ "$wrapped" = yes ] && tag="$tag,dmesg-wrapped"
	if [ "$fw" = yes ] && [ -n "$indev" ] && [ "$indev" != none ]; then
		record touch PASS "spi2_node=$spi2 z2=$z2mod bound=$z2bound fw_started=$fw input_dev=$indev" "$tag"
	else
		record touch FAIL "spi2_node=$spi2 z2=$z2mod bound=$z2bound fw_started=$fw input_dev=${indev:-none}" "$tag,fresh-boot-helps"
	fi
}

check_display() {
	local fb dri; fb=$(get display fb0_size); dri=$(get display dri0)
	if [ "$fb" = "750,1334" ] && [ "$dri" = yes ]; then
		record display PASS "fb0=$fb dri0=$dri"
	else
		record display FAIL "fb0=${fb:-none} dri0=${dri:-no}"
	fi
}

check_usb_net_telnet() {
	record usb_net_telnet PASS "phone.sh ping succeeded over usb0 (172.16.42.1:23); this check's own precondition"
}

for c in "${CHECKS[@]}"; do
	run_if "$c" && "check_$c"
done

# ------------------------------------------------------------------- report
echo
printf '%-16s %-6s %-6s %s\n' "CHECK" "RESULT" "TAGS" "EVIDENCE"
OVERALL=PASS
for name in "${ORDER[@]}"; do
	printf '%-16s %-6s %-6s %s\n' "$name" "${RESULT[$name]}" "${TAGS[$name]:--}" "${EVIDENCE[$name]}"
	[ "${RESULT[$name]}" = PASS ] || OVERALL=FAIL
done
echo
echo "OVERALL: $OVERALL"
echo "log: $LOGFILE"
[ "$OVERALL" = PASS ]
