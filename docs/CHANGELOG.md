# Changelog

Plain-words notes on what changed in Zecky Lock it for Mac, newest first.

## Unreleased

- Send, with more than one wallet behind the lock: the paying wallet is named
  under the amount ("… available in Donations"), as the first line of the
  receipt ("From", in gold) and on the button ("Send 0.01 ZEC from
  Donations"). With one wallet nothing changes. (Tester feedback, 13 Nov.)
- Go Max: during the first check of history the page no longer says "needs an
  update" weeks early. The node's own guess of the network height is only used
  once it is close to the newest block.
- Go Max: when the node stops while starting, the page shows one calm line
  ("Your wallet is fine"), a "Try again" button that waits half a minute and
  starts the node again, and "Still not working?" with the next steps.
- Wallets out of sight: right-click a wallet on the home screen and choose
  "Keep out of sight". It leaves the row and keeps syncing and receiving. A
  small gold star appears next to "+": click it to show those wallets again,
  click it once more to put them away. The main wallet always stays. This is
  tidiness, not secrecy: the star is there for anyone at the unlocked Mac,
  and a payment to a wallet out of sight shows only when you look at it.
- Sending over Tor (first build, in testing): payments leave over Tor, each
  on its own connection, to two public servers; with Go Max the wallet
  still reads from its own node. If Tor cannot connect the payment waits
  and the Send screen says so; it is never sent another way by itself.
  With your own node you can then choose "Send through my own node".
  Settings › Network › Sending switches it off. Needs the engine's
  tor-submit commit (90e877d).
- Go Max (first build, in testing): the GO MAX button on the home screen
  (also Settings › Go Max) runs your own pruned
  Zcash node inside Lock it on this Mac. It checks every block since Canopy
  itself (about 20 GB of disk; the first check takes most of a day and
  downloads the chain once), and when it is up to date Lock it reads the
  chain from it instead of a server. Off switches back; Remove node deletes
  its data. Nothing accepts connections from outside this Mac.
- The line under the balance says how long your Zcash has been in the lock,
  in one unit only and never as a date: "Locked since today", "Locked for 3
  days", "for 2 weeks", "for 4 months", "for 1 year". A date ("1 week on Nov
  12") was read as an unlock date. An empty lock shows no line. Every wallet
  on the key ring has its own count. Same as Lock it iPhone.
- The count starts at the first payment in after the lock was last empty.
  Sending (any size) and receiving more do not reset it; locking in, the
  Ironwood move and payments to your own address count as nothing. It is
  worked out from the wallet history, so it comes back the same after a
  restore. It waits for the first full sync, and says "Locked on this Mac"
  when the history does not reach back to the start.
- Milestones: 1 week, every month of the first year, 1 year, then every year,
  each with its own name from Locked to Legend (4 years). The gold ring fills
  towards the next one and glows softly on the day you reach it. 1 week,
  1 year and every year after also engrave a line into the medallion. No
  notifications, badges or pop-ups.
- Click the line for the holding page: the milestone path, and highlights
  (received since then, stacking pace, payments in, largest payment in,
  longest before). The first time you open it on a milestone day, that
  milestone lights up once.
- Erase this wallet, in each wallet's menu on the key ring, removes only that
  wallet: a page shows its name, balance and address start, and Erase stays
  off until you type its name. Erasing the wallet that holds the lock passes
  the lock to the next wallet with words (same code and keys, checked before
  anything is removed). "This Mac" can be renamed. Settings now says plainly
  "Erase everything on this Mac".
- New wallets: the words show with a click and hide after 2 minutes; three
  words are asked back before the wallet is added. Key ring chips can be
  moved left or right.
- Sync details: the ring counts every block since the wallet birthday, so
  after a night closed it starts near the top (for example 99.6%) and moves
  to 100% instead of jumping from 0. One decimal, gliding between readings
  (not with Reduce Motion), 100% only when up to date, and the line under it
  says how many new blocks are left. The status line uses the same number.
- Engine v4.0.0-zecky.5: current checkpoints, so a new wallet (new,
  restored or Seal it) starts checking near its birthday instead of months
  of older blocks.
- Network: your own server is remembered when you switch to a public one.
- Send: "Fee included" works on a whole balance; the engine's not-enough
  message is shown in plain words.
- Seal it uses the same Send screen as the lock, with the address book;
  Send Zcash and Receive open the right part; amounts are read safely.
- "Receiving +… ›" shows for every wallet; the "still on its way" note on
  the Send screen clears by itself.
