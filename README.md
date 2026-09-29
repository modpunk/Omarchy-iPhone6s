# Omarchy iPhone6s

Linux drivers for the **iPhone 6s** (Apple A9) on [HoolockLinux](https://github.com/HoolockLinux),
tethered-booted through checkm8 and pongoOS.

## What this is

A HoolockLinux kernel and its test ramdisk, booted on an iPhone 6s (N71, Samsung A9) with a
tethered, RAM-only chain:

```
checkm8 (palera1n) -> pongoOS -> m1n1 -> Linux + initramfs
```

Nothing is written to the phone. Reboot it and it is an iPhone again. This repo collects the
driver patches, test kit, and hardware notes that grow that kernel into something usable.

## What it is not

It is **not** the Omarchy desktop, and it won't be soon. Hyprland needs a GPU, and the 6s has a
PowerVR GT7600 with no open driver. There is no storage driver yet either, so everything runs
from RAM. [Omarchy](https://omarchy.org) is the goal and the inspiration, not the current state.

## Status

Tested on one iPhone 6s (N71, Samsung) running `7.3.0-rc1-g6831bc701a6c`.

| | |
|---|---|
| **Works** | simpledrm framebuffer (750x1334), all 5 buttons, backlight, PMIC RTC, watchdog, both CPU cores, 2 GB RAM, USB gadget (NCM network + ACM serial), telnet root shell at `172.16.42.1` |
| **In progress** | battery gauge (bq27540 over HDQ), Bluetooth (BCM4350 on UART), touchscreen (SPI multitouch), PCIe (read-only NVMe + Wi-Fi), extra UART buses, PMIC/RTC fixes |
| **Out of scope** | GPU, audio, camera, modem, sensors behind the AOP coprocessor, NFC, Secure Enclave |

Per-driver detail lives in [`docs/drivers/`](docs/drivers/), hardware addresses in
[`docs/hardware.md`](docs/hardware.md), and the first successful boot in
[`docs/first-boot-2026-09-28.log`](docs/first-boot-2026-09-28.log).

## Quick start

You need a Linux host, an iPhone 6s, a Lightning cable, and the pieces from the
[HoolockLinux setup docs](https://github.com/HoolockLinux/docs): their `linux` kernel tree,
m1n1, the test initramfs, and palera1n + pongoOS + pongoterm. `kit/boot.sh` expects them under
`$HOOLOCK` (override any path with `KSRC`, `M1N1`, `BIN`, `INITRAMFS`, `OUT`).

```sh
export HOOLOCK=~/hoolock        # linux/, m1n1/m1n1.bin, bin/, initramfs/
kit/boot.sh kernel              # build Image.gz + s8000-n71.dtb / s8003-n71m.dtb (16K pages)
kit/boot.sh blob                # m1n1 + bootargs + dtbs + kernel + initramfs -> out/m1n1-linux.bin
# put the phone in DFU mode
kit/boot.sh pongo               # checkm8 + load pongoOS (sudo)
kit/boot.sh linux               # send the blob and bootm (Ctrl+C once m1n1 starts)
telnet 172.16.42.1              # or: kit/boot.sh shell  (USB serial)
```

The host gets `172.16.42.2` over USB networking. Driver authors: read
[`testkit/TESTING-RULES.md`](testkit/TESTING-RULES.md) before running anything on the phone, and
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) before opening a PR.

## Layout

```
kit/boot.sh          build + tethered boot
testkit/             phone.sh / phone.py (safe live-test access), kbuild.sh (out-of-tree modules),
                     dtbo_loader (apply DT overlays at runtime), hello (vermagic check), overlays/
tools/               Apple device-tree (ADT) parsers
patches/<driver>/    git format-patch series against HoolockLinux/linux 6831bc701
docs/                hardware inventory, first-boot log, driver notes, contributing guide
```

No Apple or Broadcom binaries are in this repo, and none will be accepted: no IPSW contents,
kernelcache, device-tree dumps, or firmware. Extraction steps live next to the code that needs them.

## License

Kernel code and patches are GPL-2.0 ([`LICENSE`](LICENSE)). Device-tree files follow upstream
Linux and are `GPL-2.0+ OR MIT`, as marked in their SPDX headers.

## Credits

- [HoolockLinux](https://github.com/HoolockLinux): the kernel, m1n1 port, ramdisk and docs this builds on
- [Asahi Linux](https://asahilinux.org): m1n1 and the Apple SoC drivers upstream
- Konrad Dybcio and Nick Chan: the A9 / iPhone device trees in mainline Linux
- checkm8 (axi0mX), [palera1n](https://github.com/palera1n/palera1n) and
  [pongoOS](https://github.com/checkra1n/pongoOS): the tethered boot path
- Part identification from the [iFixit iPhone 6s teardown](https://www.ifixit.com/Teardown/iPhone+6s+Teardown/48170)

iPhone is a trademark of Apple Inc. This project is not affiliated with Apple, HoolockLinux, or Omarchy.
