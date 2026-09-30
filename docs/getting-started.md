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

| Works, verified on the phone | In progress / doesn't work reliably | Not yet / out of scope |
|---|---|---|
| Framebuffer display (750x1334, simpledrm), Hyprland 0.56 + software rendering (llvmpipe, `glFinish()` shim removes the earlier input lag), foot terminal | **Touch** — concluded 2026-09-30: coarse/quadrant position works (finger detection, IRQ and decode plumbing confirmed live); full-resolution blocked on firmware-mode RE — parked. See [`docs/drivers/touch.md`](drivers/touch.md). The screen is still display-only, not usable for the GUI | **Wi-Fi, storage and the cellular modem** — all three sit behind the A9's PCIe block, which is shelved; no network but the USB link to the laptop, and the root filesystem lives in tmpfs |
| The **Omarchy Phone shell** (QuickShell) and the Phone app, driving everything from a keyboard, with a per-device numeric lock-screen PIN | **Charging** — the SN2400 charges on its own when the supply is strong enough, but doesn't sustain reliably under Linux (suspected charger watchdog, unconfirmed) and Linux can't configure it at all (no public register map). See "Charging" below. | Audio, camera, sensors behind the AOP coprocessor, NFC, Secure Enclave — out of scope |
| Bluetooth (BCM4350): pairing a BLE keyboard over `uhid` (adv-report-type quirk fix) | **Idle/display power-off** — `hypridle` blanks DPMS + the backlight on idle; merged, not yet re-verified on this phone | |
| Battery gauge (bq27540 over HDQ): percent, voltage, current, temperature, health, `charge_now` (fixed to read Remaining Capacity) | | |
| All 5 buttons, backlight, PMIC RTC, watchdog, both CPU cores, 2 GB RAM, USB networking (`172.16.42.1` <-> `.2`) + a root USB telnet shell, fast kernel reload (kexec, no DFU) | | |

Tooling, not itself a phone-driver finding: a post-boot self-test harness
(`testkit/selftest.sh`, see [`docs/selftest.md`](selftest.md)) drives the phone through
`testkit/phone.sh` to check every driver above in one pass, and a patch-series CI
([`docs/CI.md`](CI.md)) `git am`s + build-checks every series in `patches/` on every push
(build-only, never touches the phone).

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
  `M1N1`, `BIN`, `INITRAMFS`, `OUT`). You'll also want a 16K-page kernel `.config` to start from
  (`CONFIG_ARM64_16K_PAGES`) — copy in a working one before configuring in step 1, don't start from
  an empty `O=` directory.
- A clone of [Omarchy-Phone](https://github.com/modpunk/Omarchy-Phone) with the `shell` and
  `phone-app` branches fetched. `build-rootfs.sh` takes them from `PHONE_SRC` (default
  `~/Work/omarchy-phone`) at fixed pinned commits (`SHELL_REV`/`APP_REV`) — this is what actually
  puts the shell from step 5 into the image, so it has to be there before you build the userland.
- The Broadcom Bluetooth firmware (`.hcd`) for this phone, extracted per the "Firmware" section of
  [`docs/drivers/bluetooth.md`](drivers/bluetooth.md) and placed where `FW_DIR` looks for it
  (default `~/Work/hoolock-iphone5s/firmware/brcm/`). Without it, Bluetooth (step 6) never comes up.
- For the RAM userland: `qemu-user-static` with the binfmt entry, a `/etc/subuid` range and
  unprivileged user namespaces enabled (common on a normal desktop distro). No root and no Docker
  needed — `tools/userland/build-rootfs.sh` re-execs itself into its own user namespace.
- A classic *or* BLE Bluetooth keyboard, for step 6.

Read `testkit/TESTING-RULES.md` before you improvise anything beyond these steps — the phone is
one physical device (13 rules as of this writing, including rule 13's approved power-chip write
list), and rule 8 in particular: if it stops answering for 60 seconds, stop and recover through
DFU rather than retrying in a loop.

## 1. Build a kernel with the phone's drivers

The RAM userland *requires* this — `tools/userland/build-rootfs.sh` refuses to build without a
kernel tree that already has the out-of-tree driver modules (`gpio-apple-pmic`, `mux-sn2400`,
`bq27xxx_battery_hdq_uart`) built and matching the running release. There's no plain-mainline
shortcut; you need the same combined kernel this repo tests against: `foundation`, `battery`,
`battery-fix` (the `charge_now` fix, on top of `battery`), `bluetooth` (through patch 0007, the
LE-advertising fix that makes BLE keyboards pair) and `fast-reload`, all applied to one
`$HOOLOCK/linux` tree.

Get the patches following `docs/CONTRIBUTING.md`'s recipe (`git am` onto commit `6831bc701`), in
dependency order — `battery` and `bluetooth` both depend on `foundation`, and `battery-fix`
depends on `battery`:

```sh
cd $HOOLOCK/linux && git checkout 6831bc701
git am /path/to/omarchy-iphone6s/patches/foundation/*.patch
git am /path/to/omarchy-iphone6s/patches/battery/*.patch
git am /path/to/omarchy-iphone6s/patches/battery-fix/*.patch
git am /path/to/omarchy-iphone6s/patches/bluetooth/*.patch
git am /path/to/omarchy-iphone6s/patches/fast-reload/*.patch
```

**Known gap:** `docs/CI.md` says `battery` and `bluetooth` both patch the shared `s800x-6s`
device-tree source and conflict with each other when CI applies each series in isolation on top
of `foundation` alone — but the userland image needs modules from both series, which is what the
recipe above stacks into one tree. Whether that stacking actually hits the same conflict CI
reports (or the two series only conflict when applied standalone, not on top of each other) isn't
verified in either doc; if `git am` fails here, that's the open question to resolve, not
necessarily a mistake in your command.

(If `$HOOLOCK/linux` is the same tree you use for live driver testing elsewhere, do this in a
worktree branch instead — `testkit/TESTING-RULES.md` rules 1–2 keep that tree read-only. This
walkthrough assumes a plain clone dedicated to the build.)

Seed a working 16K-page `.config` into your build directory before configuring — starting
`olddefconfig` from empty gives you a 4K-page kernel that won't run the ALARM userland. Then turn
on, in that `.config`: `CONFIG_MUX_CORE=y`, `CONFIG_MUX_SN2400`, `CONFIG_BATTERY_BQ27XXX=y`,
`CONFIG_BATTERY_BQ27XXX_HDQ_UART`, `CONFIG_SERIAL_DEV_BUS=y`, `CONFIG_I2C_APPLE=y` (battery), and
`CONFIG_UHID=y` (lets BLE/HOGP keyboards work; without it only classic HID keyboards do). Build it,
pinning the release so module vermagic matches what the image expects:

```sh
export BUILD=~/Work/hoolock-iphone5s/build/fast-reload   # one build dir, used for everything below
cp /path/to/a/working/16k-page.config "$BUILD/.config"   # e.g. config_16k, kept alongside $HOOLOCK
make O="$BUILD" LLVM=1 ARCH=arm64 KERNELRELEASE=7.3.0-rc1-g6831bc701a6c olddefconfig
make O="$BUILD" LLVM=1 ARCH=arm64 KERNELRELEASE=7.3.0-rc1-g6831bc701a6c \
  Image.gz apple/s8000-n71.dtb apple/s8003-n71m.dtb \
  drivers/gpio/gpio-apple-pmic.ko drivers/mux/mux-sn2400.ko \
  drivers/power/supply/bq27xxx_battery_hdq_uart.ko
```

You'll point both `kit/boot.sh` (`BUILD=`) and the userland build (`KBUILD=`) at this same `$BUILD`
directory from here on, so the kernel, the dtbs and the three phone-driver modules all come from
one matching build.

## 2. Build the userland

```sh
cd ~/Work/omarchy-iphone6s
KBUILD=~/Work/hoolock-iphone5s/build/fast-reload tools/userland/build-rootfs.sh
tools/userland/mk-initramfs.sh               # wraps the stock ramdisk so it can switch_root into that rootfs
```

This bootstraps Arch Linux ARM rootlessly (`unshare --user`, qemu-aarch64 for scriptlets): a few
minutes, about 270 MB of packages the first time. It installs systemd, Hyprland, the Omarchy Phone
shell and Phone app (from `PHONE_SRC`, see "What you need"), BlueZ, PipeWire, the Bluetooth
firmware (from `FW_DIR`), and copies in the three driver modules from `$KBUILD` built in step 1 —
it refuses to continue if any of these are missing or don't match the kernel release.

## 3. First and only DFU boot: checkm8, pongoOS, Linux

Everything from here on can be pushed to the phone without touching it again: this is the one
button-and-DFU boot you need. Once the phone is running a kernel with the fast-reload patch (which
you just built), later kernel swaps can use `kit/reload.sh` instead — no buttons, no DFU (step 7).

**Enter DFU mode:**

1. Hold **Power + Home** together for about **8 seconds**, until the screen goes black.
2. **Release Power**, but **keep holding Home** for about **5 more seconds**.
3. The screen stays black (no Apple logo, no "connect to iTunes" screen) — that's DFU.

If you land in **recovery mode** instead (a "connect to a computer" screen), `palera1n` can drive
the phone from there back into DFU; you don't have to restart the button sequence by hand.

**Build the boot blob and send it.** Run this from inside the directory that holds the `boot.sh`
you're invoking — its path handling assumes that, and copying it elsewhere or `cd`-ing away from
it before running it breaks the relative paths it builds from:

```sh
cd ~/Work/omarchy-iphone6s
INITRAMFS=~/Work/hoolock-iphone5s/build/userland/initramfs-userland.gz \
  BUILD=~/Work/hoolock-iphone5s/build/fast-reload kit/boot.sh blob   # also records out/blob-dtbs/, needed by step 7
kit/boot.sh pongo    # checkm8 + load pongoOS (asks for sudo)
kit/boot.sh linux    # send the blob to pongoOS and boot it
```

Use the **patched** `initramfs-userland.gz` from step 2 here, not the stock HoolockLinux ramdisk —
its `/init` knows how to `switch_root` into the userland once you push it, and otherwise behaves
exactly like the stock one (see [`docs/userland.md`](userland.md)).

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

Optionally, `testkit/selftest.sh` prints a PASS/FAIL table of every driver known to work on this
boot ([`docs/selftest.md`](selftest.md)) — a good sanity check before moving on.

## 4. Push the userland and hand over

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

The `omarchy`/`omarchy` credentials and the unauthenticated root telnet are **dev
defaults, fine only while the phone is tethered to your laptop** over the private
`172.16.42.0/24` USB link — there is no other network this reaches.

If SSH complains the host key for `172.16.42.1` changed, that's an old entry from a previous
build: `ssh-keygen -R 172.16.42.1`.

## 5. The shell starts itself

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

### The lock screen PIN

The lock screen's PIN is now its own secret (`ophone-pin`, PAM'd through `/etc/pam.d/ophone-lock`),
independent of the `omarchy` account/SSH/sudo password — see
[`docs/userland.md`](userland.md#lock-screen-pin-provisioning) for the full mechanism. A freshly
built image has **no PIN configured** and boots (and restarts) unlocked; once you provision one
(`push-rootfs.sh`'s `PHONE_PIN_FILE`/`PROMPT_PIN`, or `ssh omarchy@172.16.42.1 sudo ophone-pin
set` any time after boot) the shell boots and restarts locked from then on, including a plain
`systemctl --user restart omarchy-phone-session`. The easiest ways to trigger a lock by accident
from a keyboard are `SUPER+L` and `SUPER+Esc` (the power key — a tap locks and blanks the screen;
a long press opens the power menu, which also has a Lock item).

If you do get locked out (or forget the PIN), it's recoverable over SSH, which the lock screen
doesn't block — root can set a new PIN without knowing the old one:

```sh
ssh omarchy@172.16.42.1 sudo ophone-pin set
```

## 6. A Bluetooth keyboard, since there's no touch

Pair it **from the phone**, not the laptop — the keyboard has to be paired to the phone's own
Bluetooth chip:

```sh
ssh -t omarchy@172.16.42.1 bluetoothctl
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
- **A USB hub port can stop passing data after a failed reload or a bad kexec.** If the phone goes
  quiet after a `kit/reload.sh` attempt, try a different port on the hub before assuming the phone
  itself is stuck.

## 7. Faster iteration: reload without DFU (optional)

Now that the phone is running a kernel with the fast-reload patch, later kernel changes can go
straight to the phone with a kexec instead of another DFU cycle:

```sh
kit/reload.sh          # push Image + DTB + ramdisk, kexec, wait for telnet back: ~30-60 s
kit/reload.sh -n       # dry run first, if you want to see what it would carry over
```

A reload is a reboot as far as the phone's running state goes: you land back in the ramdisk, with
the userland gone, so redo steps 4 onward afterwards (`push-rootfs.sh --go`).

**Do this only while the phone is still in the ramdisk stage, before `push-rootfs.sh --go`.** A
reload started from inside the Arch userland previously lost the USB connection (no
re-enumeration) and needed a full DFU recovery to get back; the kernel + `kit` fix for this has
since merged to `main` ([#13](https://github.com/modpunk/Omarchy-iPhone6s/pull/13)), but per
[`docs/fast-reload.md`](fast-reload.md#reloading-from-the-arch-userland) it has not yet been
re-verified with an actual kexec from inside the running userland on this phone — treat a reload
from inside the userland session as a DFU trip waiting to happen until that's confirmed. See
`docs/fast-reload.md` for the full mechanism and its other failure modes.

## Charging

Charging does **not** work reliably under Linux. The SN2400 charger is an undocumented Apple/TI
part with no public register map, so Linux can't program it — charge limits and source detection
aren't configurable, and charging (when it happens at all) is entirely autonomous in the charger
itself:

- On a **USB hub with its own power supply**, the gauge has been seen reporting
  `status=Charging` at roughly +300 mA (measured on the idle ramdisk; less under Hyprland), but
  this hasn't been shown to sustain to a full charge — a suspected SN2400 charge watchdog may cut
  it off (unconfirmed hypothesis, not a proven root cause). Don't rely on a session to charge the
  phone; check `cat /sys/class/power_supply/bq27540-0/capacity` and don't assume it's climbing.
- On an **unpowered hub or laptop port**, the cable only covers the phone's own load (net about
  -75 to -85 mA at idle, roughly 15 hours per charge), so the battery drains.
- Heavy work (unpacking the rootfs, full-speed rendering) can draw far more than the supply
  provides even in the charging case above.
- **Charge the phone in iOS between Linux sessions** rather than relying on charging under Linux.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Phone drains, or doesn't gain charge, while tethered | Bus-powered hub port; Linux doesn't drive the charger either way. A hub with its own power supply is more likely to gain charge, but charging doesn't reliably sustain under Linux even then (see "Charging") — charge in iOS between sessions if the battery is low. |
| A hub port stops passing data after a bad reload | Try a different port on the hub before troubleshooting the phone. |
| Stuck in recovery mode instead of DFU | Let `palera1n` drive it back to DFU rather than redoing the button sequence by hand. |
| `kit/boot.sh linux` prints `LIBUSB_ERROR_IO` at the end | Normal — the phone re-enumerating as its Linux USB gadget, not a failure. |
| `tools/userland/build-rootfs.sh` dies with a missing/mismatched `.ko` | `KBUILD` isn't pointing at a kernel build with the three driver modules, or its `KERNELRELEASE` doesn't match. Revisit step 1. |
| `telnet 172.16.42.1` / SSH doesn't come up after a boot | Try `kit/boot.sh shell` (USB serial, autologin root); check `dmesg` on the phone. |
| SSH says the host key for `172.16.42.1` changed | Old entry from a previous build: `ssh-keygen -R 172.16.42.1`. |
| `push-rootfs.sh` reports the unpack failed / md5 mismatch | Rerun it; if it repeats, recover through DFU rather than retrying on a half-switched root. |
| Phone doesn't answer for 60+ seconds at any point | Per `testkit/TESTING-RULES.md` rule 8: stop, don't retry in a loop — it has likely panicked or hung. Recover through DFU: `kit/boot.sh pongo && kit/boot.sh linux`. |
| Locked yourself out of the lock screen / forgot the PIN | See "The lock screen PIN" above — recover over SSH: `ssh omarchy@172.16.42.1 sudo ophone-pin set`. |
| Bluetooth keyboard doesn't do anything | It must be paired *from the phone*, not the laptop; confirm with `bluetoothctl` over SSH/telnet on the phone. |
| Keyboard pairing didn't survive a reload/reboot | Expected — the root is RAM-only. Seed it back with `BT_KEYS_TGZ`/`BT_ADDR_FILE` on the next `push-rootfs.sh` (see step 6). |
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
[`docs/userland.md`](userland.md), and for the kexec mechanics behind step 7 see
[`docs/fast-reload.md`](fast-reload.md).
