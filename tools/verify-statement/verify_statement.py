#!/usr/bin/env python3
"""Verify a Zecky attested Go Max statement (experiment, formats v0 and v1).

Checks, with no Zecky server involved:
  1. Apple's certificate chain: leaf <- intermediate <- the pinned Apple App
     Attestation Root CA (its SHA-256 is pinned below).
  2. The app: rpIdHash == SHA-256("<team id>.<bundle id>"), and that it is
     the app you expect (--app-id).
  3. The fingerprint: SHA-256 of the fingerprint text is the statement's hash,
     and Apple's nonce (attestation) or the key's signature (assertion)
     covers exactly that hash. In v1 what is signed is the client data, which
     holds the fingerprint hash and the challenge; with --challenge the
     statement must answer exactly your challenge (so it is fresh).
  4. The key: the key ID is the SHA-256 of the attested public key.
It reports the App Attest environment (development or production).

What a pass means: an app signed by that team, with that bundle ID, on an
Apple device with App Attest, produced this fingerprint. It does not mean the
fingerprint is right, nor which version or source code of the app made it.

Needs Python 3.9+ and the `cryptography` package (pip install cryptography).
Licence: Apache-2.0, as the rest of Zecky Lock it.
"""

import argparse
import base64
import datetime
import hashlib
import json
import pathlib
import struct
import sys

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT_PEM = pathlib.Path(__file__).with_name("apple_app_attestation_root_ca.pem")
# SHA-256 of Apple App Attestation Root CA (valid 2020-03-18 to 2045-03-15).
ROOT_SHA256 = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"
NONCE_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")
# macOS: the access policy of the attested key in the security chip. Apple:
# trust a Mac's key only with exactly this value (SIP and full security on).
ACL_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.6")
ACL_MAC_SECURE = base64.b64decode(
    "MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB")
AAGUID = {
    b"appattestdevelop": "development",
    b"appattest" + b"\x00" * 7: "production",
}


class Failure(Exception):
    pass


def cbor(data, i=0):
    """A small CBOR decoder: the types App Attest uses, nothing more."""
    head = data[i]
    major, info = head >> 5, head & 31
    i += 1
    if info < 24:
        value = info
    elif info in (24, 25, 26, 27):
        n = {24: 1, 25: 2, 26: 4, 27: 8}[info]
        value = int.from_bytes(data[i:i + n], "big")
        i += n
    else:
        raise Failure("unsupported CBOR length")
    if major == 0:
        return value, i
    if major == 1:
        return -1 - value, i
    if major == 2:
        return data[i:i + value], i + value
    if major == 3:
        return data[i:i + value].decode(), i + value
    if major == 4:
        out = []
        for _ in range(value):
            item, i = cbor(data, i)
            out.append(item)
        return out, i
    if major == 5:
        out = {}
        for _ in range(value):
            key, i = cbor(data, i)
            out[key], i = cbor(data, i)
        return out, i
    raise Failure(f"unsupported CBOR type {major}")


def check(condition, message):
    if not condition:
        raise Failure(message)
    print(f"  ok  {message}")


def apple_facts(auth, attested):
    """What Apple's App Attest service put in the signed authenticator data:
    the app's build number, its validation category and, when the app opted
    in, the CDHash (the fingerprint of its exact code). Lock it cannot write
    these; the system service does."""
    if not auth[32] & 0x80:
        return {}
    offset = 37
    if attested:
        size = int.from_bytes(auth[53:55], "big")
        _, offset = cbor(auth, 55 + size)
    facts, _ = cbor(auth, offset)
    return facts if isinstance(facts, dict) else {}


def report_facts(facts, args):
    build = facts.get("apple_bundle_version_01")
    category = facts.get("apple_validation_category_01")
    cdhash = facts.get("apple_cd_hash_hash_01")
    if build is not None:
        print(f"  ok  Apple attests the app's build number: {build}")
    else:
        print("  --  no build number attested by Apple in this evidence")
    if isinstance(category, bytes) and len(category) == 4:
        print(f"  --  Apple validation category {int.from_bytes(category, 'little')}")
    if isinstance(cdhash, bytes):
        print(f"  ok  Apple attests the app's code fingerprint (CDHash): {cdhash.hex()}")
    else:
        print("  --  no code fingerprint (CDHash) attested: which exact code is not proven")
    if args.build is not None:
        check(str(build) == str(args.build), f"it is exactly build {args.build}")
    if args.cdhash is not None:
        check(isinstance(cdhash, bytes) and cdhash.hex() == args.cdhash.lower(), "it runs exactly the code you expect (CDHash)")


def load_root():
    pem = ROOT_PEM.read_bytes()
    root = x509.load_pem_x509_certificate(pem)
    found = root.fingerprint(hashes.SHA256()).hex()
    check(found == ROOT_SHA256, f"Apple App Attestation Root CA is the pinned one ({ROOT_SHA256[:16]}…)")
    return root


def within(cert, when):
    return cert.not_valid_before_utc <= when <= cert.not_valid_after_utc


def check_key_certificates(leaf, intermediate, root, when):
    """Apple's chain for the key, checked the way Apple intends: once, at the
    moment Apple attested the key. The leaf is valid for three days only; the
    key itself lives on in this Mac's security chip, and every later answer
    is signed by it. The intermediate must still be valid now (to 2030)."""
    try:
        intermediate.verify_directly_issued_by(root)
        leaf.verify_directly_issued_by(intermediate)
    except (InvalidSignature, ValueError, TypeError) as error:
        raise Failure(f"the key's certificate chain does not verify: {error}")
    print("  ok  the key's certificate chain: leaf <- intermediate <- Apple root (signatures)")
    attested = leaf.not_valid_before_utc + datetime.timedelta(seconds=60)
    check(within(leaf, attested) and within(intermediate, attested),
          f"Apple attested the key on {attested:%Y-%m-%d %H:%M} UTC, with valid certificates")
    check(attested <= when + datetime.timedelta(minutes=5), "the key was attested before the statement was made")
    now = datetime.datetime.now(datetime.timezone.utc)
    check(within(intermediate, now), f"Apple's intermediate certificate is still valid (until {intermediate.not_valid_after_utc:%Y-%m-%d})")
    try:
        raw = leaf.extensions.get_extension_for_oid(ACL_OID).value.value
    except x509.ExtensionNotFound:
        raise Failure("no macOS key access policy in Apple's certificate")
    # SEQUENCE { [3] { OCTET STRING { policy } } }
    check(raw == bytes.fromhex("3046a3440442") + ACL_MAC_SECURE,
          "the Mac had System Integrity Protection and full security on (Apple's key policy)")


def verify_attestation(blob, client_hash, key_id, app_id, when, root):
    """Apple's steps for an attestation object. Returns the attested public key."""
    obj, _ = cbor(blob)
    check(obj.get("fmt") == "apple-appattest", "format is apple-appattest")
    chain = obj["attStmt"]["x5c"]
    check(len(chain) == 2, "two certificates: leaf and intermediate")
    leaf = x509.load_der_x509_certificate(chain[0])
    intermediate = x509.load_der_x509_certificate(chain[1])
    check_key_certificates(leaf, intermediate, root, when)
    auth = obj["authData"]
    nonce = hashlib.sha256(auth + client_hash).digest()
    ext = leaf.extensions.get_extension_for_oid(NONCE_OID).value.value
    # SEQUENCE { [1] { OCTET STRING (32) } }
    check(ext[:6] == bytes.fromhex("3024a1220420") and ext[6:] == nonce,
          "Apple's nonce covers this fingerprint (SHA-256 of authData and the fingerprint hash)")
    public = leaf.public_key()
    point = public.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    check(hashlib.sha256(point).digest() == key_id, "key ID is the SHA-256 of the attested public key")
    check(auth[:32] == hashlib.sha256(app_id.encode()).digest(), f"app is {app_id}")
    check(int.from_bytes(auth[33:37], "big") == 0, "counter is 0 (a fresh attestation)")
    environment = AAGUID.get(auth[37:53])
    check(environment is not None, f"App Attest environment: {environment}")
    cred_len = int.from_bytes(auth[53:55], "big")
    check(auth[55:55 + cred_len] == key_id, "credential ID is the key ID")
    return public, auth


def verify_assertion(blob, client_hash, public, app_id):
    obj, _ = cbor(blob)
    auth = obj["authenticatorData"]
    nonce = hashlib.sha256(auth + client_hash).digest()
    try:
        public.verify(obj["signature"], nonce, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise Failure("the key's signature does not cover this answer (its signed data was changed)")
    print("  ok  the attested key signed this answer")
    check(auth[:32] == hashlib.sha256(app_id.encode()).digest(), f"app is {app_id}")
    counter = int.from_bytes(auth[33:37], "big")
    check(counter > 0, f"counter is {counter} (a later statement by the same key)")
    return auth


# --- Code identity (issue #2, Andrew Miller's correction) ------------------
# Each answer from build 12 on carries, for the arm64 slice of Lock it's own
# program: the SHA-256 CodeDirectory, its first page, and the DER entitlements.
CS_MAGIC_EMBEDDED = 0xFADE0CC0; CS_MAGIC_CD = 0xFADE0C02; CS_MAGIC_DER_ENT = 0xFADE7172
ARM64 = 16777228
# Entitlements that name who signed, not what the code is; and the one Apple
# adds when it signs a build for TestFlight (seen on build 12, 21 Nov 2026).
IDENTITY_KEYS = {"application-identifier", "com.apple.application-identifier",
                 "com.apple.developer.team-identifier", "keychain-access-groups",
                 "beta-reports-active"}

def macho_slices(d):
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

def load_commands(m):
    ncmds = struct.unpack("<I", m[16:20])[0]; off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", m[off:off + 8]); yield cmd, off, size; off += size

def code_identity(path, cputype=ARM64, subtype=0):
    """From a signed Mach-O: the SHA-256 CodeDirectory, page 0 and the DER entitlements blob."""
    d = open(path, "rb").read()
    for m in macho_slices(d):
        ct, st = struct.unpack("<II", m[4:12])
        if ct != cputype or (st & 0x00FFFFFF) != subtype:
            continue
        sig = next(((struct.unpack("<II", m[o + 8:o + 16])) for c, o, s in load_commands(m) if c == 0x1D), None)
        if not sig: raise ValueError("not signed")
        blob = m[sig[0]:sig[0] + sig[1]]
        magic, length, count = struct.unpack(">III", blob[:12])
        assert magic == CS_MAGIC_EMBEDDED
        cds, ent = [], None
        for i in range(count):
            typ, off = struct.unpack(">II", blob[12 + i * 8:20 + i * 8])
            bm, bl = struct.unpack(">II", blob[off:off + 8])
            if bm == CS_MAGIC_CD: cds.append(blob[off:off + bl])
            elif bm == CS_MAGIC_DER_ENT: ent = blob[off:off + bl]
        cd = next((c for c in cds if c[37] == 2), None)  # hashType SHA-256
        if cd is None: raise ValueError("no SHA-256 CodeDirectory")
        page = 1 << cd[39]
        return {"codeDirectory": cd, "page0": m[:page], "entitlements": ent}
    raise ValueError("no arm64 slice")

def parse_cd(cd):
    (magic, length, version, flags, hashOffset, identOffset, nSpecial, nCode, codeLimit,
     hashSize, hashType, platform, pageSize) = struct.unpack(">IIIIIIIIIBBBB", cd[:40])
    assert magic == CS_MAGIC_CD and hashSize == 32
    slots = [cd[hashOffset + i * 32:hashOffset + (i + 1) * 32] for i in range(nCode)]
    special = {k: cd[hashOffset - k * 32:hashOffset - (k - 1) * 32] for k in range(1, nSpecial + 1)}
    return dict(version=version, flags=flags, codeLimit=codeLimit, pageSize=1 << pageSize,
                slots=slots, special=special,
                identifier=cd[identOffset:].split(b"\0")[0].decode())

def mask_page0(p):
    b = bytearray(p); ncmds = struct.unpack("<I", p[16:20])[0]; off = 32
    for _ in range(ncmds):
        if off + 8 > len(p): break
        cmd, size = struct.unpack("<II", p[off:off + 8])
        if cmd == 0x1D: b[off + 12:off + 16] = bytes(4)
        elif cmd == 0x19 and p[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            b[off + 32:off + 40] = bytes(8); b[off + 48:off + 56] = bytes(8)
        off += size
    return bytes(b)

def der(data, i=0):
    tag = data[i]; i += 1; ln = data[i]; i += 1
    if ln & 0x80:
        n = ln & 0x7F; ln = int.from_bytes(data[i:i + n], "big"); i += n
    return tag, data[i:i + ln], i + ln

def der_value(tag, body):
    if tag == 0x0C: return body.decode()
    if tag == 0x01: return body != b"\0"
    if tag == 0x02: return int.from_bytes(body, "big", signed=True)
    if tag in (0x30, 0x31):  # sequence of values
        out, i = [], 0
        while i < len(body):
            t, b, i = der(body, i); out.append(der_value(t, b))
        return out
    if tag in (0xB0, 0x70) or tag & 0x20:  # dictionary [APPLICATION 16] / context
        out, i = {}, 0
        while i < len(body):
            t, b, i = der(body, i)          # SEQUENCE { key, value }
            _, k, j = der(b, 0); vt, vb, _ = der(b, j)
            out[k.decode()] = der_value(vt, vb)
        return out
    return body.hex()

def entitlements(blob):
    """DER entitlements blob (magic, length, DER) -> dict."""
    _, length = struct.unpack(">II", blob[:8])
    body = blob[8:length]
    tag, inner, _ = der(body)          # [APPLICATION 16] { INTEGER 1, [CONTEXT 16] dict }
    _, _, j = der(inner, 0)            # version
    t, d, _ = der(inner, j)
    return der_value(0xB0, d)


def app_id_of(ent):
    return ent.get("com.apple.application-identifier") or ent.get("application-identifier")


def check_code_identity(data, cdhash, rp_id_hash, reference):
    """The code the answer shows is the code Apple attests; with a reference
    build, that it is the same code. Returns the app ID from the entitlements."""
    shown = data["codeIdentity"]
    check(shown.get("slice") == "16777228.0", "it shows the code of its Apple silicon slice")
    cd_blob = base64.b64decode(shown["codeDirectory"])
    page0 = base64.b64decode(shown["page0"])
    ent_blob = base64.b64decode(shown["entitlements"])
    check(isinstance(cdhash, bytes) and hashlib.sha256(cd_blob).digest() == cdhash,
          "SHA-256 of the CodeDirectory it shows is the CDHash Apple attests in this answer")
    cd = parse_cd(cd_blob)
    check(len(page0) == cd["pageSize"] and hashlib.sha256(page0[:min(cd["pageSize"], cd["codeLimit"])]).digest() == cd["slots"][0],
          "its first page is the one the CodeDirectory hashes (slot 0)")
    check(cd["special"].get(7) == hashlib.sha256(ent_blob).digest(),
          "its entitlements are the ones the CodeDirectory hashes (special slot 7)")
    ent = entitlements(ent_blob)
    app_id = app_id_of(ent)
    check(app_id and hashlib.sha256(app_id.encode()).digest() == rp_id_hash,
          f"Apple's rpIdHash is SHA-256 of its application-identifier ({app_id})")
    print(f"  --  code: {len(cd['slots'])} pages of {cd['pageSize']} bytes, code limit {cd['codeLimit']}, flags {cd['flags']:#x}")
    if reference:
        ref = code_identity(str(pathlib.Path(reference) / "Contents" / "MacOS" / "Zecky Lock it")
                            if pathlib.Path(reference).is_dir() else reference)
        compare_code({"codeDirectory": cd_blob, "page0": page0, "entitlements": ent_blob}, ref, "the answer", "your build")
    else:
        print("  --  pass --reference \"Your build.app\" (built from the published source) to check which code this is")
    return app_id


def compare_code(a, b, name_a, name_b):
    ca, cb = parse_cd(a["codeDirectory"]), parse_cd(b["codeDirectory"])
    check(ca["codeLimit"] == cb["codeLimit"], f"same code limit ({name_a} {ca['codeLimit']}, {name_b} {cb['codeLimit']})")
    check(ca["flags"] == cb["flags"], f"same CodeDirectory flags ({name_a} {ca['flags']:#x}, {name_b} {cb['flags']:#x})")
    differ = [i for i, (x, y) in enumerate(zip(ca["slots"], cb["slots"])) if i and x != y]
    check(len(ca["slots"]) == len(cb["slots"]) and not differ,
          f"every page but the first is the same ({len(ca['slots']) - 1} pages)"
          + (f"; first different page {differ[0]}" if differ else ""))
    check(mask_page0(a["page0"]) == mask_page0(b["page0"]), "the first page is the same, signer fields zeroed")
    ea = {k: v for k, v in entitlements(a["entitlements"]).items() if k not in IDENTITY_KEYS}
    eb = {k: v for k, v in entitlements(b["entitlements"]).items() if k not in IDENTITY_KEYS}
    check(ea == eb, "the entitlements are the same, apart from team, app ID and TestFlight's beta-reports-active"
          + ("" if ea == eb else f"; differ: {sorted(k for k in set(ea) | set(eb) if ea.get(k) != eb.get(k))}"))


def main():
    parser = argparse.ArgumentParser(description="Verify a Zecky attested Go Max statement (v3; older formats are refused).")
    parser.add_argument("statement", nargs="?", help="the statement file (.json)")
    parser.add_argument("--challenge", default=None,
                        help="the 64-hex challenge you sent: the statement must answer exactly this")
    parser.add_argument("--height", type=int, default=None,
                        help="the block height you asked for (&height=H): the fingerprint must be for exactly this height")
    parser.add_argument("--app-id", default=None,
                        help='the app you expect, "<team id>.<bundle id>", e.g. ABCDE12345.app.zecky.lockit; '
                             'optional when the answer shows its code (then taken from its entitlements)')
    parser.add_argument("--reference", default=None,
                        help="your own build of the published source (the .app, or its program): "
                             "checks the answer runs exactly that code, whoever signed it")
    parser.add_argument("--compare-apps", nargs=2, metavar=("A", "B"), default=None,
                        help="compare the code of two builds (rebuild check) and exit")
    parser.add_argument("--onion", default=None,
                        help="the onion address you asked: the signed answer must name exactly it (not relayed)")
    parser.add_argument("--build", default=None,
                        help="the build number you expect, as Apple attests it (e.g. 9)")
    parser.add_argument("--cdhash", default=None,
                        help="the code fingerprint (CDHash, hex) you expect, as Apple attests it")
    args = parser.parse_args()
    if args.compare_apps:
        try:
            a, b = (code_identity(str(pathlib.Path(x) / "Contents" / "MacOS" / "Zecky Lock it") if pathlib.Path(x).is_dir() else x)
                    for x in args.compare_apps)
            compare_code(a, b, "A", "B")
        except (Failure, ValueError) as error:
            print(f"FAIL  {error}")
            return 1
        print("PASS  same code (whoever signed each)")
        return 0
    if not args.statement:
        parser.error("a statement file is needed")
    data = json.loads(pathlib.Path(args.statement).read_text())
    shows_code = "codeIdentity" in data
    if args.app_id is None and not shows_code:
        parser.error("--app-id is needed for answers that do not show their code (build 11 and older)")
    print(f"Statement: {args.statement}")
    try:
        version = data.get("format")
        if version in ("zecky-attested-statement/v0", "zecky-attested-statement/v1", "zecky-attested-statement/v2"):
            raise Failure(f"older answer format ({version.rsplit('/', 1)[1]}): where it came from is not signed (issue #3)")
        check(version == "zecky-attested-statement/v3", f"format {version}")
        # Everything below is read from the signed client data only.
        client = data["clientDataJSON"].encode()
        client_data = json.loads(client)
        canonical_client = json.dumps(client_data, sort_keys=True, separators=(",", ":")).encode()
        check(canonical_client == client, "client data is canonical (sorted keys, no spaces)")
        check(client_data.get("v") == 3 and client_data.get("purpose") == "zecky-go-max-state",
              "client data is for a Go Max state statement (v3)")
        check(client_data.get("challenge") == data.get("challenge", ""), "client data carries the statement's challenge")
        if args.challenge is not None:
            check(client_data.get("challenge") == args.challenge.lower(), "it answers exactly your challenge (fresh)")
        elif client_data.get("challenge"):
            print("  --  a challenge is present; pass --challenge to check it was yours")
        else:
            print("  --  no challenge: nobody asked for this statement, so it may not be fresh")
        if args.onion is not None:
            check(client_data.get("onion") == args.onion.lower(),
                  f"it names the onion address you asked ({args.onion[:12]}…), so it is not relayed")
        else:
            print(f"  --  signed onion address: {client_data.get('onion') or '(none)'}; pass --onion to check it is the one you asked")
        if args.app_id is None:
            args.app_id = client_data.get("appId")
            print(f"  --  signed app {args.app_id}: checked below against Apple's rpIdHash and the code's entitlements")
        else:
            check(client_data.get("appId") == args.app_id, f"signed app is the expected app {args.app_id}")
        fingerprint_hash = client_data.get("fingerprintSHA256", "")
        has_fingerprint = bool(data.get("fingerprintJSON"))
        if has_fingerprint:
            text = data["fingerprintJSON"].encode()
            check(hashlib.sha256(text).hexdigest() == fingerprint_hash, "fingerprint text matches the signed hash")
            canonical = json.dumps(json.loads(text), sort_keys=True, separators=(",", ":")).encode()
            check(canonical == text, "fingerprint text is canonical (sorted keys, no spaces)")
            fingerprint = json.loads(text)
            print(f"  --  fingerprint (signed) at height {fingerprint.get('height')}")
            cross = client_data.get("crossCheck") or {}
            check(cross.get("result") == "agrees",
                  f"the node's tree state agreed with an independent server ({cross.get('server') or 'none'}) before it was signed")
            check((client_data.get("nodeCheck") or {}).get("dataUnchangedSinceLockIt") is True,
                  "the node's data is as Lock it sealed it at its last clean stop")
        else:
            check(fingerprint_hash == "", "no fingerprint, and none signed")
            print(f"  --  no chain fingerprint ({data.get('fingerprintNote', 'none')}): this answer proves genuine only")
            cross = client_data.get("crossCheck")
            if cross:
                print(f"  --  signed cross-check: {cross.get('result')} ({cross.get('server') or 'no server reached'})")
        if args.height is not None:
            check(has_fingerprint and fingerprint.get("height") == args.height,
                  f"it carries a fingerprint for exactly the height you asked ({args.height})")
        node = client_data.get("node") or {}
        state = node.get("state")
        if state == "up-to-date":
            print(f"  --  node state (signed): up to date at block {node.get('tip')}")
        elif state == "syncing":
            print(f"  --  node state (signed): syncing, at block {node.get('tip')} of about {node.get('estimate')}")
        else:
            print(f"  --  node state (signed): {state}")
        lock_it = client_data.get("lockIt") or {}
        print(f"  --  signed: Lock it {lock_it.get('version')} ({lock_it.get('build')}), node {node.get('build')} {node.get('subversion')}")
        if (client_data.get("nodeCheck") or {}).get("ownNode"):
            print("  --  signed: Lock it checked the node was its own (Lock it's own check, see issue #6 for limits)")
        client_hash = hashlib.sha256(client).digest()
        key_id = base64.b64decode(data["keyId"])
        when = datetime.datetime.fromisoformat(client_data["createdAt"].replace("Z", "+00:00"))
        root = load_root()
        if data.get("kind") == "attestation":
            _, auth = verify_attestation(base64.b64decode(data["attestation"]), client_hash, key_id, args.app_id, when, root)
            facts = apple_facts(auth, True)
            report_facts(facts, args)
        elif data.get("kind") == "assertion":
            # The key's own attestation was made over an earlier answer. Its
            # data (environment, credential) only counts once its nonce, over
            # the client data it was made for, is in Apple's certificate
            # (issue #4). Older answers do not carry that client data.
            key_client = data.get("keyAttestationClientDataJSON")
            if key_client is None:
                raise Failure("older answer format: the key attestation is not bound (no keyAttestationClientDataJSON)")
            att, _ = cbor(base64.b64decode(data["keyAttestation"]))
            leaf = x509.load_der_x509_certificate(att["attStmt"]["x5c"][0])
            intermediate = x509.load_der_x509_certificate(att["attStmt"]["x5c"][1])
            check_key_certificates(leaf, intermediate, root, when)
            key_nonce = hashlib.sha256(att["authData"] + hashlib.sha256(key_client.encode()).digest()).digest()
            ext = leaf.extensions.get_extension_for_oid(NONCE_OID).value.value
            check(ext[:6] == bytes.fromhex("3024a1220420") and ext[6:] == key_nonce,
                  "the key attestation is bound: Apple's nonce covers its data and the client data it was made for")
            public = leaf.public_key()
            point = public.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
            check(hashlib.sha256(point).digest() == key_id, "key ID is the SHA-256 of the attested public key")
            check(att["authData"][:32] == hashlib.sha256(args.app_id.encode()).digest(), f"key belongs to {args.app_id}")
            check(AAGUID.get(att["authData"][37:53]) is not None,
                  f"App Attest environment: {AAGUID.get(att['authData'][37:53])}")
            cred_len = int.from_bytes(att["authData"][53:55], "big")
            check(att["authData"][55:55 + cred_len] == key_id, "credential ID is the key ID")
            auth = verify_assertion(base64.b64decode(data["assertion"]), client_hash, public, args.app_id)
            # Apple's facts from this answer's signed data only: a key attested
            # by one build can be used by another (issue #2).
            facts = apple_facts(auth, False)
            report_facts(facts, args)
        else:
            raise Failure("unknown statement kind")
        if shows_code:
            app = check_code_identity(data, facts.get("apple_cd_hash_hash_01"), auth[:32], args.reference)
            check(app == args.app_id, f"the code's entitlements name the signed app ({app})")
        else:
            print("  --  the answer does not show its code (build 11 and older): which code made it is not checked")
    except (Failure, KeyError, ValueError) as error:
        print(f"FAIL  {error}")
        return 1
    if has_fingerprint:
        print("PASS  genuine app, this fingerprint. (Not: that the fingerprint is right, or which code made it unless --reference or --cdhash was checked.)")
    else:
        print("PASS  genuine app. (No chain fingerprint in this answer.)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
