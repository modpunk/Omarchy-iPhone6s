# Bluetooth (BCM4350 over uart1)

> **Depends on:** the `foundation` series (PR #3, `patches/foundation/0001..0005`: uart1 node
> `serial1`, PMIC `#size-cells = <0>`, samsung_tty remove fix). Apply foundation first, then
> `patches/bluetooth/*.patch`. Checked: both series `git am` cleanly onto `6831bc701`, and the
> result is identical to the `6s/bluetooth` branch.

## What

- **Hardware**: Bluetooth half of the Broadcom BCM4350 combo chip (USI 339S00043 module;
  WLAN half is on PCIe). Apple DT node `/arm-io/uart1/bluetooth`, compatible `bluetooth,n88`,
  `transport-speed` 3000000, `transport-encoding` 3 (H4).
- **Bus**: Apple S5L UART `uart1`, phys 0x20a0c4000, AIC 193, PMGR domain `ps_uart1`.
- **Linux**: stock `hci_uart` + `hci_bcm` serdev + `btbcm` (all built in), plus a new small
  GPIO driver for the PMIC pin that drives REG_ON.

### Pins (decoded from the Apple DT `function-*` properties)

Format of a `function-*` GPIO reference: `<phandle> 'GPIO' <pin> <flags>`.

| Signal | ADT property | Controller | Pin | Linux |
|---|---|---|---|---|
| BT REG_ON (power enable) | `bluetooth/function-power_enable` = `<pmu GPIO 0x08 0x101>` | D2255 PMU on i2c0 @0x74 | 8 | `shutdown-gpios = <&pmic_gpio 8 GPIO_ACTIVE_HIGH>` |
| BT_WAKE (host -> chip) | `bluetooth/function-bt_wake` = `<gpio GPIO 0x47 0x101>` | AP GPIO | 71 | `device-wakeup-gpios = <&pinctrl_ap 71 GPIO_ACTIVE_HIGH>` |
| UART TX | `uart1/function-tx` = `<gpio GPIO 0x18 0x102>` | AP GPIO | 24 | `APPLE_PINMUX(24, 1)` |
| UART RTS | `uart1/function-rts` = `<gpio GPIO 0x1a 0x2>` | AP GPIO | 26 | `APPLE_PINMUX(26, 1)` |
| UART RX / CTS | (not listed; UART pins come in groups of 4) | AP GPIO | 25 / 27 | left as iBoot set them |
| host wake (chip -> host) | none in the ADT for BT; PMU `event_name-gpio10 = "bluetooth"` is a PMU interrupt input | PMU | - | not wired up |

- No separate reset pin and no 32 kHz clock reference in the ADT.
- **Shared with WLAN?** No shared pin: WLAN REG_ON is a *different* PMU pin,
  `/arm-io/uart4/wlan function-reg_on = <pmu GPIO 0x0a 0x101>` (PMU GPIO 10). Nothing here
  touches it.
- On the live phone (read only) the AP pin configs were: 24 `000723a1` (UART function),
  25 `000763a1`, 26 `00072203` (still GPIO -> needs the pinmux), 27 `00076220`, 71 `00072202`.

### Patches

| # | Patch | Notes |
|---|---|---|
| 0001 | dt-bindings: gpio: Add Apple PMIC GPIO controller | `apple,antigua-pmic-gpio`, child of `apple,pmic` |
| 0002 | gpio: Add Apple I2C PMIC GPIO driver | `gpio-apple-pmic.c`, see "Provenance" |
| 0003 | Bluetooth: btbcm: Add BCM4350C5 UART support | subver 0x6607 in the UART table; default addr 43:50:C5:00:1F:AC invalid |
| 0004 | dt-bindings: net: bluetooth: brcm: Add BCM4350 | + `$ref` bluetooth-controller (allows `local-bd-address`) |
| 0005 | Bluetooth: hci_bcm: Add BCM4350 support | `brcm,bcm4350-bt`, same match data as bcm4349 |
| 0006 | arm64: dts: apple: s800x-6s: Add Bluetooth | pmic gpio node, uart1 pinmux, `&serial1` + `bluetooth0` |

Build checks on `6s/bluetooth` (foundation + these): full `Image` + `dtbs` build (LLVM, 0
warnings), `W=1` clean for the three touched C files, `dt_binding_check` clean for the three
touched bindings, `CHECK_DTBS=y` for `s8000-n71.dtb` / `s8003-n71m.dtb` shows no findings in the
new nodes. `checkpatch --strict`: only the `Co-Authored-By` trailer form and the MAINTAINERS
reminder for the new files.

## Status

**Partial.** On the live phone, with the throwaway overlay and the stock kernel: the patchram
loaded, `hci0` came up, powered on and an LE scan returned nearby devices. That boot was later
found to have a corrupted shared UART driver state (another overlay was removed, which freed the
samsung `uart_driver` while uart1 was bound), so treat the result as **encouraging but to be
re-done on a clean boot**. The patches themselves (PMIC GPIO driver, BCM4350 entries, DT) are
**build-tested only**; they have never run on the phone. Pairing a keyboard was not tried.

## Evidence (live phone, kernel `7.3.0-rc1-g6831bc701a6c #2`, stock drivers)

How it was brought up (the running kernel has no PMIC GPIO driver, so REG_ON was set by a
one-shot test module):

1. `bt6s_pwr_v1.ko`: powered `ps_uart1` through a virtual genpd consumer, then **wrote the
   PMIC once**: register 0x910 (PMU GPIO 8) from `0x80` to `0x81` with `regmap_write`, guarded by
   "only if it reads exactly 0x80". Nothing else on the PMIC was written.
   ```
   bt6s_pwr_v1: uart1 domain on: 0
   bt6s_pwr_v1: pmu[0x910] before = 80 (0)
   bt6s_pwr_v1: write 0; pmu[0x910] after = 81, in[0x187] = 22
   ```
   Status byte 0x187 read 0x20 before (recon module) and 0x22 after: bit 1 changed, not bit 0 as the
   `0x186 + n/8` guess predicts for GPIO 8, so the pad-status mapping is **unconfirmed**
   (possibly off by one).
2. Overlay (earlier version of `testkit/overlays/bluetooth-uart1.dtso`, without
   `power-domains`, `brcm,bcm4349-bt` as stand-in compatible, firmware pushed as
   `/lib/firmware/brcm/BCM.apple,n71.hcd`):
   ```
   20a0c4000.serial: ttySAC1 MMIO32:0x000000020a0c4000 (irq = 59, base_baud = 0) is a APPLE S5L
   serial serial0: tty port ttySAC1 registered
   hci_uart_bcm serial0-0: No reset resource, using default baud rate
   Bluetooth: hci0: BCM: chip id 110
   Bluetooth: hci0: BCM: features 0x2f
   Bluetooth: hci0: BCM4350C5
   Bluetooth: hci0: BCM (003.006.007) build 0000
   Bluetooth: hci0: BCM 'brcm/BCM.apple,n71.hcd' Patch
   Bluetooth: hci0: BCM: features 0x2f
   Bluetooth: hci0: BCM4350 UART 37.4 MHz Albarossa USI Black Magick MCC
   Bluetooth: hci0: BCM (003.006.007) build 0825
   ```
   Build 0000 -> 0825 and the local name change prove the patchram ran. Everything ran at
   115200 baud (no `max-speed`); the 3 Mbaud Apple uses is not reachable from a 24 MHz clkref
   with 16x oversampling anyway (max 1.5 Mbaud) and was not tried.
3. User space: the ramdisk has none, so an aarch64 Alpine chroot with BlueZ 5.86 was pushed
   (`testkit/bluetooth/mk-alpine-bluez.sh`). `hciconfig -a` before power-on:
   ```
   hci0:   Type: Primary  Bus: UART
           BD Address: 43:50:C5:00:1F:AC  ACL MTU: 1021:8  SCO MTU: 192:1
           Features: 0xbf 0xfe 0xcf 0xfe 0xdb 0xff 0x7b 0x87
   ```
   `btmgmt public-addr <phone's own address from the iBoot ADT>` (not published), then
   `btmgmt power on`: `hci0 Set Powered complete, settings: powered br/edr`, `hciconfig`: `UP RUNNING`.
   `btmgmt le on`, `ssp on`, then `btmgmt find` (LE + BR/EDR discovery):
   ```
   hci0 type 7 discovering on
   hci0 dev_found: BE:16:11:00:6F:C3 type LE Public rssi -88 ... name MELK-OF21C3
   hci0 dev_found: 02:24:05:13:F7:30 type LE Public rssi -78 ... name BJ_LED_M
   hci0 dev_found: D7:26:FA:4D:FA:2D type LE Random rssi -87 ... name N0A7T
   hci0 dev_found: C3:45:48:5D:59:CD type LE Random rssi -87 ... name N0GZE
   ... (11 LE results in ~10 s)
   hci0 type 7 discovering off
   ```
   `hcitool inq` / `hcitool scan` (classic BR/EDR inquiry) found **nothing**, possibly just no
   discoverable classic device nearby; not investigated. `bluetoothd` + D-Bus started in the
   chroot and `bluetoothctl show` listed the controller (Powered: yes, input and hog plugins loaded).
   `/dev/uhid` does not exist (`CONFIG_UHID` is off), so **BLE (HOGP) keyboards cannot work** with
   the current config; classic HID keyboards go through the built-in `CONFIG_BT_HIDP`.

Not tested at all: the PMIC GPIO driver, `brcm,bcm4350-bt`, the new firmware name, the in-tree DT,
`local-bd-address`, pairing, HID input, suspend/`bt_wake`, host wake, BT/WLAN coexistence.

## Firmware

iOS does not ship the patchram as a file. `/usr/sbin/BlueTool` in the root filesystem embeds all
boards' `.hcd` images; the one for this phone (USI module, "Albarossa" = N71) is
`BCM4350C5_19.1.235.4921_Albarossa_OS_USI_BM_MCC_20210628.hcd` (80991 bytes; Murata-module phones
use `..._4920_..._MUR_...`). BlueTool itself reports the same name as the controller after
loading: `BCM4350 UART 37.4 MHz Albarossa USI Black Magick MCC`.

```sh
unzip iPhone_4.7_15.8.8_19H422_Restore.ipsw 098-68805-067.dmg      # ~5 GB APFS rootfs
apfs-fuse -o ro 098-68805-067.dmg mnt                              # github.com/sgan81/apfs-fuse
tools/extract-bt-firmware.py mnt/root/usr/sbin/BlueTool out/
# out/brcm/BCM4350C5.apple,n71.hcd   <- requested by a kernel with these patches
# out/brcm/BCM.apple,n71.hcd         <- requested by the stock 6831bc701 kernel
```

apfs-fuse builds without root (`pip install cmake` in a venv, configure with
`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`, and `CXX_FLAGS="-O2 -include cstdint -std=c++17"` with
current GCC); FUSE mounting worked as a normal user. On the phone copy the file to
`/lib/firmware/brcm/` (the ramdisk root is RAM, so this is per boot).

## BD address

The chip boots with the Broadcom default 43:50:C5:00:1F:AC (patch 0003 marks it invalid, so a
patched kernel keeps `hci0` unconfigured until an address is set). The real address is in syscfg
(`BMac`), which is not readable yet, **but iBoot copies it into the runtime Apple DT**
(`/dev/mtd1ro`, `/arm-io/uart1/bluetooth/local-mac-address`, 6 bytes). Read it with
`tools/adt2.py` and set it with `btmgmt --index 0 public-addr <addr>` before powering on (or,
later, have the loader fill `local-bd-address` via the `bluetooth0` alias). It is device-unique:
never commit it. If you can't read it, use a locally administered address (first octet with bit
1 set, e.g. `02:xx:xx:xx:xx:xx`).

## Provenance (read this)

- Pins, pin numbers and the REG_ON/BT_WAKE assignments: Apple DT (IPSW template and iBoot
  runtime ADT), decoded by hand as in the table above.
- **From disassembly of iOS 15.8.8 code**:
  - The D2255 PMU GPIO register layout used by patch 0002 (config register `0x900 + 2*n`,
    output-mode bits 7:6, level bit 0, pad status `0x186 + n/8`) comes from
    `AppleD2255PMU::_setGPIOFunction` / `_getGPIOFunction` in the kernelcache. Reads of those
    registers on the phone were consistent with it (GPIO 8 = 0x80, GPIO 10 = 0x80, others
    varied), and one write (above) changed 0x910 as expected, but the status-bit mapping is not
    confirmed and the meaning of the other config bits is unknown.
  - `tools/extract-bt-firmware.py` finds the blob by the code pattern BlueTool uses to register
    it (adr/mov/movk/adrp+add), found by disassembling BlueTool.
- Firmware name and chip ids: from BlueTool strings and from what the controller reports.

## Post-reboot test plan (clean boot, same kernel #2)

Nothing in steps 3+ has been approved yet: **step 3 writes the PMIC** (REG_ON). Do not run it
without the human's go-ahead.

1. `phone.sh ping`; confirm `ps_uart1` has a phandle (fnd_phandle loaded):
   `od -An -tx1 /proc/device-tree/soc/power-management@20e000000/power-controller@801e0/phandle`
   (expect `00 00 f0 3c`; update the overlay if it differs).
2. Push firmware: `phone.sh push BCM.apple,n71.hcd`, then under `phone.sh lock` copy it to
   `/lib/firmware/brcm/BCM.apple,n71.hcd`.
3. **(PMIC write, needs approval)** `phone.sh insmod apple_pmic_gpio_t1.ko` (live-test copy of
   patch 0002 with a unique driver name). It does not write anything by itself.
4. `phone.sh overlay bluetooth-uart1.dtbo` (`testkit/overlays/bluetooth-uart1.dtso`: pmic
   `gpio@900`, uart1 pinmux, `serial@20a0c4000` with `power-domains = <0xf03c>`, `bluetooth` child
   with `shutdown-gpios = <pmic_gpio 8>`). hci_bcm then drives REG_ON through the new driver:
   this is the first real test of patch 0002. Apply **once**, never remove (TESTING-RULES 11).
   Expect the same dmesg as above; also check
   `cat /sys/kernel/debug/gpio` shows the PMIC chip and line 8 high.
5. `sh phone-bt-up.sh /tmp/6s/alp-bt.tgz <addr>` (testkit/bluetooth), then
   `timeout 25 chroot /tmp/alp btmgmt --index 0 find`. Record dmesg + output.
6. Keyboard (classic, not BLE): run `bluetoothctl` in the chroot, `agent on`, `default-agent`,
   `scan on`, `pair <kbd>`, `trust`, `connect`; check `dmesg` for an `input:` line and
   `/dev/input/event*`. BLE keyboards need `CONFIG_UHID=y` first.
7. If step 4 fails, do not remove the overlay; report and reboot.

## Known issues / next steps

- Status-bit mapping of the PMU GPIO pads (0x186+) is a guess; `get()` on inputs may be wrong.
- No host-wake IRQ (BT's is a PMU interrupt input); runtime PM/low-power mode not set up.
- Only 115200 baud tested. Faster needs `max-speed` (<= 1.5 Mbaud with the 24 MHz clkref) and a
  test; 3 Mbaud needs the real UART clock.
- `local-bd-address` is a zero placeholder until a loader fills it from the ADT.
- Enable `CONFIG_UHID` for BLE keyboards; ship BlueZ in the ramdisk.
- Calibration blobs (`bluetooth-tx-calibration` / `-rx-calibration` in the runtime ADT) are not
  sent to the chip; iOS probably does. Scanning worked without them.

## Test kit files

- `testkit/overlays/bluetooth-uart1.dtso`: live-test overlay (clean boot, apply once).
- `testkit/bluetooth/apple_pmic_gpio_t1.c`: patch 0002 as an out-of-tree module with a unique
  driver name and a lookup of the PMIC regmap that works for overlay-added nodes.
- `testkit/bluetooth/pwr/bt6s_recon_v1.c`: read-only dump of the PMU GPIO registers and AP pin
  configs. `bt6s_pwr_v1.c`: the one-shot helper used for the evidence above; **it writes the
  PMIC** (0x910 := 0x81) and powers `ps_uart1` through a virtual genpd consumer. Superseded by
  step 3/4 of the test plan; kept for the record.
- `testkit/bluetooth/mk-alpine-bluez.sh`, `phone-bt-up.sh`: BlueZ user space for the ramdisk.
