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
| uart3| 0x20a0cc000   | 0x4000 | 195 | 83 | uart-1,samsung | stockholm (NFC, nfc,primary) — do not touch |
| uart4| 0x20a0d0000   | 0x4000 | 196 | 84 | uart-1,samsung | wlan (wlan-pcie-uart,bcm4350: WLAN sideband UART) |
| uart5| 0x20a0d4000   | 0x4000 | 197 | 85 | uart-1,samsung | gas-gauge (bq27540, hdq) |
| uart6| 0x20a0d8000   | 0x4000 | 198 | 86 | uart-1,samsung | iap (iap,uart: Lightning accessory) |
| spi1 | 0x20a084000   | 0x4000 | 189 | 75 | spi-1,samsung  | audio-codec cs42l71 |
| spi2 | 0x20a088000   | 0x4000 | 190 | 76 | spi-1,samsung  | multi-touch,n71,2 |
| spi3 | 0x20a08c000   | 0x4000 | 191 | 77 | spi-1,samsung  | mesa (Touch ID sensor, SEP-paired) — DO NOT TOUCH |
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
- CORRECTED 2026-09-29 (earlier version misplaced these on spi3):
  spi1: audio-codec cs42l71 (338S00105). spi3: mesa = Touch ID (do not touch).
  i2c0: pmu d2255 (main PMIC), display-pmu chestnut (TI 65730AOP), backlight lm3539.
  i2c1: audio-speaker + audio-actuator cs35l19 (338S1285) @0x40.., tigris charger sn2400, tristar cbtl1610 (NXP 1610A3).
  i2c2: als ct821, display-eeprom. Writing to i2c0/i2c1 devices can kill power/display — read-only only.
  All out of scope now.
- sgx: PowerVR GT7600 — no open driver, out of scope. aop sensors, isp, sep, nfc, baseband: out of scope.

Known bugs in the running boot: "OF: Bad cell count for /soc/i2c@20a110000/pmic@74" x5;
RTC reads 2021-08-19 (rtc_offset nvmem cell wrong or unapplied).

## Runtime ADT (added 2026-09-29, found by pcie agent)
iBoot's filled-in Apple DT is readable on the phone at /dev/mtd1ro (m1n1 phram "adt",
0x804374000, 160 KB). It has real values where the IPSW template has syscfg placeholders
(WLAN MAC, calibrations, apcie tunables, sart-region, likely touch MtCl and BT address).
Copy it off the phone for local use only (e.g. into firmware/, which is gitignored): it is a
device-unique Apple binary, NEVER publish. Parse: python3 ../tools/adt2.py <file> <node>.
Runtime phandles differ from the IPSW template (gpio=0x1c, aic=0x14, pmu=0x4b) — these are
ADT phandles, not Linux DT phandles; Linux phandles still come from /proc/device-tree.
Warning: don't read kernel linear-map aliases of the kernel image; pfn_is_map_memory() doesn't
protect you (caused one OOPS).

## Live phandles for overlays (added by foundation agent, loaded ~4640 s uptime)
fnd_phandle_v1.ko (foundation driver branch) gave the OFF, unreferenced PMGR domains fixed phandles (in-memory DT only):
  ps_spi1 0xf038, ps_spi2 0xf039, ps_spi3 0xf03a,
  ps_uart1 0xf03c, ps_uart3 0xf03e, ps_uart4 0xf03f, ps_uart5 0xf040, ps_uart6 0xf041
Other live Linux phandles: AIC = 1, clkref = 5, sio_p = 0x13.
Use power-domains = <0xf0xx> in overlays; never probe a block whose domain isn't on.
If the phone reboots, these are gone until fnd_phandle is loaded again (next-boot DTB from
6s/foundation will carry __symbols__ instead).
