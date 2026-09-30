# Post-boot self-test

`testkit/selftest.sh` (laptop side) + `testkit/selftest-phone.sh` (pushed to and run on the
phone) bring up and check every driver known to work, in order, and print a PASS/FAIL table so a
regression in any of them shows up immediately instead of being noticed three driver series
later. Built without touching a live phone (see `testkit/TESTING-RULES.md`); it drives the phone
only through `testkit/phone.sh`, exactly like every other tool here.

## Run it

```sh
testkit/selftest.sh                          # read-only: probe whatever this boot already has up
testkit/selftest.sh --write                  # also perform the approved loads/writes first
testkit/selftest.sh --only battery,touch      # run a subset
testkit/selftest.sh --list                   # print check names and exit
```

Exit code: `0` if every check PASSED, `1` if any FAILED, `3` if the phone didn't answer
`phone.sh ping` (rule 8: this script stops immediately, it does not retry in a loop), `4` if the
on-phone probe itself timed out mid-run (the table is not printed in that case -- a partial probe
built into a confident-looking PASS/FAIL table would be worse than no table). Run this within the
first few minutes after a fresh boot: the printk ring buffer is only 128 KiB, and a day of
dyndbg-heavy driver iteration can scroll the boot-time lines (`Bad cell count`, early oops,
patchram/firmware lines) out of it. When that's happened the probe sets `dmesg_wrapped`, and
`kernel_boot`/`bluetooth`/`touch` carry a `dmesg-wrapped` tag with `n/a (dmesg wrapped)` or a
FAIL in the evidence column for anything that check reads out of `dmesg` -- that tag means
"re-test on a fresh boot", not "regression". A full
transcript (the on-phone probe's raw output, everything `--write` did, and the summary table) is
appended to a timestamped file under `$HOOLOCK/build/selftest-logs/` (printed at the end of the
run) so two runs can be diffed.

## What it checks, in order

| # | check | PASS bar | needs a load this boot? |
|---|---|---|---|
| 1 | `kernel_boot` | `uname -r` matches the pinned release (`7.3.0-rc1-g6831bc701a6c` by default, `EXPECT_RELEASE=` to override for a kexec'd/rebuilt kernel), `/proc/device-tree/__symbols__` exists, zero `"Bad cell count"` lines, zero oops/BUG/panic lines in `dmesg`, plus `tainted` reported for context | no, always read-only |
| 2 | `init` | Arch userland: `systemctl is-system-running` is `running` or `degraded` (with `systemctl --failed` count as evidence -- `degraded` still PASSes, a failed unit is visible in the evidence column, not silently hidden); plain ramdisk: PID 1 is a shell/init, reported as evidence | no |
| 3 | `battery` | a `/sys/class/power_supply/*/uevent` exists with `VOLTAGE_NOW` in 2.5-4.5 V and `CAPACITY` 0-100 | only if the modules aren't already loaded (they auto-load on the Arch userland image; see `docs/userland.md` "Kernel asks") |
| 4 | `bluetooth` | `/sys/class/bluetooth/hci0` exists and the last `dmesg` `BCM (...) build ....` line is not build `0000` (proves the patchram actually ran, not just that the stock firmware answered) | only if not already loaded/brought up (again auto on the Arch image via `omarchy-phone-bt-address.service`) |
| 5 | `touch` | `dmesg` has a `"firmware started at 0x......"` line (from the current `apple_z2_nN` driver -- see `docs/drivers/touch.md`) **and** an input device named `iPhone 6s Touchscreen` exists | **yes, always** -- nothing loads touch automatically yet |
| 6 | `display` | `/sys/class/graphics/fb0/virtual_size` is `750,1334` and `/dev/dri/card0` exists | no |
| 7 | `usb_net_telnet` | trivially PASS -- reaching this point already proves it: the whole run is driven over the USB gadget + telnet, so a working `phone.sh ping` at the top *is* the evidence | no (it's the harness's own precondition) |

Every check prints its evidence line in the table, e.g.:

```
CHECK            RESULT TAGS   EVIDENCE
kernel_boot      PASS   -      release=7.3.0-rc1-g6831bc701a6c symbols=yes badcell=0 oops=0 tainted=0
init             PASS   -      systemd is-system-running=running failed_units=0
battery          PASS   -      mux_loaded=yes gauge_loaded=yes supply=/sys/class/power_supply/bq27540-0/uevent voltage_uv=3856000 capacity_pct=63
bluetooth        PASS   -      pmic_loaded=yes hci0=yes ...BCM (003.006.007) build 0825
touch            PASS   load   spi2_node=yes z2=apple_z2_n7 bound=apple-z2-n7 fw_started=yes input_dev=/sys/class/input/event3/device/name
display          PASS   -      fb0=750,1334 dri0=yes
usb_net_telnet   PASS   -      phone.sh ping succeeded over usb0 (172.16.42.1:23); this check's own precondition

OVERALL: PASS
```

A `load` tag means that check needed something inserted/applied *this boot* to reach PASS (so a
FAIL there after a fresh boot without `--write` is expected, not a regression -- re-run with
`--write`). `touch` always carries `load` because nothing brings it up automatically yet.

## Idempotent-ish, given no module unload

`CONFIG_MODULE_UNLOAD` is off on this phone (`TESTING-RULES.md` #4): the same module name can be
`insmod`'d exactly once per boot. `--write` checks first and skips anything already there:

- **Module already loaded?** `grep '^<name> ' /proc/modules` on the phone before every `insmod`.
- **DT node already present?** (e.g. `/proc/device-tree/soc/serial@20a0d4000` for the battery
  gauge, `.../serial@20a0c4000` for bluetooth, `.../spi@20a088000` for touch) before building and
  applying an overlay. **Overlays are never removed** by this script, in either mode (rule #11:
  removing a bound `samsung-uart` node or an `apple,pmgr-pwrstate` provider oopses the kernel).
- `touch_clk_t1.ko`'s `init` always returns `-ECANCELED` on purpose (see the `.c`), so it can be
  `insmod`'d again every run without hitting the name-reuse limit -- that's how the script gets a
  fresh register read every time before deciding whether to also write it.
- The touch `apple_z2_nN` driver is the one exception that legitimately needs a **fresh boot** to
  re-test cleanly: if a *different* `z2n*` variant is already bound to `spi0.0`, the script does
  not unbind/rmmod it (rmmod would fail with unload off anyway) -- it reports which one is bound
  and leaves it, per `docs/drivers/touch.md` step 5b/5e ("only OK to swap by hand, on the same
  boot, if you understand why").

## Write-gated steps and why (`--write`)

Everything above runs read-only by default -- no `insmod`, no overlay `apply`, ever, unless
`--write` is passed. Under `--write`, this script performs exactly the writes the project has
already agreed are safe to repeat:

- **SN2400 HDQ line-switch register (`0x1d`)** -- happens inside `mux-sn2400`'s own driver init,
  not a raw poke from this script.
- **PMIC GPIO 8 / Bluetooth `REG_ON`** -- happens inside `gpio-apple-pmic`'s driver init the same
  way.
- **PMGR touch clock (TCLK) enable** -- `touch_clk_t1.ko enable=1 expect=<value just read this
  boot>`, which only writes if the register still reads exactly what was just read (the same
  guard the module's own comment describes), then leaves the clock running.

These three are the "approved-writes list" the task that produced this harness referred to as
"`TESTING-RULES` rule 13". **As of this commit, `testkit/TESTING-RULES.md` only has 12 numbered
rules** (checked against `main` and every other branch in this repo) -- rule 13 had apparently
been agreed live but not yet written down anywhere this build-only pass could read. Whoever lands
rule 13 should reconcile its exact wording against the three writes above (and this file), and
this script's `MUX_KO`/`PMIC_GPIO_KO`/`TCLK_KO` variables are the places to adjust if it turns out
to cover something different.

**Not performed, even under `--write`:** the Chestnut display-PMU touch-analog LDO enable (i2c0
0x27, register 0x05, `|= 0x10`) and any D2255 touch-core power-cycle. `docs/drivers/touch.md`
flags both as raw register pokes that need a fresh human/coordinator OK each time they're done,
and there's no reviewed driver in this repo that performs them (unlike the three writes above,
which happen inside an actual Linux driver's `probe()`/`init()`, not a bespoke sysfs/i2c poke from
a test script). If you've already gotten that OK for this session, set `TOUCH_SUPPLY_CMD` to the
exact `phone.sh lock`-style command line you'd otherwise run by hand, and `--write` will run it
(and only it) before touching the touch modules:

```sh
TOUCH_SUPPLY_CMD='<the exact phone.sh-lock command line you were already approved to run this session>' \
	testkit/selftest.sh --write --only touch
```

The script never invents this command itself, and this file does not either -- there is no
working example above on purpose. The Chestnut register is a read-modify-write (`|= 0x10` on
whatever it currently reads, not a fixed constant), and `testkit/CONTEXT.md` warns that i2c0
writes can kill the display; get the exact one-liner (and the current register value) from
whoever approved it, not from this doc.

## On-phone helper

`testkit/selftest-phone.sh` is pushed to `/tmp/6s/selftest-phone.sh` and run once per invocation
of `testkit/selftest.sh` (read-only mode always re-pushes and re-runs it; there's nothing stateful
in it to worry about). It is plain POSIX `sh` (works under the ramdisk's busybox `ash` and the
Arch userland's `bash`), touches nothing, and only prints `SS:<section>:<key>:<value>` lines plus
a `dmesg`/`uevent` evidence dump that `testkit/selftest.sh` parses. Run it by hand for a quick
human-readable dump without the table:

```sh
testkit/phone.sh push testkit/selftest-phone.sh
testkit/phone.sh run 'sh /tmp/6s/selftest-phone.sh'
```

## Build artifacts it resolves (override with env vars)

All under `$HOOLOCK` (default `~/Work/hoolock-iphone5s`), built by the usual
`testkit/kbuild.sh`/kernel-build flow elsewhere in this project -- this script never builds a
`.ko` itself, only `insmod`s ones that already exist on disk:

| var | default | note |
|---|---|---|
| `MUX_KO` | `build/integration/drivers/mux/mux-sn2400.ko` | |
| `GAUGE_KO` | `build/integration/drivers/power/supply/bq27xxx_battery_hdq_uart.ko` | a newer `build/battery-fix/bq27xxx_hdq_uart_fix.ko` exists as of this writing; point `GAUGE_KO` at it to test that variant instead (it's a distinct module name, so both can coexist in the same boot) |
| `PMIC_GPIO_KO` | `build/integration/drivers/gpio/gpio-apple-pmic.ko` | |
| `SPI_KO` | `build/integration/drivers/spi/spi-apple-s5l.ko` | |
| `TCLK_KO` | `build/touch-next-mods-integ/tclk/touch_clk_t1.ko` | |
| `Z2_KO` | highest-numbered `build/touch-next-mods-integ/z2n*/apple_z2_n*.ko` (glob + version sort) | today that's `z2n7`; the resolver picks up `z2n8` etc. automatically, no edit needed |
| `FND_PHANDLE_KO` | `build/fnd-test/phandle/fnd_phandle_v1.ko` | only loaded if an overlay about to be applied needs a PMGR phandle that isn't there yet |
| `BATTERY_OVERLAY`, `BLUETOOTH_OVERLAY`, `TOUCH_OVERLAY` | `testkit/overlays/battery.dtso`, `bluetooth-uart1.dtso`, `touch-spi2-v1.dtso` | built with `dtc -@ -I dts -O dtb` (`DTC_FLAGS=` and `DTC=` override); on the Arch userland image these DT nodes are normally already compiled into the production DTB, so the "already present" check usually skips this entirely |
| `EXPECT_RELEASE` | `7.3.0-rc1-g6831bc701a6c` | bump this after a kernel rebuild that changes `KERNELRELEASE`, or after moving to `kit/reload.sh`'s kexec path if that ever changes it |

There is currently no `apple_z2` compatible-string match in `testkit/overlays/touch-spi2-v1.dtso`
(its child node is `hoolock,z2probe-v1`, a leftover from the diagnostic-probe series) -- the
`apple_z2_nN` drivers are bound by hand with `driver_override` + `drivers_probe`, exactly as
`docs/drivers/touch.md` step 5b/5c describes, and that's what `write_touch()` does too. This is
not a bug to fix here; it's how the whole `touch-next` series is currently tested.

## Extending it

Add a new check when a driver moves from "in progress" to "known to work" in
`docs/hardware.md`: add its name to the `CHECKS` array, write a `check_<name>()` function that
reads from `get <section> <key>` (add the matching `SS:` lines to `selftest-phone.sh` first), and
if it needs a load, add a `write_<name>()` following the same already-loaded/already-present guard
pattern as the existing three.
