# CI: patch series apply/build check

`.github/workflows/patch-series-ci.yml` runs on any change under `patches/`
(and on changes to itself). It is **build-only** — it never touches the phone,
and has no phone-specific step at all.

## What it checks

1. **`guard-no-blobs`** (always runs, hard fail): scans every file in
   `patches/` for a `GIT binary patch` hunk, and every `diff --git` path for
   anything on the `docs/CONTRIBUTING.md` "Never commit" list (IPSW/DMG/IM4P
   contents, Apple DT dumps, Broadcom firmware blobs, build output). Catches a
   binary blob smuggled into a patch before it ever reaches `git am`.

2. **`apply-check`** (hard fail, the required gate): shallow-fetches
   [`HoolockLinux/linux`](https://github.com/HoolockLinux/linux) at the exact
   commit pinned in `docs/CONTRIBUTING.md` (`6831bc701a6ce059e71e5aaa9488c9195bea6927`,
   "Merge branch 'bits/090-dart' into hoolock"), then for each series in
   `patches/*/` resets to that pinned commit (a detached checkout, never a
   branch `git am` could silently advance across iterations) and runs
   `git am`, applying each series' declared prerequisite series first, in
   isolation from every other series. Fails if any series doesn't `git am`
   cleanly, and also fails if `patches/*/` contains a directory not listed
   below (so a new series can't silently go unchecked).

   The order and dependency list live in a small `SERIES=(...)` array at the
   top of the `git am each series in dependency order` step, e.g.:

   ```
   "foundation:"
   "battery:foundation"
   "bluetooth:foundation"
   "touch:"
   "fast-reload:"
   ```

   `name:dep1,dep2`. Update this array (and its comment, which cites the
   `docs/drivers/*.md` "Depends on" note it came from) whenever a new series
   is added or a dependency changes — it is intentionally not derived
   automatically from the docs, so it stays a single, reviewable place to
   look at. This same array is emitted as a JSON build matrix for
   `build-check`, so it's the one and only place the series list lives.

3. **`checkpatch`** (best-effort, `continue-on-error: true`): runs
   `scripts/checkpatch.pl --strict` on every patch (style only, warnings
   don't fail the job — `CONTRIBUTING.md` asks for "clean where reasonable",
   not a hard requirement).

4. **`build-check`** (best-effort, `continue-on-error: true`, one job per
   series via the matrix from `apply-check`): applies each series in the
   *same isolation* as `apply-check` — base + its own declared deps only,
   never stacked with sibling series. This matters: `battery` and
   `bluetooth` both patch `arch/arm64/boot/dts/apple/s800x-6s.dtsi` and
   conflict with each other despite each applying cleanly on `foundation`
   alone, so a single combined tree with every series applied together is
   not a valid thing to build. If there's enough disk space and a
   clang/LLVM toolchain can be installed, each per-series job runs
   `make ARCH=arm64 LLVM=1 defconfig`, builds the object files that series'
   patches touch, and always also builds the `s8000-n71`/`s8003-n71m` dtbs
   (a series can `git am` cleanly and still fail to build once a
   dependency's DT nodes exist — see `docs/drivers/battery.md`). If either
   precondition isn't met, the build step is skipped with a warning and the
   job still passes.

## Where the dependency order comes from

Per `docs/CONTRIBUTING.md`, a series that depends on another must say so at
the top of its `docs/drivers/<name>.md`. As of this writing:

- `docs/drivers/foundation.md` — standalone; adds the `serial1`,
  `serial3`..`serial6` DT nodes and PMIC/tty fixes other series build on.
- `docs/drivers/battery.md` — "Depends on: the foundation series", needs the
  `serial5` node from `foundation/0001`.
- `docs/drivers/bluetooth.md` — "Depends on: the `foundation` series", needs
  the `serial1` node from `foundation/0001`.
- `docs/drivers/touch.md` — standalone ("6 patches, `git am` onto
  `6831bc701` on their own, checked"); it adds its own SPI controller nodes.
- `docs/fast-reload.md` — standalone; no dependency note (smp_spin_table
  change only).

## Local reproduction

```sh
mkdir hoolock-linux && cd hoolock-linux
git init && git remote add origin https://github.com/HoolockLinux/linux.git
git fetch --depth=1 origin 6831bc701a6ce059e71e5aaa9488c9195bea6927
git checkout FETCH_HEAD
git am /path/to/Omarchy-iPhone6s/patches/foundation/*.patch
git am /path/to/Omarchy-iPhone6s/patches/battery/*.patch   # or bluetooth, on the same tree
```

For `touch` or `fast-reload`, reset back to the fetched commit first — they
apply on their own, without `foundation`. Don't apply `battery` and
`bluetooth` in the same tree: reset to `foundation` and pick one, since they
conflict with each other on `s800x-6s.dtsi`.
