# Attested Go Max statements (experiment)

Status: experimental, from build 7 (Nov 2026) in TestFlight builds too, off
by default. Settings › Go Max shows it as a card marked Experimental once the
node has data. The first switch-on shows what is shared, the one contact with
Apple, and that statements can be linked to each other; nothing starts
without that. On a Mac below macOS 27, or one without App Attest (reduced
security, a virtual machine), the switches are disabled and the card says
why. Debug builds ask App Attest for its development environment, release
builds for production. Inspired by Andrew Miller's work on attested apps in
trusted hardware (with his permission); nothing on-chain is used here.

## The idea

Go Max is open source and reachable over Tor, so anyone can build a changed
copy that looks the same from outside: one that hides a payment, gives a
wrong chain, or logs which wallets ask about what. Whoever talks to a node (a
wallet, a phone, another node) has to trust that it runs the code it claims. The core of
this experiment is validation: a Go Max node can prove

> genuine Lock it, signed by the Zecky team, on a real Apple device with its
> security on, gives this answer to your fresh question,

and anyone can check that proof without a Zecky server. In Lock it this is
the "Genuine node" card on the Go Max page.

On top of that, as an experimental feature, each answer carries a
fingerprint of the chain at a settled block ("at height H the chain state
fingerprint is X"). Today a new Go Max node checks every block from the
start, which takes hours; later it could start from a recent point that many
genuine nodes confirm. Nothing uses those confirmations yet.

Decided 14 Nov 2026: off by default while it is tested (from build 7, a
switch on the Go Max page). Once proven, and once something checks it (first
the iPhone at pairing), it is on by default with Go Max, without a separate
switch, and the Go Max explanation says plainly that it contacts Apple once.

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
- **That the data came from Lock it's own node, as a fact anyone can check.**
  Lock it reads the node on 127.0.0.1:8232. Before attesting it checks that
  it found Go Max's ports free, started the `zakurad` inside Lock it on them,
  that this node is still running, and that the `zakurad` file is validly
  signed by the same team; only then does it make a statement, and it says so
  in it. macOS does not let a sandboxed app inspect other processes, not even
  its own children (tried: EPERM), so Lock it cannot look at the listening
  process itself, and a verifier has to take the check on trust.
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
- **The onion address only (rule, 16 Nov 2026).** Genuine node answers on
  127.0.0.1 behind its onion service, never on the node's peer-to-peer port
  (which listens on 127.0.0.1 too and accepts no outside connections) and
  never on the home IP address, so nobody can link a home address to an
  attested node. Asking another node also goes over Tor only.

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

## Fresh challenges (format v1)

From v1 App Attest signs client data, not the fingerprint alone: sorted
compact JSON of the fingerprint hash, a 32-byte challenge from whoever asks,
the purpose `zecky-go-max-state` and the version. With the developer switch on,
a debug build answers `GET /statement?challenge=<64 hex>` on 127.0.0.1:8139,
this Mac only, one at a time; `verify_statement.py --challenge` checks the
answer is for exactly that challenge. Tested on 14 Nov 2026: the answer to a
fresh challenge passed (assertion, counter 4); the same statement against
another challenge failed, and a challenge swapped inside the file broke the
key's signature.

## Over Tor

With "Answer over Tor too" on (Technical details, debug builds only), Lock
it starts Arti 2.8.0 (the Tor Project's Tor in Rust) inside its sandbox and
publishes an onion service whose port 80 forwards to the challenge endpoint
on 127.0.0.1:8139. The onion key is made on the first start and kept in
Lock it's own folder, so the address stays the same. Arti is put into Debug
builds only, after a check against its pinned SHA-256 (`GoMax/arti.sha256`);
`scripts/gomax-helpers.sh` refuses any helper that needs libraries outside
macOS, because the sandbox blocks loading them (seen: a Homebrew liblzma;
Arti is now built with `LZMA_API_STATIC=1`). Arti's log is GoMax/logs/arti.log
and every statement or refused request is a line in GoMax/logs/attest.log.

Tested on 14 Nov 2026, from the same Mac through Lock it's own Arti (SOCKS
port 9150): a fresh challenge sent to the onion address was answered with a
v1 assertion (height 3,572,357, counter 5) that passed
`verify_statement.py --challenge`; the same statement against another
challenge failed.

Lock it can also ask: with Tor answering, Technical details takes another
node's onion address, sends it a fresh challenge through Lock it's own Arti
(the onion name is resolved by Tor, not on this Mac), checks the answer is a
v1 statement for exactly that challenge, and saves it in GoMax/logs for
`verify_statement.py`. `tools/verify-statement/ask_over_tor.sh` does the same
from any computer with Tor. Tested on 14 Nov 2026 with Lock it asking its own
onion address through Tor: answered at height 3,572,764 (counter 6) and the
saved file passed `verify_statement.py --challenge` with the challenge from
attest.log; another challenge failed.

Tested on 14 Nov 2026 from another computer: an Umbrel (Raspberry Pi 5) on
the same home network asked the Mac's onion address through its own Tor
(umbrelOS's Tor proxy, with a throwaway curl container), with a challenge
made on the Umbrel. Answered at height 3,572,944 (counter 7); the file passed
`verify_statement.py --challenge`, and failed against an earlier challenge.
Not yet tested: between two Go Max nodes.

Two nodes agree: the Umbrel's own Zakura node (Rock it, not pruned, tip
3,573,051 at the time) was read at the statement's height 3,572,944 with the
same read-only calls (`getblock` verbosity 1, `z_gettreestate`), and the
fingerprint v0 built from its answers is byte for byte the one in the Go Max
statement (SHA-256 `ea606cbd…f153`). Separate machines and separate syncs,
but the same Zakura version (1.8.5) and the fingerprint built by the same
rules, so this shows agreement, not independence of software.

A quorum compares at one height, not at each node's tip: the one asking
should name it (for example `&height=H`), a node ahead of H answers as long as
it still keeps that block (Go Max keeps about four weeks), and a node behind
H says it is not there yet rather than answering for another height.

From 14 Nov 2026 the asker can name it: `GET /statement?challenge=<64
hex>&height=H` (without a height the node still takes its tip − 100). A
height above the tip is refused as `behind` (409), one less than 100 blocks
below the tip as `unsettled` (409), and one the node no longer keeps as
`not-kept` (410), each with the node's tip; the node never answers for a
different height. `verify_statement.py --height H` checks the statement is
for exactly H. Tested over Tor with Lock it asking its own onion address: H =
3,572,900 was answered for exactly that height, 4,000,000 was refused as not
there yet (tip 3,573,180), and 3,400,000 as no longer kept. The first try
once failed with a dropped Tor circuit (NWError 96); Lock it now tries a
second time with the same challenge.

Limits, so nobody can keep a Mac busy through its onion address: at most 6
statements in any 60 seconds (over Tor every request arrives from 127.0.0.1,
so this is for all askers together), answered with 429 and `retryAfter`
above that; at most 8 connections open; a connection that sends nothing is
closed after 10 seconds; refusals over the limit are one line a minute in
attest.log at most. Tested on 14 Nov 2026: eight requests in a row gave six
answers and two 429s, and an idle connection was closed after 10 seconds.

Seen: Apple's certificate for the key is valid for three days only (here
13–16 Nov; the TestFlight build 8 key from 14 Nov 07:04 to 17 Nov 07:04
UTC).

Decided 16 Nov 2026: the chain is checked at the moment Apple attested the
key (the leaf's start plus 60 seconds), and Apple's intermediate must still
be valid today (it ends 2030-03-13). This is Apple's own model (verify the
attestation once, then trust the key's signatures) and what other projects
using App Attest without a central server settled on. The node contacts
Apple once per key: at the first answer, and after "New address". The key
never leaves the Mac's security chip, and every answer is still a fresh
signature over the asker's challenge. Given up: Apple does not judge the Mac
again every few days. A maximum key age can be added later if needed.

Also from Apple's guidance for macOS: the leaf carries the key's access
policy (extension 1.2.840.113635.100.8.6), and a Mac's key is to be trusted
only when it shows System Integrity Protection and full security on. Both
verifiers check it. Every statement made so far (13–15 Nov) shows it on.
Lock it in "Finding other nodes" also keeps each node's key and answer
count, and drops a node whose count does not go up.

## In TestFlight

Tested on 15 Nov 2026 with build 8 from TestFlight (signed again by Apple,
"TestFlight Beta Distribution", App Attest production), asked from the
Umbrel over Tor: answered at height 3,574,910, passed `verify_statement.py
--challenge`, failed against an earlier challenge; the own-node check passed
on the re-signed build. Build 7 had failed at the last step with App Attest
error 0: it tried to sign with the key a development (Xcode) build had made.
Keys are now kept per App Attest environment, and a key that does not sign
is replaced once.

## Two owners, two Macs (15 Nov 2026)

Andrew Miller checked this node with build 8 three ways: with the verifier
over Tor, with a named height (3,576,000), and from his own Go Max with
"Check another node". All three answered (counter 2 to 4 in attest.log).
Checking his node back answered "not caught up": his Go Max was still on its
first sync. That showed a flaw: being genuine should not depend on being
synced.

## Genuine always (format v2, build 9, not yet tested)

A v2 answer always proves genuine Lock it, and signs the node's state with
it: up to date at block T, syncing at block T of about E (the clock's
estimate), or node not running. The chain fingerprint is added only for a
height the node has checked, settled (100 blocks below its tip) and still
keeps; otherwise the answer says why there is none (`fingerprintNote`:
syncing, behind, unsettled, not-kept, not-running). A height below a syncing
node's tip is answered with its fingerprint. The client data App Attest signs
is `{"challenge","fingerprintSHA256" (empty when none),"node":{state,tip,
estimate},"purpose","v":2}`. Requests that are refused (malformed or over the
limit) are counted and logged as one line a minute, with counts only; answers
are logged with the first characters of the challenge and the node's state.

## What Apple attests besides the key

The authenticator data that App Attest signs carries facts the system
service writes, not the app. In TestFlight build 8 the assertion carries the
app's build number (`apple_bundle_version_01` = 8) and a validation category.
The verifier now shows these and can require them (`--build 9`). No code
fingerprint (CDHash) is present. dsmack's evidence on macOS 27 does carry it
(`apple_cd_hash_hash_01`), after the app opts in with the entitlement
`com.apple.developer.devicecheck.app-attest-opt-in` = `[CDhash]`. Build 9
tries that entitlement in debug builds first; whether it is allowed and kept
in TestFlight and App Store builds, which Apple signs again, is not known
yet. With a CDHash, a check can say which exact build answered; tying that
build to the published source still needs reproducible builds.

## Built for build 9

Tested on 16 Nov 2026 (Xcode build, macOS 27): 102 unit tests pass,
including the full in-app check on a real saved answer; "Check another node"
on this Mac's own onion address over Tor answered "Genuine, key attested 15
Nov 2026, up to date, fingerprint at 3,579,290". Not yet tested: finding
other nodes between two Macs (needs a second node with build 9).


- Full verification inside Lock it (`StatementCheck`): Apple's chain to the
  pinned root, the key, the signature over a fresh challenge, the app ID,
  the build Apple attests. "Check another node" shows its verdict; the
  Python verifier stays as a second opinion.
- Go Max nodes finding each other (see docs/discovery.md).
- Apple's three-day certificate: checked at the moment Apple attested the
  key; Apple's macOS security policy (SIP, full security) checked too.

## Not done

- The CDHash opt-in in a TestFlight build.
- Moving the answering code into a separate helper program before Genuine
  node is on by default.
- Reproducible builds.
