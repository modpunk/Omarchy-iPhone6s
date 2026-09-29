#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Build the iPhone 6s (N71) multitouch firmware for Linux apple_z2 from iOS.

iOS ships the controller firmware in the root filesystem as
/usr/share/firmware/multitouch/N71.mtprops (a plist). Each personality
("C1F5B,1", "C1F5B,2") carries "Constructed Firmware": ready-made HBPP DATA
packets in wire order (a 0x18e1 NOP word followed by 0x3001 <len/4> <addr>
<hdr sum> <payload> <sum>). The kernel's Z2FW container stores blobs as
little endian 16-bit words, so every byte pair is swapped here.

Output layout (apple_z2 Z2FW v1):
  "Z2FW" u32 1
  u32 2 (SEND_CALIBRATION) u32 cal-dl-addr   -> apple,z2-cal-blob from DT
  u32 1 (SEND_BLOB) u32 len <blob>           -> one per constructed image

The result is Apple firmware: keep it local, never commit or publish it.

Usage:
  extract-n71-touch-fw.py N71.mtprops out/mtfw-n71.bin [--personality C1F5B,2]
  (get N71.mtprops by mounting the IPSW root filesystem DMG with apfs-fuse:
   apfs-fuse -o ro 098-68805-067.dmg mnt; cp mnt/root/usr/share/firmware/multitouch/N71.mtprops .)
"""
import argparse, plistlib, struct, sys

LOAD_COMMAND_SEND_BLOB = 1
LOAD_COMMAND_SEND_CALIBRATION = 2
# AppleMultitouchSPIN71 personality (iOS 15.8.8 kernelcache): cal-dl-addr
CAL_DL_ADDR = 0x10009000


def swap16(b):
    if len(b) & 1:
        raise ValueError("odd length blob")
    out = bytearray(len(b))
    out[0::2] = b[1::2]
    out[1::2] = b[0::2]
    return bytes(out)


def check_packet(img, idx):
    # 18 e1 | 30 01 | len/4 | addr lo, addr hi | hdr sum | payload | sum32
    if img[0:2] != b"\x18\xe1" or img[2:4] != b"\x30\x01":
        raise ValueError(f"image {idx}: not a NOP + HBPP DATA packet")
    words = struct.unpack(">H", img[4:6])[0]
    addr = struct.unpack(">H", img[6:8])[0] | struct.unpack(">H", img[8:10])[0] << 16
    hsum = struct.unpack(">H", img[10:12])[0]
    if sum(img[4:10]) & 0xffff != hsum:
        raise ValueError(f"image {idx}: header checksum mismatch")
    if 2 + 10 + words * 4 + 4 != len(img):
        raise ValueError(f"image {idx}: length mismatch")
    payload = img[12:12 + words * 4]
    tail = img[12 + words * 4:]
    psum = struct.unpack(">H", tail[0:2])[0] | struct.unpack(">H", tail[2:4])[0] << 16
    if sum(payload) & 0xffffffff != psum:
        raise ValueError(f"image {idx}: payload checksum mismatch")
    return addr, words * 4


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mtprops")
    ap.add_argument("out")
    ap.add_argument("--personality", default="C1F5B,2",
                    help="mt-merge-personality (ADT compatible multi-touch,n71,2 -> C1F5B,2)")
    ap.add_argument("--no-cal", action="store_true",
                    help="do not emit the SEND_CALIBRATION command")
    a = ap.parse_args()

    pl = plistlib.load(open(a.mtprops, "rb"))
    pers = pl[a.personality]
    if pers.get("PreconstructedBootloadPacketType") != "Z2":
        sys.exit("unexpected bootload packet type")
    out = [struct.pack("<4sI", b"Z2FW", 1)]
    if not a.no_cal:
        out.append(struct.pack("<II", LOAD_COMMAND_SEND_CALIBRATION, CAL_DL_ADDR))
    for i, img in enumerate(pers["Constructed Firmware"]):
        addr, n = check_packet(img, i)
        print(f"image {i}: {len(img)} bytes, {n} payload bytes -> 0x{addr:08x}")
        blob = swap16(img)
        out.append(struct.pack("<II", LOAD_COMMAND_SEND_BLOB, len(blob)))
        out.append(blob)
        if len(blob) % 4:
            out.append(b"\0" * (4 - len(blob) % 4))
    data = b"".join(out)
    open(a.out, "wb").write(data)
    print(f"firmware version {pers.get('Constructed Firmware Version')}, wrote {len(data)} bytes to {a.out}")


if __name__ == "__main__":
    main()
