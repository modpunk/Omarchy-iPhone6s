#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Build the device tree for a kexec reload and decide where every segment goes.

m1n1 fills in a lot of the DT at boot (memory, reserved-memory, framebuffer,
cpu-release-addr, chosen, serial number, disabled devices, ...). A freshly
compiled .dtb has none of that, so we carry m1n1's work over with a 3-way merge:

    delta = running (/sys/firmware/fdt)  -  base (the .dtb the running boot started from)
    out   = new .dtb  +  delta  +  reload overrides

Overrides: bootargs, initrd location, fresh kaslr-seed/rng-seed, the spin-table
park page (reserved-memory node "linux,spin-table-park" + cpu-release-addr), and
/chosen/fast-reload,base = sha256 of the new .dtb so the next reload can find its base.

No dependencies beyond the Python standard library.

  fdtmerge.py merge --base B.dtb --running R.dtb --new N.dtb --kernel Image \\
                    --initrd initrd.gz --park 0xADDR:0xSIZE [--cmdline STR] --out out.dtb
      prints KERNEL_ADDR= INITRD_ADDR= DTB_ADDR= PURG_ADDR= (shell), delta on stderr
  fdtmerge.py pick DIR R.dtb     print the .dtb in DIR whose root compatible matches R
  fdtmerge.py get R.dtb /path prop    print a string property (empty if missing)
  fdtmerge.py sha FILE           sha256 of a file (the base key)
"""
import hashlib
import os
import struct
import sys

FDT_MAGIC = 0xD00DFEED
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9

SZ_64K = 0x10000
SZ_2M = 0x200000


class Node:
    def __init__(self, name):
        self.name = name
        self.props = {}      # insertion ordered
        self.children = []

    def child(self, name):
        for c in self.children:
            if c.name == name:
                return c
        return None


class FDT:
    def __init__(self, root, rsv, boot_cpuid=0):
        self.root, self.rsv, self.boot_cpuid = root, rsv, boot_cpuid

    @staticmethod
    def load(path):
        data = open(path, "rb").read()
        (magic, total, off_struct, off_str, off_rsv, ver, _lc, boot_cpuid,
         size_str, size_struct) = struct.unpack_from(">10I", data, 0)
        if magic != FDT_MAGIC:
            raise SystemExit(f"{path}: not a flattened device tree")
        rsv, o = [], off_rsv
        while True:
            a, s = struct.unpack_from(">QQ", data, o)
            o += 16
            if a == 0 and s == 0:
                break
            rsv.append((a, s))
        strings = data[off_str:off_str + size_str]

        def sname(off):
            return strings[off:strings.index(b"\0", off)].decode()

        o, stack, root = off_struct, [], None
        while True:
            (tok,) = struct.unpack_from(">I", data, o)
            o += 4
            if tok == BEGIN_NODE:
                end = data.index(b"\0", o)
                n = Node(data[o:end].decode())
                o = (end + 4) & ~3
                if stack:
                    stack[-1].children.append(n)
                else:
                    root = n
                stack.append(n)
            elif tok == END_NODE:
                stack.pop()
            elif tok == PROP:
                ln, noff = struct.unpack_from(">II", data, o)
                o += 8
                stack[-1].props[sname(noff)] = data[o:o + ln]
                o = (o + ln + 3) & ~3
            elif tok == NOP:
                pass
            elif tok == END:
                break
            else:
                raise SystemExit(f"{path}: bad FDT token {tok:#x}")
        return FDT(root, rsv, boot_cpuid)

    def dump(self):
        strtab, stroff, st = bytearray(), {}, bytearray()

        def soff(name):
            if name not in stroff:
                stroff[name] = len(strtab)
                strtab.extend(name.encode() + b"\0")
            return stroff[name]

        def pad():
            while len(st) % 4:
                st.append(0)

        def emit(n):
            st.extend(struct.pack(">I", BEGIN_NODE))
            st.extend(n.name.encode() + b"\0")
            pad()
            for k, v in n.props.items():
                st.extend(struct.pack(">III", PROP, len(v), soff(k)))
                st.extend(v)
                pad()
            for c in n.children:
                emit(c)
            st.extend(struct.pack(">I", END_NODE))

        emit(self.root)
        st.extend(struct.pack(">I", END))
        rsv = b"".join(struct.pack(">QQ", a, s) for a, s in self.rsv) + bytes(16)
        off_rsv = 40
        off_struct = off_rsv + len(rsv)
        off_str = off_struct + len(st)
        total = off_str + len(strtab)
        hdr = struct.pack(">10I", FDT_MAGIC, total, off_struct, off_str, off_rsv,
                          17, 16, self.boot_cpuid, len(strtab), len(st))
        return hdr + rsv + bytes(st) + bytes(strtab)

    # path helpers -----------------------------------------------------
    def nodes(self):
        """[(path, node, parent_path)] in tree order."""
        res = []

        def walk(n, path, parent):
            res.append((path, n, parent))
            for c in n.children:
                walk(c, (path.rstrip("/") + "/" + c.name), path)

        walk(self.root, "/", None)
        return res

    def find(self, path):
        if path == "/":
            return self.root
        n = self.root
        for part in path.strip("/").split("/"):
            n = n.child(part)
            if n is None:
                return None
        return n

    def remove(self, path):
        parent = self.find(path.rsplit("/", 1)[0] or "/")
        name = path.rsplit("/", 1)[1]
        if parent is not None:
            parent.children = [c for c in parent.children if c.name != name]

    def phandles(self):
        m = {}
        for path, n, _ in self.nodes():
            for key in ("phandle", "linux,phandle"):
                if key in n.props and len(n.props[key]) == 4:
                    m[struct.unpack(">I", n.props[key])[0]] = path
        return m


def cells(n, name, default):
    v = n.props.get(name)
    return struct.unpack(">I", v)[0] if v and len(v) == 4 else default


def regs(fdt, path):
    """Decode reg of node at path using its parent's #address-cells/#size-cells."""
    n = fdt.find(path)
    parent = fdt.find(path.rsplit("/", 1)[0] or "/")
    if n is None or "reg" not in n.props:
        return []
    ac, sc = cells(parent, "#address-cells", 2), cells(parent, "#size-cells", 1)
    raw = n.props["reg"]
    words = struct.unpack(f">{len(raw) // 4}I", raw)
    out, step = [], ac + sc
    for i in range(0, len(words) - step + 1, step):
        a = s = 0
        for w in words[i:i + ac]:
            a = (a << 32) | w
        for w in words[i + ac:i + step]:
            s = (s << 32) | w
        out.append((a, s))
    return out


def enc_cells(value, ncells):
    return b"".join(struct.pack(">I", (value >> (32 * (ncells - 1 - i))) & 0xFFFFFFFF)
                    for i in range(ncells))


# Properties whose cells are (partly) phandles: name -> (stride, [phandle cell offsets])
PHANDLE_PROPS = {
    "interrupt-parent": (1, [0]),
    "memory-region": (1, [0]),
    "cpus": (1, [0]),
    "power-domains": (1, [0]),     # Apple PMGR: #power-domain-cells = 0
    "iommu-addresses": (5, [0]),   # <phandle iova(2) size(2)>
}


def three_way(base, running, new, log):
    """Apply running-minus-base onto new, in place. Returns #changes."""
    bp = {p: n for p, n, _ in base.nodes()}
    rp = {p: n for p, n, _ in running.nodes()}
    r_ph = running.phandles()
    n_ph_by_path = {v: k for k, v in new.phandles().items()}
    used = set(new.phandles())
    changes = 0

    def translate(name, val):
        spec = PHANDLE_PROPS.get(name)
        if not spec or len(val) % 4:
            return val
        stride, offs = spec
        words = list(struct.unpack(f">{len(val) // 4}I", val))
        for i in range(0, len(words), stride):
            for o in offs:
                if i + o < len(words):
                    path = r_ph.get(words[i + o])
                    if path is not None and path in n_ph_by_path:
                        words[i + o] = n_ph_by_path[path]
                    elif path is not None:
                        log(f"  warn: {name} references {path}, not in new DT")
        return struct.pack(f">{len(words)}I", *words)

    def setprop(path, n, k, v):
        nonlocal changes
        if k in ("phandle", "linux,phandle"):
            # Keep the new DT's own numbering; give loader-added phandles a free value.
            if "phandle" in n.props or "linux,phandle" in n.props:
                return
            (ph,) = struct.unpack(">I", v)
            if ph in used:
                ph = max(used | {0}) + 1
            used.add(ph)
            n_ph_by_path[path] = ph
            v = struct.pack(">I", ph)
        else:
            v = translate(k, v)
        if n.props.get(k) != v:
            n.props[k] = v
            changes += 1
            log(f"  set  {path}:{k} ({len(v)} bytes)")

    # Pass 1: create loader-added nodes and assign their phandles first, so
    # references from other properties can be translated in pass 2.
    for path, rn, parent in running.nodes():
        if path in bp or new.find(path) is not None:
            continue
        pn = new.find(parent)
        if pn is None:
            log(f"  skip {path}: parent missing in new DT")
            continue
        nn = Node(rn.name)
        pn.children.append(nn)
        changes += 1
        log(f"  add  {path}")
        for k in ("phandle", "linux,phandle"):
            if k in rn.props:
                setprop(path, nn, k, rn.props[k])

    for path, rn, _ in running.nodes():
        nn = new.find(path)
        if nn is None:
            continue
        bn = bp.get(path)
        for k, v in rn.props.items():
            if bn is None or bn.props.get(k) != v:
                setprop(path, nn, k, v)
        if bn is not None:
            for k in bn.props:
                if k not in rn.props and k in nn.props:
                    del nn.props[k]
                    changes += 1
                    log(f"  del  {path}:{k}")

    for path in bp:
        if path not in rp and new.find(path) is not None:
            new.remove(path)
            changes += 1
            log(f"  del  {path} (loader removed it)")

    # Memory reservations the loader added (secondary stacks, initrd, ...).
    r_initrd = None
    rc = running.find("/chosen")
    if rc is not None and "linux,initrd-start" in rc.props:
        s = int.from_bytes(rc.props["linux,initrd-start"], "big")
        e = int.from_bytes(rc.props.get("linux,initrd-end", b""), "big") if \
            "linux,initrd-end" in rc.props else s
        r_initrd = (s, e)
    for a, s in running.rsv:
        if (a, s) in base.rsv or (a, s) in new.rsv:
            continue
        if r_initrd and a < r_initrd[1] and r_initrd[0] < a + s:
            log(f"  drop memreserve {a:#x}+{s:#x} (old initrd)")
            continue
        new.rsv.append((a, s))
        changes += 1
        log(f"  add  memreserve {a:#x}+{s:#x}")
    return changes


def place(fdt, park, sizes):
    """Lowest-address placement of (name, size, align) inside /memory minus reservations."""
    mem = []
    for path, n, _ in fdt.nodes():
        if n.props.get("device_type") == b"memory\0":
            mem += regs(fdt, path)
    busy = list(fdt.rsv) + [park]
    rm = fdt.find("/reserved-memory")
    if rm is not None:
        for c in rm.children:
            busy += regs(fdt, "/reserved-memory/" + c.name)
    busy = [(a, a + s) for a, s in busy if s]
    out = {}
    taken = []
    for name, size, align in sizes:
        best = None
        for base, msize in sorted(mem):
            a, end = (base + align - 1) & ~(align - 1), base + msize
            while a + size <= end:
                clash = [e for s, e in busy + taken if a < e and s < a + size]
                if not clash:
                    best = a
                    break
                a = (max(clash) + align - 1) & ~(align - 1)
            if best is not None:
                break
        if best is None:
            raise SystemExit(f"no room for {name} ({size:#x} bytes)")
        out[name] = best
        taken.append((best, best + size))
    return out


def up(x, a):
    return (x + a - 1) & ~(a - 1)


def root_compat(fdt):
    return fdt.root.props.get("compatible", b"").split(b"\0")[0].decode()


def cmd_pick(d, running):
    want = root_compat(FDT.load(running))
    for f in sorted(os.listdir(d)):
        if f.endswith(".dtb"):
            try:
                if root_compat(FDT.load(os.path.join(d, f))) == want:
                    print(os.path.join(d, f))
                    return 0
            except (SystemExit, struct.error):
                pass
    print(f"no .dtb in {d} with compatible {want}", file=sys.stderr)
    return 1


def cmd_get(path, node, prop):
    n = FDT.load(path).find(node)
    v = n.props.get(prop, b"") if n is not None else b""
    print(v.rstrip(b"\0").decode(errors="replace"))
    return 0


def cmd_merge(a):
    log = (lambda m: print(m, file=sys.stderr))
    base, running, new = FDT.load(a["--base"]), FDT.load(a["--running"]), FDT.load(a["--new"])
    new_sha = hashlib.sha256(open(a["--new"], "rb").read()).hexdigest()
    if root_compat(new) != root_compat(running):
        raise SystemExit(f"new DT is {root_compat(new)}, phone runs {root_compat(running)}")
    if root_compat(base) != root_compat(running):
        raise SystemExit(f"base DT is {root_compat(base)}, phone runs {root_compat(running)}")
    log("carrying loader changes (running - base) into the new DT:")
    n = three_way(base, running, new, log)
    log(f"  {n} change(s)")

    park_addr, park_size = (int(x, 0) for x in a["--park"].split(":"))
    chosen = new.find("/chosen")
    if chosen is None:
        raise SystemExit("new DT has no /chosen")
    if "--cmdline" in a:
        chosen.props["bootargs"] = a["--cmdline"].encode() + b"\0"
    chosen.props["kaslr-seed"] = os.urandom(8)
    chosen.props["rng-seed"] = os.urandom(64)
    chosen.props["fast-reload,base"] = new_sha.encode() + b"\0"

    # Park page: the previous kernel's secondaries spin there (see the kernel patch).
    rm = new.find("/reserved-memory")
    if rm is None:
        raise SystemExit("new DT has no /reserved-memory")
    rm.children = [c for c in rm.children
                   if c.props.get("compatible", b"").split(b"\0")[0] != b"linux,spin-table-park"]
    ac, sc = cells(rm, "#address-cells", 2), cells(rm, "#size-cells", 2)
    pn = Node(f"spin-table-park@{park_addr:x}")
    pn.props["compatible"] = b"linux,spin-table-park\0"
    pn.props["reg"] = enc_cells(park_addr, ac) + enc_cells(park_size, sc)
    pn.props["no-map"] = b""
    rm.children.append(pn)
    cpus = new.find("/cpus")
    for c in (cpus.children if cpus else []):
        if c.name.startswith("cpu@") and "reg" in c.props:
            hwid = int.from_bytes(c.props["reg"], "big")
            c.props["cpu-release-addr"] = struct.pack(">Q", park_addr + 0x800 + 8 * (hwid & 0xFF))

    ksize = os.path.getsize(a["--kernel"])
    hdr = open(a["--kernel"], "rb").read(64)
    if hdr[56:60] != b"ARM\x64":
        raise SystemExit(f"{a['--kernel']}: not an arm64 Image")
    text_offset, image_size = struct.unpack_from("<QQ", hdr, 8)
    isize = os.path.getsize(a["--initrd"])

    # Placeholder initrd values have the final size, so the dtb size is final too.
    chosen.props["linux,initrd-start"] = bytes(8)
    chosen.props["linux,initrd-end"] = bytes(8)
    dsize = len(new.dump())
    at = place(new, (park_addr, park_size), [
        ("kernel", up(max(image_size, ksize) + text_offset, SZ_64K), SZ_2M),
        ("initrd", up(isize, SZ_64K), SZ_64K),
        ("dtb", up(dsize, SZ_64K), SZ_64K),
        ("purgatory", SZ_64K, SZ_64K),
    ])
    kaddr = at["kernel"] + text_offset
    chosen.props["linux,initrd-start"] = struct.pack(">Q", at["initrd"])
    chosen.props["linux,initrd-end"] = struct.pack(">Q", at["initrd"] + isize)
    blob = new.dump()
    assert len(blob) == dsize
    open(a["--out"], "wb").write(blob)
    print(f"KERNEL_ADDR={kaddr:#x}\nINITRD_ADDR={at['initrd']:#x}\n"
          f"DTB_ADDR={at['dtb']:#x}\nPURG_ADDR={at['purgatory']:#x}\nBASE_SHA={new_sha}")
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "pick":
        return cmd_pick(argv[2], argv[3])
    if len(argv) == 5 and argv[1] == "get":
        return cmd_get(argv[2], argv[3], argv[4])
    if len(argv) == 3 and argv[1] == "sha":
        print(hashlib.sha256(open(argv[2], "rb").read()).hexdigest())
        return 0
    if len(argv) >= 2 and argv[1] == "merge":
        a, i = {}, 2
        while i < len(argv):
            a[argv[i]] = argv[i + 1]
            i += 2
        need = ["--base", "--running", "--new", "--kernel", "--initrd", "--park", "--out"]
        missing = [k for k in need if k not in a]
        if missing:
            raise SystemExit("merge: missing " + " ".join(missing))
        return cmd_merge(a)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
