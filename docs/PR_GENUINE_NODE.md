<!-- Draft description for the pull request go-max → main. Paste it when
     opening the PR on GitHub. Not shown in the app. -->

# Genuine node: App Attest for p2p Go Max nodes

Go Max is open source and reachable over Tor, so a changed copy can look the
same from outside. With Genuine node on, a node proves it is genuine Lock it
on a real Mac: it answers a fresh challenge with a statement signed by an App
Attest key, and anyone can check it with `tools/verify-statement`, without a
Zecky server. Experimental and off by default.

How it works

- `GET /statement?challenge=<64 hex>[&height=H]` on 127.0.0.1:8139, published
  as an onion service by Arti 2.8.0 inside the app sandbox.
- The statement holds a fingerprint of the chain at a settled block (block
  hash, block commitments, Sapling/Orchard/Ironwood roots, tree sizes, pool
  totals, chain supply). App Attest signs the client data that holds the
  fingerprint's hash and the challenge, so an old answer cannot be replayed.
- A node never answers for another height: behind (409), unsettled (409),
  not kept (410), each with its tip.
- At most 6 statements a minute, 8 open connections, 10 s idle timeout.
- Before starting, Lock it checks the node it reads is its own (started on
  free ports, still running, `zakurad` signed by the same team). macOS does
  not let a sandboxed app inspect other processes, so a verifier has to take
  that check on trust.

Measurements (14–15 Nov 2026, MacBook Air, macOS 27.2, Zakura 1.8.5)

Asked from a Raspberry Pi 5 (Umbrel) over its own Tor, with a challenge made
on the Pi: answered at height 3,572,944 and verified (counter 7); the same
file against an earlier challenge failed. The Pi's own Zakura node, read at
that height, gave a byte-identical fingerprint (SHA-256 ea606cbd…f153), all
eleven fields. Named heights over Tor: 3,572,900 answered for exactly that
height, 4,000,000 refused as behind, 3,400,000 as not kept. Eight requests in
a row: 6 answered, 2 refused with 429. TestFlight build 8 (re-signed by Apple, App Attest production), asked from the
Pi over Tor on 15 Nov: answered at height 3,574,910 and verified; the
own-node check passed on the re-signed build. Build 7 had failed at the last
step, because it tried to sign with a key made by a development build; keys
are now kept per App Attest environment.

What it does not prove: which version or source code made the answer; that
needs reproducible builds. Both nodes in the comparison run the same Zakura
version, so it shows agreement, not independent software. Design note:
`docs/ATTESTED_STATEMENTS.md`.

Try it

```
HEIGHT=<H> ./tools/verify-statement/ask_over_tor.sh <address>.onion <team id>.app.zecky.lockit [socks port]
```
