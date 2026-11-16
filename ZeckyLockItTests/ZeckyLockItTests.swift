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

    func testEngravedLinesOnlyForOneWeekAndEachYear() {
        XCTAssertEqual(Milestone.engraved(after: 0), 0)
        XCTAssertEqual(Milestone.engraved(after: 7), 1)
        XCTAssertEqual(Milestone.engraved(after: 120), 1, "monthly milestones engrave nothing")
        XCTAssertEqual(Milestone.engraved(after: 400), 2)
        XCTAssertEqual(Milestone.engraved(after: 365 * 3), 4)
        XCTAssertTrue(Milestone.engravedToday(after: 365))
        XCTAssertFalse(Milestone.engravedToday(after: 30))
    }

    // MARK: Milestones (as Lock it iPhone: 1 week, every month of the first year, then every year)

    func testMilestoneDays() {
        XCTAssertEqual(Milestone.list(through: 400), [7, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 365, 730])
    }

    func testDayOneIsOnTheWayToOneWeek() {
        XCTAssertEqual(Milestone.progress(after: 0), 0)
        XCTAssertFalse(Milestone.reachedToday(after: 0))
        XCTAssertEqual(Milestone.progress(after: 3), 3.0 / 7, accuracy: 1e-9)
    }

    func testTheRingStartsOverAfterEachMilestone() {
        XCTAssertEqual(Milestone.progress(after: 10), 3.0 / 23, accuracy: 1e-9)
        XCTAssertEqual(Milestone.progress(after: 45), 15.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(Milestone.progress(after: 350), 20.0 / 35, accuracy: 1e-9)
        XCTAssertEqual(Milestone.progress(after: 400), 35.0 / 365, accuracy: 1e-9)
    }

    func testOnTheMilestoneDayOnlyTheRingIsFullAndGlows() {
        for day in [7, 30, 60, 330, 365, 730, 1095, 3650] {
            XCTAssertTrue(Milestone.reachedToday(after: day), "day \(day)")
            XCTAssertEqual(Milestone.progress(after: day), 1)
            XCTAssertFalse(Milestone.reachedToday(after: day + 1))
            XCTAssertFalse(Milestone.reachedToday(after: day - 1))
        }
        XCTAssertFalse(Milestone.reachedToday(after: 100))
        XCTAssertFalse(Milestone.reachedToday(after: 5000))
    }

    func testEveryMilestoneHasItsOwnNameRisingToLegend() {
        let days = [7, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 365, 730, 1095, 1460]
        let names = days.map(Milestone.name)
        XCTAssertEqual(Set(names).count, days.count)
        XCTAssertEqual(names.first, "Locked")
        XCTAssertEqual(Milestone.name(365), "Guardian")
        XCTAssertEqual(Milestone.name(1460), "Legend")
        XCTAssertEqual(Milestone.name(1825), "Legend · 5 years")
        XCTAssertEqual(Milestone.line(30), "1 month in the lock.")
        XCTAssertEqual(Milestone.line(90), "3 months in the lock.")
        XCTAssertEqual(Milestone.line(7), "1 week in the lock.")
        XCTAssertEqual(Milestone.line(1460), "4 years in the lock.")
    }

    private var gregorian: Calendar { Calendar(identifier: .gregorian) }
    private func localDay(_ y: Int, _ m: Int, _ d: Int) -> Date { gregorian.date(from: DateComponents(year: y, month: m, day: d))! }

    func testTheWholePathRunsToLegend() {
        let path = Milestone.path(since: localDay(2026, 1, 10), held: 10, calendar: gregorian)
        XCTAssertEqual(path.map(\.days), [7, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 365, 730, 1095, 1460])
        XCTAssertTrue(path[0].reached)
        XCTAssertEqual(gregorian.component(.day, from: path[0].at), 17)
        XCTAssertEqual(path[1].inDays, 20)
        XCTAssertEqual(path[1].progress ?? 0, 3.0 / 23, accuracy: 1e-9)
        XCTAssertNil(path[2].progress)
    }

    func testPastLegendThePathKeepsTheNextThreeYears() {
        let path = Milestone.path(since: localDay(2020, 1, 1), held: 1500, calendar: gregorian)
        XCTAssertEqual(path.suffix(4).map(\.days), [1460, 1825, 2190, 2555])
    }

    func testTheShortViewIsTheLastReachedAndTheNextTwo() {
        let since = localDay(2026, 1, 10)
        XCTAssertEqual(Milestone.shortPath(Milestone.path(since: since, held: 3, calendar: gregorian)).map(\.days), [7, 30, 60])
        XCTAssertEqual(Milestone.shortPath(Milestone.path(since: since, held: 45, calendar: gregorian)).map(\.days), [30, 60, 90])
        XCTAssertEqual(Milestone.shortPath(Milestone.path(since: since, held: 400, calendar: gregorian)).map(\.days), [365, 730, 1095])
    }

    // MARK: Locked for … (the line under the balance)

    func testLockedLineUsesTheLargestWholeUnitOnly() {
        let cases: [(Int, String)] = [
            (0, "since today"), (1, "for 1 day"), (2, "for 2 days"), (6, "for 6 days"),
            (7, "for 1 week"), (13, "for 1 week"), (14, "for 2 weeks"), (29, "for 4 weeks"),
            (30, "for 1 month"), (59, "for 1 month"), (60, "for 2 months"), (364, "for 11 months"),
            (365, "for 1 year"), (729, "for 1 year"), (730, "for 2 years"),
        ]
        for (days, text) in cases { XCTAssertEqual(Holding.heldFor(days: days), text, "\(days) days") }
    }

    func testDaysAreCalendarDays() {
        let cal = gregorian
        let since = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 23, minute: 30))!
        XCTAssertEqual(Holding.days(since: since, now: cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 23, minute: 59))!, calendar: cal), 0)
        XCTAssertEqual(Holding.days(since: since, now: cal.date(from: DateComponents(year: 2026, month: 1, day: 11, hour: 0, minute: 5))!, calendar: cal), 1)
        XCTAssertEqual(Holding.days(since: since, now: cal.date(from: DateComponents(year: 2026, month: 2, day: 9, hour: 8))!, calendar: cal), 30)
    }

    // MARK: When the count starts and restarts (from the history, as Lock it iPhone)

    private let fee: Int64 = 10_000
    private func at(_ day: Int) -> Date { Date(timeIntervalSince1970: 1_768_046_400 + Double(day) * 86_400) }
    private func receive(_ day: Int, _ zats: Int64) -> HoldingEntry {
        HoldingEntry(height: day, date: at(day), change: zats, internalMove: false)
    }
    /// The engine's signed change: a send's value already includes its fee.
    private func send(_ day: Int, _ zatsWithFee: Int64) -> HoldingEntry {
        HoldingEntry(height: day, date: at(day), change: -zatsWithFee, internalMove: false)
    }
    /// Locking in, the Ironwood move or a payment to an own address: only the fee leaves.
    private func move(_ day: Int) -> HoldingEntry {
        HoldingEntry(height: day, date: at(day), change: -fee, internalMove: true)
    }

    func testNothingInGivesNoCount() {
        XCTAssertNil(Holding.since([]))
    }

    func testStartsAtTheFirstPaymentIn() {
        XCTAssertEqual(Holding.since([receive(5, 100), receive(1, 100)]), at(1))
    }

    func testASmallSendDoesNotResetIt() {
        XCTAssertEqual(Holding.since([receive(1, 100_000_000), send(3, 1_010_000)]), at(1))
    }

    func testABigSendThatLeavesSomethingDoesNotResetIt() {
        XCTAssertEqual(Holding.since([receive(1, 100_000_000), send(3, 99_990_000)]), at(1))
    }

    func testTheFeeIsCountedOnce() {
        // 0.001 in, 0.0009 out including its fee: 0.0001 stays, not zero.
        XCTAssertEqual(Holding.since([receive(1, 100_000), send(2, 90_000)]), at(1))
    }

    func testAPaymentInBetweenDoesNotResetIt() {
        XCTAssertEqual(Holding.since([receive(1, 100_000), send(2, 50_000), receive(4, 70_000)]), at(1))
    }

    func testRestartsOnlyAfterTheBalanceWasZero() {
        XCTAssertEqual(Holding.since([receive(1, 100_000), send(2, 100_000), receive(6, 50_000)]), at(6))
    }

    func testAnEmptyLockHasNoCount() {
        XCTAssertNil(Holding.since([receive(1, 100_000), send(2, 100_000)]))
    }

    func testInternalMovesCountAsNothing() {
        XCTAssertEqual(Holding.since([receive(1, 100_000), move(2), move(3)]), at(1))
        // A history that begins with a move never starts the count there.
        XCTAssertEqual(Holding.since([move(1), receive(3, 50_000)]), at(3))
        XCTAssertNil(Holding.since([HoldingEntry(height: 1, date: at(1), change: 5_000, internalMove: true)]))
    }

    func testARestoreGivesTheSameStartInAnyOrder() {
        let list = [receive(1, 100_000), send(2, 100_000), receive(6, 50_000), send(9, 20_000)]
        XCTAssertEqual(Holding.since(list.reversed()), Holding.since(list))
        XCTAssertEqual(Holding.since(list.shuffled()), at(6))
    }

    func testAHistoryMissingItsStartGivesNoCount() {
        XCTAssertTrue(Holding.historyComplete([receive(1, 300_000), send(2, 50_000)], pendingIn: 0, balance: 250_000))
        // Held 1 ZEC since long ago; a restore from later only shows 0.1 ZEC in.
        XCTAssertFalse(Holding.historyComplete([receive(30, 10_000_000)], pendingIn: 0, balance: 110_000_000))
    }

    func testAPaymentStillWaitingToComeInIsNotAMissingStart() {
        XCTAssertTrue(Holding.historyComplete([receive(1, 300_000)], pendingIn: 200_000, balance: 500_000))
    }

    // MARK: The holding page

    func testThePageCountsWhatCameInSinceTheStart() {
        let h = Holding.summary([receive(1, 300_000), send(2, 50_000), receive(3, 900_000), move(4), receive(5, 200_000)],
                                now: at(12), calendar: gregorian)
        XCTAssertEqual(h?.since, at(1))
        XCTAssertEqual(h?.days, 11)
        XCTAssertEqual(h?.current.paymentsIn, 3)
        XCTAssertEqual(h?.current.received, 1_400_000)
        XCTAssertEqual(h?.current.largest?.zatoshi, 900_000)
        XCTAssertEqual(h?.current.largest?.at, at(3))
        XCTAssertNil(Holding.summary([]))
        XCTAssertNil(Holding.summary([receive(1, 100), send(2, 100)]))
    }

    func testOnlyWhatCameInAfterTheLastEmptyLockCounts() {
        let h = Holding.summary([receive(1, 5_000_000), send(2, 5_000_000), receive(4, 100_000)], now: at(6), calendar: gregorian)
        XCTAssertEqual(h?.current.received, 100_000)
        XCTAssertEqual(h?.current.paymentsIn, 1)
    }

    func testLongestBeforeOnlyWhenItWasLongerThanNow() {
        let list = [receive(1, 100_000), send(41, 100_000), receive(50, 100_000)]
        XCTAssertEqual(Holding.summary(list, now: at(60), calendar: gregorian)?.longestBefore?.days, 40)
        XCTAssertNil(Holding.summary(list, now: at(95), calendar: gregorian)?.longestBefore)
    }

    func testStackingPacePeriodsAndRounding() {
        XCTAssertNil(Holding.pace(received: 1_000_000, days: 0))
        XCTAssertNil(Holding.pace(received: 0, days: 10))
        XCTAssertEqual(Holding.pace(received: 3_000_000, days: 3)?.zatoshi, 1_000_000)
        XCTAssertEqual(Holding.pace(received: 3_000_000, days: 3)?.per, .day)
        XCTAssertEqual(Holding.pace(received: 14_000_000, days: 14)?.zatoshi, 7_000_000)
        XCTAssertEqual(Holding.pace(received: 14_000_000, days: 14)?.per, .week)
        XCTAssertEqual(Holding.pace(received: 120_000_000, days: 120)?.zatoshi, 30_000_000)
        XCTAssertEqual(Holding.pace(received: 120_000_000, days: 120)?.per, .month)
        // 1,234,567 zats over 10 days is 864,196.9 a week: 864,000.
        XCTAssertEqual(Holding.pace(received: 1_234_567, days: 10)?.zatoshi, 864_000)
    }

    func testTheMilestoneMomentIsShownOnceAndResetByErase() {
        let defaults = UserDefaults(suiteName: "zecky.tests.moment")!
        defaults.removePersistentDomain(forName: "zecky.tests.moment")
        XCTAssertFalse(MilestoneMoment.seen(since: at(1), days: 30, defaults: defaults))
        MilestoneMoment.markSeen(since: at(1), days: 30, defaults: defaults)
        XCTAssertTrue(MilestoneMoment.seen(since: at(1), days: 30, defaults: defaults))
        XCTAssertFalse(MilestoneMoment.seen(since: at(1), days: 365, defaults: defaults))
        XCTAssertFalse(MilestoneMoment.seen(since: at(2), days: 30, defaults: defaults))
        MilestoneMoment.reset(defaults: defaults)
        XCTAssertFalse(MilestoneMoment.seen(since: at(1), days: 30, defaults: defaults))
        defaults.removePersistentDomain(forName: "zecky.tests.moment")
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

    // MARK: Checking three words after writing them down

    func testTheWordCheckAsksThreeDifferentPositionsInOrder() {
        for _ in 0..<200 {
            let picked = WordCheck.pick(24)
            XCTAssertEqual(picked.count, 3)
            XCTAssertEqual(Set(picked).count, 3)
            XCTAssertEqual(picked, picked.sorted())
            XCTAssertTrue(picked.allSatisfy { (0..<24).contains($0) })
        }
    }

    func testTypedWordsCompareWithoutCaseOrSpaces() {
        XCTAssertTrue(WordCheck.matches("  Legal ", "legal"))
        XCTAssertFalse(WordCheck.matches("legel", "legal"))
        XCTAssertFalse(WordCheck.matches("", "legal"))
    }

    // MARK: Key ring order

    func testTheKeyRingKeepsTheOwnersOrderAndAddsNewWalletsAfter() {
        XCTAssertEqual(KeyRingOrder.ordered(["main", "a", "b"], saved: []), ["main", "a", "b"])
        XCTAssertEqual(KeyRingOrder.ordered(["main", "a", "b", "c"], saved: ["b", "main", "a"]), ["b", "main", "a", "c"])
        // A removed wallet drops out of the order.
        XCTAssertEqual(KeyRingOrder.ordered(["main", "b"], saved: ["a", "b", "main"]), ["b", "main"])
    }

    func testMovingAChipLeftAndRight() {
        XCTAssertEqual(KeyRingOrder.moved("b", by: -1, in: ["main", "a", "b"]), ["main", "b", "a"])
        XCTAssertEqual(KeyRingOrder.moved("main", by: 1, in: ["main", "a"]), ["a", "main"])
        XCTAssertEqual(KeyRingOrder.moved("main", by: -1, in: ["main", "a"]), ["main", "a"], "nothing left of the first")
        XCTAssertEqual(KeyRingOrder.moved("x", by: 1, in: ["main", "a"]), ["main", "a"])
    }

    // MARK: Handing the lock to another wallet

    // Public BIP39 test phrases only.
    private let lockA = "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
    private let lockB = "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
    private let other = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"

    private func entry(_ id: String, _ words: String, lock: String) throws -> KeyRingVault.Entry {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: try Mnemonic.seed(from: lock)),
                                       salt: Data("zecky".utf8), info: Data("zecky-lockit-keyring-v1".utf8), outputByteCount: 32)
        return KeyRingVault.Entry(id: id, name: id, birthday: 1, box: try AES.GCM.seal(Data(words.utf8), using: k).combined!)
    }

    private func words(_ e: KeyRingVault.Entry, lock: String) throws -> String? {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: try Mnemonic.seed(from: lock)),
                                       salt: Data("zecky".utf8), info: Data("zecky-lockit-keyring-v1".utf8), outputByteCount: 32)
        guard let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: e.box), using: k) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    func testAHandoverReencryptsTheOthersForTheNewLockAndDropsTheNewLead() throws {
        // Wallets b (becoming the lock) and c, both sealed under lock A.
        let list = [try entry("b", lockB, lock: lockA), try entry("c", other, lock: lockA)]
        let moved = try KeyRingVault.rekeyed(list, dropping: ["b"], oldMain: lockA, newMain: lockB)
        XCTAssertEqual(moved.map(\.id), ["c"])
        XCTAssertEqual(try words(moved[0], lock: lockB), other, "c opens to the same words with the new lock")
        XCTAssertNil(try words(moved[0], lock: lockA), "and no longer with the old one")
    }

    func testAHandoverStopsOnADamagedEntry() throws {
        var bad = try entry("c", other, lock: lockA)
        bad.box = Data(repeating: 1, count: bad.box.count)
        XCTAssertThrowsError(try KeyRingVault.rekeyed([bad], dropping: [], oldMain: lockA, newMain: lockB))
        // Entries made for another lock are refused too, never re-sealed blindly.
        XCTAssertThrowsError(try KeyRingVault.rekeyed([try entry("c", other, lock: lockB)], dropping: [], oldMain: lockA, newMain: lockB))
    }

    func testTheLockTagTellsLocksApartWithoutTheWords() throws {
        XCTAssertEqual(try KeyRingVault.lockTag(mainPhrase: lockA), try KeyRingVault.lockTag(mainPhrase: lockA))
        XCTAssertNotEqual(try KeyRingVault.lockTag(mainPhrase: lockA), try KeyRingVault.lockTag(mainPhrase: lockB))
    }

    // MARK: The sync ring (every block since the birthday, as Lock it iPhone)

    func testANightOfNewBlocksStartsHighNotAtZero() {
        // 100,000 blocks since the birthday, the newest 400 still to check.
        let share = SyncMath.checkedShare(toScan: [(199_600, 200_000)], birthday: 100_000, tip: 200_000)
        XCTAssertEqual(share ?? 0, 0.996, accuracy: 1e-9)
        XCTAssertEqual(SyncMath.ringPercent(share: share ?? 0, synced: false), 99.6)
    }

    func testRangesAreClippedAndOverlapsCountOnce() {
        // Open: 100…160 and 190…200 = 70 of 100.
        let share = SyncMath.checkedShare(toScan: [(50, 150), (120, 160), (190, 400)], birthday: 100, tip: 200)
        XCTAssertEqual(share ?? 0, 0.3, accuracy: 1e-9)
        // Older ranges below the birthday (another wallet's) do not count.
        XCTAssertEqual(SyncMath.checkedShare(toScan: [(10, 90)], birthday: 100, tip: 200), 1)
    }

    func testNever100BeforeUpToDateAlways100When() {
        XCTAssertEqual(SyncMath.ringPercent(share: 0.99999, synced: false), 99.9)
        XCTAssertEqual(SyncMath.ringPercent(share: 1, synced: false), 99.9)
        XCTAssertEqual(SyncMath.ringPercent(share: 0.5, synced: true), 100)
    }

    func testNoNumberWithoutANetworkBlock() {
        XCTAssertNil(SyncMath.checkedShare(toScan: [], birthday: 100, tip: 0))
    }

    func testThisWalletIsCheckedFromItsOwnBirthdayNotFromOlderRanges() {
        // Only an older range (another wallet's) is left: this wallet is complete.
        XCTAssertEqual(SyncMath.checkedThrough(toScan: [(3_425_600, 3_524_000)], birthday: 3_524_536, tip: 3_551_141), 3_551_141)
        // A gap after the birthday: checked up to its start.
        XCTAssertEqual(SyncMath.checkedThrough(toScan: [(3_540_000, 3_541_000)], birthday: 3_524_536, tip: 3_551_141), 3_540_000)
        XCTAssertNil(SyncMath.checkedThrough(toScan: [], birthday: 100, tip: 0))
    }

    func testOlderBlocksShareGrowsFromWhereTheyStarted() {
        // Nothing below the birthday: no older blocks.
        XCTAssertNil(SyncMath.older(toScan: [(150, 200)], birthday: 100, start: nil))
        // 0..<100 below a birthday of 100, half still open.
        let first = SyncMath.older(toScan: [(50, 120)], birthday: 100, start: nil)
        XCTAssertEqual(first?.start, 50)
        XCTAssertEqual(first?.share, 0)
        let later = SyncMath.older(toScan: [(75, 120)], birthday: 100, start: 50)
        XCTAssertEqual(later?.start, 50)
        XCTAssertEqual(later?.share ?? 0, 0.5, accuracy: 0.0001)
    }

    // MARK: Go Max

    func testGoMaxNodeSettings() {
        let zakura = GoMaxConfig.zakura(dataDir: "/tmp/Go Max/zakura", retention: 10_000)
        XCTAssertTrue(zakura.contains("checkpoint_sync = false"))
        XCTAssertTrue(zakura.contains("storage_mode = { pruned = { tx_retention = 10000 } }"))
        XCTAssertTrue(zakura.contains(#"p2p_stack = "legacy""#))
        XCTAssertTrue(zakura.contains(#"listen_addr = "127.0.0.1:8233""#))
        XCTAssertTrue(zakura.contains(#"listen_addr = "127.0.0.1:8232""#))
        XCTAssertTrue(zakura.contains(#"cache_dir = "/tmp/Go Max/zakura""#))
        XCTAssertTrue(zakura.contains(#"identity_dir = "/tmp/Go Max/zakura/identity""#))
        // The byte counters for the data overview, on this Mac only; left
        // out when their port is taken (Zakura would refuse to start).
        XCTAssertTrue(zakura.contains("[metrics]"))
        XCTAssertTrue(zakura.contains(#"endpoint_addr = "127.0.0.1:8234""#))
        XCTAssertTrue(zakura.contains("\n[tracing]"))
        let noMetrics = GoMaxConfig.zakura(dataDir: "/tmp/Go Max/zakura", retention: 10_000, metrics: false)
        XCTAssertFalse(noMetrics.contains("[metrics]"))
        XCTAssertFalse(noMetrics.contains("8234"))
        // Nothing listens beyond this Mac.
        XCTAssertFalse(zakura.contains("0.0.0.0"))
        XCTAssertFalse(zakura.contains("[::]"))
        let zaino = GoMaxConfig.zaino(dataDir: "/tmp/zaino")
        XCTAssertTrue(zaino.contains(#"listen_address = "127.0.0.1:8137""#))
        XCTAssertTrue(zaino.contains(#"validator_jsonrpc_listen_address = "127.0.0.1:8232""#))
        XCTAssertTrue(zaino.contains("ephemeral_finalised_state = true"))
        XCTAssertFalse(zaino.contains("0.0.0.0"))
    }

    func testGoMaxTomlStrings() {
        XCTAssertEqual(GoMaxConfig.tomlString(#"a "b" \c"#), #""a \"b\" \\c""#)
        XCTAssertEqual(GoMaxConfig.tomlString("x\ny"), #""x\u000Ay""#)
    }

    func testGoMaxRetentionDiskAndSizes() {
        XCTAssertEqual(GoMaxConfig.retention(widened: false), 10_000)
        XCTAssertEqual(GoMaxConfig.retention(widened: true), 100_000)
        XCTAssertEqual(GoMaxConfig.missingBytes(free: GoMaxConfig.minFreeBytes), 0)
        XCTAssertEqual(GoMaxConfig.missingBytes(free: 0), GoMaxConfig.minFreeBytes)
        XCTAssertEqual(GoMaxConfig.formatBytes(17_100_000_000), "17 GB")
        XCTAssertEqual(GoMaxConfig.formatBytes(1_500_000_000), "1.5 GB")
        XCTAssertEqual(GoMaxConfig.formatBytes(980_000_000), "980 MB")
    }

    func testGoMaxReadsTheNodesAnswer() {
        let answer: [String: Any] = ["blocks": 3_557_549, "estimatedheight": 3_557_550,
                                     "verificationprogress": 0.99999, "size_on_disk": 15_200_000_000, "pruned": true]
        let info = GoMaxChainInfo(rpcResult: answer)
        XCTAssertEqual(info?.blocks, 3_557_549)
        XCTAssertEqual(info?.sizeOnDisk, 15_200_000_000)
        XCTAssertEqual(info?.atTip, true)
        let notANumber: [String: Any] = ["blocks": true]
        XCTAssertNil(GoMaxChainInfo(rpcResult: notANumber))
        XCTAssertNil(GoMaxChainInfo(rpcResult: nil))
    }

    func testGoMaxStopHeight() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let stop = GoMaxSupport.stopHeight
        XCTAssertEqual(GoMaxSupport.state(reported: 0, seenAt: nil, now: now), .fine)
        XCTAssertEqual(GoMaxSupport.state(reported: stop - GoMaxSupport.noticeBlocks - 1, seenAt: nil, now: now), .fine)
        // Two weeks of blocks ahead: the notice, with the date of the stop.
        XCTAssertEqual(GoMaxSupport.state(reported: stop - 3_456, seenAt: nil, now: now),
                       .soon(now.addingTimeInterval(86_400)))
        XCTAssertEqual(GoMaxSupport.state(reported: stop, seenAt: nil, now: now), .soon(now))
        XCTAssertEqual(GoMaxSupport.state(reported: stop + 1, seenAt: nil, now: now), .ended)
        // An old height and the clock: near after the time that passed,
        // ended only a day of blocks past the stop.
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(GoMaxSupport.state(reported: stop - 3 * 3_456, seenAt: twoDaysAgo, now: now),
                       .soon(now.addingTimeInterval(86_400)))
        XCTAssertEqual(GoMaxSupport.state(reported: stop - 3_456, seenAt: twoDaysAgo, now: now), .soon(now))
        XCTAssertEqual(GoMaxSupport.state(reported: stop - 3_456, seenAt: now.addingTimeInterval(-3 * 86_400), now: now), .ended)
        // A stopped node stays stopped, whatever it is asked.
        XCTAssertEqual(GoMaxPhase.next(after: .expired, running: false, info: nil, wasEverReady: true), .expired)
        XCTAssertEqual(GoMaxWords.short(.expired, nil), "Needs an update")
    }

    func testGoMaxPausedOnBatteryStaysPausedUntilLockItResumesIt() {
        XCTAssertEqual(GoMaxPhase.next(after: .paused, running: false, info: nil, wasEverReady: false), .paused)
        XCTAssertEqual(GoMaxWords.short(.paused, nil), "Paused · plug in to sync")
        XCTAssertEqual(GoMaxWords.status(.paused, nil), "Paused on battery · carries on when the charger is connected")
    }

    func testBeforeYouStartGoMax() {
        let gib: UInt64 = 1_073_741_824
        let roomy = GoMaxComputer(freeBytes: 112_000_000_000, memoryBytes: 16 * gib, hasBattery: true, onBattery: false)
        XCTAssertTrue(roomy.enoughSpace)
        XCTAssertEqual(roomy.lines(hasData: false, onlyPluggedIn: true).map(\.good), [true, true, true, true])
        XCTAssertEqual(roomy.lines(hasData: false, onlyPluggedIn: true).map(\.text),
                       ["Free space: 112 GB (Go Max needs about 38 GB)", "Memory: 16 GB",
                        "Data: the first sync downloads about 350 GB. Use a connection without a data limit.", "Plugged in"])
        // Low Data Mode or a hotspot: a warning, never a stop.
        var limited = roomy
        limited.limitedConnection = true
        XCTAssertEqual(limited.lines(hasData: false, onlyPluggedIn: true)[2],
                       GoMaxComputer.Line(good: false, text: "Data: this connection is limited. The first sync downloads about 350 GB; better to use one without a data limit."))
        XCTAssertTrue(limited.enoughSpace)

        // Too little space: the only thing that stops a start.
        let full = GoMaxComputer(freeBytes: 12_000_000_000, memoryBytes: 8 * gib, hasBattery: false, onBattery: false)
        XCTAssertFalse(full.enoughSpace)
        let fullLines = full.lines(hasData: false, onlyPluggedIn: true)
        XCTAssertEqual(fullLines.count, 3)   // a desktop Mac: no power line
        XCTAssertFalse(fullLines[0].good)
        XCTAssertTrue(fullLines[0].text.hasPrefix("Free space: 12 GB. Go Max needs about 38 GB: free up"))
        XCTAssertTrue(fullLines[1].good)      // 8 GB is not warned
        // A node that already has its data needs no new room.
        XCTAssertTrue(full.lines(hasData: true, onlyPluggedIn: true)[0].good)

        // Little memory and on battery: warned, not stopped.
        let small = GoMaxComputer(freeBytes: 60_000_000_000, memoryBytes: 4 * gib, hasBattery: true, onBattery: true)
        let smallLines = small.lines(hasData: false, onlyPluggedIn: true)
        XCTAssertEqual(smallLines.map(\.good), [true, false, true, false])
        XCTAssertEqual(smallLines[3].text, "Running on battery. Plug in to sync: the first check waits for the charger.")
        // The first check done: no warning about it on battery.
        XCTAssertEqual(small.lines(hasData: true, onlyPluggedIn: true)[3],
                       GoMaxComputer.Line(good: true, text: "On battery. Catching up waits for the charger; up to date, the node keeps running."))
        XCTAssertEqual(small.lines(hasData: false, onlyPluggedIn: false)[3].text,
                       "Running on battery. The first check drains the battery quickly; plug in if you can.")
    }

    func testExpectedFinishCountsTheSpamYears() throws {
        XCTAssertEqual(GoMaxPace.work(0), 0)
        // A spam block is much more work than one before or after.
        XCTAssertGreaterThan(GoMaxPace.work(GoMaxPace.spamStart + 1) - GoMaxPace.work(GoMaxPace.spamStart),
                             4 * (GoMaxPace.work(GoMaxPace.spamEnd + 1) - GoMaxPace.work(GoMaxPace.spamEnd)))

        let t = Date(timeIntervalSince1970: 1_763_200_000)
        var samples = GoMaxPace.Samples()
        samples.add(t, 1_855_000)
        XCTAssertNil(samples.finish(tip: 3_560_000), "one sample is not a speed")
        // 7,200 blocks an hour in the spam years, as on a tester's laptop.
        samples.add(t.addingTimeInterval(3_600), 1_862_200)
        let finish = try XCTUnwrap(samples.finish(tip: 3_560_000))
        let hours = finish.timeIntervalSince(t.addingTimeInterval(3_600)) / 3_600
        // At spam speed the rest would take (3,560,000 - 1,862,200) / 7,200
        // = 236 hours; counted with the faster rest it is far less…
        XCTAssertLessThan(hours, 236)
        // …but more than the spam that is left alone: 237,800 blocks at 7,200 an hour.
        XCTAssertGreaterThan(hours, Double(GoMaxPace.spamEnd - 1_862_200) / 7_200)

        // Nothing moved, or the node started over: no estimate.
        var still = GoMaxPace.Samples()
        still.add(t, 100)
        still.add(t.addingTimeInterval(1_000), 100)
        XCTAssertNil(still.finish(tip: 200))
        still.add(t.addingTimeInterval(2_000), 50)
        XCTAssertNil(still.finish(tip: 200))
        // Less than a quarter of an hour: no estimate yet.
        var short = GoMaxPace.Samples()
        short.add(t, 100)
        short.add(t.addingTimeInterval(600), 200)
        XCTAssertNil(short.finish(tip: 1_000))
    }

    func testTheSpamLineAndTheFinishWords() {
        XCTAssertTrue(GoMaxPace.spamLine(height: 1_000_000).hasPrefix("Ahead: the spam years"))
        XCTAssertTrue(GoMaxPace.spamLine(height: 1_905_000).contains(": 50% of this stretch done"))
        XCTAssertTrue(GoMaxPace.spamLine(height: 2_200_000).hasPrefix("The spam years are done"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let now = Date(timeIntervalSince1970: 1_763_200_000)   // Sat 15 Nov 2025, 10:46:40 in Amsterdam
        XCTAssertEqual(GoMaxPace.finishText(nil, now: now, calendar: calendar), "Measuring speed…")
        XCTAssertEqual(GoMaxPace.finishText(now.addingTimeInterval(300), now: now, calendar: calendar), "In a few minutes")
        // More than 3 hours away: to the hour (10:46:40 + 5 h = 15:46:40 → 16:00).
        // (Newer macOS puts a narrow space before PM.)
        func text(_ at: Date) -> String {
            GoMaxPace.finishText(at, now: now, calendar: calendar).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(text(now.addingTimeInterval(5 * 3_600)), "About Sat, Nov 15 at 4:00 PM")
        // Closer: to 10 minutes (10:46:40 + 1 h = 11:46:40 → 11:50).
        XCTAssertEqual(text(now.addingTimeInterval(3_600)), "About Sat, Nov 15 at 11:50 AM")
    }

    @MainActor func testGenuineNodeAnswersOnThisMacOnlyBehindItsOnion() {
        // The answering port is not the node's peer-to-peer port, and the
        // node's own ports never listen beyond this Mac.
        XCTAssertNotEqual(Int(AttestedStatementMaker.port), GoMaxConfig.p2pPort)
        XCTAssertEqual(GoMaxConfig.host, "127.0.0.1")
    }

    func testTheDataOverviewKeepsCountingOverRestarts() {
        let text = """
        # TYPE zcash_net_in_bytes_total counter
        zcash_net_in_bytes_total 1500
        zcash_net_out_bytes_total{peer="a"} 20
        zcash_net_out_bytes_total{peer="b"} 22
        zcash_net_in_bytes_total_other 9
        """
        XCTAssertEqual(GoMaxData.counter(GoMaxData.inCounter, in: text), 1_500)
        XCTAssertEqual(GoMaxData.counter(GoMaxData.outCounter, in: text), 42)
        XCTAssertNil(GoMaxData.counter("missing", in: text))

        var total = GoMaxData.Total()
        total.read(1_000)
        total.read(1_500)
        XCTAssertEqual(total.total, 1_500)
        // Lock it starts Zakura again: what it counted is kept.
        total.restart()
        total.read(200)
        XCTAssertEqual(total.total, 1_700)
        // Zakura restarted by itself: a lower reading than before.
        total.read(50)
        XCTAssertEqual(total.total, 1_750)

        XCTAssertEqual(GoMaxData.removed(downloaded: 212.4e9, kept: 18.6e9), 193.8e9, accuracy: 1)
        XCTAssertEqual(GoMaxData.removed(downloaded: 5e9, kept: 18e9), 0)
        XCTAssertEqual(GoMaxData.format(212.4e9), "212.4 GB")
        XCTAssertEqual(GoMaxData.format(980e6), "980 MB")
    }

    func testGoMaxPhases() {
        let syncing = GoMaxChainInfo(blocks: 2_000_000, estimatedHeight: 3_557_000, verificationProgress: 0.6)
        let tip = GoMaxChainInfo(blocks: 3_557_000, estimatedHeight: 3_557_001, verificationProgress: 1)
        let slightlyBehind = GoMaxChainInfo(blocks: 3_556_990, estimatedHeight: 3_557_000, verificationProgress: 0.9999)
        let afterSleep = GoMaxChainInfo(blocks: 3_556_800, estimatedHeight: 3_557_000, verificationProgress: 0.9999)
        XCTAssertEqual(GoMaxPhase.next(after: .starting, running: true, info: nil, wasEverReady: false), .starting)
        XCTAssertEqual(GoMaxPhase.next(after: .starting, running: true, info: syncing, wasEverReady: false), .syncing)
        XCTAssertEqual(GoMaxPhase.next(after: .syncing, running: true, info: tip, wasEverReady: false), .ready)
        XCTAssertEqual(GoMaxPhase.next(after: .ready, running: true, info: slightlyBehind, wasEverReady: true), .ready)
        XCTAssertEqual(GoMaxPhase.next(after: .ready, running: true, info: afterSleep, wasEverReady: true), .catchingUp)
        XCTAssertEqual(GoMaxPhase.next(after: .ready, running: false, info: tip, wasEverReady: true), .problem)
        XCTAssertEqual(GoMaxPhase.next(after: .stopped, running: true, info: tip, wasEverReady: true), .stopped)
        XCTAssertEqual(GoMaxPhase.next(after: .updating, running: true, info: nil, wasEverReady: true), .updating)
    }

    func testGoMaxWords() {
        XCTAssertEqual(GoMaxWords.behind(10), "a few minutes behind")
        XCTAssertEqual(GoMaxWords.behind(100), "about 40 minutes behind")
        XCTAssertEqual(GoMaxWords.behind(288), "about 2 hours behind")
        XCTAssertEqual(GoMaxWords.behind(10_000), "about 3 days behind")
        XCTAssertEqual(GoMaxWords.status(.ready, nil), "Up to date · every block since Canopy verified on this Mac")
        // Ready but 45 blocks behind (12 Nov: called up to date while stuck without peers).
        let lagging = GoMaxChainInfo(blocks: 3_564_845, estimatedHeight: 3_564_890, verificationProgress: 0.99999)
        XCTAssertEqual(GoMaxWords.status(.ready, lagging), "A little behind · 45 blocks to catch up")
        XCTAssertEqual(GoMaxWords.short(.ready, lagging), "Catching up")
        let atTip = GoMaxChainInfo(blocks: 3_564_890, estimatedHeight: 3_564_891, verificationProgress: 0.99999)
        XCTAssertEqual(GoMaxWords.short(.ready, atTip), "Up to date")
        // Three or four blocks "behind" the clock's estimate is still up to date.
        let nearTip = GoMaxChainInfo(blocks: 3_564_887, estimatedHeight: 3_564_891, verificationProgress: 0.99999)
        XCTAssertEqual(GoMaxWords.status(.ready, nearTip), "Up to date · every block since Canopy verified on this Mac")
        XCTAssertEqual(GoMaxWords.peers(1), "Connected to 1 other Zcash node")
        XCTAssertEqual(GoMaxWords.peers(14), "Connected to 14 other Zcash nodes")
        XCTAssertEqual(GoMaxWords.status(.off, nil), "Off")
        let syncing = GoMaxChainInfo(blocks: 2_000_000, estimatedHeight: 3_557_000, verificationProgress: 0.605)
        XCTAssertTrue(GoMaxWords.status(.syncing, syncing).hasPrefix("Checking history · 60% · verified up to "))
        XCTAssertEqual(GoMaxWords.storage(sizeOnDisk: 15_200_000_000, retention: 100_000), "Using 15 GB · keeps about 4 weeks of recent blocks")
        XCTAssertEqual(GoMaxWords.storage(sizeOnDisk: 15_200_000_000, retention: 10_000), "Using 15 GB · keeps a few days of recent blocks")
        XCTAssertEqual(GoMaxWords.short(.syncing, syncing), "Checking history · 60%")
    }

    func testGoMaxBlockDates() {
        // Genesis, Blossom and NU7 by their known dates.
        let date = { (h: Int) in GoMaxWords.verifiedDate(GoMaxChainInfo(blocks: h, estimatedHeight: 3_557_000, verificationProgress: 0)) }
        XCTAssertEqual(date(0), "Oct 28, 2016")
        XCTAssertEqual(date(653_600), "Dec 11, 2019")
        XCTAssertEqual(date(3_543_405), "Oct 25, 2026")
        // Canopy (Nov 18, 2020), between the anchors.
        XCTAssertEqual(date(1_046_400), "Nov 18, 2020")
    }

    func testGoMaxReadsHTTPAnswers() {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        XCTAssertEqual(LocalRPC.body(of: plain), Data("{}".utf8))
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(LocalRPC.body(of: chunked), Data("{\"a\":1}".utf8))
        XCTAssertNil(LocalRPC.body(of: Data("HTTP/1.1 500 Internal Server Error\r\n\r\n".utf8)))
    }

    // MARK: Sending over Tor

    func testExactAmounts() {
        XCTAssertEqual(Amount.exact(10_000, .zec), "0.0001 ZEC")
        XCTAssertEqual(Amount.exact(100_000, .zec), "0.001 ZEC")
        XCTAssertEqual(Amount.exact(110_000, .zec), "0.0011 ZEC")
        XCTAssertEqual(Amount.exact(123_450_000_000, .zec), "1,234.500 ZEC")
        XCTAssertEqual(Amount.exact(1, .zec), "0.00000001 ZEC")
        XCTAssertEqual(Amount.exact(10_000, .zats), "10,000 zats")
    }

    func testSendOutcomes() throws {
        let server = LightWalletEndpoint(address: "zec.rocks", port: 443, secure: true)
        // Accepted is sent, with or without Tor.
        XCTAssertEqual(try WalletEngine.outcome(of: [.accepted(by: server)], overTor: true), .sent)
        // Tor could not connect: waiting, never "sent".
        XCTAssertEqual(try WalletEngine.outcome(of: [.unreachable], overTor: true), .waitingForTor)
        XCTAssertEqual(try WalletEngine.outcome(of: [.unreachable], overTor: false), .saved)
        // No answer in time: over Tor that is "Tor did not connect" too.
        XCTAssertEqual(try WalletEngine.outcome(of: [.timedOut], overTor: true), .waitingForTor)
        XCTAssertEqual(try WalletEngine.outcome(of: [.timedOut], overTor: false), .saved)
        XCTAssertEqual(try WalletEngine.outcome(of: [.accepted(by: server), .notAttempted], overTor: true), .saved)
        // A refusal is an error, nothing was sent.
        XCTAssertThrowsError(try WalletEngine.outcome(of: [.rejected(code: -25, message: "no")], overTor: true))
    }

    func testTorNeverGetsThePrivateNode() {
        // Over Tor, whatever server is chosen: public servers only, two of them, with TLS.
        let endpoints = Server.broadcastEndpoints(overTor: true)
        XCTAssertEqual(endpoints.count, 2)
        for endpoint in endpoints {
            XCTAssertFalse(Server.isHomeNode(endpoint.host), endpoint.host)
            XCTAssertFalse(endpoint.isOnPrivateNetwork, endpoint.host)
            XCTAssertTrue(endpoint.secure)
        }
        // Without Tor: the server Lock it reads from, and only that.
        XCTAssertEqual(Server.broadcastEndpoints(overTor: false).map(\.host), [Server.host])
    }

    func testUndeliveredPaymentsAreRemembered() {
        // A dummy id, removed again: the real list is left as it was.
        let id = Data((0..<32).map { UInt8($0) })
        XCTAssertFalse(Undelivered.ids.contains(id))
        Undelivered.insert(id)
        XCTAssertTrue(Undelivered.ids.contains(id))
        Undelivered.remove(id)
        XCTAssertFalse(Undelivered.ids.contains(id))
    }

    func testWalletReadsOlderBlocksFromItsServer() {
        // The node answered "block not found" for a block it has dropped: the wallet needs its server.
        XCTAssertEqual(GoMaxReading.missing(oldestNeeded: 3_172_501, nodeBlocks: 3_565_431, nodeHasIt: false), 3_172_501)
        // The node has the oldest block the wallet needs: it can serve the wallet.
        XCTAssertNil(GoMaxReading.missing(oldestNeeded: 3_564_890, nodeBlocks: 3_565_431, nodeHasIt: true))
        // Nothing left to check, or no answer from the node: nothing is concluded.
        XCTAssertNil(GoMaxReading.missing(oldestNeeded: nil, nodeBlocks: 3_565_431, nodeHasIt: false))
        XCTAssertNil(GoMaxReading.missing(oldestNeeded: 3_172_501, nodeBlocks: 3_565_431, nodeHasIt: nil))
        // A block above the node's newest is not an older block: the node is a little behind.
        XCTAssertNil(GoMaxReading.missing(oldestNeeded: 3_565_440, nodeBlocks: 3_565_431, nodeHasIt: false))
    }

    func testNodeAnswerAboutABlock() {
        func answer(_ status: String, _ body: String) -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
        }
        // As the node answered on 12 Nov 2026.
        let dropped = #"{"jsonrpc":"1.0","id":"1","result":null,"error":{"code":-1,"message":"block not found"}}"#
        let kept = #"{"jsonrpc":"1.0","id":"1","result":{"hash":"00","height":3564000}}"#
        XCTAssertEqual(LocalRPC.blockFound(in: answer("200 OK", dropped)), false)
        XCTAssertEqual(LocalRPC.blockFound(in: answer("500 Internal Server Error", dropped)), false)
        XCTAssertEqual(LocalRPC.blockFound(in: answer("200 OK", kept)), true)
        XCTAssertNil(LocalRPC.blockFound(in: answer("200 OK", "not json")))
        XCTAssertNil(LocalRPC.blockFound(in: Data()))
    }

    func testWalletQuietOnItsNode() {
        // Five minutes of blocks the wallet has not heard of.
        XCTAssertTrue(GoMaxReading.walletQuiet(nodeBlocks: 3_565_454, walletNetwork: 3_565_431))
        XCTAssertFalse(GoMaxReading.walletQuiet(nodeBlocks: 3_565_435, walletNetwork: 3_565_431))
        // Before the wallet knows any block, nothing is concluded.
        XCTAssertFalse(GoMaxReading.walletQuiet(nodeBlocks: 3_565_454, walletNetwork: 0))
    }

    func testOlderBlocksWordsAndAddWalletWords() {
        XCTAssertEqual(GoMaxWords.olderBlocks(from: 3_172_501, server: "eu.zec.rocks"),
                       "Lock it reads older blocks (from block 3,172,501) from eu.zec.rocks: this node keeps only recent blocks. It returns to this node by itself once they are checked.")
        XCTAssertEqual(String(describing: WalletEngine.plain(ZcashError.synchronizerNotPrepared)),
                       "Lock it is still connecting. Try again in a moment.")
    }

    func testWalletsKeptOutOfSight() {
        let ids = [KeyRingOrder.main, "aa", "bb", "cc"]
        // Out of sight: off the row, back on it while the star shows them.
        XCTAssertEqual(KeyRingHidden.inSight(ids, hidden: ["bb"], showing: false), [KeyRingOrder.main, "aa", "cc"])
        XCTAssertEqual(KeyRingHidden.inSight(ids, hidden: ["bb"], showing: true), ids)
        // The main wallet never goes out of sight, whatever was saved.
        XCTAssertEqual(KeyRingHidden.with(KeyRingOrder.main, in: []), [])
        XCTAssertEqual(KeyRingHidden.inSight(ids, hidden: [KeyRingOrder.main], showing: false), ids)
        // Adding twice keeps one; taking away works.
        XCTAssertEqual(KeyRingHidden.with("bb", in: ["bb"]), ["bb"])
        XCTAssertEqual(KeyRingHidden.without("bb", in: ["aa", "bb"]), ["aa"])
        // Move right among the wallets in sight steps over the one out of sight.
        XCTAssertEqual(KeyRingOrder.moved("aa", by: 1, in: ids, among: [KeyRingOrder.main, "aa", "cc"]), [KeyRingOrder.main, "cc", "bb", "aa"])
        // At the end of the row nothing moves.
        XCTAssertEqual(KeyRingOrder.moved("cc", by: 1, in: ids, among: [KeyRingOrder.main, "aa", "cc"]), ids)
    }

    func testStoppedWhileStartingSaysWhatToDo() {
        // One short, calm line on the page; the steps only behind "Still not working?".
        XCTAssertLessThan(GoMaxWords.stoppedWhileStarting.count, 110)
        XCTAssertTrue(GoMaxWords.stoppedWhileStarting.contains("Your wallet is fine"))
        XCTAssertTrue(GoMaxWords.stillNotWorking.contains("Remove node and its data"))
        XCTAssertTrue(GoMaxWords.stillNotWorking.contains("Show the node's logs"))
    }

    func testStopIsNotJudgedByTheNodesGuessDuringFirstSync() {
        // As seen on 13 Nov 2026: first check of history at 2017, the node's
        // estimate about 60,000 blocks too high, the wallet's server correct.
        let h = GoMaxSupport.networkHeight(nodeBlocks: 470_000, nodeEstimate: 3_629_500,
                                           verificationProgress: 0.01, walletNetwork: 3_569_000)
        XCTAssertEqual(h, 3_569_000)
        XCTAssertEqual(GoMaxSupport.state(reported: h, seenAt: nil, now: Date(), stopHeight: 3_643_309), .fine)
        // Even an estimate past the stop does not end Go Max mid-sync.
        XCTAssertEqual(GoMaxSupport.networkHeight(nodeBlocks: 470_000, nodeEstimate: 3_700_000,
                                                  verificationProgress: 0.01, walletNetwork: 3_569_000), 3_569_000)
        // Before the wallet knows a height, the node's verified blocks count.
        XCTAssertEqual(GoMaxSupport.networkHeight(nodeBlocks: 470_000, nodeEstimate: 3_629_500,
                                                  verificationProgress: 0.01, walletNetwork: 0), 470_000)
        // Close to the newest block, the node's estimate counts again (the stop itself).
        let atStop = Date(timeIntervalSince1970: 1_796_500_000) // 5 Dec 2026
        XCTAssertEqual(GoMaxSupport.networkHeight(nodeBlocks: 3_643_300, nodeEstimate: 3_643_320,
                                                  verificationProgress: 0.9999, walletNetwork: 3_643_300, now: atStop), 3_643_320)
    }

    // MARK: Attested statements (experiment)

    func testStateFingerprintV0MatchesTheNodeCheck() throws {
        // Height 3,572,141 as read from a caught-up Go Max node on 14 Nov 2026,
        // twice, with the same answers. The hash was worked out separately
        // (Python, sort_keys, no spaces) from the same answers.
        let block: [String: Any] = [
            "height": 3_572_141,
            "hash": "00000000004cd7dd4872e1297afcff16d35326e9866c66fe99f3fe4eb5c95cb8",
            "blockcommitments": "49647988e37d90f6c388891372bc01e876b74be2ac0d0a7bba9b8a353cd27591",
            "trees": ["sapling": ["size": Int64(73_998_529)], "orchard": ["size": Int64(50_482_901)], "ironwood": ["size": Int64(1_221_975)]],
            "valuePools": [
                ["id": "transparent", "chainValueZat": Int64(1_203_207_003_547_583)],
                ["id": "sprout", "chainValueZat": Int64(1_222_421_094_946)],
                ["id": "sapling", "chainValueZat": Int64(41_799_243_186_949)],
                ["id": "orchard", "chainValueZat": Int64(32_095_005_911_000)],
                ["id": "lockbox", "chainValueZat": Int64(7_623_449_971_263)],
                ["id": "ironwood", "chainValueZat": Int64(418_168_756_608_146)],
            ],
            "chainSupply": ["chainValueZat": Int64(1_704_115_880_319_887)],
        ]
        func pool(_ root: String) -> [String: Any] { ["commitments": ["finalRoot": root]] }
        let tree: [String: Any] = [
            "hash": "00000000004cd7dd4872e1297afcff16d35326e9866c66fe99f3fe4eb5c95cb8",
            "sapling": pool("10bbab91363c4fbea88fb7587b4a4c4bffda5bc86416e9c8265bac0ba70cb743"),
            "orchard": pool("f678cf38d95a8f9e237bf1a60ce64885fad0aac4aa9275603c6460e2f2696f36"),
            "ironwood": pool("2a7de8393e1af1ce6cb442703370be3bd77d1061eb045ee6dd5be89990c9171f"),
        ]
        let fingerprint = try XCTUnwrap(StateFingerprint.make(block: block, treeState: tree))
        let json = try StateFingerprint.canonicalJSON(fingerprint)
        XCTAssertEqual(StateFingerprint.sha256Hex(json), "f17eb64d714918b65d3994aa22a60a24288bbd18e1ed8e6608e6883de5da9d5c")
        // A tree state from another block is refused.
        var other = tree
        other["hash"] = "00"
        XCTAssertNil(StateFingerprint.make(block: block, treeState: other))
    }

    func testStatementClientDataCarriesTheChallenge() throws {
        let json = try StatementClientData.json(
            fingerprintSHA256: "f17eb64d714918b65d3994aa22a60a24288bbd18e1ed8e6608e6883de5da9d5c",
            challenge: String(repeating: "ab", count: 32))
        // The same bytes as the verifier's Python check.
        XCTAssertEqual(StateFingerprint.sha256Hex(json), "5ccba1dc81a5bd165c8add75720af17ce187277d810e1fc5d46f2e24a327db5b")
        XCTAssertTrue(StatementClientData.validChallenge(""))
        XCTAssertTrue(StatementClientData.validChallenge(String(repeating: "0f", count: 32)))
        XCTAssertFalse(StatementClientData.validChallenge(String(repeating: "AB", count: 32)))
        XCTAssertFalse(StatementClientData.validChallenge("abc"))
    }

    func testStatementClientDataV2SignsTheNodeState() throws {
        let c = String(repeating: "ab", count: 32)
        let syncing = StatementClientData.NodeState(state: "syncing", tip: 3_412_000, estimate: 3_576_300)
        let json = try StatementClientData.jsonV2(fingerprintSHA256: "", challenge: c, node: syncing)
        // Sorted keys, no spaces: the same bytes the verifier rebuilds.
        XCTAssertEqual(String(decoding: json, as: UTF8.self),
                       "{\"challenge\":\"\(c)\",\"fingerprintSHA256\":\"\",\"node\":{\"estimate\":3576300,\"state\":\"syncing\",\"tip\":3412000},\"purpose\":\"zecky-go-max-state\",\"v\":2}")
        let stopped = StatementClientData.NodeState(state: "not-running", tip: nil, estimate: 3_576_300)
        XCTAssertNil(stopped.dictionary["tip"])
    }

    func testStatementSummaryForTheLog() throws {
        let syncing = try JSONSerialization.data(withJSONObject: [
            "nodeState": ["state": "syncing", "tip": 3_412_000, "estimate": 3_576_300], "fingerprintNote": "syncing"])
        XCTAssertEqual(AttestedStatementMaker.summary(of: syncing), " · syncing at block 3412000, no fingerprint (syncing)")
        let upToDate = try JSONSerialization.data(withJSONObject: [
            "nodeState": ["state": "up-to-date", "tip": 3_576_300, "estimate": 3_576_300],
            "fingerprint": ["v": 0], "height": 3_576_200])
        XCTAssertEqual(AttestedStatementMaker.summary(of: upToDate), " · up to date, fingerprint at 3576200")
    }

    /// A real statement from TestFlight build 8, asked from another machine
    /// over Tor on 15 Nov 2026 and checked with tools/verify-statement.
    /// A real answer kept on this Mac only, never in the repository (it
    /// carries an App Attest key ID): the newest asked-*.json in GoMax/logs,
    /// saved by "Check another node". Without one, these tests are skipped.
    private func localStatement() throws -> (data: Data, challenge: String) {
        let logs = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("GoMax/logs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.lastPathComponent.hasPrefix("asked-") && $0.pathExtension == "json" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        guard let newest else { throw XCTSkip("No asked-*.json in GoMax/logs yet: check a node first, then run the tests again.") }
        let data = try Data(contentsOf: newest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (data, try XCTUnwrap(json["challenge"] as? String))
    }

    func testAKeyIsCheckedAtTheMomentAppleAttestedIt() throws {
        // Apple's leaf certificate is valid for three days; the chain is
        // checked when Apple attested the key, so older keys still pass.
        let (data, challenge) = try localStatement()
        let result = StatementCheck.check(data, expectedAppID: "W2F7RNV886.app.zecky.lockit", challenge: challenge)
        XCTAssertTrue(result.genuine, result.reason)
        let attested = try XCTUnwrap(result.attestedAt)
        XCTAssertLessThan(attested, Date())
        XCTAssertNotNil(result.keyId)
        // Apple attests a build number for TestFlight and App Store builds
        // only; an answer from an Xcode build carries none.
    }

    func testDiscoveryAcceptsOnlyV3OnionNames() {
        let good = String(repeating: "a", count: 50) + "234567.onion"
        XCTAssertTrue(GenuineNodes.validOnion(good))
        XCTAssertFalse(GenuineNodes.validOnion(good.uppercased()))
        XCTAssertFalse(GenuineNodes.validOnion(String(repeating: "a", count: 55) + ".onion"))
        XCTAssertFalse(GenuineNodes.validOnion(String(repeating: "a", count: 50) + "234561.onion"))
        XCTAssertFalse(GenuineNodes.validOnion(String(repeating: "a", count: 56) + ".onion/x"))
        XCTAssertFalse(GenuineNodes.validOnion("http://" + good))
    }

    func testStatementCheckAcceptsAGenuineAnswerAndNothingElse() throws {
        let app = "W2F7RNV886.app.zecky.lockit"
        let (data, challenge) = try localStatement()
        let genuine = StatementCheck.check(data, expectedAppID: app, challenge: challenge)
        XCTAssertTrue(genuine.genuine, genuine.reason)

        // Another challenge: not fresh for this asker.
        XCTAssertFalse(StatementCheck.check(data, expectedAppID: app, challenge: String(repeating: "00", count: 32)).genuine)
        // Another app.
        XCTAssertFalse(StatementCheck.check(data, expectedAppID: "ABCDE12345.app.zecky.lockit", challenge: challenge).genuine)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // A changed fingerprint, when the answer has one.
        if let text = json["fingerprintJSON"] as? String {
            json["fingerprintJSON"] = text + " "
            let altered = try JSONSerialization.data(withJSONObject: json)
            XCTAssertFalse(StatementCheck.check(altered, expectedAppID: app, challenge: challenge).genuine)
            json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        // Client data the key did not sign.
        var client = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((json["clientDataJSON"] as? String ?? "").utf8)) as? [String: Any])
        client["fingerprintSHA256"] = String(repeating: "0", count: 64)
        json["fingerprintSHA256"] = client["fingerprintSHA256"]
        json["clientDataJSON"] = String(decoding: try StateFingerprint.canonicalJSON(client), as: UTF8.self)
        json.removeValue(forKey: "fingerprintJSON")
        let swapped = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(StatementCheck.check(swapped, expectedAppID: app, challenge: challenge).genuine)
    }

    func testStatementRequestsAreParsedStrictly() {
        let c = String(repeating: "ab", count: 32)
        func parse(_ query: String) -> StatementRequest? {
            if case .success(let r) = StatementRequest.parse("GET /statement?\(query) HTTP/1.1") { return r }
            return nil
        }
        XCTAssertEqual(parse("challenge=\(c)"), StatementRequest(challenge: c, height: nil))
        XCTAssertEqual(parse("challenge=\(c)&height=3572944"), StatementRequest(challenge: c, height: 3_572_944))
        XCTAssertEqual(parse("height=3572944&challenge=\(c)"), StatementRequest(challenge: c, height: 3_572_944))
        XCTAssertNil(parse("height=3572944"))                         // no challenge
        XCTAssertNil(parse("challenge="))                             // empty challenge
        XCTAssertNil(parse("challenge=\(c.uppercased())"))
        XCTAssertNil(parse("challenge=\(c)&height=0"))
        XCTAssertNil(parse("challenge=\(c)&height=-5"))
        XCTAssertNil(parse("challenge=\(c)&height=12a"))
        XCTAssertNil(parse("challenge=\(c)&height=1&height=2"))      // repeated
        XCTAssertNil(parse("challenge=\(c)&challenge=\(c)"))
        XCTAssertNil(parse("challenge=\(c)&other=1"))                // unknown
        if case .success = StatementRequest.parse("POST /statement?challenge=\(c) HTTP/1.1") { XCTFail("only GET") }
    }

    func testStatementRequestsAreLimitedPerMinute() {
        var limit = RequestLimit()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<6 { XCTAssertTrue(limit.allow(at: start.addingTimeInterval(Double(i))).allowed) }
        let seventh = limit.allow(at: start.addingTimeInterval(10))
        XCTAssertFalse(seventh.allowed)
        XCTAssertEqual(seventh.retryAfter, 50)                   // the first leaves at 60 s
        XCTAssertFalse(limit.allow(at: start.addingTimeInterval(59.5)).allowed)
        XCTAssertTrue(limit.allow(at: start.addingTimeInterval(60)).allowed)   // one left the window
        XCTAssertFalse(limit.allow(at: start.addingTimeInterval(60.5)).allowed)
        XCTAssertEqual(limit.recent.count, 6)                    // refusals are not counted
    }

    func testHeightsTheClockDoesNotAllowAreNotTrusted() {
        // 14 Nov 2026, 13:10 UTC: the real tip was 3,572,285.
        let now = Date(timeIntervalSince1970: 1_794_661_800)
        let limit = GoMaxSupport.plausibleMax(at: now)
        XCTAssertGreaterThan(limit, 3_572_285)
        XCTAssertLessThan(limit, 3_590_000)
        // A remembered guess about 26,000 blocks too high is dropped; a real one is kept.
        XCTAssertEqual(GoMaxSupport.trustedRemembered(height: 3_598_400, seenAt: now, now: now), 0)
        XCTAssertEqual(GoMaxSupport.trustedRemembered(height: 3_572_285, seenAt: now, now: now), 3_572_285)
        // Dropped, it shows no early notice.
        XCTAssertEqual(GoMaxSupport.state(reported: GoMaxSupport.trustedRemembered(height: 3_598_400, seenAt: now, now: now),
                                          seenAt: now, now: now, stopHeight: 3_643_309), .fine)
        // A caught-up node's estimate above the clock is capped; its verified blocks are not.
        XCTAssertEqual(GoMaxSupport.networkHeight(nodeBlocks: 3_572_285, nodeEstimate: 3_640_000,
                                                  verificationProgress: 1, walletNetwork: 3_572_285, now: now), limit)
        XCTAssertEqual(GoMaxSupport.networkHeight(nodeBlocks: 3_643_400, nodeEstimate: 0,
                                                  verificationProgress: 1, walletNetwork: 0, now: now), 3_643_400)
    }
}
