# Touch (iPhone 6s N71 multitouch on spi2)

**Status:** partial. With the 32 kHz touch clock and the analog supply on, the controller
answers in HBPP (2026-09-29): `1f01`, then `4879`, and the bootloader version at 0x10008ffc
is 0x434d15c1. The first driver run then failed on the calibration packet (status 0x4f81, a
framing bug, see "Calibration packet rejected"). Fixed on `6s/touch-next`, not yet run live.
No touch events have been seen.

Patches: `patches/touch/` (the first 6 commits of `6s/touch-next`; the power, clock and
bootloader fixes after them are only on the branch) (6 patches, `git am` onto `6831bc701` on their own, checked).

## What

| item | value (source: IPSW ADT, runtime ADT, iOS 15.8.8 kernelcache) |
|---|---|
| controller | `/arm-io/spi2`, `spi-1,samsung`, `spi-version 1`, 0x20a088000, AIC 190, PMGR ps_spi2 (0x801c8) |
| device | `/arm-io/spi2/multi-touch`, `multi-touch,n71,2`, iOS class `AppleMultitouchN1SPI` (kext `AppleMultitouchSPIN71`) |
| pins | SCK/MOSI/MISO = GPIO 41-43 (periph 1, set by iBoot, read from the live pin registers). CS = GPIO 44 (`function-spi_cs0`) |
| reset / irq | reset = GPIO 75 (active low, iBoot leaves it asserted: pin reg 0x72202). irq = GPIO 142 (`interrupt-parent` is the GPIO controller, not AIC) |
| SPI mode | ADT reg `00000000 7c000000 01 03 01 08 ...`: 124 ns period (about 8 MHz), CPOL=1, CPHA=1, MSB first, 8 bit |
| power | `function-power_ldo` = D2255 output 0x19 (pmuL 0x219, enable reg 0x319 bit0): **ON** (read 0x01 live). `function-power_ana` = Chestnut display PMU (i2c0 0x27, dpLE 0x302) reg 0x05 bit4: off at boot (0x0f), set to 0x1f live on 2026-09-29 |
| clock | `function-clock_enable` = PMGR `TCLK` (8, 100, 0x8000): a **32768 Hz** reference; PMGR `clocks` entry 8 is "LPO". Not enabled by Linux. See "Power and clock" |

## SPI controller (A9 is not the M1 block)

The iOS `AppleSamsungSPI` driver for spi-version 1 only ever touches registers 0x00-0x4c
(CTRL, CFG, STATUS, PIN, TXDATA 0x10, RXDATA 0x20, CLKDIV 0x30, RXCNT 0x34, WORD_DELAY 0x38,
TXCNT 0x4c). It reads the TX FIFO level from STATUS[10:6] and the RX level from STATUS[15:11],
with a 16-entry FIFO. The version-1 constant table is {word-size shift 15, NCLK bit 0x4000,
LSB-first bit 0x2000, depth 16}, and status is cleared with 0x0040000f. CFG also carries CPHA
bit1, CPOL bit2, master+clock-enable 0x18, MODE bits 6:5 and the IRQ enables at bits 7-8.
There is no FIFOSTAT/IE/IF/SHIFTCFG/PINCFG, so upstream `spi-apple.c` (M1) does not fit.
This matches the HoolockLinux `tests/kat-spi` "S5L" experiment. That work was WIP; the bit-13
meaning there is inverted compared with iOS.

New driver `drivers/spi/spi-apple-s5l.c` (`apple,s8000-spi`, `apple,s5l-spi`): polled PIO,
programmed in the same order as iOS. Runtime PM is deliberately off so SCK keeps its idle level.
The ref clock is 48 MHz (measured live from SCK for a known divider; commit 70a84a98dd65 on
6s/touch-fixes adds a fixed `clk_spi_ref`).

DT: `spi1/spi2/spi3` nodes after the i2c nodes in `s800-0-3.dtsi` (disabled). spi2 is enabled
in `s800x-6s.dtsi` with `cs-gpios`. The touchscreen node is in `s8000-n71.dts` and
`s8003-n71m.dts`, left `disabled`. spi3 (Touch ID, `mesa`) and spi1 (codec) stay disabled and
untouched.

## Protocol: Z2 / HBPP (evidence)

Evidence for Z2:
- `AppleMultitouchSPIN71` personality: `Z2Compliant = true`, `mt-merge-personality C1F5B,2`,
  `fw-execute-addr 0x10003400`, `cal-dl-addr 0x10009000`, `prox-cal-addr 0x10009600`,
  `fll-mval 6099 @0x10003060`, `clk32-clock-enable 1 @0x10003518`, `ref-clk-div-val 2`,
  `reset-deassert-delay 15`.
- Rootfs `/usr/share/firmware/multitouch/N71.mtprops`: `PreconstructedBootloadPacketType = Z2`,
  version `0x0670.mihu`, 2 constructed images (65460 and 18600 bytes). Each is a `18e1` NOP
  word plus an HBPP DATA packet (`30 01 len/4 addr hdrsum payload sum32`). The extraction
  script checks all header and payload checksums: image 0 goes to 0x0, image 1 to 0x401900.
- Kext code (`MTSPIBootloader_Z2/_N1`, `AppleMultitouchZ2SPI`) uses the same packet ids as the
  Asahi touch bar tooling:
  - `1a a1` ATN
  - `18 e1` NOP
  - `30 01` DATA
  - `1e 33` register write (addr, mask, value, sum)
  - `1f 01` request calibration
  - `1c 73` memory read
  - `1d 53` EXECUTE
  - acks `4bc1` (data) and `4ad1` (register)
  - HBPP detect set {18e1, 1aa1, 1f01, 4879, 4969, 4ad1, 4bc1}
  - after boot: wake `19 c1` and `ee ... 00ee`, the same framing as apple_z2's `EB` read
- Differences from the touch bar: no boot IRQ is awaited. iOS order is:
  1. dummy ATN+NOP transfer ("ensuring S_CLK is high")
  2. deassert reset, wait 15 ms
  3. HBPP check
  4. calibration DATA
  5. firmware images
  6. N1 register sequence: read version @0x10008ffc; write fll, ref-clk-div, 0x10003058=6, const-cal @0x10003000 (2 if version==0x434d11a0, else 3), clk32
  7. request calibration, wait 65 ms
  8. EXECUTE, then 40 ms

Evidence against or open: the post-boot report layout (touch bar parser reused) and the raw
coordinate range are unverified. The analog rail is off.

## Firmware and calibration (never committed)

- `tools/touch/extract-n71-touch-fw.py N71.mtprops apple/mtfw-n71.bin` builds a Z2FW file:
  SEND_CALIBRATION(0x10009000) plus 2 SEND_BLOBs, 84092 bytes. Push it to
  `/lib/firmware/apple/` on the phone.
- `tools/touch/adt-touch-cal.py <runtime-adt>` prints `apple,z2-cal-blob` from the runtime ADT
  (`/dev/mtd1ro`, 1024 bytes, device unique). The IPSW ADT only has the syscfg placeholder.

## Power and clock (2026-09-29)

Live state before this section: 48 MHz SPI works, reset (GPIO 75) toggles, Chestnut 0x05 = 0x1f
(touch analog on, read back), D2255 0x319 = 0x01. The controller still returns all zeros on MISO
(pad 43 has a pull-down, so "nobody drives it") and the IRQ pad (142, pulled up) stays low.

**The D2255 "voltage code 0" idea does not hold.** In the p1 survey about 22 outputs that are on
(0x3xx non-zero, e.g. 0x302, 0x303, 0x30b, 0x30c Touch ID, 0x312-0x321) read 0x00 at 0x2xx,
and two outputs that are off (0x306, 0x311) read non-zero there. The phone runs on those rails,
so 0x2xx is not a per-output voltage where 0 means 0 V; the touch output is in the same state
as most of what iBoot left on. Corellium's GPL iPhone 7 kernel (`hx-h9p-d10.dts`) describes the
same pair of touch supplies as pure on/off switches: `touch_pwrsw` = PMU 0x31f bit0 and
`touch_ldo` = Chestnut 0x05 mask 0x10, with no voltage programming. **No D2255 voltage write is
proposed.** No public source gives the D2255 voltage encoding.

**What is missing is the 32 kHz touch clock.** The Apple DT asks for it (`TCLK`, 0x8000 =
32768 Hz) and the N1 boot writes `clk32-clock-enable`; the FLL value 6099 x 32768 Hz = 199.9 MHz
also points at a 32 kHz reference. Linux never enables it. On A10 (same SPI2 address, same
Chestnut/PMU touch rails) Corellium's `clk-hx-pmgr.c` drives it through one PMGR register at
0x2_0e07_8000: bit31 DISABLE, bit19 ENABLE, bit18 BUSY, bits 9:0 divider from 24 MHz (732 for
32768 Hz). That offset is inside the A9 PMGR range from the Apple DT, but it is **not confirmed on
A9** (the A9 and A10 PMGR power-state tables are similar, not identical: spi2 is 0x801c8 on A9 and
0x801d8 on A10). Hence the read-first plan below.

Power-on order (Corellium, iPhone 7): reset low, analog (Chestnut) on, 2-5 ms, core (PMU) on,
2-5 ms, CS high, clock on, 1-2 ms, then reset release / firmware. apple_z2 now does the same.

Kernel (branch `6s/touch-next`, local): `apple,pmu-switch` regulator driver (children of the
PMIC and of the new `apple,chestnut-pmu` simple-mfd-i2c node), `apple,s8000-touch-clock` clock
driver (child of the PMGR syscon), apple_z2 `vdd-supply` / `avdd-supply` / `clocks` with the order
above, DT CS delays 5000/10000 ns. All new DT nodes stay disabled until the clock is confirmed.
The running kernel has `CONFIG_REGULATOR` off, so live tests switch rails with the approved
one-bit writes and leave the supplies out of the DT.

## Calibration packet rejected (0x4f81), 2026-09-29

The driver (`apple_z2_n2`, bound to spi0.0) got through the HBPP check and then logged
`blob of 1040 bytes: ack 0x4f81`, -EIO.

**Cause: the calibration DATA packet had two stray bytes.** `struct apple_z2_hbpp_blob_hdr`
(0x3001, len/4, 32-bit addr, 16-bit header sum) is 10 bytes on the wire, but it isn't
`__packed`, so `sizeof()` is 12 and `apple_z2_build_cal_blob()` put `00 00` between the header sum
and the payload: 12 + 1024 + 4 = 1040. Apple's constructed images use the 10-byte header (the
extractor checks `2 + 10 + words*4 + 4 == len`), and so does the Asahi Z2FW generator
(`pkt_len = 14 + len(payload)`). The bootloader took the pad as payload bytes 0-1 and read the last
2 payload bytes plus the low half of the sum as the sum32: 0xe72c0000 against 0xe72c for this
phone's blob. The touch bar never checks the status, so the bug is in the base tree too.

0x4f81 itself: a status word in the same family as `4879` (idle), `4969`, `4ad1` (register ack),
`4bc1` (data ack) and `4c39` (memory read reply, seen in the diag: `4c39 15c1 434d 0166`, value
0x434d15c1, then the byte sum of the value). It is not an ack. Nothing public names it, so the
driver only calls it "reject". The framing bug is enough to explain it.

Also different from the diag run that worked, and now matched in the driver:
- **SPI clock**: the driver ran the bootloader at the DT 8 MHz; the diag used 1 MHz. The driver
  now uses `hbpp_speed_hz` (default 1000000) for every HBPP packet and the DT speed after
  EXECUTE.
- **CS setup/hold**: the booted (integration) DT and `touch-live.dtso` have no
  `spi-cs-*-delay-ns`, and the SPI core only reads them when the device is created, so the driver
  ran with 0/0. It now sets 5000/10000 ns when the DT gives none (probe prints the values).

Other changes (kernel commits `9ffac47ae2ba`, `0bb693fe6158`): the calibration packet is built
in wire order (1038 bytes; checked offline with the extractor's `check_packet`). Its payload is
swapped per 16-bit word, because the bootloader stores each big-endian wire word
little-endian: the images carry the ARM word e59ff018 as `f0 18 e5 9f`. `hbpp_cal_swap=0` turns
the swap off; the sum is the same either way. Long packets go as one message of 4 KiB transfers
with CS held. ATN is polled (50 x 1 ms) while the status is still idle. The memory read reply is
checked. dyndbg traces every packet, status word and report.

## Live-test plan (main session runs every step)

Modules for the running (integration) kernel: `~/Work/hoolock-iphone5s/build/touch-next-mods-integ/`
(`tclk/touch_clk_t1.ko`, `tclkdrv/clk_apple_touch_v1.ko`, `z2n2/apple_z2_n2.ko`); the same modules
built against the base tree are in `build/touch-next-mods/`. Check `uname -a` / the vermagic
first and use the set that matches.

Read-only:

1. `phone.sh ping`; `dmesg | tail`; check that the earlier touch modules and overlays are
   still there (`ls /sys/bus/spi/devices/`, `cat /sys/bus/spi/devices/spi*/of_node/compatible`,
   `readlink /sys/bus/spi/devices/spi*/driver`).
2. `phone.sh insmod touch_clk_t1.ko` (no parameters, returns -ECANCELED). Record: the TCLK line,
   `tclk+4`, D2255 0x219/0x319, Chestnut 0x05, pads.
   - Fits the A10 layout if `unknown-bits 00000000`, and idle means `disable 1 enable 0`.
   - `enable 1` with a divider near 732: the clock is already running; skip step 3 and go to
     the reset-polarity fallback (touch_diag_d2 `reset_invert=1`, step 4).
   - Unknown bits set, all zeros, or all ones: **stop**, the register is not the touch clock on
     A9. Don't write. Report the value.

Writes (each needs its own OK; one at a time; read back):

3. TCLK enable, only if step 2 was idle and fit the layout:
   `phone.sh insmod touch_clk_t1.ko enable=1 expect=0x<value from step 2>`.
   The module refuses if the value changed. Check the `after` line: `disable 0 enable 1 busy 0
   div 732`. Pads line printed 5 ms later: note pad 142.
3b. Touch analog supply (rule-13 pre-approved write): if step 2 showed Chestnut 0x05 = 0x0f,
   set bit 4 (0x05 = 0x1f) with the chestnut_ldo module used on 2026-09-29, and read it back.
   The p1 survey found it restored to 0x0f after the earlier test. Order then matches
   Corellium: analog on, core on (0x319 already 0x01), clock on, then reset release in step 4.
4. HBPP check with the clock and analog supply on: touch_diag_d2 (still loaded, or reload `build/touch-diag/d2`)
   `step=4 mode=3 speed_hz=1000000 cs_setup_ns=5000 cs_hold_ns=10000`, write `run`. The pass
   mark is HBPP words in the RX (`18e1`, `1aa1`, `4bc1`, ...) and a non-zero N1 version at
   0x10008ffc. If it is still all zeros: restore the clock
   (`touch_clk_t1.ko restore=1 expect=<step-2 value>`) and try `reset_invert=1` once. If both
   fail, the next candidate (Corellium order) is a core power cycle with the analog rail on:
   0x319 bit0 off, wait, on again. That is a D2255 write outside rule 13 and needs a new OK.
5. Only if step 4 passed: firmware and driver, steps 5a-6b below.

Driver bring-up test (after step 4, clock and analog supply still on):

5a. Preconditions (read-only): `/lib/firmware/apple/mtfw-n71.bin` is 84092 bytes;
   `touch_clk_t1.ko` (no parameters) shows `enable 1 ... div 732`; Chestnut 0x05 = 0x1f;
   `cat /sys/bus/spi/devices/spi0.0/of_node/compatible` starts with `apple,n71-multitouch`, and
   `apple,z2-cal-blob` is 1024 bytes (`wc -c /sys/bus/spi/devices/spi0.0/of_node/apple,z2-cal-blob`,
   from `touch-live.dtbo`). Use the `touch-next-mods-integ` set (the one loaded last time):
   both sets print the same vermagic, so `uname -r` can't tell them apart.
5b. Remove the old driver: `echo spi0.0 > /sys/bus/spi/drivers/apple-z2-n2/unbind` (if bound),
   `rmmod apple_z2_n2`.
5c. `insmod apple_z2_n2.ko dyndbg=+p` (from `build/touch-next-mods-integ/z2n2/`), then
   `echo apple-z2-n2 > /sys/bus/spi/devices/spi0.0/driver_override;
   echo spi0.0 > /sys/bus/spi/drivers_probe`. Probe is async and the upload takes about 1 s at
   1 MHz, so read `dmesg` after 3 s.
5d. Expected info lines, in order:
   - `HBPP at 1000000 Hz (run 8000000 Hz), mode 3, CS setup 5000 hold 10000 ns`
   - `HBPP bootloader: ...` (words from {1f01, 4879, ...})
   - `calibration 1038 bytes to 0x10009000: acked`
   - `blob of 65460 bytes: acked`, then `blob of 18600 bytes: acked`
   - `bootloader version 0x434d15c1`
   - `calibration request done, status 0x.... (...)`: record the value, it isn't checked
   - `firmware started at 0x10003400`
   Then `readlink /sys/bus/spi/devices/spi0.0/driver` ends in `apple-z2-n2`.
   dyndbg lines to check: calibration tx head `30 01 01 00 90 00 10 00 00 a1 ...`; image 0 head
   `18 e1 30 01 3f e9 00 00 00 00 01 28 f0 18 e5 9f`, tail `01 18 00 00 ea 35 00 57`; image 1
   head `18 e1 30 01 12 26 19 00 00 40 00 91`, tail `60 1a 00 00 bd ff 00 19`; the three
   REG_WRITEs (0x10003060, 0x1000305c, 0x10003058), 0x10003000 and 0x10003518 each with
   `status 0x4ad1 (ACK_REG)`.
5e. If it fails, save the whole dmesg and stop. Don't retry blindly. Which failure it is:
   - calibration still `reject`: framing is now the same as Apple's images, so capture the tx
     trace. The next candidates are a leading NOP (like the images) and `hbpp_speed_hz=500000`.
   - `after 50 polls` with `idle`: the bootloader never finished the packet.
   - image 0 `spi error` / `timeout`: the SPI controller, not the protocol.
   - REG_WRITE not `ACK_REG`: the register write mask meaning (0xffffffff) is the suspect.
   - `read ...: unexpected reply`: note it. Only the const-cal choice depends on the version.
   - boot completes but reports are garbage: the report reads after EXECUTE run at the DT
     8 MHz, and there is no runtime knob for it (an overlay can't change `spi-max-frequency`
     on an existing device). Suspect this first; changing it needs a rebuild.
   Clean up after a failure: `echo spi0.0 > .../apple-z2-n2/unbind` if bound,
   `echo > /sys/bus/spi/devices/spi0.0/driver_override`, `rmmod apple_z2_n2`.
6. No finger: find the node
   (`grep -l "iPhone 6s Touchscreen" /sys/class/input/event*/device/name`), note the
   `apple-z2-irq` count in `/proc/interrupts`, then run `evtest /dev/input/eventN` for 10 s.
   Expected: no events. The IRQ count may rise a little; each read shows up as a dyndbg
   `EB reply` or `report` line. Turn dyndbg off before long runs:
   `echo 'module apple_z2_n2 -p' > /sys/kernel/debug/dynamic_debug/control`.

Human finger test:

6b. One finger held in the centre with evtest running: expect `BTN_TOUCH 1`,
   `ABS_MT_TRACKING_ID`, `ABS_MT_POSITION_X/Y`, then release on lift. If the IRQ count rises
   but there are no events, turn dyndbg back on and save the `report` lines. The report layout
   is the unverified touch bar parser. If the IRQ count does not move, look at pad 142 / the
   IRQ trigger.
7. One finger in each corner (top-left, top-right, bottom-left, bottom-right), then the
   centre, then a slow drag along each edge, then two fingers. Record the raw
   ABS_MT_POSITION_X/Y at each corner, check BTN_TOUCH and slot release on lift.
8. Fix the axes in the DT (kernel side, applies to every consumer): `touchscreen-size-x/-y` =
   raw maxima, `touchscreen-inverted-x/-y` / `touchscreen-swapped-x-y` from the corner table.
   Use the udev `LIBINPUT_CALIBRATION_MATRIX` rule (`tools/userland/overlay/etc/udev/rules.d/`)
   only for an offset the DT can't express. Then start Hyprland (`phone-hyprland`) and tap foot.

## Provenance

| fact | source |
|---|---|
| SPI v1 register usage, FIFO level fields, depth 16, CFG bits, 0x40000f clear, PIO order | iOS 15.8.8 kernelcache, `AppleSamsungSPI` kext, static disassembly (capstone) |
| "S5L" variant idea (FIFO levels in STATUS) | HoolockLinux `tests/kat-spi` branch (public, read-only) |
| M1 SPI layout used for comparison | upstream `spi-apple.c`, Asahi m1n1 `hw/spi.py` (public) |
| spi2 reg/irq/clock-gate, `function-spi_cs0` GPIO 44, reset GPIO 75, irq GPIO 142, SPI mode/period in `reg`, power/clock functions | IPSW ADT `DeviceTree.n71ap` (template) |
| `multi-touch-calibration` (1024 B) and orb/prox cal values | runtime ADT from `/dev/mtd1ro` (device unique, not published) |
| PMGR index to ps_spi2 (0x801c8) | ADT pmgr `devices` table, cross-checked with foundation |
| SCK/MOSI/MISO = GPIO 41-43 func 1, CS 44 func 1, reset 75 = output low | live read-only pin-register dump (`tpindump1`) |
| LDO26 on (0x319=01), Chestnut 0x05 = 0x0f (touch analog off) | live read-only PMU/i2c reads (`ttpwr_v1`) |
| LDO index 0x19 -> reg 0x319, Chestnut select 2 -> reg 0x05 bit4 | iOS `AppleD2255PMU` LDO table and `AppleChestnutDisplayPMU::setLDO`, static disassembly |
| `Z2Compliant`, N1 addresses (fll, ref-clk-div, clk32, cal-dl, prox-cal, fw-execute) | iOS kernelcache `__PRELINK_INFO`, `AppleMultitouchSPIN71` personality |
| HBPP packet ids, ack codes, N1 boot order, MemRead/RegWrite/EXECUTE formats | iOS `AppleMultitouchSPI` kext (`MTSPIBootloader_Z2/_N1`, `AppleMultitouchZ2SPI`), static disassembly |
| D2255 0x2xx/0x3xx pages, Chestnut 0x05 | live read-only survey `touch_power_p1` (2026-09-29) |
| touch supplies as on/off switches (PMU 0x31f bit0, Chestnut 0x05 mask 0x10), power-on order, 32 kHz touch clock register layout at PMGR+0x78000 on A10 | Corellium `linux-sandcastle` (GPL): `hx-h9p-d10.dts`, `hx-pmu-i2c-pwrsw.c`, `hx-touch.c`, `clk-hx-pmgr.c` |
| TCLK (8, 100, 0x8000), PMGR `clocks` entry 8 = "LPO" | runtime ADT, `/arm-io/spi2/multi-touch` and `/arm-io/pmgr` |
| constructed firmware images, `PreconstructedBootloadPacketType=Z2`, version 0x0670.mihu | IPSW rootfs `/usr/share/firmware/multitouch/N71.mtprops` (checksums checked by the extractor) |
| Z2FW container, touch bar packet layouts (0x3001 DATA with a 10-byte header, 0x1e33 RMW, 0x1f01), EB/E1 report read | Asahi `asahi_firmware/multitouch.py` and upstream `apple_z2.c` (public) |
| 0x4f81 reject on the padded calibration packet, memread reply `4c39 <value> <sum>` | live driver and touch_diag_d2 step 4 runs (2026-09-29) |

No touch report has been seen yet. Live HBPP traffic so far: the diag check and memory read, and the driver's rejected calibration packet.
