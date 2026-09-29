# iPhone 6s hardware inventory (N71AP / N71mAP)

A working summary for driver authors. Sources: Apple's device tree from iOS 15.8.8 (19H422)
read with `tools/adt2.py` (see `tools/README.md` to extract your own), the running Linux boot
(`docs/first-boot-2026-09-28.log`), and the
[iFixit iPhone 6s teardown](https://www.ifixit.com/Teardown/iPhone+6s+Teardown/48170) for part numbers.

- **SoC**: Apple A9 (APL0898), two Twister cores. Samsung build = `s8000` (N71AP, Linux `s8000-n71.dts`),
  TSMC build = `s8003` (N71mAP, Linux `s8003-n71m.dts`). The test phone is Samsung.
- **RAM**: 2 GB LPDDR4 (Linux sees 0x800000000-0x87da0bfff).
- **Addresses**: `arm-io` children map child `0x0` to CPU `0x2_0000_0000`, so phys = `0x200000000 + reg`.
- **IRQs**: AIC numbers are the ADT numbers; Linux uses the same index in `<AIC_IRQ n ...>`.
  Interrupts on *child* devices (touch, codec, PMIC...) are usually GPIO lines: check the
  node's `interrupt-parent` in the ADT before using them.

## Buses

| bus   | phys          | AIC irq | PMGR gate | Linux status |
|-------|---------------|---------|-----------|--------------|
| uart0 | 0x20a0c0000   | 192     | 80        | works (`serial0`, debug console) |
| uart1 | 0x20a0c4000   | 193     | 81        | in progress (`serial1`, Bluetooth) |
| uart3 | 0x20a0cc000   | 195     | 83        | in progress (`serial3`, NFC lives here) |
| uart4 | 0x20a0d0000   | 196     | 84        | in progress (`serial4`, Wi-Fi side channel) |
| uart5 | 0x20a0d4000   | 197     | 85        | in progress (`serial5`, battery gauge) |
| uart6 | 0x20a0d8000   | 198     | 86        | in progress (`serial6`, iAP / Lightning accessories) |
| spi1  | 0x20a084000   | 189     | 75        | not yet (`spi1`) |
| spi2  | 0x20a088000   | 190     | 76        | in progress (`spi2`, touch) |
| spi3  | 0x20a08c000   | 191     | 77        | not yet (`spi3`) |
| i2c0  | 0x20a110000   | 206     | -         | works (`i2c-apple`, PMIC) |
| i2c1  | 0x20a111000   | 207     | -         | not yet |
| i2c2  | 0x20a112000   | 208     | -         | not yet |
| apcie | ADT `apcie,s8000`, 4 ports | 244, 247, 250, 253 | - | in progress (Apple A9 PCIe is not the M1 block) |
| USB   | 0x20c100000 (dwc2 device) | 214 | - | works (gadget: NCM + ACM) |

PMGR gate = Apple's clock-gate index; match it to the `ps_*` domain in `s800-0-3-pmgr.dtsi`
by register offset. Labels `serial1`..`serial6` and `spi1`..`spi3` are fixed so driver series merge.

## Devices

| device | ADT node (compatible) | bus / addr | chip (iFixit / ADT) | Linux status |
|--------|-----------------------|------------|---------------------|--------------|
| Display | `mipi-dsim/lcd` (`lcd,pinot`), `disp0` | DSI | 4.7" 750x1334 LCD | works via simpledrm on the iBoot framebuffer; no display controller driver |
| Backlight | `dwi` (`dwi,s8000`); also `i2c0/lm3539` | DWI; i2c0 @0x62 | TI LM3539 | works (`apple-dwi-bl`) |
| Display PMIC | `i2c0/display-pmu` (`display-pmu,chestnut`) | i2c0 @0x27 | TI 65730AOP | left as iBoot set it |
| PMIC | `i2c0/pmu` (`pmu,d2255`) | i2c0 @0x74 | Dialog 338S00120 | RTC works (`rtc-apple-pmic`); fixes pending (bad cell count, RTC offset) |
| Buttons | `buttons` | GPIO | - | works (`gpio-keys`, all 5) |
| Watchdog | `wdt` (`wdt,s8000`) | 0x2102b0000 | - | works (`apple-watchdog`) |
| Battery gauge | `uart5/gas-gauge` (`gas-gauge,bq27540`, HDQ) | uart5 | TI bq27540 | in progress (1-Wire over UART + `bq27xxx` HDQ) |
| Charger | `i2c1/tigris` (`charger,sn2400`) | i2c1 @0x75 | TI SN2400 | not yet |
| Bluetooth | `uart1/bluetooth` (`bluetooth,n88`) | uart1 | USI 339S00043 (Broadcom BCM4350) | in progress (`hci_bcm` serdev; firmware extracted locally, never committed) |
| Wi-Fi | `apcie/pci-bridge1/wlan` (`wlan-pcie,bcm4350`) | PCIe port 1 | USI 339S00043 (Broadcom BCM4350) | in progress (needs PCIe; `brcmfmac`) |
| Storage | `apcie/pci-bridge0/s3e`, `nvme-mmu0` | PCIe port 0 | Toshiba THGBX5G7D2KLFXG 16 GB NAND, Apple ANS2 NVMe | in progress, **read-only** (holds iOS) |
| Touch | `spi2/multi-touch` (`multi-touch,n71,2`) | spi2 | 343S00014 (3D Touch), Apple multitouch | in progress (protocol vs `apple_z2` unverified) |
| Touch ID | `spi3/mesa` (`biosensor,mesa`) | spi3 | Apple Mesa | out of scope (SEP) |
| Audio codec | `spi1/audio-codec` (`audio-control,cs42l71`), `mca0` | spi1 + I2S | Cirrus 338S00105 (CS42L71) | out of scope |
| Speaker amp | `i2c1/audio-speaker` (`audio-control,cs35l19`), `mca2` | i2c1 @0x40 | Cirrus 338S1285 (CS35L19) | out of scope |
| Lightning / USB mux | `i2c1/tristar` (`tristar,cbtl1610`) | i2c1 @0x1a | NXP 1610A3 (Tristar) | not yet |
| Ambient light | `i2c2/als` (`als,ct821`) | i2c2 @0x29 | - | not yet |
| Motion sensors | `aop/iop-aop-nub/{accel,gyro,compass,pressure}` | AOP coprocessor | InvenSense MP67B (gyro/accel), compass, barometer | out of scope (behind AOP firmware) |
| NFC | `uart3/stockholm` (`nfc,primary,gpio`) | uart3 | NXP 66V10 | out of scope |
| Modem | `apcie/pci-bridge2/baseband-pcie`, `baseband` | PCIe port 2 | Qualcomm MDM9635M | out of scope |
| GPU | `sgx` (`gpu,s8000`) | AIC 170-174 | PowerVR GT7600 | out of scope (no open driver) |
| Camera / ISP | `isp`, `dart-isp` | - | - | out of scope |
| Secure Enclave | `sep` | - | - | out of scope |
| IOMMUs | `dart-apcie0/1/2`, `dart-disp0`, ... | - | Apple DART | DART support is in the base tree; PCIe DARTs in progress |

"works" = seen working on the live phone (7.3.0-rc1-g6831bc701a6c). Everything marked
"in progress" has a driver agent on it; see `docs/drivers/<name>.md` once its PR lands.
