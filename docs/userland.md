# RAM userland (Arch Linux ARM)

A full Linux userland that the iPhone 6s runs from RAM: systemd, a getty on the framebuffer,
sshd on the USB network, iwd, BlueZ, PipeWire, seatd, Mesa llvmpipe, Hyprland 0.56 and the
foot terminal, plus the Omarchy Phone shell (QuickShell) and the Phone app (GTK4 + libadwaita).
It's the base for Omarchy Phone (Arch Linux ARM + Hyprland).

**Status:** builds and passes every laptop-side check, and the PID 1 hand-over passes a
laptop rehearsal. It runs on the phone: on 2026-09-29 Hyprland 0.56.2 drew foot on the
simpledrm panel with llvmpipe (see "Hyprland on simpledrm"). The phone shell and Phone app were
added the same day and pass the laptop checks; they haven't run on the phone yet (see
"Omarchy Phone shell and Phone app").

## How it boots

```
checkm8 -> pongoOS -> m1n1 -> Linux + initramfs-userland.gz  (HoolockLinux ramdisk, patched /init)
   telnet 172.16.42.1 works as before
laptop: push-rootfs.sh  ->  nc | unxz | tar  into a tmpfs at /newroot   (streamed, ~205 MB over USB)
phone:  stage2.sh go    ->  touches /run/userland-go
PID 1 (/init idle loop) ->  kill ramdisk processes, move /dev /proc /sys /run,
                            switch_root /newroot /usr/lib/systemd/systemd
   ssh omarchy@172.16.42.1, telnet (phone.sh) and USB serial all work again
```

`switch_root` has to run as PID 1, and PID 1 on the stock ramdisk sits in
`while true; do sleep 255; done`, so a script started over telnet can't switch roots.
`mk-initramfs.sh` builds `initramfs-userland.gz`: the stock ramdisk, unchanged, plus a second
cpio archive that overrides `/init` with a copy whose idle loop runs `/userland-switch.sh` when
`/run/userland-go` exists. If that flag never appears, the ramdisk behaves exactly like the stock
one. If the new root is incomplete, the switch script logs to kmsg and returns, so PID 1 keeps
idling instead of exiting (an exit would panic the kernel).

The kernel has no SQUASHFS, EROFS or OVERLAY_FS, so the root must be a plain tarball unpacked
into tmpfs. The ramdisk's busybox has `unxz` but no zstd, so the tarball is `.tar.xz`
(`--check=crc32`, `--numeric-owner`).

## Artifacts

Everything lives under `~/Work/hoolock-iphone5s/build/userland/`. None of it goes in git: it
contains the Broadcom BT firmware, your SSH public keys and the sshd host keys.

| file | size | what |
|---|---|---|
| `rootfs.tar.xz` | 205 MiB (214,606,316 B) | the userland; md5 in `rootfs.tar.xz.md5`. Without the phone shell and app it was 147 MiB |
| unpacked | 1099 MiB | in tmpfs on the phone (`SIZE=1400m` cap); 353 packages, list in `rootfs.packages.txt`. The phone shell and app added 311 MiB (was 788 MiB, 269 packages) |
| `initramfs-userland.gz` | 2.6 MiB | stock HoolockLinux ramdisk + patched `/init` + `userland-switch.sh` |
| `check-report.txt` | | output of `check-rootfs.sh` (16K scan, missing libraries, smoke tests) |
| `root/` | | the unpacked tree, owned by subuids (see "Rebuild") |
| `ssh-hostkeys/` | | sshd host keys, reused on every rebuild so the fingerprint stays the same |

## Commands for the phone session

Rules from `testkit/TESTING-RULES.md` apply. Steps 2 to 4 hold the shared phone lock.

1. **Boot the patched ramdisk** (this is a normal reboot: DFU buttons, then sudo). BOOTARGS don't
   change:
   ```sh
   cd ~/Work/omarchy-iphone6s
   INITRAMFS=~/Work/hoolock-iphone5s/build/userland/initramfs-userland.gz kit/boot.sh blob
   kit/boot.sh pongo && kit/boot.sh linux
   ```
   `kit/boot.sh` does the same thing as `~/Work/hoolock-iphone5s/boot.sh`, except that it also
   takes path overrides. That boot.sh hard-codes the stock initramfs. If you boot a different
   kernel build, add `KSRC=` (the tree with `arch/arm64/boot/Image.gz` and the dtbs).
   Then bring up whatever the session normally loads (BT modules, firmware push, overlays).
   Everything under `/lib/firmware` and every small file in `/tmp/6s` gets copied into the new
   root (`/usr/lib/firmware`, `/var/lib/6s-testkit/`), because `switch_root` deletes the ramdisk.
2. **Set the clock** (the RTC reads 2021; the kernel clock survives the switch):
   `~/Work/hoolock-iphone5s/testkit/phone.sh settime`
3. **Push and unpack** (about 205 MB over NCM, then the phone's `unxz`; this took 45 s under
   qemu on the laptop):
   ```sh
   ~/Work/omarchy-iphone6s/tools/userland/push-rootfs.sh
   ```
   It pushes `stage2.sh`, mounts `/newroot`, streams the tarball, then checks the tar exit code
   and the stream md5. It prints `unpacked OK`.
4. **Hand over:**
   ```sh
   ~/Work/hoolock-iphone5s/testkit/phone.sh lock 'sh /tmp/6s/stage2.sh go'
   ```
   The telnet session drops about 3 s later. You can do steps 3 and 4 in one go with
   `push-rootfs.sh --go`, which also waits for sshd and prints `systemctl is-system-running`.
5. **Log in:**
   ```sh
   ssh -o StrictHostKeyChecking=accept-new root@172.16.42.1      # key auth (laptop ~/.ssh/*.pub baked in)
   ssh omarchy@172.16.42.1                                        # key, or password "omarchy"
   ~/Work/hoolock-iphone5s/testkit/phone.sh ping                  # still works: phone-telnetd
   kit/boot.sh shell                                              # USB serial, autologin root
   ```
6. **Checks:**
   ```sh
   ssh root@172.16.42.1 'systemctl --failed; journalctl -b -p warning --no-pager | tail -40;
     free -m; swapon; bluetoothctl list; ls -l /dev/dri'
   ssh omarchy@172.16.42.1 'systemctl --user --failed; wpctl status | head'
   ```
   The host key is the same on every build (`ssh-hostkeys/`). If ssh says the key for
   172.16.42.1 changed (an old entry from other tests), run `ssh-keygen -R 172.16.42.1`.
7. **Hyprland + the phone shell** (start it over SSH; seatd hands out the seat):
   ```sh
   ssh omarchy@172.16.42.1 phone-hyprland                  # log: ~/.cache/hyprland.log
   ssh omarchy@172.16.42.1 'tail -50 ~/.cache/hyprland.log; pgrep -a qs'
   ssh omarchy@172.16.42.1 pkill -x Hyprland               # stop (qs exits with it)
   ssh omarchy@172.16.42.1 PHONE_PLAIN=1 phone-hyprland    # the old foot-only session instead
   ```
   Screenshot (Hyprland's socket dir is the newest one under `/run/user/1000/hypr`):
   ```sh
   ssh omarchy@172.16.42.1 'WAYLAND_DISPLAY=wayland-1 grim /tmp/s.png' && scp omarchy@172.16.42.1:/tmp/s.png .
   ```

**No reboot yet?** `stage2.sh nsboot` is an **experimental** path for the stock ramdisk. It boots
systemd as PID 1 of a new pid and mount namespace, the same way a container runs it. It stops
the ramdisk's mdev, unudhcpd and gettys, and keeps the ramdisk telnetd as a fallback (the rootfs
copy of `phone-telnetd` is masked). `systemctl poweroff` inside it only ends the namespace. It
hasn't been rehearsed on the laptop, so use `go` after the reboot when you can.

**If it goes wrong:** if sshd doesn't come up, try `kit/boot.sh shell` (serial-getty on ttyGS0,
autologin root) and `phone.sh ping` (phone-telnetd). Boot messages go to the framebuffer
(`console=tty0`). If PID 1 refused the switch, the ramdisk keeps running: check
`dmesg | grep userland`.

## What's in it, and why

| need | choice | notes |
|---|---|---|
| distro | Arch Linux ARM aarch64 (core/extra/alarm, 2026-09-29) | matches Omarchy. Hyprland 0.56.2 is the same version as the laptop, so it uses the Lua config |
| init | systemd 262 | the kernel config has everything it needs (see "Kernel asks") |
| console | `getty@tty1` on simpledrm fbcon, `/etc/issue` shows the ssh address | plus `serial-getty@ttyGS0` with autologin root |
| USB network | systemd-networkd `10-usb-gadget.network` | `172.16.42.1/24` (same address as the ramdisk, `KeepConfiguration=yes`), DHCP server hands out `.2` (replaces unudhcpd). `99-default.link` is masked so `usb0` keeps its name |
| SSH | openssh; `PermitRootLogin prohibit-password`, password auth on | the laptop's `~/.ssh/*.pub` goes into root's and omarchy's `authorized_keys` |
| testkit | `phone-telnetd.service`: busybox telnetd, root, bound to 172.16.42.1:23 | keeps `phone.sh`/`phone.py` working. Dev only: `systemctl disable --now phone-telnetd` |
| Wi-Fi | iwd 3.12 (what Omarchy uses; NetworkManager would add ~30 MB of deps) | enabled, but a `ConditionPathExistsGlob=/sys/class/ieee80211/*` drop-in keeps it idle until a Wi-Fi driver exists |
| Bluetooth | bluez 5.87 + bluez-utils, `bluetooth.service` | the `.hcd` from `firmware/brcm/` is installed as `brcm/BCM.apple,n71.hcd` and `BCM4350C5.apple,n71.hcd` |
| audio | pipewire 1.6.9, wireplumber, pipewire-pulse (user units, enabled globally) | the kernel has no ALSA (CONFIG_SND off). This is for BT audio later |
| seat | seatd (`seat` group), plus systemd-logind | `phone-hyprland` sets `LIBSEAT_BACKEND=seatd`, which works from an SSH session |
| graphics | mesa 26.2.3 (llvmpipe, `kms_swrast_dri.so` and `dri_gbm.so` present), llvm-libs 22 | simpledrm has no render node; see "Hyprland on simpledrm" |
| compositor | hyprland 0.56.2 + libei (the binary links `libeis.so.1`, but ALARM only pulls it in through xorg-xwayland) | Xwayland and hyprland-guiutils are left out (`assume-installed.txt`) |
| terminal | foot 1.28 | renders on the CPU with pixman, so it's cheap on llvmpipe. Alacritty/Ghostty would render through GL on llvmpipe |
| font | ttf-jetbrains-mono, plus a subset of JetBrainsMono Nerd Font and Noto Sans | the shell names both families. The subset (Nerd Font Regular/Bold, Noto Sans Light/Regular/Medium/Bold, ~10 MB) is extracted from the cached 232 MB + 107 MB packages into `/usr/share/fonts/omarchy-phone/`, not pacman-tracked |
| phone shell | quickshell 0.3.1 (Qt 6), wtype, brightnessctl, upower, libnotify | see "Omarchy Phone shell and Phone app" |
| phone app | gtk4, libadwaita, python-gobject (python 3) | `GSK_RENDERER=cairo` in the session. Icons: adwaita-icon-theme (Yaru isn't in ALARM) |
| memory | zram-generator: `zram0` = min(RAM/2, 1 GiB), zstd | tmpfs pages can swap out to zram, so cold parts of the rootfs stay compressed |
| user | `omarchy` / `omarchy`, groups wheel seat video input audio render, passwordless sudo, lingering | root password locked. Linger keeps `/run/user/1000` and the PipeWire user units alive after the SSH command that started Hyprland exits |
| misc | `LANG=C.UTF-8` (built into glibc, no locale-gen), UTC, volatile journal (48 MB), fixed machine-id, `/usr/lib/clock-epoch` | firstboot and networkd-wait-online are masked |

Removed to save space: man, doc, info and gtk-doc pages, translations, `/usr/include`, `*.a`,
gir XML, `libteflon`, the default Hyprland wallpapers, Python's test suite, IDLE, Tk and `-O`
bytecode, Qt's mkspecs/metatypes/cmake. That takes the 1.6 GB install down to 1099 MiB.
The phone shell and app cost 311 MiB of it: Python 61 MiB, Qt 6 about 100 MiB (`/usr/lib/qt6` 50
plus the libraries), GTK 4 + libadwaita about 25 MiB, icons 23 MiB, GStreamer (linked by GTK 4)
13 MiB, fonts 8 MiB. binutils (51 MB, pulled in only by makepkg's dropins) and the gcc sanitizer runtimes are
never installed. The biggest items left are
libLLVM (161 MB), libgallium (52 MB) and ICU data (32 MB).

RAM: with the plain image, Hyprland and two foot windows left 562 MB available (see "Hyprland on
simpledrm"). The shell and app add 311 MiB of tmpfs, so expect roughly 250 MB available before
QuickShell and the Phone app start. zram lets cold tmpfs pages compress, and a compressed
read-only root (squashfs/erofs, see "Kernel asks") would give back most of the 1.1 GB.

## 16K pages

The phone's kernel uses 16K pages (`CONFIG_ARM64_16K_PAGES`). Userspace breaks in two known ways:

1. **ELF segments aligned below 16K**: the kernel can't map them. `check-rootfs.sh` parses every
   aarch64 ELF in the root. **0 of 3045 have a PT_LOAD alignment below 0x4000** (ALARM links with
   64K max-page-size).
2. **Allocators that bake the page size in at build time**: jemalloc and tcmalloc. x86 Arch
   builds jemalloc with lg-page 12, which aborts on 16K pages with "Unsupported system page
   size". **ALARM's aarch64 jemalloc (5.4.0) is built for 64K pages and runs with 16K ones.**
   quickshell links it. `check-rootfs.sh` proves it under qemu with a test-only preload
   (`shim/pagesize16k.c`) that makes `sysconf(_SC_PAGESIZE)` return 16384: jemalloc and
   `qs --version` start. The control, 128 KiB, makes jemalloc refuse. gperftools (tcmalloc) is
   installed as a dependency of libjxl, but no binary in the image links it. The check reports
   every package that links either one.

qemu-user always runs the guest on the host's 4K pages, so the laptop smoke tests can't catch a
16K-only failure. The static scan above is the substitute, and the phone gives the real answer.
For the first run, check `journalctl -b | grep -i 'page size\|mmap\|SIGSEGV\|SIGBUS'` and
`coredumpctl list`.

Workarounds, if a package breaks on the device:
- jemalloc users, if an ALARM update ever drops the 64K build (the check's `@16K` lines turn
  into "Unsupported system page size"): rebuild jemalloc with `--with-lg-page=16` (the PKGBUILD
  change Asahi uses), or rebuild the app with its system allocator.
- Anything else that breaks: run the Alpine aarch64 build of that one tool from a musl chroot.
  `testkit/bluetooth/mk-alpine-bluez.sh` already builds such a chroot rootlessly with
  `apk.static`. No package needed this so far.

## Hyprland on simpledrm

simpledrm is KMS-only: there's no render node and no GPU (the PowerVR has no open driver). Mesa's
GBM takes its software path (`kms_swrast` + llvmpipe, dumb buffers on `card0`) and Hyprland
renders through EGL on GBM with it. Checked on the phone on 2026-09-29: Hyprland 0.56.2,
aquamarine 0.15.1, Mesa 26.2.3, 750x1334 at scale 2, foot drawn, the KMS plane scanning out
Hyprland's buffer (`/sys/kernel/debug/dri/0/state`: `allocated by = Hyprland`).

`phone-hyprland` sets `GBM_ALWAYS_SOFTWARE=1`, `GALLIUM_DRIVER=llvmpipe`,
`LIBGL_ALWAYS_SOFTWARE=1`, `AQ_DRM_DEVICES=/dev/dri/card0`, `AQ_NO_MODIFIERS=1`,
`LIBSEAT_BACKEND=seatd`, unsets `MESA_LOADER_DRIVER_OVERRIDE`, and preloads
`/usr/lib/phone-tk/aq-simpledrm.so` (`PHONE_AQ_SHIM` picks another copy).
`PHONE_NO_WATCHDOG=1` runs `Hyprland` directly instead of `start-hyprland`, and `--fg` runs it in
the foreground.

Two things were broken, and why:
- `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` (the first version of the launcher) made Hyprland
  abort with SIGABRT in `CHyprOpenGLImpl::initEGL`. The override loads `kms_swrast` as if it
  were a hardware driver. EGL on GBM then looks for a render node to pair with `card0`, finds
  none, and `eglInitialize` fails with `DRI2: failed to get compatible render device`.
  With `GBM_ALWAYS_SOFTWARE=1` instead, GBM opens `kms_swrast` as a software driver and EGL
  doesn't need a render node.
- aquamarine still tries to build its own EGL device-platform renderer on each GPU. Mesa lists
  only the software EGL device, which has no DRM file (`eglQueryDeviceStringEXT` returns
  `EGL_BAD_PARAMETER`), so `CDRMRenderer::attempt` fails. With a single GPU,
  `updateSecondaryRendererState` retries `initMgpu()` on every commit: it reopens the node,
  creates a new GBM device, fails again, and logs 7 lines per frame. aquamarine already skips
  this renderer for evdi (KMS with no EGL renderer). The shim (`tools/userland/shim/aq-simpledrm.c`,
  cross-built by `build-rootfs.sh` with host clang + lld) makes `drmGetVersion()` report
  `simpledrm` as `evdi`, only when libaquamarine calls it, so `rendererRequired = false`. The log
  then says `with driver evdi`, which is expected. The upstream fix is to treat `simpledrm` like
  `evdi` in aquamarine `src/backend/drm/DRM.cpp`. Hyprland itself never used that renderer.

Measured on the phone (Hyprland plus two foot windows, one running `top -d 1`): Hyprland RSS
about 225 MB (about 108 MB of it shared, mostly llvm-libs), foot 13 MB each, 562 MB still
available. CPU is 0% when idle, and about 4.5% of the system with one update per second.
Hyprland used 1.6 s of CPU per 20 s under that load with the shim. The run without it (2.0 s) had
`Hyprland` started directly with the file log on, so it isn't a clean comparison. The effect
you can see is the log going from 7 lines per commit to none.

`~/.config/hypr/hyprland.lua` (from `/etc/skel`): the preferred mode at scale 2 (375x667
logical), with animations, blur, shadows and rounding off, Xwayland off, software cursor,
`foot` started at launch, SUPER+Return and SUPER+W.

Notes:
- `hyprctl` over SSH needs `HYPRLAND_INSTANCE_SIGNATURE` for the running instance. That's the
  newest directory in `/run/user/1000/hypr` (`ls -t | head -1`); crashed runs leave old ones.
- With `start-hyprland` the file log stays empty. `hyprctl rollinglog` shows the recent log.
- A Lua config error shows up as a banner: `hyprctl configerrors` over SSH.
- Harmless log noise: `failed to parse edid`, `Couldn't get the gamma_size prop`, and one
  `Cannot commit when a page-flip is awaiting` at the first modeset.

## Omarchy Phone shell and Phone app

Sources: [Omarchy-Phone](https://github.com/modpunk/Omarchy-Phone) branches `shell` and `phone-app`.
`build-rootfs.sh` takes them with `git archive` from `PHONE_SRC` (default `~/Work/omarchy-phone`)
at the commits pinned in `SHELL_REV` and `APP_REV`, so a rebuild installs the same code. Bump the
two defaults (or pass the variables) to ship newer ones. Both SHAs go into
`/etc/omarchy-phone-release` and `/usr/share/omarchy-phone/REVISIONS`.

| path in the image | what |
|---|---|
| `/usr/share/omarchy-phone/shell/` | `hypr/` (Lua config, `devices/iphone6s.lua`), `qs/` (QuickShell UI), `bin/`, `system/` |
| `/usr/share/omarchy-phone/apps/phone/` | `omarchy_phone/` (byte-compiled at build), `bin/`, `data/` |
| `/usr/local/bin/{ophone-ctl,ophone-sys,omarchy-phone,phoned,phonectl}` | symlinks into the trees above |
| `/usr/share/applications/org.omarchy.Phone.desktop` | the Phone app in the shell's app grid and dock (also the `tel:`/`sip:` handler) |
| `/etc/systemd/logind.conf.d/omarchy-phone.conf` | logind ignores the power key, so Hyprland (and the shell) get it |
| `/etc/pam.d/ophone-lock` | the lock screen's PIN check (`auth include login`) |
| `~omarchy/.config/hypr/hyprland.lua` | session wrapper (from `/etc/skel`); `plain.lua` is the old foot-only config |

What starts: `phone-hyprland` (unchanged simpledrm env and `aq-simpledrm.so` preload) also
exports `OPHONE_DEVICE=iphone6s`, `OPHONE_SHELL=/usr/share/omarchy-phone/shell` and, if it's
missing, `DBUS_SESSION_BUS_ADDRESS`. Hyprland reads `~/.config/hypr/hyprland.lua`, which
`dofile`s the shell's `hypr/hyprland.lua` (monitors, keys and touch from `devices/iphone6s.lua`,
the `scrolling` layout, animations) and then sets what the image needs on top: Xwayland off,
software cursor, `GSK_RENDERER=cairo`, `QS_ICON_THEME=Adwaita`. At `hyprland.start` the shell's
config runs `qs -p /usr/share/omarchy-phone/shell/qs`. The shell owns
`org.freedesktop.Notifications` on the session bus. `phoned` isn't started with the session: the
Phone app starts it when it opens (loopback backend; baresip isn't installed). The shipped
`data/phoned.service` user unit isn't installed, because it points at `~/.local/bin` and is
wanted by `graphical-session.target`, which nothing starts here.

Drive it over SSH: `ophone-ctl home|switcher|shade|lock|keyboard|isLocked|notifications`,
`notify-send -a Test Hello "from ssh"`, `omarchy-phone &`, `phonectl simulate "+1 900 555 0123" "Prize Dept"`.

Known gaps and caveats:
- **Lock screen:** the PIN pad checks the user's password through PAM, and the default password
  `omarchy` isn't numeric, so a lock (power key short press, `ophone-ctl lock`) can't be undone
  on the screen. Over SSH, restart the session (the shell starts unlocked):
  `pkill -x Hyprland; phone-hyprland`, or build with a numeric `USERPASS=`.
- **Wi-Fi tile and status:** `Quickshell.Networking` and `ophone-sys wifi|airplane` use
  NetworkManager, which isn't installed (the image uses iwd, and there's no Wi-Fi driver yet).
- `devices/iphone6s.lua` asks for `750x1334@60`, where the plain config used `preferred`.
- Animations are on in the shell's config. On llvmpipe each slide redraws the full panel.
- Left out on purpose (`assume-installed.txt`): `xdg-desktop-portal-gtk` (it would pull gtk3),
  `libvips` (an appstream dependency that nothing links; it pulls imath, openexr, hdf5 and more,
  about 90 MB), `xdg-utils`, Qt translations. Not installed: NetworkManager, baresip, and wvkbd
  and Yaru icons (neither of those two is in ALARM). libgtk-4 links libcups and GStreamer directly, so those stay.

## Kernel asks (for the integration config)

- `CONFIG_RFKILL=y`: iwd and bluetoothd warn without `/dev/rfkill`.
- `CONFIG_CFG80211` (+ brcmfmac): needed before iwd has anything to manage.
- `CONFIG_CGROUP_BPF=y`: systemd uses it for device ACLs and IP accounting in units. It warns
  and carries on without it.
- `CONFIG_SQUASHFS` (xz/zstd) or `CONFIG_EROFS_FS`, plus `CONFIG_OVERLAY_FS`: the root could then
  stay compressed in RAM (~150 MB instead of 788 MB) with a tmpfs upper layer. This is the
  biggest possible memory win.
- `CONFIG_SND` + the cs42l71 codec: only when audio work starts.

## Rebuild

Everything runs as your normal user. It needs `qemu-user-static` with the binfmt entry
(installed), a `/etc/subuid` range (present) and unprivileged user namespaces (enabled). No root
and no Docker.

```sh
cd ~/Work/omarchy-iphone6s
tools/userland/build-rootfs.sh               # install config strip check pack  (a few minutes; ~270 MB of packages, cached in cache/)
STAGES="config strip check pack" tools/userland/build-rootfs.sh   # after editing overlay/ or bumping SHELL_REV/APP_REV
tools/userland/mk-initramfs.sh               # initramfs-userland.gz from the stock ramdisk
tools/userland/test-switch-sim.sh            # rehearse the PID 1 switch on the laptop (must print PASS)
```

`build-rootfs.sh` re-execs itself in `unshare --user --map-auto --map-root-user --mount --pid`.
Host pacman installs into `root/` with `--config tools/userland/pacman-alarm.conf`
(`Architecture = aarch64`) and a keyring built from `archlinuxarm-keyring` (signatures are
verified, `SigLevel = Required`). Scriptlets run in a chroot through
`/usr/bin/qemu-aarch64-static`, which is copied into the root because binfmt has no F flag, and
removed before packing. The tree is owned by subuids. Delete it with
`unshare --user --map-auto --map-root-user rm -rf ~/Work/hoolock-iphone5s/build/userland/root`.

`check-rootfs.sh` also lists unresolved `DT_NEEDED`. The 23 it reports are optional front ends
whose libraries aren't installed (pinentry-gtk/qt, avahi-ui, mpg123 jack/sdl outputs, glycin-heif,
ssh-sk-helper/libfido2, arpd, sensord, tiffgt, pylibmount, Qt's gtk3 platform theme and
mysql/odbc/psql SQL drivers, appstream's `asc-mediaworker` (libvips)). None of the configured
services use them. The smoke tests (systemd, Hyprland, foot, sshd, iwd, bluetoothd, bluetoothctl,
pipewire, wireplumber, seatd, busybox, `sshd -t`, `qs`, upowerd, brightnessctl, PyGObject with
GTK 4.22 + Adw 1.9, the Phone app modules, `phonectl`) all start under qemu. The check also
parses both session configs with `Hyprland --verify-config` (phone shell and `PHONE_PLAIN=1`),
checks the font matches (`JetBrainsMono Nerd Font`, `Noto Sans`), the `call-start-symbolic`
icon, the user `dbus.socket`, and the jemalloc 16K run (see "16K pages").

Known gaps: busybox tar drops file capabilities, so `newuidmap`/`newgidmap` lose
`cap_setuid`/`cap_setgid`. Only rootless containers need those; on the phone, run
`setcap cap_setuid=ep /usr/bin/newuidmap; setcap cap_setgid=ep /usr/bin/newgidmap` if you need
them. `ping` works through `net.ipv4.ping_group_range` without capabilities.

## Files

| path | runs on | what |
|---|---|---|
| `tools/userland/build-rootfs.sh` | laptop | rootless ALARM bootstrap, configure, strip, check, pack |
| `tools/userland/packages.txt`, `assume-installed.txt` | | the package set and the deps left out on purpose |
| `tools/userland/pacman-alarm.conf` | laptop | aarch64 pacman config (mirror.archlinuxarm.org) |
| `tools/userland/overlay/` | | files copied into the root (networkd, sshd, units, iwd, foot, Hyprland session config, `phone-hyprland`) |
| `tools/userland/shim/aq-simpledrm.c` | phone (LD_PRELOAD) | stops aquamarine's per-frame EGL renderer retry on simpledrm; built by `build-rootfs.sh` |
| `tools/userland/shim/pagesize16k.c` | laptop (qemu, test only) | makes `sysconf(_SC_PAGESIZE)` say 16 KiB, for the jemalloc/quickshell check |
| `tools/userland/overlay/etc/skel/.config/hypr/` | phone | `hyprland.lua` (phone shell session), `plain.lua` (foot only) |
| `tools/userland/check-rootfs.sh` | laptop | 16K ELF/allocator scan, library resolution, qemu smoke tests |
| `tools/userland/mk-initramfs.sh` | laptop | builds `initramfs-userland.gz` |
| `tools/userland/test-switch-sim.sh` | laptop | PID 1 switch_root rehearsal with the ramdisk's own busybox |
| `tools/userland/push-rootfs.sh` | laptop | stream + unpack + verify (`--go` to hand over and wait for ssh) |
| `tools/userland/phone/stage2.sh` | phone | `prep`, `recv`, `unpack`, `status`, `go`, `nsboot` |
| `tools/userland/phone/userland-switch.sh` | phone (PID 1) | sourced by the patched `/init` |
