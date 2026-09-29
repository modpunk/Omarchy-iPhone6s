#!/usr/bin/env python3
"""Run a shell command on the 6s Hoolock ramdisk over telnet (172.16.42.1:23).
Reads until a sentinel so output is complete. Exit 3 if the phone is unreachable."""
import os, socket, sys, time, uuid
HOST = os.environ.get("PHONE_HOST", "172.16.42.1")
def main():
    cmd = sys.argv[1]; timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 60
    try:
        s = socket.create_connection((HOST, 23), timeout=10)
    except OSError as e:
        print(f"phone unreachable: {e}", file=sys.stderr); sys.exit(3)
    tag = uuid.uuid4().hex[:8]
    buf = b""
    def pump(until, deadline):
        nonlocal buf
        while until not in buf:
            s.settimeout(max(0.1, deadline - time.time()))
            try: d = s.recv(65536)
            except socket.timeout: return False
            if not d: return False
            out = b""; i = 0; clean = b""
            while i < len(d):
                if d[i] == 255 and i + 2 < len(d):
                    c, o = d[i+1], d[i+2]
                    if c in (251, 252): out += bytes([255, 254, o])
                    elif c in (253, 254): out += bytes([255, 252, o])
                    i += 3; continue
                clean += d[i:i+1]; i += 1
            if out: s.sendall(out)
            buf += clean
        return True
    pump(b"# ", time.time() + 10)
    beg, end = f"__BEG_{tag}\n".encode(), f"__END_{tag}_".encode()
    s.sendall(f"printf '__BEG_%s\\n' {tag}; {cmd}; __rc=$?; echo; printf '__END_%s_%s\\n' {tag} $__rc\n".encode())
    ok = pump(end, time.time() + timeout)
    text = buf.replace(b"\r", b"")
    if not ok:
        sys.stdout.write(text.decode(errors="replace"))
        print(f"[phone.py] timed out after {timeout}s", file=sys.stderr); sys.exit(4)
    i = text.rfind(beg); j = text.rfind(end)
    body = text[i + len(beg):j] if i >= 0 else text[:j]
    rest = text[j + len(end):].split(b"\n")[0].strip()
    rc = int(rest) if rest.isdigit() else 0
    sys.stdout.write(body.decode(errors="replace").rstrip("\n") + "\n")
    sys.exit(rc)
main()
