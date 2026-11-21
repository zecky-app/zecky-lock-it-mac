#!/usr/bin/env python3 -I
"""Signer-independent fingerprints of the code nested inside Lock it.

Andrew Miller's correction on issues #3 and #8: CDHashes of the helpers depend
on who signed them, so they cannot be pinned for self-builds or for TestFlight,
which signs the app again. This fingerprint does not depend on the signer:

  for each architecture slice of the Mach-O file: SHA-256 of the bytes up to
  the code signature (LC_CODE_SIGNATURE dataoff), with the three fields a
  signature changes set to zero: LC_CODE_SIGNATURE datasize and the
  __LINKEDIT segment's vmsize and filesize.

Checked on 21 Nov 2026: each helper gives the same fingerprint signed by the
linker (GoMax/bin), by Xcode for Debug, and by Apple Distribution (archive).

  scripts/nested-code-pins.py "path/to/Zecky Lock it.app"   writes the pins
      into ZeckyLockIt/GoMaxNode.swift (between the PINS markers)
  scripts/nested-code-pins.py --helpers GoMax/bin              updates only
      the three helper pins (gomax-helpers.sh does this)
  scripts/nested-code-pins.py --check NAME FILE              exit 0 if FILE
      matches the pinned fingerprint of NAME
  scripts/nested-code-pins.py --show FILE                    prints them

Lock it computes the same in Swift (NestedCode in GoMaxNode.swift) and refuses
to start a helper that does not match.
"""
import hashlib, re, struct, sys, pathlib

ITEMS = [
    ("zakurad", "MacOS/zakurad"),
    ("zainod", "MacOS/zainod"),
    ("arti", "MacOS/arti"),
    ("libswiftCompatibilitySpan.dylib", "Frameworks/libswiftCompatibilitySpan.dylib"),
    ("libzcashlc", "Frameworks/libzcashlc.framework/Versions/A/libzcashlc"),
]
ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT = ROOT / "ZeckyLockIt" / "GoMaxNode.swift"
LC_SEGMENT_64, LC_CODE_SIGNATURE = 0x19, 0x1D

def slices(d):
    magic = struct.unpack(">I", d[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        n = struct.unpack(">I", d[4:8])[0]
        for i in range(n):
            if magic == 0xCAFEBABE:
                _, _, off, size, _ = struct.unpack(">iiIII", d[8 + i * 20:28 + i * 20])
            else:
                _, _, off, size, _, _ = struct.unpack(">iiQQII", d[8 + i * 32:40 + i * 32])
            yield d[off:off + size]
    else:
        yield d

def slice_digest(m):
    if struct.unpack("<I", m[:4])[0] != 0xFEEDFACF:
        raise ValueError("not a 64-bit Mach-O slice")
    cputype, subtype, _, ncmds = struct.unpack("<IIII", m[4:20])
    b = bytearray(m); off = 32; limit = None
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", m[off:off + 8])
        if cmd == LC_CODE_SIGNATURE:
            limit = struct.unpack("<I", m[off + 8:off + 12])[0]
            b[off + 12:off + 16] = bytes(4)
        elif cmd == LC_SEGMENT_64 and m[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            b[off + 32:off + 40] = bytes(8)
            b[off + 48:off + 56] = bytes(8)
        off += size
    if limit is None:
        raise ValueError("not signed: sign it first (the fingerprint is taken up to the signature)")
    return f"{cputype}.{subtype}", hashlib.sha256(bytes(b[:limit])).hexdigest()

def digests(path):
    return dict(slice_digest(m) for m in slices(pathlib.Path(path).read_bytes()))

def pinned():
    block = re.search(r"// BEGIN PINS.*?// END PINS", SWIFT.read_text(), re.S).group(0)
    out = {}
    for name, body in re.findall(r'"([^"]+)": \[(.*?)\]', block, re.S):
        out[name] = dict(re.findall(r'"(\d+\.\d+)": "([0-9a-f]{64})"', body))
    return out

def matches(name, path):
    pins = pinned().get(name)
    found = digests(path)
    return bool(pins) and all(pins.get(k) == v for k, v in found.items()) and any(k.startswith("16777228.") for k in found)

def write(app=None, helpers=None):
    old = pinned() if helpers else {}
    lines = ["// BEGIN PINS (written by scripts/nested-code-pins.py; do not edit by hand)",
             "    static let pins: [String: [String: String]] = ["]
    for name, rel in ITEMS:
        if app:
            d = digests(pathlib.Path(app) / "Contents" / rel)
        elif rel.startswith("MacOS/") and (pathlib.Path(helpers) / name).exists():
            d = digests(pathlib.Path(helpers) / name)
        else:
            d = old.get(name, {})
        inner = ", ".join(f'"{k}": "{v}"' for k, v in sorted(d.items()))
        lines.append(f'        "{name}": [{inner}],')
    lines += ["    ]", "    // END PINS"]
    text = SWIFT.read_text()
    new = re.sub(r"// BEGIN PINS.*?// END PINS", "\n".join(lines), text, count=1, flags=re.S)
    SWIFT.write_text(new)
    print("\n".join(lines))

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--check"] and len(a) == 3:
        ok = matches(a[1], a[2])
        print(f"nested-code: {a[1]} {'matches its pin' if ok else 'does NOT match its pin'}")
        sys.exit(0 if ok else 1)
    if a[:1] == ["--show"] and len(a) == 2:
        for k, v in digests(a[1]).items(): print(k, v)
        sys.exit(0)
    if a[:1] == ["--helpers"] and len(a) == 2:
        write(helpers=a[1]); sys.exit(0)
    if len(a) == 1:
        write(app=a[0]); sys.exit(0)
    print(__doc__); sys.exit(2)
