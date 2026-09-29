#!/usr/bin/env bash
# Build an out-of-tree module dir against the EXACT tree the phone is running.
# The base tree is READ-ONLY: never run make in it without M=.
#   ./kbuild.sh <module-dir>
set -euo pipefail
KSRC="${KSRC:-${HOOLOCK:-$HOME/Work/hoolock-iphone5s}/linux}"
dir="$(cd "${1:?module dir}" && pwd)"
exec make -C "$KSRC" M="$dir" LLVM=1 ARCH=arm64 -j"$(nproc)" modules
