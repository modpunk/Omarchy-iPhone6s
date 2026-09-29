#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Post-reboot, read-only touch bring-up for the iPhone 6s (steps 1-3 of
# docs/drivers/touch.md). It only probes: it powers the spi2 PMGR domain, binds the S5L
# SPI driver, applies the spi2 overlay ONCE and runs the HBPP liveness probe
# (bootloader version read). It STOPS before any PMIC/display-PMU write and
# just prints the write step 4 would need.
#
# Env: TESTKIT (default ~/Work/hoolock-iphone5s/testkit)
#      TOUCH_TREE  kernel tree with patches/touch applied (for spi-apple-s5l.c)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTKIT="${TESTKIT:-$HOME/Work/hoolock-iphone5s/testkit}"
TOUCH_TREE="${TOUCH_TREE:-$HOME/Work/hoolock-iphone5s/linux/.claude/worktrees/touch}"
PH="$TESTKIT/phone.sh"
DTC="${DTC:-$HOME/Work/hoolock-iphone5s/linux/scripts/dtc/dtc}"
OUT="${OUT:-$HOME/Work/hoolock-iphone5s/build/touch-live}"
SPI_NODE=/proc/device-tree/soc/spi@20a088000
PD=/proc/device-tree/soc/power-management@20e000000/power-controller@801c8

die() { echo "live-test: $*" >&2; exit 1; }

"$PH" ping >/dev/null || die "phone not answering"

# --- build (host only) -------------------------------------------------------
mkdir -p "$OUT"
for m in ttpwr_v1 tspis_v1 tz2probe_v1; do
	mkdir -p "$OUT/$m"
	cp "$HERE/live-test/$m.c" "$OUT/$m/"
	echo "obj-m += $m.o" > "$OUT/$m/Kbuild"
done
cp "$TOUCH_TREE/drivers/spi/spi-apple-s5l.c" "$OUT/tspis_v1/"
for m in ttpwr_v1 tspis_v1 tz2probe_v1; do
	"$TESTKIT/kbuild.sh" "$OUT/$m" >/dev/null || die "build of $m failed"
done
"$DTC" -@ -I dts -O dtb -o "$OUT/touch-spi2-v1.dtbo" \
	"$HERE/../../testkit/overlays/touch-spi2-v1.dtso" 2>/dev/null

# --- step 1: preconditions + power domain + controller driver -----------------
ph=$("$PH" run "hexdump -e '4/1 \"%02x\"' $PD/phandle 2>/dev/null" | tr -d '\r\n' | tail -c 8)
[ "$ph" = "0000f039" ] || die "ps_spi2 phandle is '$ph', expected 0000f039 (load fnd_phandle first)"
loaded() { "$PH" run "grep -q '^$1 ' /proc/modules && echo yes || echo no" | tail -1 | tr -d '\r'; }
for m in ttpwr_v1 tspis_v1; do
	if [ "$(loaded $m)" = yes ]; then echo "== $m already loaded"
	else echo "== insmod $m"; "$PH" insmod "$OUT/$m/$m.ko" | grep -E "ttpwr|rc=" || true; fi
done

# --- step 2: spi2 overlay, applied at most once per boot, never removed -------
if [ "$("$PH" run "test -d $SPI_NODE && echo yes || echo no" | tail -1 | tr -d '\r')" = yes ]; then
	echo "== spi2 node already present, not re-applying"
else
	echo "== applying spi2 overlay (keep it; never remove)"
	"$PH" overlay "$OUT/touch-spi2-v1.dtbo" | grep -E "rc=|id=|s5l|spi" || true
fi
"$PH" run "dmesg | grep -i -E 's5l|20a088000' | tail -5"

# --- step 3: HBPP liveness probe (reads only; reset re-asserted at end) -------
if [ "$(loaded tz2probe_v1)" = yes ]; then
	echo "== tz2probe_v1 already ran this boot; its log:"
else
	echo "== insmod tz2probe_v1"
	"$PH" insmod "$OUT/tz2probe_v1/tz2probe_v1.ko" >/dev/null || true
fi
"$PH" run "dmesg | grep -E 'tz2probe|z2probe|spi_setup|HBPP|ATN_ACK|N1 version|SPI_APU_EN|irq' | tail -30"

# --- step 4: NOT done here ---------------------------------------------------
cat <<'MSG'

== STOP. Step 4 needs explicit human approval (display-PMU write):
   Chestnut display PMU, i2c0 addr 0x27, register 0x05: read-modify-write
   value |= 0x10  (touch analog LDO, ADT function-power_ana select 2, options 3),
   exactly what iOS AppleChestnutDisplayPMU::setLDO does. Last read value was 0x0f.
   Nothing was written by this script.
MSG
