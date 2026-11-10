# Go Max: a Zcash node inside Lock it for Mac

Settings › Go Max. One switch: Lock it runs its own pruned Zcash node on this
Mac, checks the chain itself, and reads it from there instead of a server.

Status: **first build, branch `go-max`, 10 Nov 2026. Not yet built or run.**
Nothing here is confirmed until the Xcode build log and the app show it.

## What was measured (Rock it pruned prototype, MacBook Air, 8–9 Nov 2026)

| | |
| --- | --- |
| Node | Zakura 1.8.5 (Zebra fork), pruned, `checkpoint_sync = false` |
| Light-wallet server | Zaino `feat/nu7` at `aaf8122` + the two Rock it patches, ephemeral |
| First sync from genesis | 13 h 29 min |
| Disk at the tip | 15.2 GB with a 10,000-block window; about 20 GB with 100,000 |
| Memory | 1.7–2.7 GB while syncing |
| Wallet test | Lock it synced through it; a new wallet received funds |

Two rules from those runs, built into the code:

1. **`checkpoint_sync = false`.** With Zakura's checkpoint fast path a pruned
   node drops its transparent address indexes. The engine asks for them on
   every sync (GetAddressUtxos), gets an error and retries forever.
2. **Sync with the smallest window (10,000 blocks), widen to 100,000 at the
   tip.** The window counts blocks, and the 2022–23 spam blocks are large: a
   100,000-block window during the first sync reached 39 GB and climbing.

## The pieces

| File | What it does |
| --- | --- |
| `ZeckyLockIt/GoMax.swift` | The two settings files, the phases, the words on the page. No disk, no network; tested. |
| `ZeckyLockIt/GoMaxNode.swift` | Starts, watches and stops the two programs; widens the window at the tip; switches Lock it's server to the node and back. Reads the node over JSON-RPC on 127.0.0.1 (a plain TCP connection, not the web). |
| `ZeckyLockIt/GoMaxPage.swift` | Settings › Go Max. |
| `GoMax/Helpers.entitlements` | The two programs run inside Lock it's sandbox (app-sandbox + inherit). |
| `scripts/gomax-helpers.sh` | Copies `zakurad` and `zainod` into `GoMax/bin` (not in git) and pins their SHA-256 in `GoMax/bin.sha256`. |
| `scripts/gomax-embed.sh` | Build step: checks the pins, puts both programs in `Contents/MacOS`, signs them. Without them the app builds as before and the page says the build has no node inside. |

Everything the node stores is in Lock it's container:
`~/Library/Containers/app.zecky.lockit.mac/Data/Library/Application Support/GoMax/`
(`zakura/`, `zaino/`, `logs/`, the two `.toml` files), left out of Time Machine.

## Ports, all on this Mac only

| Port | Program | |
| --- | --- | --- |
| 8232 | Zakura JSON-RPC | Lock it and Zaino read the node here |
| 8233 | Zakura peer-to-peer | listens on 127.0.0.1 only; the node connects out to its peers |
| 8137 | Zaino | Lock it's server while Go Max is up to date |

Nothing accepts connections from outside this Mac. A phone (pairing) is the
next stage; it will need Zaino on the home-network address and Tor.

If something else already answers on 8232 or 8137 (a node started by hand,
like the prototype), Go Max says so and does not start.

## First test on the Mac

1. Stop the prototype node in its Terminal windows (Ctrl-C in the Zaino window,
   then in the Zakura window), so the ports are free.
2. `scripts/gomax-helpers.sh`
3. Build and run in Xcode. The build log should end the "Go Max programs"
   step with "zakurad and zainod are in the app."
4. Settings › Go Max › switch on.

To skip the 13-hour first sync, the prototype's state can be copied into the
container before step 4 (both stopped):
`ditto ~/rockit-proto/state-full ~/Library/Containers/app.zecky.lockit.mac/Data/Library/Application\ Support/GoMax/zakura`
The settings Go Max writes match the ones that state was made with.

## Open questions only a build can answer

- Whether a sandboxed Lock it may start the two programs from its own bundle
  as signed here. If not, `zakura.log` stays empty and Console shows a
  sandbox message.
- Whether Zakura's RPC answers the plain HTTP request in `LocalRPC`.
- How long the node takes to open a 15 GB state after an unclean stop
  (Lock it waits up to 3 minutes).

## Not in this branch yet

- Pairing a phone: home-network address, certificate, QR, Tor onion service.
- Node updates before Zakura's stop heights.
- Reproducible builds of `zakurad` and `zainod` from pinned tags (the pins
  now are local prototype builds, for testing only).
