#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Print the iPhone multitouch calibration from a *runtime* Apple device tree
as a DT property for the apple_z2 driver (apple,z2-cal-blob).

iBoot fills /arm-io/spi2/multi-touch/multi-touch-calibration from syscfg
(MtCl); the IPSW template only has the placeholder string
'syscfg/MtCl/0x400,zeroes/0x400'. On a HoolockLinux boot the runtime ADT
is readable at /dev/mtd1ro (m1n1 phram "adt"):
    cat /dev/mtd1ro > adt.bin
The calibration is device unique: keep the output local, never publish it.

Usage: adt-touch-cal.py adt.bin [node-name] > cal.dtsi-fragment
"""
import struct, sys


def props_of(d, want):
    found = {}

    def s(b):
        return b.split(b"\0")[0].decode(errors="replace")

    def node(o, path):
        np_, nc = struct.unpack_from("<II", d, o)
        o += 8
        props = {}
        for _ in range(np_):
            name = s(d[o:o + 32])
            ln = struct.unpack_from("<I", d, o + 32)[0] & 0x7fffffff
            o += 36
            props[name] = d[o:o + ln]
            o += (ln + 3) & ~3
        p = path + "/" + s(props.get("name", b"?"))
        if p.endswith("/" + want):
            found[p] = props
        for _ in range(nc):
            o = node(o, p)
        return o

    node(0, "")
    return found


def main():
    d = open(sys.argv[1], "rb").read()
    want = sys.argv[2] if len(sys.argv) > 2 else "multi-touch"
    nodes = props_of(d, want)
    if not nodes:
        sys.exit(f"no {want} node")
    path, props = next(iter(nodes.items()))
    cal = props.get("multi-touch-calibration", b"")
    if not cal or cal.startswith(b"syscfg/"):
        sys.exit(f"{path}: multi-touch-calibration not filled in (template ADT?)")
    print(f"/* {path} multi-touch-calibration, {len(cal)} bytes - device unique */")
    body = " ".join(f"{b:02x}" for b in cal)
    print(f"apple,z2-cal-blob = [{body}];")


if __name__ == "__main__":
    main()
