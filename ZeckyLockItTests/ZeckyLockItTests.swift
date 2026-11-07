import CryptoKit
import XCTest
import ZcashLightClientKit
@testable import ZeckyLockIt

/// Runs inside the app (so the Keychain behaves as in real use), but the
/// app does not start a wallet while testing. Only public test vectors and
/// dummy Keychain items are used; the real wallet is never touched.
final class ZeckyLockItTests: XCTestCase {

    // MARK: Recovery phrase (BIP39)

    func testWordlistMatchesItsFingerprint() {
        if case .failure(let failure) = Mnemonic.words { XCTFail("\(failure)") }
    }

    func testOfficialVectorsAndRestoreCompatibility() throws {
        XCTAssertTrue(WalletSelfTest.run().hasPrefix("Wallet: OK"), WalletSelfTest.run())
        // 24 words from 256 bits, as every BIP39 wallet restores them.
        let phrase = try Mnemonic.phrase(from: [UInt8](repeating: 0x7f, count: 32))
        XCTAssertEqual(phrase.split(separator: " ").count, 24)
        XCTAssertNoThrow(try Mnemonic.validate(phrase))
        XCTAssertEqual(Mnemonic.normalize("  LEGAL  winner "), "legal winner")
    }

    func testWrongWordsAreRefused() {
        XCTAssertFalse(Mnemonic.isValid(Array(repeating: "abandon", count: 24).joined(separator: " ")))
        XCTAssertFalse(Mnemonic.isValid("not real words at all"))
    }

    // MARK: Randomness

    func testFreshEntropyIs256BitsAndNeverRepeats() throws {
        let a = try Entropy.secure(32)
        let b = try Entropy.secure(32)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.allSatisfy { $0 == a[0] })
    }

    // MARK: Keychain

    func testKeychainItemsAreThisDeviceOnlyAndNeverSynced() throws {
        let service = "app.zecky.lockit.mac.test-\(UUID().uuidString)"
        defer { try? KeyStore.delete(service: service) }
        try KeyStore.save(Data("dummy".utf8), service: service)
        let p = try XCTUnwrap(try KeyStore.protection(service: service))
        XCTAssertEqual(p.accessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertFalse(p.synced)
        XCTAssertEqual(try KeyStore.read(service: service), Data("dummy".utf8))
        try KeyStore.delete(service: service)
        XCTAssertNil(try KeyStore.read(service: service))
    }

    // MARK: Lock rules, every combination

    func testTimeLockRules() {
        for from in TimeLock.choices {
            for to in TimeLock.choices {
                let need = LockRules.timeLock(from: from, to: to)
                XCTAssertEqual(need, to >= from ? .nothing : .waitCurrentTimeLock, "\(from) → \(to)")
            }
        }
    }

    func testCodeRules() {
        XCTAssertEqual(LockRules.code(had: false, will: true), .owner)   // put on
        XCTAssertEqual(LockRules.code(had: true, will: true), .owner)    // change
        XCTAssertEqual(LockRules.code(had: true, will: false), .owner)   // remove
        XCTAssertEqual(LockRules.code(had: false, will: false), .nothing)
    }

    func testAddressBookRules() {
        XCTAssertEqual(LockRules.addressRule(on: true), .nothing)
        XCTAssertEqual(LockRules.addressRule(on: false), .owner)
        XCTAssertEqual(LockRules.addAddress(ruleOn: true), .owner)
        XCTAssertEqual(LockRules.addAddress(ruleOn: false), .nothing)
        XCTAssertEqual(LockRules.removeAddress, .nothing)
    }

    func testKeysToTheLockRules() {
        XCTAssertEqual(LockRules.check(on: true), .nothing)
        XCTAssertEqual(LockRules.check(on: false), .owner)
        for from in Keys.waits {
            for to in Keys.waits {
                XCTAssertEqual(LockRules.wait(from: from, to: to), to >= from ? .nothing : .owner, "\(from) → \(to)")
            }
        }
    }

    func testAlwaysTheOwner() {
        XCTAssertEqual(LockRules.breakGlass, .owner)
        XCTAssertEqual(LockRules.showPhrase, .owner)
        XCTAssertEqual(LockRules.erase, .owner)
    }

    // MARK: Network

    func testOwnNodeRangesMatchTheIPhone() {
        for host in ["10.0.0.5", "127.0.0.1", "192.168.1.20", "172.16.0.1", "172.31.255.1", "100.64.0.1", "100.127.1.1"] {
            XCTAssertTrue(Server.isHomeNode(host), host)
        }
        for host in ["zec.rocks", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.1.1", "1.2.3", "300.1.1.1"] {
            XCTAssertFalse(Server.isHomeNode(host), host)
        }
    }

    func testOwnNodeIsLabelledHonestly() {
        XCTAssertEqual(Server.nodeKind("192.168.1.20"), .homeNetwork)
        XCTAssertEqual(Server.nodeKind("10.0.0.5"), .homeNetwork)
        XCTAssertEqual(Server.nodeKind("100.101.2.3"), .tailscaleIP)
        XCTAssertEqual(Server.nodeKind("127.0.0.1"), .thisMac)
        XCTAssertNil(Server.nodeKind("zec.rocks"))
        XCTAssertNil(Server.nodeKind("10.0.0.1.example.com"))
    }

    // MARK: Waiting for confirmations (same numbers as the iPhone)

    func testWaitingCountsDownLikeTheIPhone() {
        typealias Item = WalletEngine.ActivityItem
        // Heights just before NU7 (75-second blocks) and well after it (25 s).
        let b = 3_500_100, n = 3_600_100
        let received = Item(id: Data([1]), kind: .received, amount: 1, date: Date(), state: .confirmed, minedHeight: b)
        let own = Item(id: Data([2]), kind: .sent, amount: 1, date: Date(), state: .confirmed, minedHeight: b)
        let pending = Item(id: Data([3]), kind: .received, amount: 1, date: nil, state: .waiting, minedHeight: nil)

        // In block b, network at b+3: 4 of 10, 6 blocks × 75 s ≈ 8 minutes.
        XCTAssertEqual(WalletEngine.slowestWaiting([received], networkHeight: b + 3),
                       .init(confirmations: 4, needed: 10, minutes: 8))
        XCTAssertEqual(WalletEngine.waitingText(.init(confirmations: 4, needed: 10, minutes: 8)),
                       "usable in about 8 minutes · 4/10 confirmations")
        // After NU7: 6 blocks × 25 s ≈ 3 minutes.
        let receivedAfter = Item(id: Data([4]), kind: .received, amount: 1, date: Date(), state: .confirmed, minedHeight: n)
        XCTAssertEqual(WalletEngine.slowestWaiting([receivedAfter], networkHeight: n + 3)?.minutes, 3)
        // Own change needs 3: at b+2 it is done.
        XCTAssertNil(WalletEngine.slowestWaiting([own], networkHeight: b + 2))
        // Not in a block yet: the slowest wins.
        XCTAssertEqual(WalletEngine.slowestWaiting([received, pending], networkHeight: b + 3)?.confirmations, 0)
        XCTAssertEqual(WalletEngine.waitingText(nil), "usable within about 12 minutes")
        XCTAssertEqual(WalletEngine.waitingText(nil, networkHeight: n), "usable within about 4 minutes")
        XCTAssertNil(WalletEngine.slowestWaiting([received], networkHeight: 0))
    }

    // MARK: Payment requests (ZIP-321)

    func testPaymentRequestsOneRecipientOnly() throws {
        let r = try PaymentRequest.parse("zcash:u1abc?amount=0.5&memo=SGVsbG8&label=Coffee%20shop")
        XCTAssertEqual(r, PaymentRequest(address: "u1abc", amount: "0.5", memo: "Hello", label: "Coffee shop"))
        XCTAssertEqual(try PaymentRequest.parse("zcash:?address=u1abc&amount=1").address, "u1abc")
        XCTAssertEqual(try PaymentRequest.parse("zcash:u1abc").amount, nil)
        XCTAssertThrowsError(try PaymentRequest.parse("zcash:?address=u1a&amount=1&address.1=u1b&amount.1=2")) {
            XCTAssertEqual($0 as? PaymentRequest.Problem, .severalRecipients)
        }
        XCTAssertThrowsError(try PaymentRequest.parse("zcash:u1abc?amount=0.123456789"))
        XCTAssertThrowsError(try PaymentRequest.parse("zcash:u1abc?req-unknown=1")) {
            XCTAssertEqual($0 as? PaymentRequest.Problem, .unsupported)
        }
        XCTAssertThrowsError(try PaymentRequest.parse("zcash:u1abc?REQ-Unknown=1")) {
            XCTAssertEqual($0 as? PaymentRequest.Problem, .unsupported, "req- in any case")
        }
        XCTAssertThrowsError(try PaymentRequest.parse("zcash:u1abc?amount=1&amount=2")) {
            XCTAssertEqual($0 as? PaymentRequest.Problem, .repeated)
        }
        XCTAssertThrowsError(try PaymentRequest.parse("zcash:u1abc?amount=1,5")) {
            XCTAssertEqual($0 as? PaymentRequest.Problem, .badAmount)
        }
        // Own-node addresses: no leading zeros (iPhone audit C-27).
        XCTAssertFalse(Server.isHomeNode("010.0.0.1"))
        XCTAssertFalse(Server.isHomeNode("192.168.01.5"))
        XCTAssertFalse(Server.isHomeNode("10.0.0."))
        XCTAssertTrue(Server.isHomeNode("10.0.0.1"))
        XCTAssertTrue(Server.isHomeNode("192.168.1.0"))
        XCTAssertThrowsError(try PaymentRequest.parse("u1abc"))
        XCTAssertTrue(PaymentRequest.isRequest("  ZCASH:u1abc"))
    }

    func testAddressesAreGroupedInFours() {
        XCTAssertEqual(Contacts.grouped("abcdefghij"), "abcd efgh ij")
    }
    // MARK: Security keys (WebAuthn answers, checked with a made-up key)

    private func cbor(_ items: [UInt8]...) -> Data { Data(items.joined()) }
    private func bytesHead(_ major: UInt8, _ n: Int) -> [UInt8] { n < 24 ? [major << 5 | UInt8(n)] : [major << 5 | 24, UInt8(n)] }

    private func clientData(_ type: String, _ challenge: Data) -> Data {
        let c = challenge.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Data("{\"type\":\"\(type)\",\"challenge\":\"\(c)\",\"origin\":\"https://zecky.app\"}".utf8)
    }

    private func authData(rp: String = "zecky.app", flags: UInt8, count: UInt32, id: Data? = nil, key: P256.Signing.PublicKey? = nil) -> Data {
        var d = Data(SHA256.hash(data: Data(rp.utf8)))
        d.append(flags)
        d.append(contentsOf: [UInt8(count >> 24 & 0xff), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)])
        if let id, let key {
            d.append(Data(count: 16)) // AAGUID
            d.append(contentsOf: [UInt8(id.count >> 8), UInt8(id.count & 0xff)])
            d.append(id)
            let raw = [UInt8](key.x963Representation)
            // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
            d.append(cbor([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21], bytesHead(2, 32), Array(raw[1...32]), [0x22], bytesHead(2, 32), Array(raw[33...64])))
        }
        return d
    }

    func testSecurityKeyPairingAndAnswers() throws {
        let key = P256.Signing.PrivateKey()
        let id = SecurityKeys.randomBytes(16)
        let challenge = SecurityKeys.randomBytes(32)
        let auth = authData(flags: 0x41, count: 0, id: id, key: key.publicKey)
        // {"fmt": "none", "attStmt": {}, "authData": auth}
        let att = cbor([0xa3, 0x63], Array("fmt".utf8), [0x64], Array("none".utf8), [0x67], Array("attStmt".utf8), [0xa0],
                       [0x68], Array("authData".utf8), [0x59, UInt8(auth.count >> 8), UInt8(auth.count & 0xff)], [UInt8](auth))
        let paired = try WebAuthn.readRegistration(credentialId: id, attestationObject: att,
                                                   clientDataJSON: clientData("webauthn.create", challenge), challenge: challenge)
        XCTAssertEqual(paired.publicKey, key.publicKey.x963Representation)
        XCTAssertThrowsError(try WebAuthn.readRegistration(credentialId: id, attestationObject: att,
                                                            clientDataJSON: clientData("webauthn.create", SecurityKeys.randomBytes(32)), challenge: challenge))

        func answer(_ count: UInt32, rp: String = "zecky.app", flags: UInt8 = 0x01, signer: P256.Signing.PrivateKey? = nil, type: String = "webauthn.get") throws -> UInt32 {
            let a = authData(rp: rp, flags: flags, count: count)
            let cd = clientData(type, challenge)
            var msg = a; msg.append(contentsOf: SHA256.hash(data: cd))
            let sig = try (signer ?? key).signature(for: msg).derRepresentation
            return try WebAuthn.readAssertion(credentialId: id, authenticatorData: a, clientDataJSON: cd, signature: sig,
                                              challenge: challenge, keys: [WebAuthn.Paired(id: id, publicKey: paired.publicKey, signCount: 5)]).1
        }
        XCTAssertEqual(try answer(6), 6)
        XCTAssertThrowsError(try answer(5), "counter must go up")
        XCTAssertThrowsError(try answer(7, rp: "evil.example"))
        XCTAssertThrowsError(try answer(7, flags: 0x00), "key must be touched")
        XCTAssertThrowsError(try answer(7, signer: P256.Signing.PrivateKey()), "wrong key")
        XCTAssertThrowsError(try answer(7, type: "webauthn.create"))
    }

    func testSecurityKeyRules() {
        XCTAssertEqual(LockRules.keyAction(.addFirst, keyCount: 0), .owner)
        XCTAssertEqual(LockRules.keyAction(.addMore, keyCount: 1), .key)
        XCTAssertEqual(LockRules.keyAction(.remove, keyCount: 2), .key)
        XCTAssertEqual(LockRules.keyAction(.phraseOn, keyCount: 2), .nothing)
        XCTAssertEqual(LockRules.keyAction(.startRemoval, keyCount: 1), .owner)
        XCTAssertNil(LockRules.removalStartHeight(synced: 0, seen: 100))
        XCTAssertNil(LockRules.removalStartHeight(synced: 80, seen: 100))
        XCTAssertEqual(LockRules.removalStartHeight(synced: 95, seen: 100), 100)
        // 48 hours = 2,304 blocks of 75 s before NU7, 6,912 of 25 s after it.
        let t48 = Date(timeIntervalSince1970: 49 * 3600)
        let before = SecurityKeys.Removal(startedAt: Date(timeIntervalSince1970: 0), startHeight: 3_400_000)
        XCTAssertFalse(LockRules.removalDue(before, now: Date(timeIntervalSince1970: 47 * 3600), networkHeight: 3_500_000))
        XCTAssertFalse(LockRules.removalDue(before, now: t48, networkHeight: 3_402_303))
        XCTAssertTrue(LockRules.removalDue(before, now: t48, networkHeight: 3_402_304))
        let after = SecurityKeys.Removal(startedAt: Date(timeIntervalSince1970: 0), startHeight: 3_600_000)
        XCTAssertFalse(LockRules.removalDue(after, now: t48, networkHeight: 3_602_304), "2,304 blocks are only 16 hours after NU7")
        XCTAssertTrue(LockRules.removalDue(after, now: t48, networkHeight: 3_606_912))
        // Crossing NU7: 1,404 blocks of 75 s, then 2,700 of 25 s.
        let across = SecurityKeys.Removal(startedAt: Date(timeIntervalSince1970: 0), startHeight: 3_542_000)
        XCTAssertFalse(LockRules.removalDue(across, now: t48, networkHeight: 3_546_103))
        XCTAssertTrue(LockRules.removalDue(across, now: t48, networkHeight: 3_546_104))
    }
    // MARK: NU7

    func testBlockTimesAcrossNU7() {
        XCTAssertEqual(BlockTime.spacing(at: 3_543_404), 75)
        XCTAssertEqual(BlockTime.spacing(at: 3_543_405), 25)
        XCTAssertEqual(BlockTime.seconds(from: 3_543_400, to: 3_543_410), 4 * 75 + 6 * 25)
        XCTAssertEqual(BlockTime.blocksBack(seconds: 3600, from: 3_500_000), 48)
        XCTAssertEqual(BlockTime.blocksBack(seconds: 3600, from: 3_700_000), 144)
        // A year back from a tip after NU7: the blocks since NU7, then 75 s ones.
        let tip = 3_543_405 + 999
        XCTAssertEqual(BlockTime.blocksBack(seconds: 25_000 + 75 * 100, from: tip), 1000 + 100)
    }

    func testRestoreFromDateAfterNU7StartsEarlyEnough() {
        // On 30 Nov 2026, 24.5 days after NU7 (84,672 blocks of 25 s), a
        // wallet from November must start before 1 Nov, which was about
        // 4.5 days of 75-second blocks before NU7. Counting everything at
        // 75 s would start some 48,000 blocks too late and miss funds.
        let now = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                 year: 2026, month: 11, day: 30).date!
        let tip = 3_543_405 + 84_672
        let start = Birthday.estimate(year: 2026, month: 11, tip: tip, now: now)
        XCTAssertLessThanOrEqual(start, 3_543_405 - 5_184)
    }

    func testTheEngineKnowsNU7SoReleasesAreNotPaused() {
        XCTAssertTrue(NetworkUpgrade.engineKnowsNU7, "this build runs the Zecky engine with NU7")
        XCTAssertEqual(WalletSelfTest.engineBranch(at: 3_543_404), 0x37A5_165B, "NU6.3 (Ironwood) the block before")
        XCTAssertEqual(WalletSelfTest.engineBranch(at: 3_543_405), 0x7719_0AD9, "NU7 from its activation")
        XCTAssertEqual(WalletSelfTest.engineBranch(at: 4_000_000), 0x7719_0AD9)
        XCTAssertFalse(NetworkUpgrade.releasesPaused(networkHeight: 3_543_364))
        XCTAssertFalse(NetworkUpgrade.releasesPaused(networkHeight: 3_600_000))
        XCTAssertNoThrow(try NetworkUpgrade.checkReleases(networkHeight: 3_600_000))
    }
    // MARK: Sending needs the open lock (iPhone audit C-09)

    @MainActor func testSendingNeedsTheOpenLock() {
        XCTAssertTrue(LockRules.maySend(lockOpen: true))
        XCTAssertFalse(LockRules.maySend(lockOpen: false))
        // A fresh engine starts with the lock closed until the app says otherwise.
        XCTAssertFalse(WalletEngine().lockIsOpen())
    }
    // MARK: Typed amounts (iPhone audit C-19)

    func testAmountsAreReadWithoutGuessing() {
        XCTAssertEqual(AmountInput.zec("1.5"), 150_000_000)
        XCTAssertEqual(AmountInput.zec("1,5"), 150_000_000)
        XCTAssertEqual(AmountInput.zec("0,001"), 100_000)
        XCTAssertEqual(AmountInput.zec("12,34"), 1_234_000_000)
        XCTAssertEqual(AmountInput.zec(".25"), 25_000_000)
        XCTAssertNil(AmountInput.zec("1,500"), "1.5 or 1500? asked, not guessed")
        XCTAssertTrue(AmountInput.ambiguous("1,500"))
        XCTAssertFalse(AmountInput.ambiguous("1,5"))
        XCTAssertEqual(AmountInput.question("1,500", unit: "ZEC"), "Is that 1.5 ZEC or 1500 ZEC? Type 1.500 or 1500.")
        XCTAssertNil(AmountInput.zec("1.123456789"), "at most 8 decimals")
        XCTAssertNil(AmountInput.zec("0"))
        XCTAssertNil(AmountInput.zec("99999999999"), "too large, no overflow")
        XCTAssertEqual(AmountInput.zats("1,500"), 1_500)
        XCTAssertEqual(AmountInput.zats("250 000"), 250_000)
        XCTAssertNil(AmountInput.zats("1.5"), "a dot is not a thousands separator")
        XCTAssertEqual(AmountInput.fiat("25,50"), 25.5)
        XCTAssertNil(AmountInput.fiat("1,500"))
        XCTAssertNil(AmountInput.fiat("25.555"))
    }
    // MARK: Sync details

    func testSyncDetailsNumbers() {
        XCTAssertEqual(SyncMath.behind(network: 3_600_100, wallet: 3_600_000), 100)
        XCTAssertEqual(SyncMath.behind(network: 3_600_000, wallet: 3_600_100), 0)
        XCTAssertNil(SyncMath.behind(network: 0, wallet: 3_600_000))
        XCTAssertTrue(SyncMath.nearlyCurrent(network: 3_600_003, wallet: 3_600_000), "a new block or two: still up to date")
        XCTAssertFalse(SyncMath.nearlyCurrent(network: 3_600_010, wallet: 3_600_000))
        XCTAssertFalse(SyncMath.nearlyCurrent(network: 0, wallet: 3_600_000))
        XCTAssertTrue(SyncMath.isDroppedConnection("LightWalletService.blockStream failed."))
        XCTAssertTrue(SyncMath.isDroppedConnection("rpc error: Unavailable"))
        XCTAssertFalse(SyncMath.isDroppedConnection("The wallet data on this Mac belongs to other words."))
        let t = Date(timeIntervalSince1970: 0)
        let samples = (0..<3).map { SyncMath.Sample(at: t.addingTimeInterval(Double($0) * 10), height: 1_000 + $0 * 100) }
        XCTAssertEqual(SyncMath.minutesLeft(behind: 6_000, samples: samples), 10, "10 blocks a second")
        XCTAssertNil(SyncMath.minutesLeft(behind: 6_000, samples: Array(samples.prefix(2))))
        XCTAssertEqual(SyncMath.checkedFraction(birthday: 1_000, wallet: 1_500, network: 2_000), 0.5)
        // Problems: newest first, at most 5, no repeats within a minute.
        var list: [SyncMath.Problem] = []
        list = SyncMath.adding(.init(at: t, message: "A"), to: list)
        list = SyncMath.adding(.init(at: t.addingTimeInterval(30), message: "A"), to: list)
        XCTAssertEqual(list.count, 1)
        for i in 0..<6 { list = SyncMath.adding(.init(at: t.addingTimeInterval(100 + Double(i)), message: "B\(i)"), to: list) }
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list.first?.message, "B5")
    }
    // MARK: Engraving

    func testOneEngravedLinePerMilestone() {
        XCTAssertEqual(Milestone.reached(after: 0), 0)
        XCTAssertEqual(Milestone.reached(after: 7), 1)
        XCTAssertEqual(Milestone.reached(after: 120), 3)
        XCTAssertEqual(Milestone.reached(after: 400), 4)
        XCTAssertTrue(Milestone.reachedToday(after: 30))
        XCTAssertFalse(Milestone.reachedToday(after: 31))
    }
    // MARK: Lost my keys

    func testRemovalTargetIs48HoursOfBlocks() {
        XCTAssertEqual(LockRules.removalTargetHeight(from: 3_600_000), 3_606_912, "6,912 blocks of 25 s after NU7")
        XCTAssertEqual(LockRules.removalTargetHeight(from: 3_400_000), 3_402_304, "2,304 blocks of 75 s before NU7")
        let across = LockRules.removalTargetHeight(from: 3_542_000)
        XCTAssertEqual(across, 3_546_104)
    }

    // MARK: Sending

    func testNotEnoughFundsIsShownInPlainWords() {
        let raw = ZcashError.rustProposalInsufficientFunds(Zatoshi(100_000), Zatoshi(110_000))
        XCTAssertEqual(WalletEngine.planProblem(raw), "Not enough available for this amount plus the fee.")
    }
}
