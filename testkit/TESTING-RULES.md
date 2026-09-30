# 6s live-test rules (every agent, no exceptions)

The phone is ONE tethered iPhone 6s (N71, Samsung A9) running the HoolockLinux
RAM ramdisk. If it crashes, only the human can bring it back (DFU buttons +
sudo `./boot.sh pongo && ./boot.sh linux`). Treat every crash as expensive.

1. Base kernel tree ~/Work/hoolock-iphone5s/linux is READ-ONLY. Never run make in
   it except through `testkit/kbuild.sh <dir>` (M= build). Never commit/checkout there.
   Its build is exactly what the phone runs (7.3.0-rc1-g6831bc701a6c #2); drifting it
   breaks vermagic for everyone.
2. Your code lives in your own git worktree of that repo:
     git -C ~/Work/hoolock-iphone5s/linux worktree add .claude/worktrees/<name> -b 6s/<name>
   Edit only files under that worktree. Full kernel/dtb builds use
   `make O=$HOME/Work/hoolock-iphone5s/build/<name> ...` (copy linux/.config there first).
3. Phone access ONLY through testkit/phone.sh:
     phone.sh run '<cmd>'        read-only probes, any time (cat /proc/device-tree, /sys, dmesg)
     phone.sh insmod x.ko        state-changing, takes the shared flock
     phone.sh overlay x.dtbo     state-changing, takes the shared flock
     phone.sh lock '<cmd>'       any other state-changing command (echo > sysfs bind/unbind, register pokes)
   Hold the lock only while touching the phone, never while compiling.
4. CONFIG_MODULE_UNLOAD is OFF. A module name loads once per boot. Every test
   iteration needs a NEW module name AND a new platform driver name (suffix _v2, _v3…).
   Hand a device to the new driver by unbinding the old one
   (echo <dev> > /sys/bus/platform/drivers/<old>/unbind) then bind / driver_override.
5. The running DT has NO __symbols__: overlays use `target-path = "/soc/..."`
   and raw numeric phandles (read them from /proc/device-tree/<node>/phandle on the
   phone). Remove overlays you are done with (echo <id> > /sys/class/misc/dtbo/remove).
   Compile overlays with ~/Work/hoolock-iphone5s/linux/scripts/dtc/dtc -@ -I dts -O dtb.
6. NEVER write to the NVMe/NAND (it holds iOS). Storage work is read-only: no
   writes, no partitioning, no mkfs, block device must be read-only
   (set_disk_ro / reject REQ_OP_WRITE) before it is ever exposed.
7. No raw register pokes (devmem) to an unknown address; only addresses that come
   from Apple's device tree for the block you own, and only reads unless you know
   the write is safe.
8. Health: if `phone.sh ping` fails for 60 s the phone has panicked or hung.
   STOP phone testing, do not retry in a loop, note the last thing you loaded, and
   report "phone down after <x>". Keep working on code / build-only verification.
9. Never commit Apple or Broadcom binaries anywhere public: IPSW contents, *.im4p,
   kernelcache, Apple ADT dumps (.bin), firmware (.hcd, brcmfmac*.bin, NVRAM,
   touch firmware). Commit extraction scripts instead. Local copies go in
   ~/Work/hoolock-iphone5s/firmware/ (gitignored, never in the public repo).
10. The laptop firewall (ufw) blocks inbound; phone.sh pushes by connecting out to
    an nc listener on the phone. Don't open ports on the laptop.
11. (added after oops #2) NEVER remove an overlay whose nodes are bound to a driver,
    and never unbind samsung-uart: of_overlay_remove on a bound apple,s5l-uart node
    NULL-derefs in serial_core_unregister_port. Root cause: upstream
    s3c24xx_serial_remove() calls uart_unregister_driver() on every port removal,
    freeing state the other ttySAC ports still use (fix on the foundation branch;
    until that kernel boots, one removal corrupts every UART port). Never remove an overlay that adds an
    apple-pmgr-pwrstate provider (no .remove → genpd freed while registered).
    Apply bus/power overlays ONCE per boot and keep them; iterate only on child nodes
    and freshly named drivers. Removing is only OK for overlays that nothing bound to.
12. Don't read kernel-image linear-map aliases (oops #1). The phone is tainted and
    fragile now; prefer build-only verification for anything with an unproven
    remove/teardown path.
13. (2026-09-29, user approved explicitly: "1. approved") Power-chip writes are allowed,
    limited to the exact values iOS writes: D2255 PMIC GPIO 8 (BT REG_ON) and GPIO 10
    (WLAN REG_ON); SN2400 charger reg 0x1d (0x04 / 0x06 / 0x00 HDQ handover);
    display-PMU (chestnut) reg 0x05 bit 4 (touch analog supply). One write at a time,
    read back before and after, log it, restore the original value when the test ends
    where iOS would. Everything else on i2c0/i2c1/i2c2 stays read-only.
    NVMe writes remain FORBIDDEN (would destroy the user's iOS install).
