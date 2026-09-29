# Contributing

Driver work happens as out-of-tree patches against the HoolockLinux kernel.
Each driver gets one PR, from a branch named `driver/<name>`.

## Base

All patches are `git format-patch` output against
[HoolockLinux/linux](https://github.com/HoolockLinux/linux) at commit
**`6831bc701`** (`Merge branch 'bits/090-dart' into hoolock`). The phone runs
`7.3.0-rc1-g6831bc701a6c`, so modules built from that tree load without a vermagic mismatch.

```sh
git clone https://github.com/HoolockLinux/linux && cd linux
git checkout 6831bc701
git am /path/to/Omarchy-iPhone6s/patches/<name>/*.patch
```

## Layout of a driver PR

```
patches/<name>/0001-....patch     git format-patch -o patches/<name> 6831bc701..HEAD
patches/<name>/0002-....patch     numbered, applied in order with git am
docs/drivers/<name>.md            what it does, live-test evidence, status
testkit/overlays/<name>*.dtso     optional: DT overlay used for live testing
```

- `patches/<name>/` must apply cleanly with `git am` onto `6831bc701`, on its own.
  If it depends on another driver's series, say so at the top of `docs/drivers/<name>.md`
  and name the series it goes on top of.
- One logical change per patch, kernel style (`scripts/checkpatch.pl` clean where reasonable),
  with a `Signed-off-by:`.
- DT changes go in the patches (`arch/arm64/boot/dts/apple/...`). Use the fixed labels from
  `testkit/CONTEXT.md` (`serial1`..`serial6`, `spi1`..`spi3`) so series merge.
- Overlays in `testkit/overlays/` are source (`.dtso`) only.

### `docs/drivers/<name>.md`

- **What**: the hardware (chip, bus, ADT node) and the Linux driver used or written.
- **Status**: works / partial / blocked, in one line.
- **Evidence**: the dmesg lines or command output from the live phone that prove it
  (kernel version string included). Say plainly what was not tested.
- **Firmware**: if the device needs a blob, how to extract it (a script or commands),
  never the blob.
- **Known issues / next steps**.

## Testing on the phone

Read `testkit/TESTING-RULES.md` before touching the phone. The short form: one tethered phone
on a RAM ramdisk, all access through `testkit/phone.sh`, no module unload (new module name per
try), never write to the NAND.

## Never commit

Apple or Broadcom binaries, in any form:

- IPSW contents: `*.ipsw`, `*.dmg`, `*.im4p`, kernelcache, iBoot, SEP firmware
- Apple device-tree dumps (`*-apple-dt.bin`) or verbatim text dumps of them
- Firmware blobs: Broadcom `*.hcd`, `brcmfmac*`, NVRAM (`*.txt.nvram`), touch/multitouch firmware
- Build output: `*.ko`, `*.o`, `*.dtb`, `*.dtbo`, `Image*`

Commit the script that extracts a blob instead. `.gitignore` covers the common cases; check
`git diff --stat` before you push anyway.
