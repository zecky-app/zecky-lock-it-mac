#!/usr/bin/env python3
"""Writes ZeckyLockIt/Acknowledgements.md: the open-source software that is
actually linked into Zecky Lock it for Mac, with each package's own LICENSE
and NOTICE text. Usage: scripts/notices.py <SourcePackages/checkouts folder>.
Regenerate after any dependency change (see docs/ENGINE.md). The list of
shipped packages below was taken from the app binary's symbols on 7 Nov 2026:
swift-crypto, swift-certificates, swift-asn1, swift-algorithms,
swift-async-algorithms, swift-http-types, swift-http-structured-headers,
swift-service-lifecycle, swift-system and swift-numerics are resolved but not
linked, so they are not listed."""
import json, os, sys

SHIPPED = [
    ("grpc-swift", "gRPC Swift"), ("swift-nio", "SwiftNIO"), ("swift-nio-ssl", "SwiftNIO SSL (includes BoringSSL)"),
    ("swift-nio-http2", "SwiftNIO HTTP/2"), ("swift-nio-extras", "SwiftNIO Extras"),
    ("swift-nio-transport-services", "SwiftNIO Transport Services"), ("swift-protobuf", "Swift Protobuf"),
    ("swift-log", "SwiftLog"), ("swift-atomics", "Swift Atomics"), ("swift-collections", "Swift Collections"),
    ("SQLite.swift", "SQLite.swift"),
]

OFL = open(os.path.join(os.path.dirname(__file__), "OFL-1.1.txt")).read()

LICENSES = os.path.join(os.path.dirname(__file__), "licenses")

def read(name):
    return open(os.path.join(LICENSES, name), encoding="utf-8").read()

def go_max():
    """The two programs Go Max ships inside the app (Contents/MacOS)."""
    return ["## Go Max: Zakura (zakurad) 1.8.5", "",
            "The Zcash node inside Go Max is Zakura 1.8.5 (github.com/zakura-core/zakura), a fork of the Zcash Foundation's Zebra, "
            "built from source and unchanged. Licensed under MIT OR Apache-2.0, at your option:", "",
            "```", read("zakura-LICENSE-MIT").strip(), "```", "", "```", read("zakura-LICENSE-APACHE").strip(), "```", "",
            "## Go Max: Zaino (zainod)", "",
            "The light-wallet server inside Go Max is Zaino by Zingo Labs (github.com/zingolabs/zaino), branch feat/nu7 at aaf8122, "
            "built from source with two small changes made for Rock it. Licensed under the Apache License, Version 2.0 "
            "(full text in the Zakura section above):", "",
            "```", read("zaino-LICENSE").strip("\n"), "```", "",
            "Both programs are built with their Rust dependencies, each under its own open-source license; every crate is listed in "
            "each project's Cargo.lock.", ""]

def main(checkouts):
    root = os.path.join(os.path.dirname(__file__), "..")
    resolved = json.load(open(os.path.join(root, "ZeckyLockIt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")))
    versions = {p["identity"]: p["state"].get("version", p["state"].get("revision", "")[:7]) for p in resolved["pins"]}
    out = ["# Acknowledgements", "",
           "Zecky Lock it for Mac includes the open-source software below. Only what is linked into the app is listed.", "",
           "## Zcash engine", "",
           "The Zecky engine v4.0.0-zecky.5 is the official zcash-swift-wallet-sdk 4.0.0 (MIT, Electric Coin Company and contributors) "
           "adapted to the NU7 releases of librustzcash, the Zcash developers' own core, and its Rust dependencies, published under "
           "MIT OR Apache-2.0. Every crate is listed in the engine's Cargo.lock.", ""]
    out += go_max()
    for folder, name in SHIPPED:
        d = os.path.join(checkouts, folder)
        out += [f"## {name} {versions.get(folder.lower(), '')}".rstrip(), ""]
        for f in ("LICENSE", "LICENSE.txt", "NOTICE.txt", "NOTICES.txt"):
            p = os.path.join(d, f)
            if os.path.exists(p):
                out += ["```", open(p, encoding="utf-8", errors="replace").read().strip(), "```", ""]
        if folder == "swift-nio-ssl":
            out += ["BoringSSL parts derived from OpenSSL are under the OpenSSL license "
                    "(https://www.openssl.org/source/license.html). This product includes cryptographic software written "
                    "by Eric Young (eay@cryptsoft.com) and software written by Tim Hudson (tjh@cryptsoft.com).", ""]
    out += ["## Inter (font)", "", "Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter).", "",
            "## Newsreader (font)", "", "Copyright 2020 The Newsreader Project Authors (https://github.com/productiontype/Newsreader).", "",
            "Both fonts are licensed under the SIL Open Font License, Version 1.1:", "", "```", OFL.strip(), "```", "",
            "## BIP 39 English word list", "",
            "From the Bitcoin Improvement Proposals repository (github.com/bitcoin/bips), BIP 39 by Marek Palatinus, Pavol Rusnak, "
            "Aaron Voisine and Sean Bowe.", ""]
    open(os.path.join(root, "ZeckyLockIt/Acknowledgements.md"), "w").write("\n".join(out))
    print("wrote", len(SHIPPED), "packages")

main(sys.argv[1])
