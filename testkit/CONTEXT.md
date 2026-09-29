# iPhone 6s (N71AP, Samsung A9 s8000) hardware facts — shared by all agents

Live phone: `testkit/phone.sh run 'dmesg'`. Boot log: ../docs/first-boot-2026-09-28.log
Hardware summary: ../docs/hardware.md. Apple ADT (iOS 15.8.8, 19H422): extract
n71ap-apple-dt.bin yourself from the IPSW (../tools/README.md); it is never published.
Dump props of any node:
  python3 ../tools/adt2.py n71ap-apple-dt.bin <node-name> [...]
IPSW: iPhone_4.7_15.8.8_19H422_Restore.ipsw (kernelcache, root filesystem DMG
with firmware). Local copies only, never committed.

Already working: simpledrm fb 750x1334, gpio-keys (all 5), dwi backlight, PMIC RTC,
wdt, dwc2 USB gadget (NCM + ACM), both Twister cores, 2 GB RAM.
Linux DT: linux/arch/arm64/boot/dts/apple/{s8000-n71.dts, s800x-6s.dtsi,
s800-0-3-common.dtsi, s800-0-3.dtsi, s800-0-3-pmgr.dtsi}. Only serial0 exists today.

Apple arm-io ranges: child 0x0 -> CPU 0x2_0000_0000 (so phys = 0x200000000 + reg).
AIC irq numbers below are the Apple ADT numbers (Linux AIC uses the same index: <AIC_IRQ n ...>).
| bus  | phys          | size   | irq | clock-gate idx | ADT compat      | child |
| uart0| 0x20a0c0000   | 0x4000 | 192 | 80 | uart-1,samsung | (debug; = Linux serial0) |
| uart1| 0x20a0c4000   | 0x4000 | 193 | 81 | uart-1,samsung | bluetooth (bluetooth,n88) |
| uart3| 0x20a0cc000   | 0x4000 | 195 | 83 | uart-1,samsung | (see tree) |
| uart4| 0x20a0d0000   | 0x4000 | 196 | 84 | uart-1,samsung | (see tree; wlan-pcie-uart?) |
| uart5| 0x20a0d4000   | 0x4000 | 197 | 85 | uart-1,samsung | gas-gauge (bq27540, hdq) |
| uart6| 0x20a0d8000   | 0x4000 | 198 | 86 | uart-1,samsung | (see tree) |
| spi1 | 0x20a084000   | 0x4000 | 189 | 75 | spi-1,samsung  | audio-codec cs42l71 |
| spi2 | 0x20a088000   | 0x4000 | 190 | 76 | spi-1,samsung  | multi-touch,n71,2 |
| spi3 | 0x20a08c000   | 0x4000 | 191 | 77 | spi-1,samsung  | (see tree) |
Clock-gate idx = Apple PMGR device index; find the matching ps_* power-domain in
s800-0-3-pmgr.dtsi (e.g. ps_uart1, ps_spi2) — verify by reg offset, don't guess.
Fixed DT labels (use exactly these so branches merge): serial1, serial3, serial4,
serial5, serial6 ; spi1, spi2, spi3.

Peripherals (ADT path → chip):
- /arm-io/uart5/gas-gauge: TI bq27540, HDQ protocol. Linux: CONFIG_BATTERY_BQ27XXX_HDQ=y,
  CONFIG_W1=y, CONFIG_W1_MASTER_UART=y (1-Wire over UART, not HDQ).
- /arm-io/uart1/bluetooth: Broadcom (USI 339S00043 module, BCM4350 combo). Linux hci_bcm serdev.
  props: transport-speed, local-mac-address from syscfg (unavailable → set addr from host).
- /arm-io/spi2/multi-touch: compatible multi-touch,n71,2, irq 0x8e, calibration in syscfg
  (MtCl, falls back to zeroes). 3D Touch IC 343S00014 on the display (iFixit).
  Linux has drivers/input/touchscreen/apple_z2.c (M1 Touch Bar) — protocol match UNVERIFIED.
- /arm-io/apcie (apcie,s8000, 4 ports, msi) → pci-bridge0/s3e (Apple NVMe "ANS2", nvme-mmu0,
  Toshiba THGBX5G7D2KLFXG 16 GB NAND), wlan (wlan-pcie,bcm4350), baseband-pcie (Qualcomm MDM9635M).
  Linux PCIE_APPLE=y is the M1 driver (different block). dart-apcie0/1/2 IOMMUs.
- spi1 audio-codec cs42l71 (338S00105), i2c1 audio-speaker/actuator cs35l19 (338S1285), spi3 mesa (Touch ID),
  tigris charger sn2400, als ct821, display-pmu chestnut (TI 65730AOP) — out of scope now.
- sgx: PowerVR GT7600 — no open driver, out of scope. aop sensors, isp, sep, nfc, baseband: out of scope.

Known bugs in the running boot: "OF: Bad cell count for /soc/i2c@20a110000/pmic@74" x5;
RTC reads 2021-08-19 (rtc_offset nvmem cell wrong or unapplied).
