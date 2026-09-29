#!/usr/bin/env bash
# Build kexec-lite: static, freestanding aarch64 (no libc, no sysroot; clang + lld only).
#   kit/fast-reload/build.sh [outdir]      -> <outdir>/kexec-lite (default: next to this script)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="${1:-$HERE}"
mkdir -p "$OUTDIR"
clang --target=aarch64-linux-gnu -O2 -Wall -Wextra -Wno-unused-parameter \
	-ffreestanding -fno-builtin -nostdlib -static -fno-pic \
	-fno-stack-protector -fno-asynchronous-unwind-tables -mgeneral-regs-only \
	-fuse-ld=lld -Wl,-e,_start -Wl,--build-id=none -Wl,-z,noexecstack \
	-o "$OUTDIR/kexec-lite" "$HERE/kexec-lite.c"
llvm-strip "$OUTDIR/kexec-lite" 2>/dev/null || true
echo "$OUTDIR/kexec-lite"
