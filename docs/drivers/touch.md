# Touch (iPhone 6s N71 multitouch on spi2)

**Status: concluded, parked (2026-09-30).** Live testing is done. The controller boots over
HBPP, and the full plumbing works end to end: finger down -> IRQ -> two-phase SPI report read
-> decode path, with `BTN_TOUCH` auto-firing through input-mt's pointer emulation once the
per-finger slot path runs (`INPUT_MT_DIRECT` emits it unconditionally from
`input_mt_sync_frame`, confirmed by reading `input-mt.c`; earlier zero-`BTN_TOUCH` readings were
a symptom of the locate step failing, not a missing feature). **But the controller, as
initialized by this driver, only ever emits a COARSE report:** the frame's payload-length field
is hardcoded `0x0002` in every capture, which leaves about one bit of position per axis (screen
quadrant) plus a touch-onset settle counter — there is no full-resolution X/Y anywhere in the
report. Three live firmware-mode experiments to unlock a richer report were all negative (see
"Live-test results" below). Full-resolution touch needs an unknown vendor firmware command
outside the driver's reverse-engineered command table; reaching it needs either observing iOS's
own init sequence or blind command fuzzing (brick risk on a tethered, no-recovery-partition
device). Touch is **parked**: coarse/quadrant position works, usable high-resolution touch does
not exist yet. PR #19 (`touch-next`, the branch all of this was tested on) stays open and
unmerged.

Patches: `patches/touch/` (6 patches, `git am` onto `6831bc701` on their own, checked) cover the
SPI controller, DT and the original apple_z2 iPhone variant, and are build-only (CI never boots
the phone — see `docs/CI.md`). The live results below were obtained with a much more iterated
HBPP-path driver developed on the unmerged `6s/touch-next` branch (PR #19): the power/clock
bring-up (32 kHz touch clock, Chestnut analog rail, PMU switches) and the report-read fixes that
made finger detection possible live only on that branch, not in `patches/touch/`.

## What

| item | value (source: IPSW ADT, runtime ADT, iOS 15.8.8 kernelcache) |
|---|---|
| controller | `/arm-io/spi2`, `spi-1,samsung`, `spi-version 1`, 0x20a088000, AIC 190, PMGR ps_spi2 (0x801c8) |
| device | `/arm-io/spi2/multi-touch`, `multi-touch,n71,2`, iOS class `AppleMultitouchN1SPI` (kext `AppleMultitouchSPIN71`) |
| pins | SCK/MOSI/MISO = GPIO 41-43 (periph 1, set by iBoot, read from the live pin registers). CS = GPIO 44 (`function-spi_cs0`) |
| reset / irq | reset = GPIO 75 (active low, iBoot leaves it asserted: pin reg 0x72202). irq = GPIO 142 (`interrupt-parent` is the GPIO controller, not AIC) |
| SPI mode | ADT reg `00000000 7c000000 01 03 01 08 ...`: 124 ns period (about 8 MHz), CPOL=1, CPHA=1, MSB first, 8 bit |
| power | `function-power_ldo` = D2255 LDO index 0x19 ("ldo26", enable reg 0x319 bit0): **ON** (read 0x01 live). `function-power_ana` = Chestnut display PMU (i2c0 0x27) reg 0x05 bit4: **OFF** (read 0x0f live). `function-clock_enable` = PMGR `TCLK` 8/100/0x8000 (not decoded) |

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
The ref clock is assumed to be clkref (24 MHz); iOS uses a PMGR "nclk" whose rate I could not
find. The live probe measures the real SCK rate.

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

Resolved by live testing (see "Live-test results" below): the post-boot report is **not** the
touch bar's `EA`/`EB` frame — N71 has its own frame format (`e0 00 02 00 ...` header, an 18-byte
per-finger record, then a static footer), and the live-observed length field caps the real
payload at 2 bytes regardless of the announced frame size, so no raw coordinate range was ever
recoverable from it. The analog rail being off (below) was the pre-bring-up, iBoot-left state;
the live results required completing power/clock bring-up (Chestnut analog rail on, 32 kHz
touch clock enabled) on the `6s/touch-next` branch, not in the `patches/touch/` series below.

## Firmware and calibration (never committed)

- `tools/touch/extract-n71-touch-fw.py N71.mtprops apple/mtfw-n71.bin` builds a Z2FW file:
  SEND_CALIBRATION(0x10009000) plus 2 SEND_BLOBs, 84092 bytes. Push it to
  `/lib/firmware/apple/` on the phone.
- `tools/touch/adt-touch-cal.py <runtime-adt>` prints `apple,z2-cal-blob` from the runtime ADT
  (`/dev/mtd1ro`, 1024 bytes, device unique). The IPSW ADT only has the syscfg placeholder.

## Original live-test plan (as designed, before the first boot)

This was the plan going in; all of it has since been executed (and then far exceeded — see
"Live-test results" right below). Kept for history.

1. Confirm `ps_spi2` phandle 0xf039 (fnd_phandle). Load `tools/touch/live-test/ttpwr_v1.c`
   (read-only rail report plus spi2 domain), then `tspis_v1` (the S5L driver).
2. Apply `testkit/overlays/touch-spi2-v1.dtso` **once and never remove it**. It adds spi2 and a
   `hoolock,z2probe-v1` child. Expect `S5L SPI controller, ref clock 24000000 Hz`.
3. Load `tz2probe_v1`. It logs: irq level; 1 KiB timing (actual SCK); dummy transfer; reset
   deassert plus irq edges; 3 HBPP checks (expect `IN HBPP`, words like `18e1/1aa1/...`);
   ATN_ACK; read-only reads of 0x10008ffc (N1 version) and 0x10003800. Reset is re-asserted at
   the end. A version value is the "controller is talking" proof.
4. Only then: enable the Chestnut touch analog LDO (reg 0x05 |= 0x10, what iOS does). That is a
   display-PMU write and needs the human or coordinator's OK. Next, bind `apple,n71-multitouch`
   (new overlay child with the cal blob, firmware pushed) and run `evtest`.
5. Human touch test: on `/dev/input/eventN` ("iPhone 6s Touchscreen"), touch and drag one
   finger in each corner, then two fingers. Check that ABS_MT_POSITION_X/Y change, the range
   and orientation (it may be inverted or scaled against 750x1334), and that BTN_TOUCH/slot
   release on lift.

## Live-test results (concluded 2026-09-30)

Extensive live testing on the `6s/touch-next` branch (PR #19, unmerged — a long chain of driver
iterations well past the original 6-patch series) got the controller fully booting and
reporting:

- **Plumbing confirmed working end to end:** finger down -> IRQ -> two-phase SPI report read
  (the N71-specific frame, not the touch bar's `EA`/`EB`) -> decode path. `BTN_TOUCH` auto-fires
  via input-mt's pointer emulation once the per-finger slot path runs — confirmed by reading
  `input-mt.c` (`INPUT_MT_DIRECT` always emits it from `input_mt_sync_frame`); the earlier
  zero-`BTN_TOUCH` readings were a symptom of the locate step failing on most reads, not a
  missing feature.
- **The report is coarse only.** Across every captured frame (idle and finger-present, multiple
  sessions), the frame's payload-length field is hardcoded `0x0002`. Only two bits in the
  18-byte per-finger record move with finger position at all (`record[4]` bits 4 and 5 — the
  X and Y quadrant MSBs), giving roughly one bit of resolution per axis (which screen quadrant),
  plus a touch-onset settle counter that decays after contact and was originally mistaken for
  motion data. No full-resolution X/Y field exists anywhere in the 91-byte frame (header,
  record, or the previously-unlogged tail bytes 64-90, which turned out to be a static footer).
- **Three live firmware-mode experiments, all negative:**
  1. `post_boot_cmd=1` (send the `19 c1` probe after boot) — acked, report stayed coarse.
  2. `post_boot_cmd=2` (also an `EE` config packet in `EB` framing) — acked, report stayed
     coarse.
  3. `report_len=256 report_overread=1` (read far past the announced length) — the extra bytes
     were dummy fill identical to the static footer; not an under-read.
- **Conclusion:** the controller, as initialized via HoolockLinux's HBPP path, will not emit
  more than a coarse/quadrant report through any command in the driver's reverse-engineered
  table. Full-resolution touch needs an unknown vendor firmware mode command — finding it needs
  either observing iOS's own touch-controller init sequence or blind command fuzzing, which
  carries brick risk on this tethered, no-recovery-partition device. **Touch is parked** at
  "coarse/quadrant position works; usable high-resolution touch not yet achievable." PR #19
  stays open and unmerged; do not merge it as "touch working" until (or unless) high-resolution
  decode is solved.

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
| LDO26 on (0x319=01), Chestnut 0x05 = 0x0f (touch analog off, pre-bring-up iBoot state) | live read-only PMU/i2c reads (`ttpwr_v1`) |
| Coarse-only report (length field hardcoded 0x0002), quadrant-only position bits, 3 negative firmware-mode experiments, HBPP-path plumbing (IRQ/decode/`BTN_TOUCH`) confirmed working | live SPI capture and decode analysis, 2026-09-30 investigation on `6s/touch-next` (PR #19, unmerged) |
| LDO index 0x19 -> reg 0x319, Chestnut select 2 -> reg 0x05 bit4 | iOS `AppleD2255PMU` LDO table and `AppleChestnutDisplayPMU::setLDO`, static disassembly |
| `Z2Compliant`, N1 addresses (fll, ref-clk-div, clk32, cal-dl, prox-cal, fw-execute) | iOS kernelcache `__PRELINK_INFO`, `AppleMultitouchSPIN71` personality |
| HBPP packet ids, ack codes, N1 boot order, MemRead/RegWrite/EXECUTE formats | iOS `AppleMultitouchSPI` kext (`MTSPIBootloader_Z2/_N1`, `AppleMultitouchZ2SPI`), static disassembly |
| constructed firmware images, `PreconstructedBootloadPacketType=Z2`, version 0x0670.mihu | IPSW rootfs `/usr/share/firmware/multitouch/N71.mtprops` (checksums checked by the extractor) |
| Z2FW container, touch bar packet layouts (0x3001 DATA, 0x1e33 RMW, 0x1f01), EB/E1 report read | Asahi `asahi_firmware/multitouch.py` and upstream `apple_z2.c` (public) |

The hardware/protocol identification above (SPI register usage, HBPP packet formats, ADT
facts) comes from static analysis, as noted per-row in the table above. The report-format and
resolution findings in "Live-test results" come from live SPI traffic captured on the phone on
2026-09-30.
