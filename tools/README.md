# tools

Parsers for Apple's flattened device tree (the "ADT" iBoot hands the kernel).
They read a raw ADT dump; the dump itself is Apple's and is never committed here.

| script   | what it does |
|----------|--------------|
| `adt.py`  | print the node tree with each node's `compatible` list |
| `adt2.py` | dump every property of the named node(s): `adt2.py <adt.bin> uart5 gas-gauge` |

## Getting the ADT for the iPhone 6s

1. Download the iOS restore image for your model from Apple, e.g.
   `iPhone_4.7_15.8.8_19H422_Restore.ipsw` (iPhone 6s, iOS 15.8.8). Keep it outside this repo.
2. Pull the device tree out of the IPSW (it is a zip):

   ```sh
   unzip -j iPhone_4.7_15.8.8_19H422_Restore.ipsw Firmware/all_flash/DeviceTree.n71ap.im4p
   # DeviceTree.n71map.im4p is the TSMC (N71mAP, s8003) variant
   ```
3. Unwrap the IMG4 payload with [pyimg4](https://github.com/m1stadev/PyIMG4):

   ```sh
   python3 -m venv .venv && .venv/bin/pip install pyimg4
   .venv/bin/pyimg4 im4p extract -i DeviceTree.n71ap.im4p -o n71ap-apple-dt.bin
   ```
4. Explore it:

   ```sh
   python3 tools/adt.py  n71ap-apple-dt.bin | less
   python3 tools/adt2.py n71ap-apple-dt.bin multi-touch
   ```

`n71ap-apple-dt.bin`, `*.im4p` and `*.ipsw` are in `.gitignore`. Don't commit them,
or any text dump of them. Summarize facts in `docs/` instead.
