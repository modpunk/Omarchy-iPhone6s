# foundation: UART bus nodes, PMIC cell-count fix, RTC, samsung_tty remove fix

Base: HoolockLinux `6831bc701`. Series: `patches/foundation/0001..0005`, applies on its own.
Other driver series (bluetooth, battery, touch) depend on the `serial1`..`serial6` labels from 0001.

**Status:** UART nodes defined and bus-level probe verified live (uart3/4/6 via overlay;
uart1/uart5 bound live by the bluetooth/battery overlays with the same reg/irq/compatible).
PMIC "Bad cell count": root cause found, fixed, built. **Not live-verified**: the phone
was left tainted before the repro could run, and the fix was never booted. RTC 2021 date: not a driver bug (the PMIC holds a stale offset); explained
below, with a host-side remedy. samsung_tty remove oops: found live, fixed, built only.

## Patches

| # | Patch | What |
|---|-------|------|
| 0001 | `arm64: dts: apple: s800-0-3: Add uart1, uart3-uart6 nodes` | `serial1`, `serial3`..`serial6` in `s800-0-3.dtsi`, all `disabled`; `serialN` aliases in `s800-0-3-common.dtsi` |
| 0002 | `dt-bindings: mfd: apple,pmic: Allow subdevices without size cells` | binding: PMIC `#size-cells` 0 or 1; nvmem `size` property |
| 0003 | `nvmem: simple-mfd-nvmem: Allow reg without size cells` | accepts `reg = <base>` + `size`, keeps `<base size>` working |
| 0004 | `arm64: dts: apple: s800x-6s: Use register-offset addressing for PMIC` | 6s PMIC `#size-cells = <0>`, `rtc@500 reg = <0x500>`, `nvmem@5000 reg = <0x5000>; size = <0x28>` |
| 0005 | `tty: serial: samsung_tty: Only unregister uart_driver with the last port` | fixes the oops on port removal (below) |

None of the new serial nodes is enabled in `s800x-6s.dtsi`. The consumers enable their own port
with a child: `&serial1 { status = "okay"; bluetooth { ... }; };` and `&serial5` for the gauge.
This matters because serdev scans for children only at port probe, so a port that is
enabled bare and later gets a child from an overlay stays a plain tty. Per the coordinator,
uart3 (NFC), uart4 (WLAN sideband) and uart6 (iAP) stay disabled.

## UART nodes (0001)

| label | reg | AIC irq | ADT clock-gate | PMGR offset (ADT `devices`) | Linux domain | ADT child |
|-------|-----|---------|----------------|-----------------------------|--------------|-----------|
| serial1 | 0x2_0a0c4000 | 193 | 0x51 | 0x801e0 | ps_uart1 | bluetooth |
| serial3 | 0x2_0a0cc000 | 195 | 0x53 | 0x801f0 | ps_uart3 | stockholm (NFC) |
| serial4 | 0x2_0a0d0000 | 196 | 0x54 | 0x801f8 | ps_uart4 | wlan (sideband) |
| serial5 | 0x2_0a0d4000 | 197 | 0x55 | 0x80200 | ps_uart5 | gas-gauge |
| serial6 | 0x2_0a0d8000 | 198 | 0x56 | 0x80208 | ps_uart6 | iap |

How the power domains were verified: I decoded the ADT `pmgr` node's `devices` table
(0x30-byte entries: device id in the top byte of the flags word, psreg index and address
offset) against its `ps-regs` table. Each UART's `clock-gates` id resolves to the PMGR offset
above, and each offset is the `reg` of the existing `ps_uartN` node. SPI1-3 (0x4b-0x4d)
resolve to `ps_spi1-3` in the same way (0x801c0/0x801c8/0x801d0). There is no uart2 on
N71. s8000 and s8003 differ only in cpufreq latencies, so both dtbs get the same nodes.

**Pinctrl:** none, following serial0 and the extra UARTs on t7000/t8103. Pin config
registers read live (`/sys/kernel/debug/regmap/20f100000.pinctrl/registers`; PERIPH =
bits 6:5):

- uart0 TX107/RX108, uart1 TX24/RX25/CTS27, uart4 TX28/RX29/CTS31 and uart6
  TX109/RX110 are already on function 1, set by iBoot.
- uart1 RTS26 and uart4 RTS30 are GPIO outputs driven high (`0x72203`). Apple drives
  RTS by hand through the ADT `function-rts` property. A consumer that wants hardware
  RTS/CTS must add `pinctrl` itself, e.g. `APPLE_PINMUX(26, 1)` for uart1.
- uart3 TX88/RTS90 are not muxed (NFC is off). uart5 pin 2 is function 1 but pin 3 is
  not; the HDQ wiring is the battery series' business.

### Live evidence (kernel `7.3.0-rc1-g6831bc701a6c #2`, running DT without these nodes)

On the running DT the `ps_uart1-6` / `ps_spi1-3` nodes have **no phandle**: dtc emits
phandles only for referenced nodes, and an overlay cannot add one to an existing node. The
domains are also off (`pm_genpd_summary`: `uart1..uart6 off-0`), so an overlay UART without
its domain would touch unpowered MMIO. `testkit/fnd_phandle` gives exactly those nodes a
deterministic phandle, `0xf000 + (offset - 0x80000)/8`, changing only the in-memory DT:

```
fnd_phandle: /soc/power-management@20e000000/power-controller@801c8 (spi2) -> phandle 0xf039
fnd_phandle: /soc/power-management@20e000000/power-controller@801e0 (uart1) -> phandle 0xf03c
fnd_phandle: /soc/power-management@20e000000/power-controller@80200 (uart5) -> phandle 0xf040
...
```

`testkit/overlays/foundation-uart.dtso` (serial3/4/6 with the 0001 properties):

```
20a0cc000.serial: ttySAC3 MMIO32:0x000000020a0cc000 (irq = 61, base_baud = 0) is a APPLE S5L
20a0d0000.serial: ttySAC4 MMIO32:0x000000020a0d0000 (irq = 62, base_baud = 0) is a APPLE S5L
20a0d8000.serial: ttySAC5 MMIO32:0x000000020a0d8000 (irq = 63, base_baud = 0) is a APPLE S5L
uart3  on   20a0cc000.serial  unsupported  SW       (pm_genpd_summary; same for uart4/uart6)
```

uart6 came up as ttySAC5 only because the running DT has no aliases. With 0001's aliases it
is ttySAC6. Probe only: the ports were never opened. uart1 and uart5 were already bound to
`samsung-uart` by the bluetooth/battery overlays (hci0 came up as BCM4350 on uart1).

## Bug: `OF: Bad cell count for /soc/i2c@20a110000/pmic@74` x5 (0002-0004)

**Root cause.** The PMIC subdevices (`rtc@500`, `nvmem@5000`) had a `reg` in a
`#size-cells = <1>` space. `simple-mfd-i2c` calls `devm_of_platform_populate()`, which
treats each child `reg` as MMIO and tries to translate it to a CPU address. The walk goes
child → pmic@74 (ok) → i2c@20a110000, whose `#size-cells = <0>` fails `OF_CHECK_COUNTS`, so
`__of_translate_address()` prints `pr_err("Bad cell count for pmic@74")`. That is five
prints:

- 2 from `of_device_alloc()` → `of_address_count()` (rtc, nvmem)
- 2 from `of_device_make_bus_id()` naming rtc and nvmem
- 1 from `drivers/nvmem/layouts.c` naming the `nvmem-layout` device, whose
  `of_device_make_bus_id()` walks up through `nvmem@5000`'s reg

A driver-only fix (creating the MFD cells without translation) would still leave the fifth.

**Fix.** Follow the convention for register-addressed children on non-MMIO buses (Qualcomm
SPMI PMICs, `kontron,sl28cpld`): the PMIC uses `#size-cells = <0>` and children have
`reg = <offset>`. Translation then stops at the first level with a silent `pr_debug`. The
nvmem length moves to a `size` property (at24 precedent). `rtc-apple-pmic` already reads
only `reg[0]`. The other Apple PMIC DTs (A7, A8, A10, SE, iPad) still use `<base size>`,
which keeps working. They could be converted the same way in a follow-up.

**Verification.** Built clean (`s8000-n71.dtb`, `s8003-n71m.dtb`), and `dtc -I dtb` shows
`#size-cells = <0x00>` with 1-cell children. `dt_binding_check` was not run (dtschema not
installed). Not live-verified. `testkit/fnd_xlate` + `testkit/overlays/foundation-xlate.dtso` is a
ready repro that touches no hardware: fake PMIC-shaped subtrees under a `#size-cells = <0>` bus,
old layout vs fixed, populated the way simple-mfd-i2c and the nvmem layout code do. Expected: 5
"Bad cell count" lines for `pmic@7e` and none for `pmic@7f`. It has not been run yet (phone
state). The definitive check is the next boot: `dmesg | grep "Bad cell"` should be empty, and
`rtc0` should still register.

## Bug: RTC boots at 2021-08-19

**Not a driver bug.** Linux computes exactly what iOS computes. The PMIC holds a stale
calendar offset.

- The nvmem cell (PMIC `0x5004`, LE32) holds `0x611ada47` = 1629149767 =
  2021-08-16 21:36:07 UTC.
- The counter (`0x502`, 6 bytes, `>>16`) ticks at exactly 1 Hz: `since_epoch` advanced 20
  over 20 s of uptime. So units and scaling are right.
- raw counter = `since_epoch - offset` = 266351 s. Against the laptop clock, the counter's
  zero point is **2026-09-25 23:54:12 UTC**, i.e. the PMIC counter restarted three days
  before the phone was first seen here (USB, iOS mode, 2026-09-28 18:26 CDT), most likely
  when a flat battery was revived.
- The offset the PMIC needs today is ≈ 1790380452.

**How iOS does it** (iOS 15.8.8 kernelcache, `AppleD2255PMURTC`; disassembly read locally,
nothing committed):

- It reads the counter as 6 bytes at `0x502`, the same as Linux.
- It reads 4 bytes at `0x5004` and 2 bytes at `0x5015` and forms a signed 47-bit offset in
  32768 Hz ticks: `s32@0x5004 << 15 | (0x5016 & 0x7f) << 8 | 0x5015`. So `s32@0x5004` is
  whole seconds, exactly the Linux cell.
- It writes the same two registers from `setMonotonicClockOffset(usecs)`.
- Its sysctl `kern.monotoniclock_offset_usecs` is described as "calendar time offset", and
  `getCurrentDateTime()`/`setCurrentDateTime()` panic with "should not be called".

In short, iOS time = counter + that offset. With a revived battery and no network time, iOS
itself would show the same August 2021 date. Neither iBoot nor m1n1/Hoolock supplies a time:
the runtime ADT (`/dev/mtd1ro`) has no RTC or time property.

**Remedy (not applied).**

- Set the clock from the host each boot, which writes nothing to the PMIC:
  `testkit/phone.sh lock "date -u -s @$(date -u +%s)"`.
- To persist it, run `hwclock -w` on the phone. The driver then writes the new offset into
  `0x5004..0x5007`, the same register iOS's `setMonotonicClockOffset` writes. It leaves the
  sub-second bits at `0x5015` alone, which is ≤1 s error. I did not write the PMIC; that is
  the human's call.

Possible refinement (not done): read the 15 fractional bits at `0x5015` too (the binding's
TODO).

## Bug found on the way: samsung_tty remove oopses (0005)

Removing my UART overlay (`echo 4 > /sys/class/misc/dtbo/remove`) oopsed:

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000740
pc : mutex_lock+0x30/0x4c
lr : serial_core_unregister_port+0x6c/0x20c
 uart_remove_one_port+0xc/0x14
 s3c24xx_serial_remove+0x1c/0x30
 ...
 of_platform_device_destroy+0x9c/0xec
 of_overlay_remove+0x1f8/0x274
```

`s3c24xx_serial_remove()` calls `uart_unregister_driver()` on **every** port removal. The first
removal (uart6) freed the shared `s3c24xx_uart_drv` state while ttySAC0, the bluetooth and
battery ports and ttySAC3/4 were still registered. The second removal hit
`drv->state == NULL`. The same code is in mainline. 0005 refcounts the ports and unregisters
only with the last one. It is **built but not live-tested** (the phone was left tainted, and
a module clone would collide with major 204). **Until a kernel with 0005 is booted: never
remove an overlay that contains a bound serial node, and never unbind samsung-uart.**

The same class of problem applies to `apple,pmgr-pwrstate`: the driver has no `.remove`, so a
power-controller node added by an overlay must never be removed.

## Next-boot image (built, not booted)

`make O=build/foundation LLVM=1 ARCH=arm64 DTC_FLAGS=-@ KERNELRELEASE=7.3.0-rc1-g6831bc701a6c
Image.gz apple/s8000-n71.dtb apple/s8003-n71m.dtb`

- DTBs carry `__symbols__`, so overlays can use `&serial1` etc.
- `KERNELRELEASE` is pinned to the base string. The only code deltas are built-in drivers
  with no exported-symbol changes, and there is no MODVERSIONS or module signing, so modules
  built with `testkit/kbuild.sh` still load. `uname -v` differs.
