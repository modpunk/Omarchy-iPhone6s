# Getting started: Omarchy Phone on an iPhone 6s

This is the practical, start-to-finish path from a stock iPhone 6s to
[Omarchy Phone](https://github.com/modpunk/Omarchy-Phone) — Arch Linux ARM + Hyprland with its
phone shell — running on the screen and driven from a laptop over USB. It assumes you have read
nothing else in this repo yet. For the "why", see the [README](../README.md); for the full detail
behind each step, see [`docs/userland.md`](userland.md), [`docs/fast-reload.md`](fast-reload.md),
[`docs/drivers/`](drivers/) and `testkit/TESTING-RULES.md`.

Nothing here is written to the phone's flash. Every boot is tethered (checkm8 -> pongoOS ->
m1n1 -> Linux) and everything runs from RAM. Reboot the phone on its own (or let the battery die)
and it's an iPhone again.

## What you get, and what you don't

Current status (see the [README](../README.md#status) for the always-up-to-date version):

| Works, verified on the phone | Doesn't (yet) |
|---|---|
| Framebuffer display (750x1334, simpledrm), Hyprland 0.56 + software rendering (llvmpipe), foot terminal | **Touch** — the SPI touch controller stays unpowered (the PMU LDO voltage code is unknown); the screen is display-only |
| The **Omarchy Phone shell** (QuickShell) and the Phone app, driving everything from a keyboard | **Charging** — the SN2400 charger is an undocumented Apple/TI part with no register map Linux can drive. See "Charging" below. |
| Bluetooth (BCM4350): LE scan, and a BLE keyboard over `uhid` | **Wi-Fi and storage** — both sit behind the A9's PCIe block, which is shelved; no network but the USB link to the laptop, and the root filesystem lives in tmpfs |
| Battery gauge (bq27540 over HDQ): percent, voltage, current, temperature, health | Audio, camera, modem, and anything behind the AOP coprocessor, NFC, Secure Enclave — out of scope |
| All 5 buttons, backlight, PMIC RTC, watchdog, both CPU cores, 2 GB RAM, USB networking (`172.16.42.1` <-> `.2`) + a root USB telnet shell, fast kernel reload (kexec, no DFU) | |

A Bluetooth keyboard is the only practical way to interact with the phone directly, since there's
no touch.

## What you need

- **A Linux host** (the laptop that does the building and stays plugged in the whole session).
- **An iPhone 6s** (N71: `s8000-n71` Samsung or `s8003-n71m` TSMC).
- **A Lightning cable**, plugged into a **USB hub that has its own power supply** — not a
  bus-powered hub, and not a laptop port directly. In practice, a hub with its own supply adds
  roughly **+300 mA** over an unpowered port, which is enough for the phone to actually gain
  charge over a session instead of just draining; an unpowered hub port only barely covers the
  load. This matters here because Linux can't drive the charger IC at all yet (see "Charging"
  below), so how much current the *hub* supplies is what decides whether the battery goes up or
  down.
- The [HoolockLinux](https://github.com/HoolockLinux) pieces: their `linux` kernel tree, `m1n1`,
  `palera1n` + `Pongo.bin` + `pongoterm`, and the test `initramfs.gz`. Lay them out under one
  directory and point `HOOLOCK` at it (`kit/boot.sh` reads `$HOOLOCK/linux`, `$HOOLOCK/m1n1/m1n1.bin`,
  `$HOOLOCK/bin/*`, `$HOOLOCK/initramfs/initramfs.gz`; override any one with `KSRC`, `BUILD`,
  `M1N1`, `BIN`, `INITRAMFS`, `OUT`).
- For the RAM userland: `qemu-user-static` with the binfmt entry, a `/etc/subuid` range and
  unprivileged user namespaces enabled (common on a normal desktop distro). No root and no Docker
  needed — `tools/userland/build-rootfs.sh` re-execs itself into its own user namespace.
- A classic *or* BLE Bluetooth keyboard, for step 6.

Read `testkit/TESTING-RULES.md` before you improvise anything beyond these steps — the phone is
one physical device, and rule 8 in particular: if it stops answering for 60 seconds, stop and
recover through DFU rather than retrying in a loop.

## 1. Build a kernel with the phone's drivers

The RAM userland *requires* this — `tools/userland/build-rootfs.sh` refuses to build without a
kernel tree that already has the out-of-tree driver modules (`gpio-apple-pmic`, `mux-sn2400`,
`bq27xxx_battery_hdq_uart`) built and matching the running release. There's no plain-mainline
shortcut; you need the same combined kernel this repo tests against: `foundation`, `battery`,
`bluetooth` (through patch 0007, the LE-advertising fix that makes BLE keyboards pair) and
`fast-reload`, all applied to one `$HOOLOCK/linux` tree.

Get the patches on following `docs/CONTRIBUTING.md`'s recipe (`git am` onto commit `6831bc701`),
in this order — `battery` and `bluetooth` both depend on `foundation`:

```sh
cd $HOOLOCK/linux && git checkout 6831bc701
git am /path/to/omarchy-iphone6s/patches/foundation/*.patch
git am /path/to/omarchy-iphone6s/patches/battery/*.patch
git am /path/to/omarchy-iphone6s/patches/bluetooth/*.patch
git am /path/to/omarchy-iphone6s/patches/fast-reload/*.patch
```

In the resulting `.config`, turn on: `CONFIG_MUX_CORE=y`, `CONFIG_MUX_SN2400`,
`CONFIG_BATTERY_BQ27XXX=y`, `CONFIG_BATTERY_BQ27XXX_HDQ_UART`, `CONFIG_SERIAL_DEV_BUS=y`,
`CONFIG_I2C_APPLE=y` (battery), and `CONFIG_UHID=y` (lets BLE/HOGP keyboards work; without it only
classic HID keyboards do). Then build it, pinning the release so module vermagic matches what the
image expects:

```sh
export BUILD=~/Work/hoolock-iphone5s/build/fast-reload   # one build dir, used for everything below
make O="$BUILD" LLVM=1 ARCH=arm64 KERNELRELEASE=7.3.0-rc1-g6831bc701a6c olddefconfig
make O="$BUILD" LLVM=1 ARCH=arm64 KERNELRELEASE=7.3.0-rc1-g6831bc701a6c \
  Image.gz apple/s8000-n71.dtb apple/s8003-n71m.dtb \
  drivers/gpio/gpio-apple-pmic.ko drivers/mux/mux-sn2400.ko \
  drivers/power/supply/bq27xxx_battery_hdq_uart.ko
```

You'll point both `kit/boot.sh` (`BUILD=`) and the userland build (`KBUILD=`) at this same `$BUILD`
directory from here on, so the kernel, the dtbs and the three phone-driver modules all come from
one matching build.

## 2. First boot: DFU, checkm8, pongoOS, Linux

This first boot has to go through DFU. Once the phone is running a kernel with the fast-reload
patch (which you just built), every later kernel swap can use `kit/reload.sh` instead — no
buttons, no DFU (step 7).

**Enter DFU mode:**

1. Hold **Power + Home** together for about **8 seconds**, until the screen goes black.
2. **Release Power**, but **keep holding Home** for about **5 more seconds**.
3. The screen stays black (no Apple logo, no "connect to iTunes" screen) — that's DFU.

If you land in **recovery mode** instead (a "connect to a computer" screen), `palera1n` can drive
the phone from there back into DFU; you don't have to restart the button sequence by hand.

**Build the boot blob and send it**, from the repo root:

```sh
cd ~/Work/omarchy-iphone6s        # kit/boot.sh must be run from the repo root, not copied elsewhere
BUILD=~/Work/hoolock-iphone5s/build/fast-reload kit/boot.sh blob   # also records out/blob-dtbs/, needed by step 7
kit/boot.sh pongo    # checkm8 + load pongoOS (asks for sudo)
kit/boot.sh linux    # send the blob to pongoOS and boot it
```

Notes on `kit/boot.sh linux`:

- Watch the phone's screen. Once you see it visibly start **m1n1**, you can **Ctrl+C** the
  `pongoterm` session on the laptop — the phone keeps booting on its own.
- Seeing `LIBUSB_ERROR_IO` printed at the end is **normal**: it's the USB connection dropping as
  the phone re-enumerates as its Linux USB gadget, not a failure.

**Confirm it's alive:**

```sh
telnet 172.16.42.1        # root shell, no auth (busybox telnetd) — fine only while tethered
# or: kit/boot.sh shell   # USB serial (autologin root)
```

## 3. Build the userland

```sh
cd ~/Work/omarchy-iphone6s
KBUILD=~/Work/hoolock-iphone5s/build/fast-reload tools/userland/build-rootfs.sh
tools/userland/mk-initramfs.sh               # wraps the stock ramdisk so it can switch_root into that rootfs
```

This bootstraps Arch Linux ARM rootlessly (`unshare --user`, qemu-aarch64 for scriptlets): a few
minutes, about 270 MB of packages the first time. It installs systemd, Hyprland, the Omarchy Phone
shell and Phone app, BlueZ, PipeWire, and copies in the three driver modules from `$KBUILD`
built in step 1 (it will refuse if they're missing or don't match the kernel release).

## 4. Boot the patched ramdisk

```sh
INITRAMFS=~/Work/hoolock-iphone5s/build/userland/initramfs-userland.gz \
  BUILD=~/Work/hoolock-iphone5s/build/fast-reload kit/boot.sh blob
kit/boot.sh pongo && kit/boot.sh linux
```

Same DFU sequence and same `LIBUSB_ERROR_IO`-is-normal caveat as step 2. Use the **patched**
`initramfs-userland.gz` here, not the stock HoolockLinux ramdisk — its `/init` knows how to
`switch_root` into the userland once you push it (see [`docs/userland.md`](userland.md)).

## 5. Push the userland and hand over

```sh
tools/userland/push-rootfs.sh --go
```

This streams `rootfs.tar.xz` (~205 MB) over the USB network into a tmpfs on the phone, unpacks it,
verifies the checksum, sets the phone's clock from the laptop, and switches PID 1 from the
ramdisk's `/init` to `systemd`. The telnet session drops a few seconds in — that's `switch_root`
tearing down the ramdisk, not a crash. `--go` then waits for SSH and prints
`systemctl is-system-running`.

The RTC reads a stale date (around 2021) on every cold boot; there's no network time source on
the phone (no Wi-Fi), so the laptop's clock is what you get, at every deploy. This only sets the
kernel's clock — the PMIC hardware RTC still holds the old offset, and writing that back is a
manual, deliberate step this repo leaves to you (`docs/drivers/foundation.md`): once you're in
SSH, `sudo hwclock -w --utc` persists it (the userland is kept in UTC throughout).

If you have a Bluetooth keyboard already paired from a previous session, `push-rootfs.sh` also
seeds its pairing back in automatically — see "A keyboard" below.

**Log in:**

```sh
ssh omarchy@172.16.42.1     # password: omarchy (also has passwordless sudo)
ssh root@172.16.42.1        # key auth only (your laptop's ~/.ssh/*.pub is baked into authorized_keys)
```

The `omarchy`/`omarchy` credentials and the unauthenticated root telnet from step 2 are **dev
defaults, fine only while the phone is tethered to your laptop** over the private
`172.16.42.0/24` USB link — there is no other network this reaches.

If SSH complains the host key for `172.16.42.1` changed, that's an old entry from a previous
build: `ssh-keygen -R 172.16.42.1`.

## 6. The shell starts itself

Hyprland and the Omarchy Phone shell start automatically as an `omarchy-phone-session` user unit
once you're in — seatd hands out the seat, no manual launch needed:

```sh
ssh omarchy@172.16.42.1 'systemctl --user status omarchy-phone-session; tail -50 ~/.cache/hyprland.log; pgrep -a qs'
```

Screenshot it (the phone has no other display output to check against):

```sh
ssh omarchy@172.16.42.1 'WAYLAND_DISPLAY=wayland-1 grim /tmp/s.png' && scp omarchy@172.16.42.1:/tmp/s.png .
```

Useful controls:

```sh
ssh omarchy@172.16.42.1 systemctl --user restart omarchy-phone-session   # restart the shell
ssh omarchy@172.16.42.1 systemctl --user stop omarchy-phone-session      # stop it, then by hand:
ssh omarchy@172.16.42.1 phone-hyprland                                  # start Hyprland (+shell) yourself
ssh omarchy@172.16.42.1 pkill -x Hyprland                               # stop a hand-started one
ssh omarchy@172.16.42.1 PHONE_PLAIN=1 phone-hyprland                    # old foot-only session instead
```

`phone-hyprland` refuses to start a second Hyprland while one's already running. Once it's up, the
shell is what you drive from the Bluetooth keyboard in the next step — the on-screen surfaces
(home, shade, switcher, lock) all take keyboard input, not just touch, since the touchscreen
doesn't work here.

### Don't lock the screen

The lock screen's PIN pad checks the **user's login password** through PAM, and the default
password (`omarchy`) is not numeric — so once locked (short-press Power, or `ophone-ctl lock`),
there is currently no PIN you can type on the pad to unlock it. **Don't lock the phone** until
you've either set a numeric password for the `omarchy` user or built the image with one
(`USERPASS=` at build time).

If you do get locked out, it's recoverable over SSH, which the lock screen doesn't block:

```sh
ssh omarchy@172.16.42.1 systemctl --user restart omarchy-phone-session   # the shell starts unlocked
```

## 7. A Bluetooth keyboard, since there's no touch

Pair it **from the phone**, not the laptop — the keyboard has to be paired to the phone's own
Bluetooth chip:

```sh
ssh omarchy@172.16.42.1 bluetoothctl
# agent on; default-agent; scan on; pair <mac>; trust <mac>; connect <mac>
```

Both classic HID and BLE (HOGP) keyboards work here (BLE needs `CONFIG_UHID=y`, which you enabled
in step 1). A BLE keyboard was seen pairing in about 3 seconds with this kernel.

A few things that only show up in real use:

- **It reconnects on its own on the next keypress** once paired — you don't need to put it back
  into pairing mode for a later session. Doing so anyway just makes the phone forget the existing
  pairing and forces you to redo it.
- **Pairings don't survive a plain reboot or reload by themselves** (the whole root is RAM and
  disappears). To keep a keyboard paired across sessions, capture `/var/lib/bluetooth` on the
  phone into a tarball and point `push-rootfs.sh` at it next time: `BT_KEYS_TGZ` (a tarball whose
  members look like `bluetooth/...`) and `BT_ADDR_FILE` (one `XX:XX:XX:XX:XX:XX` line, the
  phone's Bluetooth public address) are seeded back in automatically on every push, before the
  handover. Both stay out of git (`~/Work/hoolock-iphone5s/firmware/` by convention); pass
  `NO_BT_SEED=1` to skip seeding.
- **A USB hub port can stop responding after a failed reload or a bad kexec.** If the phone (or
  the keyboard's dongle, if you're using one instead of the phone's own radio for something else)
  goes quiet after a `kit/reload.sh` attempt, try a different port on the hub before assuming the
  phone itself is stuck.

## 8. Faster iteration: reload without DFU (optional)

Now that the phone is running a kernel with the fast-reload patch, later kernel changes can go
straight to the phone with a kexec instead of another DFU cycle:

```sh
kit/reload.sh          # push Image + DTB + ramdisk, kexec, wait for telnet back: ~30-60 s
kit/reload.sh -n       # dry run first, if you want to see what it would carry over
```

A reload is a reboot as far as the phone's running state goes: you land back in the ramdisk, with
the userland gone, so redo steps 5 onward afterwards (`push-rootfs.sh --go`). See
[`docs/fast-reload.md`](fast-reload.md) for the full mechanism and its failure modes.

## Charging

The SN2400 charger is an undocumented Apple/TI part; Linux has no driver for it and can't program
it to charge the battery. The documented expectation is idle drain of roughly 80 mA (about 15
hours per charge) with nothing else driving the current budget. In practice, what decides whether
the phone gains or loses charge over a session is the **hub**, not the OS: a hub with its own
power supply supplies roughly +300 mA more than a bus-powered one, which in testing has been
enough to net-charge rather than drain. Don't rely on this being controllable or precise — it's
incidental to how much current the hub happens to make available at the port, not something this
repo's software manages.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Phone drains, or doesn't gain charge, while tethered | Bus-powered hub port; Linux doesn't drive the charger either way. Use a hub with its own power supply. |
| A hub port stops passing data after a bad reload | Try a different port on the hub before troubleshooting the phone. |
| Stuck in recovery mode instead of DFU | Let `palera1n` drive it back to DFU rather than redoing the button sequence by hand. |
| `kit/boot.sh linux` prints `LIBUSB_ERROR_IO` at the end | Normal — the phone re-enumerating as its Linux USB gadget, not a failure. |
| `tools/userland/build-rootfs.sh` dies with a missing/mismatched `.ko` | `KBUILD` isn't pointing at a kernel build with the three driver modules, or its `KERNELRELEASE` doesn't match. Revisit step 1. |
| `telnet 172.16.42.1` / SSH doesn't come up after a boot | Try `kit/boot.sh shell` (USB serial, autologin root); check `dmesg` on the phone. |
| SSH says the host key for `172.16.42.1` changed | Old entry from a previous build: `ssh-keygen -R 172.16.42.1`. |
| `push-rootfs.sh` reports the unpack failed / md5 mismatch | Rerun it; if it repeats, recover through DFU rather than retrying on a half-switched root. |
| Phone doesn't answer for 60+ seconds at any point | Per `testkit/TESTING-RULES.md` rule 8: stop, don't retry in a loop — it has likely panicked or hung. Recover through DFU: `kit/boot.sh pongo && kit/boot.sh linux`. |
| Locked yourself out of the lock screen | See "Don't lock the screen" above — recover over SSH: `systemctl --user restart omarchy-phone-session`. |
| Bluetooth keyboard doesn't do anything | It must be paired *from the phone*, not the laptop; confirm with `bluetoothctl` over SSH/telnet on the phone. |
| Keyboard pairing didn't survive a reload/reboot | Expected — the root is RAM-only. Seed it back with `BT_KEYS_TGZ`/`BT_ADDR_FILE` on the next `push-rootfs.sh` (see step 7). |
| Clock is wrong inside the userland | `push-rootfs.sh` sets the kernel clock automatically on every push; it doesn't persist to the PMIC. Run `sudo hwclock -w --utc` once you're in SSH. |

## Safety notes

- **Never write to the phone's NVMe/NAND.** Nothing in this guide does, and storage access from
  Linux is read-only-or-nothing by design (`testkit/TESTING-RULES.md` rule 6) — it holds iOS.
- The dev credentials (`omarchy`/`omarchy`, unauthenticated root telnet) are acceptable only
  because the only network they're reachable on is the private USB link to your laptop
  (`172.16.42.0/24`). Don't bridge or forward that network anywhere else.
- This is one physical phone with no way to recover itself: if it stops responding, stop and
  recover through DFU rather than retrying blind.

---

New here and want the bigger picture first? Start with the [README](../README.md); for driver
internals see [`docs/drivers/`](drivers/), for the full userland build/session detail see
[`docs/userland.md`](userland.md), and for the kexec mechanics behind step 8 see
[`docs/fast-reload.md`](fast-reload.md).
