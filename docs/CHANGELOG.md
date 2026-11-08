# Changelog

Plain-words notes on what changed in Zecky Lock it for Mac, newest first.

## Unreleased

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
- Send: "Fee included" works on a whole balance; the engine's not-enough
  message is shown in plain words.
- Seal it uses the same Send screen as the lock, with the address book;
  Send Zcash and Receive open the right part; amounts are read safely.
- "Receiving +… ›" shows for every wallet; the "still on its way" note on
  the Send screen clears by itself.
