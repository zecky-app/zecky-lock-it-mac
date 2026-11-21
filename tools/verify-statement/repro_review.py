#!/usr/bin/env python3
"""Andrew Miller's review cases, run against one real answer.

  python3 repro_review.py <answer.json> --challenge <c> --onion <asked .onion> [--reference "<your build>.app"]

Makes a changed copy of the answer for each case, runs verify_statement.py on
it, and prints one line per case: the original must pass, every changed copy
must fail. Nothing is sent anywhere.
"""
import argparse, base64, json, pathlib, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent


def run(data, args, onion=None):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(data, f)
    cmd = [sys.executable, str(HERE / "verify_statement.py"), f.name, "--challenge", args.challenge,
           "--onion", onion or args.onion]
    if args.reference:
        cmd += ["--reference", args.reference]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout.strip().splitlines()
    pathlib.Path(f.name).unlink()
    return out[-1] if out else "(no output)"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("answer"); p.add_argument("--challenge", required=True); p.add_argument("--onion", required=True)
    p.add_argument("--reference", default=None)
    args = p.parse_args()
    original = json.loads(pathlib.Path(args.answer).read_text())

    def changed(fn):
        d = json.loads(json.dumps(original)); fn(d); return d

    def client(d, fn):
        c = json.loads(d["clientDataJSON"]); fn(c)
        d["clientDataJSON"] = json.dumps(c, sort_keys=True, separators=(",", ":"))

    def att(d, old, new):
        key = "keyAttestation" if "keyAttestation" in d else "attestation"
        blob = base64.b64decode(d[key]); assert old in blob
        d[key] = base64.b64encode(blob.replace(old, new, 1)).decode()

    def code(d):
        cd = bytearray(base64.b64decode(d["codeIdentity"]["codeDirectory"])); cd[-1] ^= 1
        d["codeIdentity"]["codeDirectory"] = base64.b64encode(bytes(cd)).decode()

    cases = [
        ("original answer", "PASS", original, None),
        ("#3 signed provenance edited (Lock it build 999-evil)", "FAIL",
         changed(lambda d: client(d, lambda c: c["lockIt"].update(build="999-evil"))), None),
        ("#3 unsigned copy added (node build 999-evil, top level)", "PASS",
         changed(lambda d: d.update(node={"build": "999-evil"})), None),
        ("#4 key attestation environment swapped (production -> development)", "FAIL",
         changed(lambda d: att(d, b"appattest" + b"\0" * 7, b"appattestdevelop")), None),
        ("#6 fingerprint text edited", "FAIL",
         changed(lambda d: d.update(fingerprintJSON=d["fingerprintJSON"].replace('"height":', '"height":1'))) if original.get("fingerprintJSON") else None, None),
        ("#8 relayed: asked through another onion address", "FAIL", original, "a" * 56 + ".onion"),
        ("#2 code shown is not the code Apple attests", "FAIL", changed(code) if "codeIdentity" in original else None, None),
    ]
    bad = 0
    for name, want, data, onion in cases:
        if data is None:
            print(f"  --    {name}: not in this answer"); continue
        got = run(data, args, onion)
        ok = got.startswith(want)
        bad += not ok
        print(f"  {'ok' if ok else 'WRONG':5} {name}: {got}")
    print("all cases as expected" if not bad else f"{bad} case(s) not as expected")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
