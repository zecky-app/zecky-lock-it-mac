# Attested Go Max statements (experiment)

Status: prototype, 14 Nov 2026. Debug builds only, behind a developer switch
(Settings › About › Technical details). Not in TestFlight or release builds.
Inspired by work on attested apps in trusted
hardware; nothing on-chain is used here.

## The idea

Today a new Go Max node checks every block from the start, which takes hours.
In the future a new node could start from a recent state instead, if many
independent, genuine Go Max nodes confirm that state. This experiment builds
the first half: one caught-up Go Max node proves

> genuine, unmodified Lock it, on a real Apple device, says: at height H the
> chain state fingerprint is X.

## What was built and tested

1. **App Attest on the Mac.** `DCAppAttestService` works for a full Mac app
   from macOS 27. Tested on a MacBook Air with macOS 27.2 and Xcode 27.2.
   On macOS each key requires Full Security mode and System Integrity
   Protection; the certificate records this.
2. **State fingerprint v0** (`StateFingerprint` in `AttestedStatement.swift`),
   read from Zakura's RPC at the tip minus 100 blocks, with read calls only:
   - block hash and block commitments (`getblock`, verbosity 1)
   - Sapling, Orchard and Ironwood note commitment tree roots (`z_gettreestate`)
   - tree sizes, value pool totals and chain supply (`getblock`)

   Serialised as JSON with sorted keys and no spaces, hashed with SHA-256.
   Two reads of height 3,572,141 gave identical answers, and Swift and a
   separate Python check produce the same bytes (unit test).
3. **Attestation.** One App Attest key per installation. The first statement
   attests the key with `clientDataHash` = SHA-256 of the fingerprint; later
   statements are assertions by that key over their own fingerprint. The
   statement file holds the fingerprint, its hash, the height, the Zakura
   build, the Lock it version and build, the app ID read from the app's own
   signature, and the attestation or assertion.
4. **Verifier** (`tools/verify-statement`), Python, no server: Apple's
   certificate chain up to the pinned App Attestation Root CA, the app ID,
   that Apple's nonce or the key's signature covers exactly the fingerprint,
   the key ID, and the environment. Passed on an attestation (height
   3,572,187, counter 0) and an assertion (3,572,203, counter 1); a changed
   height or another app ID fails.

Seen in testing: a debug build asking for the development environment
received production evidence (AAGUID `appattest`), as also reported on
Apple's developer forums for macOS 27. The verifier reports the environment
it finds instead of assuming one.

## What a statement proves

That an app signed by the Zecky team, with the bundle ID `app.zecky.lockit`,
on an Apple device with App Attest and its security on, produced this
fingerprint at this height.

## What it does not prove

- **That the fingerprint is right.** A genuine app can read wrong data.
- **Which version or which source code made it.** App Attest identifies the
  team and bundle ID, not a build. Every build the team signs passes,
  including a modified one. Proving the code needs reproducible builds:
  anyone rebuilds the published source and gets the identical app.
- **That the data came from Lock it's own node.** Lock it reads the node on
  127.0.0.1:8232. Another program on that port could feed it data. Before
  attesting, Lock it must check that the process on the port is its own
  bundled `zakurad` (path and code signature). Not built yet.
- **A full chain state.** v0 does not cover the spent-note (nullifier) sets
  of each pool or the transparent coin set. No Zcash node offers a canonical
  fingerprint of those today. So v0 confirms a checkpoint ("this is the
  chain at height H"), not a state a new node could start from.

The trust it adds rests on Apple (its App Attest service and root
certificate) and on the Zecky team's signing key.

## Privacy

- **Apple, once per key.** Attesting a key contacts Apple's App Attest
  servers from the Mac's own IP address. The request is made by a macOS
  system service, so it cannot go through Lock it's Tor. Later statements
  (assertions) are made on the Mac and contact no one.
- **A lasting identifier.** Every statement carries the installation's key.
  Whoever collects statements can link them to one installation over time,
  and to an IP address if they are shared without Tor.
- **Nothing about the wallet.** Only public chain data is in a statement.

Therefore, if this ever ships: opt-in only (an explicit choice when Go Max
is switched on, never on by default), statements shared over Tor only, a new
key now and then to limit linking (each new key is one more contact with
Apple), and the Apple contact named plainly in How Go Max works.

## Towards a quorum

1. A new node asks several Go Max nodes, over Tor, for a statement at the
   same height, each answering a fresh random challenge (the challenge goes
   into the client data), so an old statement cannot be replayed.
2. It verifies each statement on its own computer, keeps only distinct keys,
   and checks that each key's counter only goes up.
3. It accepts a fingerprint only when enough independent nodes agree (for
   example 10 of 12) and none disagrees; any disagreement means it checks
   from the start instead.
4. Independence matters more than the count: one person with many Macs is
   still one party. App Attest limits fake keys per device, not per person.

Even with a quorum, a new node should keep checking the chain from the
agreed point onwards and, in the background, verify the history it skipped.

## What we would ask the Zebra team for

A canonical, deterministic fingerprint of the full chain state at a height:
each pool's note commitment tree, each pool's nullifier set and the
transparent coin set, computed the same way by every node (for example a
Merkle root per set). With that, v1 statements could confirm a state a new
node can actually start from, and nodes could compare state without
trusting each other.

## Not done

- Checking that the node on the port is Lock it's own `zakurad`.
- A challenge-response protocol over Go Max's connection.
- Production builds, the opt-in screen, and How Go Max works texts.
- Reproducible builds.
