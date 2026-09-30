# Fast kernel reload (kexec, no DFU)

**Status**: reloads started from the busybox ramdisk work on the phone (about 10 s, USB NCM comes
back). A reload started from the Arch userland (2026-09-29) booted the new kernel but USB never
enumerated again; see "Reloading from the Arch userland" for the fix, which is not yet
tested on the phone.

Without this, every new kernel costs a DFU cycle: buttons, checkm8, pongoOS, blob. With it:

```sh
kit/reload.sh            # push Image + DTB + ramdisk, kexec, wait for telnet: ~30-60 s
```

## Why kexec needs a kernel patch here

The A9 starts its second core with **spin-table**: m1n1 parks CPU1 in a loop and Linux writes
an entry address to `cpu-release-addr`. Upstream spin-table has no way back out of the kernel,
so arm64 refuses `kexec_load` with `-EBUSY` ("CPUs are stuck in the kernel"). A kexec at that
point would overwrite the code CPU1 is running.

What was evaluated:

| Option | Verdict |
|---|---|
| kexec + `nr_cpus=1` | Gets past the `-EBUSY` check, but CPU1 stays in **m1n1's** spin loop. m1n1 gives its own memory to Linux (only the secondary stacks are `/memreserve/`d, see `dt_set_cpus`/`dt_set_memory` in HoolockLinux m1n1 `src/kboot.c`), so CPU1 ends up executing whatever Linux puts there. Unsafe. |
| kexec + `maxcpus=1` / `nosmp` | `maxcpus=1` releases CPU1 into the kernel's holding pen, which kexec overwrites. `nosmp` leaves it in m1n1 memory as above, and still gets `-EBUSY`. |
| m1n1 chainload / USB proxy | HoolockLinux m1n1 has a DWC2 USB stack and a proxy mode, but m1n1 only exists before Linux. Getting back into it needs a reboot, which means DFU. Re-entering m1n1 via kexec would need iBoot's boot_args and a fresh CPU start. |
| pongoOS | Same problem: it is gone once m1n1 runs. |
| Asahi / HoolockLinux | Neither re-parks spin-table CPUs. Nothing to reuse. |
| **Park page (chosen)** | Small kernel patch plus a tiny loader. SMP stays on, and it works across any number of reloads. |

## How it works

1. **Kernel** (`patches/fast-reload/0001-*.patch`, branch `6s/fast-reload`, touches only
   `arch/arm64/kernel/smp_spin_table.c`). The kernel reserves a 16 KiB *park page*: a
   10-instruction loop at offset 0, a `SPINPARK` magic at 0x7f0 and one u64 slot per
   `MPIDR.Aff0` at 0x800.
   - At boot, CPU1 is released from m1n1 into the park loop, not into the holding pen.
   - `cpu_boot` writes the holding pen address into CPU1's slot.
   - `cpu_disable` + `cpu_die` (new) send a dying CPU back to the park loop with the MMU off,
     using `cpu_soft_restart`. That gives spin-table real CPU hotplug, so
     `machine_kexec_prepare` accepts the image.
   - The page shows up in `/proc/iomem` as `spin-table park`.
   - A kexec'd kernel finds the page through a `reserved-memory` node compatible with
     `linux,spin-table-park` (`no-map`). It checks the magic and releases CPU1 from there,
     without rewriting the loop CPU1 is running.
2. **Phone-side loader**: `kit/fast-reload/kexec-lite.c`, about 4.5 KB, static and
   freestanding (clang + lld, no libc or sysroot). It checks the Image header, calls
   `kexec_load(2)` with four segments (kernel, initrd, dtb, and a 40-byte purgatory that sets
   `x0 = dtb` and jumps to the kernel), then `reboot(LINUX_REBOOT_CMD_KEXEC)`.
3. **Laptop side**:
   - `kit/fast-reload/fdtmerge.py` (stdlib only). A freshly compiled `.dtb` lacks everything
     m1n1 fills in: memory, reserved-memory (ADT phram), framebuffer, cpu-release-addr, chosen,
     serial number, disabled devices, `/memreserve/`. The tool does a 3-way merge,
     `new.dtb + (running /sys/firmware/fdt − base.dtb)`, where base is the dtb the running boot
     started from.
   - It then sets the bootargs, initrd location, a fresh `kaslr-seed` and `rng-seed`, the park
     node, `cpu-release-addr = park slot`, and `/chosen/fast-reload,base = sha256(new.dtb)`.
   - It places the segments in free RAM, skipping every reservation and the park page.
   - Finding the base: the first reload uses `$OUT/blob-dtbs/` (written by `kit/boot.sh blob`).
     Later reloads look up `fast-reload,base` in `$OUT/fast-reload/base-<sha>.dtb`.
4. `kit/reload.sh` ties it together through `testkit/phone.sh`, so pushes and the kexec take
   the shared phone lock:
   1. Probe the phone and pull `/sys/firmware/fdt` (hex over telnet, md5-checked).
   2. Merge, then push `kexec-lite`, the dtb, the initrd and the Image.
   3. Run `kexec_load`. The phone is still on the old kernel if this fails.
   4. Jump through `kit/fast-reload/kexec-jump.sh`: it detaches from the telnet session,
      unbinds the configfs USB gadget, waits 2 s, then calls `kexec-lite exec`. reload.sh
      waits for telnet to drop and come back, then prints `uname`, online CPUs and the park
      line from dmesg.

## One-time setup: one slow boot with the patch

The kernel running now does not have the patch, so it can't be kexec'd. Boot a patched kernel
once through DFU. `build/fast-reload` is `6s/integration` plus the patch, with `KERNELRELEASE`
pinned to `7.3.0-rc1-g6831bc701a6c` so existing modules still load:

```sh
cd ~/Work/omarchy-iphone6s        # this branch
BUILD=~/Work/hoolock-iphone5s/build/fast-reload kit/boot.sh blob   # also records out/blob-dtbs/
# DFU, then:
kit/boot.sh pongo && kit/boot.sh linux
```

Every kernel you reload **must also carry the patch**, or the reload after it will refuse and
you are back to DFU. Add it to other branches with `git cherry-pick 6s/fast-reload` or
`git am patches/fast-reload/*.patch`.

### First test on the device, in order

```sh
testkit/phone.sh run 'grep "spin-table park" /proc/iomem; dmesg | grep -i "spin-table park"; cat /sys/devices/system/cpu/online'
#   expect: "spin-table park: [mem 0x8...] (allocated)", online 0-1
testkit/phone.sh lock 'echo 0 > /sys/devices/system/cpu/cpu1/online; cat /sys/devices/system/cpu/online; echo 1 > /sys/devices/system/cpu/cpu1/online; cat /sys/devices/system/cpu/online'
#   park round trip without kexec. expect: 0, then 0-1
kit/reload.sh -n       # delta should be m1n1 fixups only (memory, reserved-memory, chosen, fb, cpus)
kit/reload.sh          # expect "(inherited)" park line, online 0-1, new uname -v
kit/reload.sh          # second hop: the base is now found through fast-reload,base
```

## Everyday use

```sh
make O=$BUILD LLVM=1 ARCH=arm64 KERNELRELEASE=7.3.0-rc1-g6831bc701a6c Image apple/s8000-n71.dtb
kit/reload.sh --build $BUILD                  # or BUILD=... kit/reload.sh
kit/reload.sh -n                              # dry run: show the carried m1n1 delta + placement
kit/reload.sh --append "loglevel=8"           # tweak bootargs (--cmdline replaces them)
kit/reload.sh --load-only                     # kexec_load only; jump later with kexec-jump.sh
kit/reload.sh --no-quiesce                    # jump with the USB gadget still bound (the old way)
```

A reload is a reboot as far as runtime state goes: loaded modules, applied overlays and the
`fnd_phandle` phandles are gone, so run `phone.sh settime` again. The ramdisk is fresh.

## Reloading from the Arch userland

The first reload from the RAM userland (systemd as PID 1, the ramdisk's gadget inherited across
`switch_root`, telnetd and sshd running) booted the new kernel. The screen showed the ramdisk
shell, but the laptop never saw a USB device again. The kexec'd DT was checked afterwards
(`out/fast-reload/stage/fr.dtb`): the ausb tunables, `usbdev` and the power domains are all
there, and the delta is the same as on the busybox reloads, so the DT is not the cause.

What the old jump did: `reboot(LINUX_REBOOT_CMD_KEXEC)` with the gadget still bound. The only
USB cleanup was dwc2's `.shutdown`: interrupts masked, PHY powered down (PWRDOWN|SIDDQ). There
was no soft disconnect (SFTDISCON), no clock ungating after a bus suspend and no core reset, so
the endpoints and their DMA stayed armed in the core. The new kernel's dwc2 probe only
*deasserts* the pmgr reset. The DT has `resets = <&ps_usbotg>` but no `reset-names`, so dwc2
never even got the reset. Whatever the old kernel left behind was inherited as it was.

This is also true of the busybox reloads, so it doesn't explain on its own why only the
userland failed. What exactly differed on the phone is still unproven, since the failed boot
left no log. The fix closes every gap on both sides:

- **kit** (`kexec-jump.sh`, used by `reload.sh`): writes `""` to every configfs gadget's `UDC`
  before the jump. That is the gadget stack's own teardown (pull-up off, endpoints disabled,
  `udc_stop` powers the PHY down), the same path the ramdisk init takes at every boot when it
  adds ACM. It finds configfs through `/proc/mounts` (`/config` in the ramdisk,
  `/sys/kernel/config` under systemd) and mounts it itself if neither is there. Under systemd it
  runs as a transient unit (`fast-reload-jump-<pid>`), outside `phone-telnetd.service`'s cgroup,
  so a telnetd restart can't kill it halfway with USB already gone. If `reboot(KEXEC)` returns,
  it binds the UDC again so the phone stays reachable.
- **kernel** (branch `6s/fast-reload-usb` of `hoolock-iphone5s/linux`, on top of `6s/fast-reload`;
  `patches/fast-reload/0002-*` and `0003-*`; built in `build/fast-reload-usb`):
  - dwc2 probe on `apple,dwc2` pulses the pmgr reset. The DT gains `reset-names = "dwc2"`, so the
    core starts from its power-on state. `dwc2.apple_reset_on_probe=0` turns this off.
  - Probe clears `PCGCTL` before the first register read, in case the previous kernel left the
    core clock-gated.
  - `.shutdown` in peripheral mode ungates the clocks, sets SFTDISCON, soft-resets the core,
    then powers the PHY down.
  - The ausb PHY `init` power-cycles the PHY (PWRDOWN|SIDDQ under reset) instead of only
    releasing it.

The kernel's `.shutdown` change only helps once the kernel you jump *from* has it. The probe
changes help on the first reload *into* it.

Rehearse the teardown without a kexec. USB drops for about 5 s, then telnet works again:

```sh
testkit/phone.sh push kit/fast-reload/kexec-jump.sh
testkit/phone.sh lock 'sh /tmp/6s/kexec-jump.sh --rehearse'; sleep 10; testkit/phone.sh ping
```

## Failure modes

- *"running kernel has no spin-table park"*: the phone runs an unpatched kernel. Do the
  one-time DFU boot.
- *`kexec_load failed (… 0x10)`* (EBUSY): same cause, or a CPU failed to come online at boot.
  Nothing has changed on the phone.
- *nosmp / nr_cpus= on the running cmdline*: refused. CPU1 may still be in m1n1 memory.
- *phone never comes back*: look at the screen (fbcon shows the new kernel's console) and
  photograph it before you DFU. Look for `No UDC found, skipping usb gadget` (dwc2 did not
  probe), `dwc2 ...: HANG! Soft Reset timeout` or `AHB Idle timeout` (core wedged),
  `Bad value for GSNPSID` (core unclocked or in reset), `controller reset failed` (pmgr reset),
  and `Could not find an interface to run a dhcp server on`. Just before the jump the old kernel
  prints `fast-reload: unbinding ...` and `fast-reload: reboot(KEXEC)` on the screen for about
  2 s. Recover through DFU.
- *wrong base* (e.g. a blob built by `~/Work/hoolock-iphone5s/boot.sh`, which does not record
  `blob-dtbs`): pass `--base <the dtb inside that blob>`. `-n` prints every carried change, so a
  bad base shows up as a long list of unrelated properties.

## Limits

- CPUs with `MPIDR.Aff1..3 != 0` are not parked, and the kernel then behaves as upstream. All
  single-cluster A7-A11 parts are fine.
- The park page leaks 16 KiB per first boot. It is reused across reloads.
- Phandle-bearing properties that m1n1 changes are translated for `interrupt-parent`,
  `memory-region`, `cpus`, `power-domains` and `iommu-addresses`. Other m1n1-changed phandle
  properties are copied as they are, and `-n` shows them.
