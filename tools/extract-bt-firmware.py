#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Extract the iPhone 6s Bluetooth patchram (.hcd) from iOS's BlueTool binary.

iOS does not ship the Broadcom patchram as a file: /usr/sbin/BlueTool embeds
every board's .hcd and registers each one with a call like

    adr   x8, <blob>            ; data pointer
    mov   w8, #lo / movk w8, #hi, lsl #16   ; length
    adrp  x6, <name> / add x6, x6, #off     ; "BCM4350C5_..._Albarossa_OS_USI_..hcd"
    bl    register_firmware

This script finds the registration for the requested file name, copies the
blob out, checks that it is a well-formed HCD command stream that ends in
Launch_RAM, and writes it under the names Linux btbcm asks for.

Nothing Apple/Broadcom-owned is stored in this repository; run this on your
own copy of the IPSW.

Getting BlueTool out of the IPSW (iOS 15.8.8 19H422, iPhone_4.7):
    unzip iPhone_4.7_15.8.8_19H422_Restore.ipsw 098-68805-067.dmg   # the ~5 GB rootfs
    apfs-fuse -o ro 098-68805-067.dmg mnt                           # github.com/sgan81/apfs-fuse
    ./extract-bt-firmware.py mnt/root/usr/sbin/BlueTool out/

Result (install on the phone as /lib/firmware/brcm/...):
    out/brcm/BCM4350C5.apple,n71.hcd   name requested by a kernel with the
                                        BCM4350C5 UART entry (patches/bluetooth)
    out/brcm/BCM.apple,n71.hcd         name requested by the stock 6831bc701 kernel
"""
import argparse
import hashlib
import os
import struct
import sys

DEFAULT_NAME = "BCM4350C5_19.1.235.4921_Albarossa_OS_USI_BM_MCC_20210628.hcd"


def macho_segments(d):
    magic, = struct.unpack_from("<I", d, 0)
    if magic != 0xFEEDFACF:
        sys.exit("not a thin 64-bit Mach-O (magic %08x)" % magic)
    ncmds, = struct.unpack_from("<I", d, 16)
    off, segs, sects = 32, [], {}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            vm, vs, fo, fs = struct.unpack_from("<QQQQ", d, off + 24)
            segs.append((vm, vs, fo, fs))
            nsect, = struct.unpack_from("<I", d, off + 64)
            for i in range(nsect):
                so = off + 72 + 80 * i
                sname = d[so:so + 16].split(b"\0")[0].decode()
                segname = d[so + 16:so + 32].split(b"\0")[0].decode()
                addr, sz, foff = struct.unpack_from("<QQI", d, so + 32)
                sects[(segname, sname)] = (addr, sz, foff)
        off += size
    return segs, sects


def vm_to_off(segs, vm):
    for s_vm, s_vs, s_fo, s_fs in segs:
        if s_vm <= vm < s_vm + s_fs:
            return vm - s_vm + s_fo
    return None


def off_to_vm(segs, off):
    for s_vm, s_vs, s_fo, s_fs in segs:
        if s_fs and s_fo <= off < s_fo + s_fs:
            return off - s_fo + s_vm
    return None


def sx(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def find_blob(d, name):
    segs, sects = macho_segments(d)
    name_off = d.find(name.encode() + b"\0")
    if name_off < 0:
        sys.exit("firmware name %r not found in the binary" % name)
    name_vm = off_to_vm(segs, name_off)
    addr, size, foff = sects[("__TEXT", "__text")]
    n = size // 4
    ins = struct.unpack_from("<%dI" % n, d, foff)
    hits = []
    for i in range(n - 1):
        w = ins[i]
        # adrp x6, page
        if (w & 0x9F00001F) != 0x90000006:
            continue
        immlo, immhi = (w >> 29) & 3, (w >> 5) & 0x7FFFF
        pc = addr + 4 * i
        page = (pc & ~0xFFF) + (sx((immhi << 2) | immlo, 21) << 12)
        w2 = ins[i + 1]
        # add x6, x6, #imm12
        if (w2 & 0xFFC003FF) != 0x910000C6:
            continue
        if page + ((w2 >> 10) & 0xFFF) != name_vm:
            continue
        blob, length = None, None
        for j in range(i - 1, max(i - 40, 0), -1):
            wj = ins[j]
            if (wj & 0xFFE0001F) == 0x52800008:          # movz w8, #imm16
                length = (length or 0) | ((wj >> 5) & 0xFFFF)
            elif (wj & 0xFFE0001F) == 0x72A00008:        # movk w8, #imm16, lsl #16
                length = (length or 0) | (((wj >> 5) & 0xFFFF) << 16)
            elif (wj & 0x9F00001F) == 0x10000008:        # adr x8, label
                imm = sx((((wj >> 5) & 0x7FFFF) << 2) | ((wj >> 29) & 3), 21)
                blob = addr + 4 * j + imm
                break
        if blob is not None and length:
            hits.append((blob, length))
    if not hits:
        sys.exit("no registration of %r found (different BlueTool build?)" % name)
    blobs = {}
    for vm, ln in hits:
        o = vm_to_off(segs, vm)
        blobs[bytes(d[o:o + ln])] = (vm, ln)
    if len(blobs) != 1:
        sys.exit("%d different blobs registered under %r" % (len(blobs), name))
    return next(iter(blobs.items()))


def check_hcd(b):
    p, cmds = 0, 0
    while p + 3 <= len(b):
        op, ln = b[p] | b[p + 1] << 8, b[p + 2]
        if op >> 10 != 0x3F:                              # vendor OGF
            return "non-vendor opcode %04x at %d" % (op, p)
        p += 3 + ln
        cmds += 1
    if p != len(b):
        return "trailing bytes"
    if b[-7:] != bytes.fromhex("4efc04ffffffff"):
        return "does not end in Launch_RAM"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bluetool", help="path to usr/sbin/BlueTool from the iOS rootfs")
    ap.add_argument("outdir", help="output directory (brcm/ is created inside)")
    ap.add_argument("--name", default=DEFAULT_NAME,
                    help="embedded file name (default: %(default)s); Murata modules use "
                         "BCM4350C5_19.1.235.4920_Albarossa_OS_MUR_BM_MCC_20210628.hcd")
    ap.add_argument("--board", default="apple,n71",
                    help="first root compatible of the Linux DT (default: %(default)s)")
    a = ap.parse_args()

    d = open(a.bluetool, "rb").read()
    blob, (vm, ln) = find_blob(d, a.name)
    err = check_hcd(blob)
    if err:
        sys.exit("extracted blob is not a valid HCD: " + err)
    outdir = os.path.join(a.outdir, "brcm")
    os.makedirs(outdir, exist_ok=True)
    chip = a.name.split("_")[0]
    names = ["%s.%s.hcd" % (chip, a.board), "BCM.%s.hcd" % a.board]
    for nm in names:
        with open(os.path.join(outdir, nm), "wb") as f:
            f.write(blob)
    print("%s: %d bytes at 0x%x, sha256 %s" % (a.name, ln, vm, hashlib.sha256(blob).hexdigest()))
    for nm in names:
        print("wrote", os.path.join(outdir, nm))


if __name__ == "__main__":
    main()
