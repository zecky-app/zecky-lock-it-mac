# Security

Zecky Lock it holds people's Zcash. If you find a weakness, please tell us
privately first, so it can be fixed before anyone else can use it.

## How to report

- Email **dev@zecky.app** with what you found, how to reproduce it, and which
  version you used (Settings › About).
- Or use GitHub's private vulnerability reporting on this repository
  ("Report a vulnerability" under the Security tab).

Please do not open a public issue, post details publicly, or test against
other people's wallets or funds. Use small amounts on your own wallet.

## What happens next

- We confirm we received it within a few days.
- We tell you what we are doing about it and when, and credit you in the
  release notes if you like.

## In scope

- The recovery phrase: how it is made, sealed (Secure Enclave / Keychain),
  shown and erased; the key ring (each wallet's own 24 words, encrypted with
  a key from the words that hold the lock) and handing the lock to another
  wallet when that one is erased.
- The keys to the lock: the Zecky code, the time lock and Break the glass,
  and the rules that weakening a key asks the owner first.
- Anything that could release Zcash without the owner, or leak the phrase,
  balance, addresses or activity off this Mac.
- Network: the wallet server, your own node (Rock it) and the optional price
  service.

## Not in scope

- Attacks that need the owner's unlocked Mac and their Mac password and their
  Zecky code all at once.
- Bugs in the Zcash libraries themselves: please report those to the Zcash
  developers as well.
