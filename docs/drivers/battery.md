# Battery fuel gauge (TI bq27540 over HDQ on uart5)

> **Depends on:** the foundation series, which adds the `serial5` node
> (`arm64: dts: apple: s800-0-3: Add uart1, uart3-uart6 nodes`). Patches
> 0001-0004 apply and build on `6831bc701` alone. Patch 0005 (the DT) applies
> with `git am`, but the dtb only builds once `serial5` exists.

**Status:** works on the phone (2026-09-29). With the SN2400 line switch and RX pinmux, the gauge answers over HDQ and `/sys/class/power_supply/bq27540-0` reports capacity, voltage, current, temperature, health, full/design charge and cycle count (first live readings: 21 %, 3.70 V, −112 mA, 29.6 °C, 1468/1690 mAh, 798 cycles). The image loads `mux-sn2400` then `bq27xxx_battery_hdq_uart` at boot. Charging itself is autonomous in the SN2400 and needs a supply with enough current: on a self-powered USB hub the gauge shows `Charging` at about +300 mA; an unpowered port only covers the load.

The history below records how it got there (the first live run got no echo because the charger holds the HDQ line until asked to hand it over).

## What

| | |
|---|---|
| Gauge | TI bq27540, ADT `/arm-io/uart5/gas-gauge` (`gas-gauge,bq27540`, `gas-gauge,hdq`) |
| Bus | uart5 @ 0x20a0d4000, AIC 197, PMGR `ps_uart5`, 24 MHz `clkref` |
| Pins | TX = AP GPIO 2, RX = AP GPIO 3. iBoot muxes TX (periph1) but leaves RX as a GPIO input |
| Line switch | The HDQ line runs through the **SN2400 "Tigris" charger** (i2c1, 0x75, ADT `/arm-io/i2c1/tigris`, `charger,sn2400`) |

Linux pieces written for this (patches in `patches/battery/`):

1. `dt-bindings: power: supply: Add SN2400 charger` (`ti,sn2400`, mux-state provider)
2. `dt-bindings: power: supply: Add TI BQ27540 with HDQ on a UART` (`ti,bq27540-hdq`, serdev child)
3. `mux: Add SN2400 charger HDQ line switch` (`drivers/mux/sn2400.c`, `CONFIG_MUX_SN2400`)
4. `power: supply: bq27xxx: Add HDQ over UART transport`
   (`drivers/power/supply/bq27xxx_battery_hdq_uart.c`, `CONFIG_BATTERY_BQ27XXX_HDQ_UART`)
5. `arm64: dts: apple: s800x-6s: Add battery fuel gauge` (i2c1 + charger, uart5 pins, `&serial5` child)

Kernel config needed: `CONFIG_MUX_CORE=y` (off in the running kernel),
`CONFIG_MUX_SN2400`, `CONFIG_BATTERY_BQ27XXX=y`, `CONFIG_BATTERY_BQ27XXX_HDQ_UART`,
`CONFIG_SERIAL_DEV_BUS=y`, `CONFIG_I2C_APPLE=y`.

## How iOS does it (reverse engineered from the 15.8.8 kernelcache)

Read out of `AppleHDQGasGaugeControl` and `AppleSN2400Charger` (disassembly of the
prelinked kexts). Nothing from the kernelcache is committed here, only the
constants below.

`AppleHDQGasGaugeControl::acquirePort()` configures the UART through IOSerial:

| event | value | meaning |
|---|---|---|
| `PD_E_DATA_RATE` (0x33) | 0x1c200 | 57600 baud (IOSerial passes 2x baud) |
| `PD_E_DATA_SIZE` (0x3b) | 0x10 | 8 data bits (2x) |
| `PD_E_DATA_INTEGRITY` (0x43) | 1 | no parity |
| `PD_RS232_E_STOP_BITS` (0xf3) | 4 | 2 stop bits (2x) |
| `PD_E_FLOW_CONTROL` (0x53) | 0 | none |

`_hdqOp()` encodes each HDQ bit as one character, LSB first: **0 -> 0xc0, 1 -> 0xfe**.
It compares the echo of every character it sent, and decodes response characters
as **1 if > 0xf8**, else 0. `_sendBreak()` asserts `PD_RS232_E_LINE_BREAK`, waits
200 us, releases, waits 40 us, and expects a break event on RX. Every transaction
starts with a break.

Around every client transaction, `lockForClient()` and `unlockForClient()` call the
gas-gauge's `function-battery_swi_request`, which points at the Tigris charger's
`HDQm` platform function (1 = acquire, 0 = release). In `AppleSN2400Charger`
that ends in `setHdqMaster()`:

- write charger register **0x1d = 0x04** (request), poll 0x1d until **bit 5** (ack)
  is set, with a 1 s timeout, and clear 0x1d on failure;
- to give the line to the charger's own gauge master ("BMU Master when
  discharging") it then writes **0x06**; "No Master when charging" is **0x00**.

## Provenance

Where each fact comes from. Nothing from the kernelcache or ADT is committed,
only the facts below.

| Fact | Source |
|---|---|
| Gauge is a bq27540 on uart5; `gas-gauge,hdq`; `battery-id-block`, `gauge-enable-interrupts` | Apple ADT (IPSW template and the iBoot-filled runtime ADT agree) |
| uart5 @ 0x20a0d4000, AIC 197, clock-gate 85 -> PMGR 0x80200 | ADT; PMGR offset per CONTEXT.md mapping |
| TX = GPIO 2 (`function-tx`, `function-battery_swi`) | ADT |
| RX = GPIO 3 | **Inference**: live pad config matches other UARTs' RX pins; not in the ADT |
| Line switch owned by the SN2400 (`function-battery_swi_request` -> tigris `HDQm`), charger at i2c1 0x75 | ADT (the reference) + iOS disassembly (what `HDQm` does) |
| SN2400 reg 0x1d: 0x04 request, bit 5 ack, 1 s timeout, 0x06 charger master, 0x00 none | iOS disassembly (`AppleSN2400Charger::setHdqMaster`, `setHDQInterfaceGated`); **no public doc** |
| iOS UART setup 57600 8N2, no flow control | iOS disassembly (`AppleHDQGasGaugeControl::acquirePort`, IOSerial event constants) |
| Bit encoding 0 -> 0xc0, 1 -> 0xfe; response bit = char > 0xf8; echo compared | iOS disassembly (`_hdqOp`) |
| Break 200 us + 40 us before every transaction, break echo expected | iOS disassembly (`_sendBreak`) |
| HDQ limits t_B, t_BR, t_HW0/1, t_CYCH, t_DW0/1, t_CYCD; 7-bit address + R/W bit, LSB first; one byte per read | TI public docs (bq27xxx datasheet HDQ timing tables, TI HDQ-over-UART app note SLUA408) |
| Standard command addresses (0x06 Temp, 0x08 Voltage, 0x2c SOC, ...) | TI bq27541 family datasheet via Linux `bq27xxx_battery.c`; **assumed** to match Apple's bq27540 firmware |
| 8O1 + 0xff for a 1 instead of 8N2 + 0xfe | **Own choice** (serdev has no stop-bit API), checked against the TI timing limits |

## Linux design

**Transport choice.** The task suggested an HDQ-over-UART w1 master so that the
existing `bq27xxx_battery_hdq` binds unchanged. That driver does not work for
this gauge. It hardcodes `di->chip = BQ27000`, whose register map (single-byte
RSOC at 0x0b, different flag bits) is not the bq27540's. It also needs a 1-Wire
master with ROM search emulation, which HDQ does not have. Instead,
`bq27xxx_battery_hdq_uart` is a serdev driver that feeds the existing
`bq27xxx_battery` core (`bq27xxx_battery_setup()` with its own `bus.read`) using
the bq27541 register map, which is the standard command set the bq27540 shares.
Only `bus.read` is provided, so the core can never write to the gauge
(sealing, reset and data-flash writes all fail with -EPERM).

**HDQ timing chosen** (bq27xxx datasheet limits in brackets):

| | UART | on the wire |
|---|---|---|
| frame | 57600 baud, 8O1 = 11 bits | 191 us per HDQ bit [t_CYCH >= 190 us] |
| host 1 | 0xff | 17 us low [t_HW1 0.5..50 us] |
| host 0 | 0xc0 | 121 us low [t_HW0 86..145 us] |
| break | `serdev_device_break_ctl()`, 200 us, then 60 us recovery | [t_B >= 190 us, t_BR >= 40 us] |
| device bit | received char >= 0xf9 is 1 | [t_DW1 32..50 us, t_DW0 80..145 us, t_CYCD >= 190 us] |

serdev cannot select two stop bits, so odd parity provides the eleventh bit.
For 0xff and 0xc0 the odd-parity bit is 1, so the line looks exactly like iOS's
8N2 frame. That is why a 1 is 0xff (17 us low, inside t_HW1) instead of iOS's
0xfe, whose odd-parity bit would be 0. On receive the parity bit is ignored
(serdev drops the flags). Each 16-bit register is read as three one-byte
transactions (high, low, then high again until stable). Each is preceded by a
break and checked against its echo.

**Line switch.** The charger's switch is a three-state mux
(0 disconnected, 1 host, 2 charger master). The gauge node carries
`mux-states = <&charger 1>`. The gauge driver selects it around every
`bus.read` and releases it afterwards. While idle, the mux goes back to what
the charger register held at boot.

**Pins.** `uart5-pins` muxes GPIO 2 and 3 to periph1. Pin 3 has the same pad
configuration pattern as the other UARTs' RX pins (uart1 pin 25, uart0 pin 108).

## Evidence

Kernel `7.3.0-rc1-g6831bc701a6c #2`. The only live run: `bq27xxx_hdq_uart_v1.ko` (the transport
without mux support) plus `battery-duplicate-pd.dtso` (uart5 on a duplicate pwrstate
node for PMGR 0x80200):

```
[ 4429.947454] 20a0d4000.serial: ttySAC2 MMIO32:0x000000020a0d4000 (irq = 60, base_baud = 0) is a APPLE S5L
[ 4429.949711] serial serial1: tty port ttySAC2 registered
[ 4429.976092] bq27xxx_hdq_uart_v1 serial1-0: cmd 0x09: bad echo (0 chars: )
[ 4430.003132] bq27xxx_hdq_uart_v1 serial1-0: cmd 0x09: bad echo (0 chars: )
[ 4430.032128] bq27xxx_hdq_uart_v1 serial1-0: cmd 0x09: bad echo (0 chars: )
[ 4430.035104] bq27xxx_hdq_uart_v1 serial1-0: error -EIO: no response from gauge
[ 4430.038042] bq27xxx_hdq_uart_v1 serial1-0: probe with driver bq27xxx_hdq_uart_v1 failed with error -5
$ cat /proc/tty/driver/s3c2410_serial
2: uart:APPLE S5L MMIO32:0x000000020a0d4000 irq:60 tx:24 rx:0 RTS|CTS|DTR|DSR|CD
```

After muxing pin 3 to periph1 by hand (`echo "PIN3 periph1" > .../pinmux-select`; regmap
0x00c went 0x00076201 -> 0x00076221) and re-binding: again `tx:48 rx:0`, the same "bad echo (0 chars)".

**Failure analysis.** The UART transmitted (tx counters rose by 8 characters per try),
but RX saw **nothing at all**: no echo of the command bits, and no break character
(no `brk:` count). The echo check fired before any timing or decoding question
could come up, so baud, bit encoding and break length are not what failed. Two
things kept RX dark:

1. **RX pin not muxed.** iBoot sets TX (GPIO 2) to periph1 but leaves GPIO 3 as a
   GPIO input (0x00076201). Fixing that alone (second try) was not enough.
2. **The HDQ line belongs to the SN2400 charger by default.** In iOS every gauge
   access is bracketed by `function-battery_swi_request` -> Tigris `HDQm`, i.e.
   charger register 0x1d = 0x04 plus a wait for the bit-5 ack (see above). Without
   that, the charger keeps the line away from the AP UART. This is the most likely
   reason for the missing echo. It is inferred from the iOS code and **not yet
   confirmed live**: the SN2400 was never read or written from Linux (i2c1 is
   disabled in the running DT).

The v1 results were recorded before the UART state was corrupted by another
overlay removal (foundation, oops #2), so they are genuine. Anything after that
point in the same boot is suspect.

Not tested at all: the SN2400 mux driver, the mux-aware transport (v2), i2c1,
the full DT. No reading of voltage, SOC, current or temperature has been made.

**Next test** (`tools/battery/live-test.sh`, for the foundation base DT with
`__symbols__` and `serial1..6`; the overlay is `testkit/overlays/battery-labels.dtso`,
built with `dtc -@`):

```
tools/battery/live-test.sh            # read-only checks, modules, overlay,
                                      # SN2400 read by a peek driver; prints
                                      # the writes it would do, then stops
tools/battery/live-test.sh --write    # binds sn2400_mux_v1 (writes 0x1d), gauge probes,
                                      # prints /sys/class/power_supply/*/uevent
```

Expected if the analysis is right:

```
sn2400_peek_v1 1-0075: sn2400 peek: reg07=0x.. reg1d=0x.. (read-only)
sn2400_mux_v1 1-0075: HDQ control 0x.., idle state N
sn2400_mux_v1 1-0075: HDQ state 1: control now 0x24 (0)     # dyndbg: request acked
bq27xxx_hdq_uart_v2 serial?-0: cmd 0x09: <8 chars> -> 0x0f   # dyndbg, echo OK
bq27xxx_hdq_uart_v2 serial?-0: HDQ link up, voltage register reads 3xxx..4xxx mV
cat /sys/class/power_supply/bq27540-0/uevent   # VOLTAGE_NOW 3.4-4.4 V, CAPACITY 0-100, TEMP ~200-400 (0.1 C)
```

If `HDQ control` reads back but echo is still empty: log register 0x1d after the
select (bit 5 set?). If the echo works but the response is empty or garbage:
dump the raw response bytes (dyndbg line) and compare with the threshold 0xf9.

## Live testing

`testkit/overlays/battery.dtso`: apply once per boot and **never remove it**.
Removing a bound samsung-uart overlay oopses the running kernel. It needs the
power-domain phandles that foundation's `fnd_phandle` module adds
(`ps_uart5 = 0xf040`). `testkit/overlays/battery-duplicate-pd.dtso` is the
first variant, which instead adds a second pwrstate node for the same PMGR
register. It has no i2c1, charger or pin parts and is kept only as a record.

The running kernel has `CONFIG_MUX_CORE=n`, so for live testing the mux core
is built as a module (`#include "drivers/mux/core.c"`) and the two drivers are
compiled with `-DCONFIG_MULTIPLEXER_MODULE=1`:

```
# Kbuild in a scratch dir inside the kernel worktree
ccflags-y += -DCONFIG_MULTIPLEXER_MODULE=1
obj-m += mux_core_v1.o sn2400_mux_v1.o bq27xxx_hdq_uart_v2.o
# each .c is a one-line #include of the real source

testkit/kbuild.sh <dir>
phone.sh insmod mux_core_v1.ko
phone.sh insmod sn2400_mux_v1.ko
phone.sh insmod bq27xxx_hdq_uart_v2.ko dyndbg=+p
phone.sh overlay battery.dtbo    # dtc -I dts -O dtb (no -@: the live tree has no __symbols__)
```

## Known issues / next steps

- Not working yet; see the evidence above for the exact next test.
- **Writes to the charger:** the SN2400 mux driver writes register 0x1d (0x04, 0x06 or 0x00, the
  same values iOS uses) on every mux state change, and once at registration to
  restore the boot state. None of this has run on the phone yet.
- `ti,sn2400` as compatible and binding location are guesses (ADT says `charger,sn2400`).
  Only the HDQ switch is described. Charging, interrupts and the iOS "reg 7" check
  before choosing BMU vs none are not implemented.
- The idle state is "whatever 0x1d held at boot". iOS instead picks BMU master vs no
  master depending on whether the phone is charging.
- Pin 3 = uart5 RX is inferred from the pad pattern, not from Apple's DT.
- `bq27540` -> bq27541 register map is assumed. Apple's gauge firmware may differ;
  check the values against the 6s battery (design capacity 1715 mAh at 0x3c).
- The UART break relies on `UCON.SBREAK`. On Samsung UARTs it auto-clears after one
  frame (191 us), which is just above t_B = 190 us.
- `dt_binding_check` (dtschema 2026.9) passes for both bindings. `dtbs_check` on s8000-n71 (with the foundation serial5 nodes) is clean. `fuel-gauge` was added to the allowed serial child names in `serial.yaml`.
- `samsung_tty` remove bug: never remove the test overlay (foundation has a fix in its series).
- Upstream: `CONFIG_MUX_CORE` must be enabled in the hoolock config.
