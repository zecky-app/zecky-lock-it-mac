#!/usr/bin/env python3
"""Verify a Zecky attested Go Max statement (experiment, format v0).

Checks, with no Zecky server involved:
  1. Apple's certificate chain: leaf <- intermediate <- the pinned Apple App
     Attestation Root CA (its SHA-256 is pinned below).
  2. The app: rpIdHash == SHA-256("<team id>.<bundle id>"), and that it is
     the app you expect (--app-id).
  3. The fingerprint: SHA-256 of the fingerprint text is the statement's hash,
     and Apple's nonce (attestation) or the key's signature (assertion)
     covers exactly that hash.
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
import sys

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT_PEM = pathlib.Path(__file__).with_name("apple_app_attestation_root_ca.pem")
# SHA-256 of Apple App Attestation Root CA (valid 2020-03-18 to 2045-03-15).
ROOT_SHA256 = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"
NONCE_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")
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


def load_root():
    pem = ROOT_PEM.read_bytes()
    root = x509.load_pem_x509_certificate(pem)
    found = root.fingerprint(hashes.SHA256()).hex()
    check(found == ROOT_SHA256, f"Apple App Attestation Root CA is the pinned one ({ROOT_SHA256[:16]}…)")
    return root


def within(cert, when):
    return cert.not_valid_before_utc <= when <= cert.not_valid_after_utc


def verify_attestation(blob, client_hash, key_id, app_id, when, root):
    """Apple's steps for an attestation object. Returns the attested public key."""
    obj, _ = cbor(blob)
    check(obj.get("fmt") == "apple-appattest", "format is apple-appattest")
    chain = obj["attStmt"]["x5c"]
    check(len(chain) == 2, "two certificates: leaf and intermediate")
    leaf = x509.load_der_x509_certificate(chain[0])
    intermediate = x509.load_der_x509_certificate(chain[1])
    try:
        intermediate.verify_directly_issued_by(root)
        leaf.verify_directly_issued_by(intermediate)
    except (InvalidSignature, ValueError, TypeError) as error:
        raise Failure(f"certificate chain does not verify: {error}")
    print("  ok  certificate chain: leaf <- intermediate <- Apple root (signatures)")
    check(within(intermediate, when) and within(leaf, when),
          f"certificates were valid when the statement was made ({when:%Y-%m-%d %H:%M} UTC)")
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
    return public


def verify_assertion(blob, client_hash, public, app_id):
    obj, _ = cbor(blob)
    auth = obj["authenticatorData"]
    nonce = hashlib.sha256(auth + client_hash).digest()
    try:
        public.verify(obj["signature"], nonce, ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise Failure("the key's signature does not cover this fingerprint")
    print("  ok  the attested key signed this fingerprint")
    check(auth[:32] == hashlib.sha256(app_id.encode()).digest(), f"app is {app_id}")
    counter = int.from_bytes(auth[33:37], "big")
    check(counter > 0, f"counter is {counter} (a later statement by the same key)")


def main():
    parser = argparse.ArgumentParser(description="Verify a Zecky attested Go Max statement (v0).")
    parser.add_argument("statement", help="the statement file (.json)")
    parser.add_argument("--app-id", required=True,
                        help='the app you expect, "<team id>.<bundle id>", e.g. ABCDE12345.app.zecky.lockit')
    args = parser.parse_args()
    data = json.loads(pathlib.Path(args.statement).read_text())
    print(f"Statement: {args.statement}")
    try:
        check(data.get("format") == "zecky-attested-statement/v0", "format zecky-attested-statement/v0")
        text = data["fingerprintJSON"].encode()
        client_hash = hashlib.sha256(text).digest()
        check(client_hash.hex() == data["fingerprintSHA256"], "fingerprint hash matches the fingerprint text")
        canonical = json.dumps(json.loads(text), sort_keys=True, separators=(",", ":")).encode()
        check(canonical == text, "fingerprint text is canonical (sorted keys, no spaces)")
        fingerprint = json.loads(text)
        check(fingerprint.get("height") == data.get("height"), f"height {data.get('height')}")
        check(data.get("appId") == args.app_id, f"statement names the expected app {args.app_id}")
        key_id = base64.b64decode(data["keyId"])
        when = datetime.datetime.fromisoformat(data["createdAt"].replace("Z", "+00:00"))
        root = load_root()
        if data.get("kind") == "attestation":
            verify_attestation(base64.b64decode(data["attestation"]), client_hash, key_id, args.app_id, when, root)
        elif data.get("kind") == "assertion":
            # The key's own attestation was made over an earlier fingerprint,
            # so its nonce is not checked here; the chain, the app, the key ID
            # and the environment are.
            att, _ = cbor(base64.b64decode(data["keyAttestation"]))
            leaf = x509.load_der_x509_certificate(att["attStmt"]["x5c"][0])
            intermediate = x509.load_der_x509_certificate(att["attStmt"]["x5c"][1])
            try:
                intermediate.verify_directly_issued_by(root)
                leaf.verify_directly_issued_by(intermediate)
            except (InvalidSignature, ValueError, TypeError) as error:
                raise Failure(f"the key's certificate chain does not verify: {error}")
            print("  ok  the key's certificate chain: leaf <- intermediate <- Apple root")
            public = leaf.public_key()
            point = public.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
            check(hashlib.sha256(point).digest() == key_id, "key ID is the SHA-256 of the attested public key")
            check(att["authData"][:32] == hashlib.sha256(args.app_id.encode()).digest(), f"key belongs to {args.app_id}")
            check(AAGUID.get(att["authData"][37:53]) is not None,
                  f"App Attest environment: {AAGUID.get(att['authData'][37:53])}")
            verify_assertion(base64.b64decode(data["assertion"]), client_hash, public, args.app_id)
        else:
            raise Failure("unknown statement kind")
    except (Failure, KeyError, ValueError) as error:
        print(f"FAIL  {error}")
        return 1
    print("PASS  genuine app, this fingerprint. (Not: that the fingerprint is right, or which code made it.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
