import CryptoKit
import LocalAuthentication
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
        XCTAssertThrowsError(try WalletEngine.outcome(of: [.rejected(code: -25, message: "no")], overTor: true)) {
            XCTAssertTrue(String(describing: $0).contains("Nothing was sent"))
        }
        // A TEX payment is two transactions. Step 1 accepted, step 2 refused:
        // part of it went out, so never "nothing was sent" (21 Nov 2026).
        XCTAssertThrowsError(try WalletEngine.outcome(of: [.accepted(by: server), .rejected(code: -25, message: "expired")],
                                                       overTor: false)) {
            let text = String(describing: $0)
            XCTAssertTrue(text.hasPrefix("Only part of this payment went through"), text)
            XCTAssertFalse(text.contains("Nothing was sent"))
        }
    }

    /// Seen 21 Nov 2026: step 2 of a TEX payment showed as "Sent −0.000 ZEC".
    /// The engine puts the tex1 receiver on step 1 (seen on the real pair).
    func testActivityNamesBothStepsOfATexPayment() {
        typealias Item = WalletEngine.ActivityItem
        let tex = "tex18qayysmdg7qqk4qta0vh0xss8ngx3qytyj4828"
        let at = Date(timeIntervalSince1970: 1_795_211_580)
        let step1 = Item(id: Data([1]), kind: .sent, amount: 110_000, date: at, state: .confirmed,
                         minedHeight: 3_597_827, fee: 10_000, texReceiver: tex)
        let step2 = Item(id: Data([2]), kind: .sent, amount: 15_000, date: at, state: .confirmed,
                         minedHeight: 3_597_827, fee: 15_000)
        let plain = Item(id: Data([3]), kind: .sent, amount: 15_000, date: at.addingTimeInterval(-86_400), state: .confirmed,
                         minedHeight: 3_590_000, fee: 15_000)
        let marked = Item.markTexSteps([step1, step2, plain])
        XCTAssertEqual(marked[0].title, "TEX payment")
        XCTAssertEqual(marked[1].title, "TEX payment · forwarding fee")
        XCTAssertEqual(marked[1].texReceiver, tex)
        XCTAssertEqual(marked[2].title, "Sent", "a fee-only payment in another block is not a TEX step")
        // The expired pair of a refused attempt: no block, same moment.
        let e1 = Item(id: Data([4]), kind: .sent, amount: 110_000, date: nil, state: .expired, fee: 10_000, texReceiver: tex)
        let e2 = Item(id: Data([5]), kind: .sent, amount: 15_000, date: nil, state: .expired, fee: 15_000)
        XCTAssertEqual(Item.markTexSteps([e1, e2]).map(\.title), ["TEX payment", "TEX payment · forwarding fee"])
        XCTAssertEqual(Item.short(tex), "tex18qayysmd…yj4828")
        XCTAssertEqual(Item(id: Data([6]), kind: .received, amount: 1, date: nil, state: .confirmed).title, "Received")
    }

    /// Zcash on the transparent address: asked once per new amount, only when
    /// up to date and nothing else is open; after locking in, news again.
    func testTheLockInNoticeAsksOncePerArrival() {
        XCTAssertTrue(OutsideNotice.shouldAsk(amount: 5_000_000, upToDate: true, busy: false, lastAsked: 0))
        XCTAssertFalse(OutsideNotice.shouldAsk(amount: 5_000_000, upToDate: true, busy: false, lastAsked: 5_000_000), "asked already")
        XCTAssertTrue(OutsideNotice.shouldAsk(amount: 7_000_000, upToDate: true, busy: false, lastAsked: 5_000_000), "more arrived")
        XCTAssertFalse(OutsideNotice.shouldAsk(amount: 5_000_000, upToDate: false, busy: false, lastAsked: 0), "still syncing")
        XCTAssertFalse(OutsideNotice.shouldAsk(amount: 5_000_000, upToDate: true, busy: true, lastAsked: 0), "a sheet is open")
        XCTAssertFalse(OutsideNotice.shouldAsk(amount: 0, upToDate: true, busy: false, lastAsked: 0))
    }

    /// Cupcake's reader (22 Nov 2026) failed with "Unable to handle '' UR
    /// tag": it needs "ur:type/1-1/…" even for one frame, in lower case.
    func testCupcakeGetsSequencedLowerCaseFrames() throws {
        let small = Data(repeating: 7, count: 40)
        let usual = SealItUREncoder.pczt(small)
        XCTAssertTrue(usual.nextPart().hasPrefix("UR:ZCASH-PCZT/"), "Seal it and Keystone: as before")
        XCTAssertTrue(usual.isSinglePart)
        let cupcake = SealItUREncoder.pczt(small, forCupcake: true)
        XCTAssertFalse(cupcake.isSinglePart)
        let frame = cupcake.nextPart()
        XCTAssertTrue(frame.hasPrefix("ur:zcash-pczt/1-1/"), frame)
        // Our own scanner still reads it back to the same message.
        let decoder = SealItURDecoder(expectedType: SealItURType.pczt)
        XCTAssertTrue(try decoder.receive(frame))
        XCTAssertEqual(try SealItPayload.parsePczt(try XCTUnwrap(decoder.message)), small)
    }

    /// Cupcake signs PCZTs in the shielded-assets layout. These vectors were
    /// made with both crates: pczt 0.10.0 parses each first string, and
    /// Cupcake's crate (zcash-shielded-assets librustzcash fb3b4de) parses
    /// each second one, and gives "DeserializeBadOption" on the first.
    static let cupcakePcztVectors: [(String, String)] = [
        // v2
        ("50435a5402000000f3cab9d20982a5fbac04f9b6c99c0801a1cbbbfd03f98bf2970de9f1b7cb056201093930797a7a7861396113e62da19ddd37433fb03859426160ebf99b6aa20101b563bfb941928d61d6b8edea322907dbe1e7e3b695eeb71083513d192c1891bfbe8ca1d90b01e6dbb1b00d0001ba91c8a10700a8e6c781b9f883aa6013a4ccb767fd79616c422286e99844f13fd7c1ef0101f80084000002c00be344c51939fef1dbaa119f3d068bb78c7f30b724f38227c0e22d019ea4aa14a0ce469abb8e7fe9394fb57ebe2bb7699b604e0b2bc83b1c69fcd5b3ba79cd26d0c0656fc5f26600bebd151faea3376aee6189a511b9b2d9dfcf5fc084cafd970925e133323901fa838b6d31f4f693fc0b04607ad9bbe44da193bf06558700d22e24025cc7a673ca1314847c17aa372691ac6cf136f08a276614516ecb24340fc5e00d08f3724ab9e2a7e98cbcd0c81acce931bc410b89675c2c8747f77c893f5691580a96f967c90af165840e27e7c097aefb6fbe3b742a2d2169020a30627878636379626379094ce7bc181460b4e6ac097930396139617a61300c2a59554843ba8a293459e87801e992a1c5cdb6e8860a06e299157d8aea0105a15b62cd5e013be69c517075f167145e74cf8ea89c95770d936593b8d8c0a275e6cc62b74fb319982283ed3a396e48ac616f0e8f9d6b0ac74d179caaaf59e0be85715f843f58ff0396c189f40df2d0c5ff0e8f87cc890f01077a7a6361303179010962633139616263797804954a9c5f000000",
         "50435a5402000000f3cab9d20982a5fbac04f9b6c99c0801a1cbbbfd03f98bf2970de9f1b7cb056201093930797a7a7861396113e62da19ddd37433fb03859426160ebf99b6aa20101b563bfb941928d61d6b8edea322907dbe1e7e3b695eeb71083513d192c1891bfbe8ca1d90b01e6dbb1b00d0001ba91c8a10700a8e6c781b9f883aa6013a4ccb767fd79616c422286e99844f13fd7c1ef0101f80084000002c00be344c51939fef1dbaa119f3d068bb78c7f30b724f38227c0e22d019ea4aa14a0ce469abb8e7fe9394fb57ebe2bb7699b604e0b2bc83b1c69fcd5b3ba79cd26d0c0656fc5f26600bebd151faea3376aee6189a511b9b2d9dfcf5fc084cafd970925e133323901fa838b6d31f4f693fc0b04607ad9bbe44da193bf06558700d22e24025cc7a673ca1314847c17aa372691ac6cf136f08a276614516ecb24340fc5e00d08f3724ab9e2a7e98cbcd0c81acce931bc410b89675c2c8747f77c893f5691580a96f967c90af165840e27e7c097aefb6fbe3b742a2d2169020a30627878636379626379094ce7bc181460b4e6ac097930396139617a61300c2a59554843ba8a293459e87801e992a1c5cdb6e8860a06e299157d8aea0105a15b62cd5e013be69c517075f167145e74cf8ea89c95770d936593b8d8c0a275e6cc62b74fb319982283ed3a396e48ac616f0e8f9d6b0ac74d179caaaf59e0be85715f843f58ff0396c189f40df2d0c5ff0e8f87cc890f01077a7a6361303179010962633139616263797804954a9c5f00000000"),
        // v1
        ("50435a5401000000c1afd3b907b2b4fbb209c2e3b1980801d39082d80c93f3e1c00181e9aeed042e020b6130316361396261617878130feda7e1647796ff022bea8ed02a82a175930f0262300394c52200000000828995d5fdb7ca87d2cb9bd0ac8307c0cbd625658aac2c9faa07d13c447e33051eeef95a60e56143d6c43bcad76c00019b0a6b5fc933154a6de28404a897c525262e6a7c07bcbee841f745c55d4e9f7401615164c6f728d718353713827ac883d7fb9659234074f5258f6c68082389d2e47f1e175a90bc432fb946e6a9471109f3b79f110a26f6229fa3452526e7bc1642aeb42bf227d50fff07c3c20624292e3b83d5a9c6eae1ec2a0f9e2cf60b7539fe0001f88205bc9a496756afe2ff7ba7cf8065dc666dc470a26b4544feb314208d5639e6f18c6dd3c3fca1e7a4260001158fb59e0945cfe8610c887948183be437bc276566f3835b05f1125b738bb15101722cd2c642e6e86403c0afeda768323f6d7cc72c9ea48608b22a13e1afd78cf9000000011158ab47f04ce1fc2c71e09454839fc36a9b488bfe66d23a02c10e16cd3efb2f02daacfb8609aa82f3ab0f01ce897ef2fc41addef3a23762d60f85420b12634f740691a4b57dff35ff3e80650209306130303963397839146f6e4577b15ca1a1636f6331447a432d84c631de073963783061627812b7b83baf6024f6360c13f64b615e3a68585090301f44ec2731a7c8efdab5dc6bbf0614665cd0e8b8bdcf63543007a52bcf61ae848f3b51cf44a8bddd5ccf695e24ae9af03305b619768b99ac6ecf5d27c7fe146d3dca0b3a377983e3cd1964c0053284808daed41033e32717c551c5f156fd1ddbfdd791cc01bb92f78a91970d077d1550d1c71ba1cb19a32572dbf4807c1732ef497d3a19d5e93c681ab64f3fbae247d501ebeedff4eafe9bb36b00014694417af63a9eb78c8b618e7a617f64141f048a84d90d1334718e252c5278bf01b56badaffd44263de56de3d984c74dbc4ea6945edabd31eca5282addf8ed99040198ee96fb0c010b6279317a7963787a7a7a62010879313979317a7830177f2bb9bb0cbacac663bcc74f5a5a2de8900b711d51970b01d8209c2bab298c35a02b0d4931d87d70faadebc9b3acaa45fcf92517d2b201c12df2bed5d4988dbdf4a301010538d7d74a7d53c055a468c7d9958c1ef19d3a9b4f5b1fea08f612a037655eb70107f172e25e8fce5800",
         "50435a5401000000c1afd3b907b2b4fbb209c2e3b1980801d39082d80c93f3e1c00181e9aeed042e020b6130316361396261617878130feda7e1647796ff022bea8ed02a82a175930f0262300394c52200000000828995d5fdb7ca87d2cb9bd0ac8307c0cbd625658aac2c9faa07d13c447e33051eeef95a60e56143d6c43bcad76c00019b0a6b5fc933154a6de28404a897c525262e6a7c07bcbee841f745c55d4e9f7401615164c6f728d718353713827ac883d7fb9659234074f5258f6c68082389d2e47f1e175a90bc432fb946e6a9471109f3b79f110a26f6229fa3452526e7bc1642aeb42bf227d50fff07c3c20624292e3b83d5a9c6eae1ec2a0f9e2cf60b7539fe0001f88205bc9a496756afe2ff7ba7cf8065dc666dc470a26b4544feb314208d5639e6f18c6dd3c3fca1e7a4260001158fb59e0945cfe8610c887948183be437bc276566f3835b05f1125b738bb15101722cd2c642e6e86403c0afeda768323f6d7cc72c9ea48608b22a13e1afd78cf900000000011158ab47f04ce1fc2c71e09454839fc36a9b488bfe66d23a02c10e16cd3efb2f02daacfb8609aa82f3ab0f01ce897ef2fc41addef3a23762d60f85420b12634f740691a4b57dff35ff3e80650209306130303963397839146f6e4577b15ca1a1636f6331447a432d84c631de073963783061627812b7b83baf6024f6360c13f64b615e3a6858500090301f44ec2731a7c8efdab5dc6bbf0614665cd0e8b8bdcf63543007a52bcf61ae848f3b51cf44a8bddd5ccf695e24ae9af03305b619768b99ac6ecf5d27c7fe146d3dca0b3a377983e3cd1964c0053284808daed41033e32717c551c5f156fd1ddbfdd791cc01bb92f78a91970d077d1550d1c71ba1cb19a32572dbf4807c1732ef497d3a19d5e93c681ab64f3fbae247d501ebeedff4eafe9bb36b00014694417af63a9eb78c8b618e7a617f64141f048a84d90d1334718e252c5278bf01b56badaffd44263de56de3d984c74dbc4ea6945edabd31eca5282addf8ed99040198ee96fb0c010b6279317a7963787a7a7a62010879313979317a7830177f2bb9bb0cbacac663bcc74f5a5a2de8900b711d51970b0001d8209c2bab298c35a02b0d4931d87d70faadebc9b3acaa45fcf92517d2b201c12df2bed5d4988dbdf4a301010538d7d74a7d53c055a468c7d9958c1ef19d3a9b4f5b1fea08f612a037655eb70107f172e25e8fce5800"),
        // v2
        ("50435a5402000000db8ed9ff0ee9e99ee708eb90dfd30d01958fa2a50fa68fa3bd01bbbdc7e60dcc00010001b4d6b2a0e8b48298c60101790001bee67ed750d450a44a8443881b4d5b00684c412ab48a31f5ef2a9b0960d5622ee16a13d3fd509fa19fcf269cef22b8264736c9ec3ee306c1f379963aea05694d9404d4f1dce20cc1d5fcb20d80f69ca30e918783b209010430627a79010a317a31306262636263630562cd12ed2e010000c2b5b9ccffe0c6c5bfb0e3e7e19b050001da47694bc5f7a9d307cda27d0985a960af9de136c168aa963451819877b44865000101010d652a457df4d5aaa82eb888ed3fe7457a208756ab4a3e0193ba7bb9545f27e80110ce5c469dc3085166d2ef1049c53ccf58ac43867caa1b134acefe34f0b0d2d00190f8edd1de3c3aa9ddd70ca41b97ddc0a49c237d3fe47ccb1af3357a9cca782300000001d75471d73e2432423fe800977c990ca65820e1e6cb48b676179c0fe8a09da6ff01f16967971e64a1b5f1085867786219369ca08cd745abe3d42856729d3d64895c0000018bbe3b759a5c738d432eec27e12517039180d82c5491617d5b8e0e5f4d11ecc401ff1e5c20b8a4f71095595439df78e1837884fa71ff8512671ae55ca64d09fede05effbc5880fc3cbc19a0cb9d1acbf08b9ebc69409928e88ea0900020b397863617930617a3979310257c10578633131610ad2efba6e1541fa444ae90114017bd1482ec998f1d927117597813c7bd6ec2c74ba9eac6f1452ce1daf5aecc96dc3c1196ed6b17e5e53f568cc6def9df1e4fa5cf968c4d625188db98c095d0110c96f8934b81d4eb8467b3d0aa4c4e62a0ca6831c9ac97afa14604d411001d2d9f54585a0e7c14b688fe6cf45c5b6733495bdb06e47140cf70598226eb43ebf78842eda3dc8fc1efac400018f7151ce67f355b37a2fafd84df4839d0bc83dba20cf8b1bc1fd99f0a681250c01a5bf98865ff0c4aeb90f6e2618d2d4208d22ede6c3c513458b9efdb8f20a4c620184707800c9017afc28aa87b13509a06aca50625251aafb96bdd492bbff797fb903cab38dec0aae8686820ab08ec181090000009ecfb0fae6d1a8c8aad9010101d3f61bb081cbc88180bca75daa6842d74089524066c095765e07f144898ad6810101154718503c156392b63dcfa80df757bf229ee09172c800",
         "50435a5402000000db8ed9ff0ee9e99ee708eb90dfd30d01958fa2a50fa68fa3bd01bbbdc7e60dcc00010001b4d6b2a0e8b48298c60101790001bee67ed750d450a44a8443881b4d5b00684c412ab48a31f5ef2a9b0960d5622ee16a13d3fd509fa19fcf269cef22b8264736c9ec3ee306c1f379963aea05694d9404d4f1dce20cc1d5fcb20d80f69ca30e918783b209010430627a79010a317a31306262636263630562cd12ed2e010000c2b5b9ccffe0c6c5bfb0e3e7e19b050001da47694bc5f7a9d307cda27d0985a960af9de136c168aa963451819877b44865000101010d652a457df4d5aaa82eb888ed3fe7457a208756ab4a3e0193ba7bb9545f27e80110ce5c469dc3085166d2ef1049c53ccf58ac43867caa1b134acefe34f0b0d2d00190f8edd1de3c3aa9ddd70ca41b97ddc0a49c237d3fe47ccb1af3357a9cca782300000001d75471d73e2432423fe800977c990ca65820e1e6cb48b676179c0fe8a09da6ff01f16967971e64a1b5f1085867786219369ca08cd745abe3d42856729d3d64895c000000018bbe3b759a5c738d432eec27e12517039180d82c5491617d5b8e0e5f4d11ecc401ff1e5c20b8a4f71095595439df78e1837884fa71ff8512671ae55ca64d09fede05effbc5880fc3cbc19a0cb9d1acbf08b9ebc69409928e88ea0900020b397863617930617a3979310257c10578633131610ad2efba6e1541fa444ae9000114017bd1482ec998f1d927117597813c7bd6ec2c74ba9eac6f1452ce1daf5aecc96dc3c1196ed6b17e5e53f568cc6def9df1e4fa5cf968c4d625188db98c095d0110c96f8934b81d4eb8467b3d0aa4c4e62a0ca6831c9ac97afa14604d411001d2d9f54585a0e7c14b688fe6cf45c5b6733495bdb06e47140cf70598226eb43ebf78842eda3dc8fc1efac400018f7151ce67f355b37a2fafd84df4839d0bc83dba20cf8b1bc1fd99f0a681250c01a5bf98865ff0c4aeb90f6e2618d2d4208d22ede6c3c513458b9efdb8f20a4c620184707800c9017afc28aa87b13509a06aca50625251aafb96bdd492bbff797fb903cab38dec0aae8686820ab08ec18109000000009ecfb0fae6d1a8c8aad9010101d3f61bb081cbc88180bca75daa6842d74089524066c095765e07f144898ad6810101154718503c156392b63dcfa80df757bf229ee09172c80000"),
    ]

    func testCupcakePcztLayoutBothWays() throws {
        func bytes(_ hex: String) -> Data {
            var d = Data(); var i = hex.startIndex
            while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); d.append(UInt8(hex[i..<j], radix: 16)!); i = j }
            return d
        }
        for (main, cupcake) in Self.cupcakePcztVectors {
            XCTAssertEqual(try CupcakePczt.toCupcake(bytes(main)), bytes(cupcake))
            XCTAssertEqual(try CupcakePczt.fromCupcake(bytes(cupcake)), bytes(main))
            XCTAssertThrowsError(try CupcakePczt.toCupcake(bytes(main).dropLast()))
        }
        XCTAssertThrowsError(try CupcakePczt.toCupcake(Data("PSBT1234".utf8)))
    }

    /// The price: every 5 minutes, and until one comes, 15 s, 30 s, 1 min,
    /// 2 min, then back to 5 minutes (CoinGecko limits calls; Tor exits are shared).
    func testThePriceRetriesPatiently() {
        let s: UInt64 = 1_000_000_000
        XCTAssertEqual(PriceFeed.wait(afterMisses: 0), 300 * s)
        XCTAssertEqual(PriceFeed.wait(afterMisses: 1), 15 * s)
        XCTAssertEqual(PriceFeed.wait(afterMisses: 2), 30 * s)
        XCTAssertEqual(PriceFeed.wait(afterMisses: 3), 60 * s)
        XCTAssertEqual(PriceFeed.wait(afterMisses: 4), 120 * s)
        XCTAssertEqual(PriceFeed.wait(afterMisses: 5), 240 * s)
        XCTAssertEqual(PriceFeed.wait(afterMisses: 6), 300 * s)
        XCTAssertEqual(PriceFeed.wait(afterMisses: 50), 300 * s)
    }

    /// A newly paired wallet's name says where it signs.
    func testASignerWalletIsNamedAfterItsDevice() {
        XCTAssertEqual(SealItFlow.walletName("Account 0", cupcake: false), "Keystone · Account 0")
        XCTAssertEqual(SealItFlow.walletName(nil, cupcake: false), "Keystone")
        XCTAssertEqual(SealItFlow.walletName("Keystone Main", cupcake: false), "Keystone Main")
        XCTAssertEqual(SealItFlow.walletName("Cupcake", cupcake: true), "Cupcake")
        XCTAssertEqual(SealItFlow.walletName("My wallet", cupcake: true), "Cupcake · My wallet")
        XCTAssertEqual(SealItFlow.walletName(" ", cupcake: true), "Cupcake")
        XCTAssertLessThanOrEqual(SealItFlow.walletName(String(repeating: "x", count: 80), cupcake: false).count, 40)
    }

    /// Cupcake finishes at exactly n distinct frames of n, so a big PCZT
    /// shows only frames 1…n, in a loop, and those n alone rebuild it.
    func testCupcakeLoopsOnlyThePlainFrames() throws {
        let big = Data((0..<3000).map { UInt8($0 % 251) })
        let cupcake = SealItUREncoder.pczt(big, forCupcake: true)
        let n = cupcake.fragmentCount
        XCTAssertGreaterThan(n, 1)
        let frames = (0..<(n * 3)).map { _ in cupcake.nextPart() }
        XCTAssertEqual(Set(frames).count, n, "never more than n different frames")
        XCTAssertEqual(Array(frames[0..<n]), Array(frames[n..<(2 * n)]))
        for (i, frame) in frames.prefix(n).enumerated() {
            XCTAssertTrue(frame.hasPrefix("ur:zcash-pczt/\(i + 1)-\(n)/"), frame)
        }
        let decoder = SealItURDecoder(expectedType: SealItURType.pczt)
        for frame in frames.prefix(n) { _ = try decoder.receive(frame) }
        XCTAssertEqual(try SealItPayload.parsePczt(try XCTUnwrap(decoder.message)), big)
    }

    /// Cupcake's account QR is a plain "zcash-wallet:" URI with a viewing key,
    /// not a UR. Lock it reads it for pairing, and refuses anything else.
    func testCupcakesPairingQRIsRead() throws {
        let tool = DerivationTool(networkType: .mainnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: [UInt8](repeating: 7, count: 32), accountIndex: Zip32AccountIndex(0))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk).stringEncoded
        let qr = "zcash-wallet:?label=My%20Cupcake&private_key=\(ufvk)"

        // The scanner takes it whole when it expects an account QR…
        let decoder = SealItURDecoder(expectedType: SealItURType.accounts)
        XCTAssertTrue(try decoder.receive(qr))
        let export = try SealItPayload.parseAccounts(try XCTUnwrap(decoder.message))
        XCTAssertTrue(export.fromCupcake)
        XCTAssertNil(export.seedFingerprint)
        XCTAssertEqual(export.accounts.first?.ufvk, ufvk)
        XCTAssertEqual(export.accounts.first?.name, "My Cupcake")
        // …not where a signed payment is expected.
        XCTAssertThrowsError(try SealItURDecoder(expectedType: SealItURType.pczt).receive(qr))

        // No label: named Cupcake.
        XCTAssertEqual(try SealItPayload.parseCupcake("zcash-wallet:?private_key=\(ufvk)").accounts.first?.name, "Cupcake")
        // A broken key, no key, a testnet key, or another scheme: refused.
        for bad in ["zcash-wallet:?label=x&private_key=uview1notakey",
                    "zcash-wallet:?label=x",
                    "zcash-wallet:?private_key=uviewtest1qqqqqqqqqqqqqqqqqqqqqqqqqqq",
                    "zcash:?private_key=\(ufvk)"] {
            XCTAssertThrowsError(try SealItPayload.parseCupcake(bad), bad)
        }
    }

    /// Audit 22 Nov 2026: with Tor sending on, the price goes over Tor too,
    /// and is never asked in the clear while Tor is not ready.
    func testThePriceTakesTheSameRoadAsPayments() {
        XCTAssertEqual(PriceFeed.road(torSending: true, torReady: true), .tor)
        XCTAssertEqual(PriceFeed.road(torSending: true, torReady: false), .wait)
        XCTAssertEqual(PriceFeed.road(torSending: false, torReady: true), .direct)
    }

    /// Audit 22 Nov 2026: a cancelled Touch ID or password prompt counted as
    /// a wrong code. Only a real wrong code counts now.
    func testACancelledPromptIsNotAWrongCode() {
        XCTAssertTrue(WalletVault.isCancellation(NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue)))
        XCTAssertTrue(WalletVault.isCancellation(NSError(domain: LAError.errorDomain, code: LAError.systemCancel.rawValue)))
        let wrapped = NSError(domain: "CryptoKit", code: 1,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: LAError.errorDomain, code: LAError.appCancel.rawValue)])
        XCTAssertTrue(WalletVault.isCancellation(wrapped), "the Secure Enclave key wraps LocalAuthentication's error")
        XCTAssertTrue(WalletVault.isCancellation(KeyStore.Failure.keychain(errSecUserCanceled)))
        // A wrong code or password still counts.
        XCTAssertFalse(WalletVault.isCancellation(KeyStore.Failure.keychain(errSecAuthFailed)))
        XCTAssertFalse(WalletVault.isCancellation(NSError(domain: LAError.errorDomain, code: LAError.authenticationFailed.rawValue)))
    }

    /// Audit 22 Nov 2026: detailed logs only from this launch's arguments,
    /// not from a value saved in Lock it's preferences.
    func testDetailedLogsComeOnlyFromTheLaunchArguments() {
        XCTAssertTrue(GoMaxNode.detailedLogs(["Zecky Lock it", "-goMax.detailedLogs", "YES"]))
        XCTAssertFalse(GoMaxNode.detailedLogs(["Zecky Lock it", "-goMax.detailedLogs", "NO"]))
        XCTAssertFalse(GoMaxNode.detailedLogs(["Zecky Lock it", "-goMax.detailedLogs"]))
        XCTAssertFalse(GoMaxNode.detailedLogs(["Zecky Lock it"]))
        // A saved value no longer counts.
        UserDefaults.standard.set(true, forKey: "goMax.detailedLogs")
        defer { UserDefaults.standard.removeObject(forKey: "goMax.detailedLogs") }
        XCTAssertFalse(GoMaxNode.detailedLogs(["Zecky Lock it"]))
    }

    /// Audit 22 Nov 2026: "\d" matched other scripts' digits, which Int64
    /// cannot read, and they were read as 0: "١.5" became 0.5 ZEC.
    func testOnlyTheDigitsZeroToNineAreReadAsAnAmount() {
        XCTAssertNil(AmountInput.zec("١.5"))
        XCTAssertNil(AmountInput.zec("١"))
        XCTAssertNil(AmountInput.zec("1.٥"))
        XCTAssertNil(AmountInput.zec("١٢,٣٤٥"))
        XCTAssertNil(AmountInput.fiat("١٢"))
        XCTAssertEqual(AmountInput.zec("1.5"), 150_000_000)
        XCTAssertEqual(AmountInput.zec("0,001"), 100_000)
        XCTAssertEqual(AmountInput.zec(".5"), 50_000_000)
    }

    /// Audit 22 Nov 2026: with bitcoin as the currency, 8 decimals.
    func testBitcoinAmountsTakeEightDecimals() {
        XCTAssertNil(AmountInput.fiat("0.00051234"), "two decimals for money")
        XCTAssertEqual(AmountInput.fiat("0.00051234", decimals: 8), 0.00051234)
        XCTAssertNil(AmountInput.fiat("0.000512345", decimals: 8))
        XCTAssertEqual(AmountInput.fiat("25,50"), 25.5)
    }

    /// Audit 22 Nov 2026: a scanned part announcing 0 parts trapped in
    /// DegreeChooser (1...0); a huge part count or message length allocated
    /// without limit. Both are refused before any decoding work.
    func testAScannedPartWithImpossibleLengthsIsRefused() throws {
        typealias Part = FountainEncoder.Part
        func cbor(seqLen: Int, messageLen: Int) -> Data {
            Part(seqNum: 1, seqLen: seqLen, messageLen: messageLen, checksum: 1, data: Data([1, 2, 3])).cbor
        }
        XCTAssertNoThrow(try Part(cbor: cbor(seqLen: 3, messageLen: 9)))
        XCTAssertThrowsError(try Part(cbor: cbor(seqLen: 0, messageLen: 9)))
        XCTAssertThrowsError(try Part(cbor: cbor(seqLen: 1001, messageLen: 9)))
        XCTAssertThrowsError(try Part(cbor: cbor(seqLen: 3, messageLen: 0)))
        XCTAssertThrowsError(try Part(cbor: cbor(seqLen: 3, messageLen: 10 * 1024 * 1024 + 1)))
        XCTAssertNoThrow(try Part(cbor: cbor(seqLen: 1000, messageLen: 10 * 1024 * 1024)))
        // The same through the scanner: a frame claiming 0 or 1001 parts.
        let decoder = SealItURDecoder(expectedType: "zcash-pczt")
        for header in ["1-0", "1-1001"] {
            let body = Bytewords.encode(cbor(seqLen: 3, messageLen: 9), style: .minimal)
            XCTAssertThrowsError(try decoder.receive("ur:zcash-pczt/\(header)/\(body)"), header)
        }
        // And a frame whose header is fine but whose part claims 0 parts.
        let zero = Bytewords.encode(cbor(seqLen: 0, messageLen: 9), style: .minimal)
        XCTAssertThrowsError(try decoder.receive("ur:zcash-pczt/1-3/\(zero)"))
    }

    /// Audit 22 Nov 2026: the time lock used only this Mac's clock. Now the
    /// wait must pass by the clock and by the blocks (25 s each) since it
    /// started, as the 48 hours of "lost my keys".
    func testMovingTheClockForwardAloneDoesNotOpenTheTimeLock() {
        let wait: TimeInterval = 24 * 3600
        let asked = Date(timeIntervalSince1970: 1_795_300_000)
        let height = 3_600_000
        let blocks24h = Int(wait) / 25   // 3,456 blocks
        // Clock moved a day forward, the chain moved 10 blocks: not open.
        XCTAssertFalse(TimeLock.passed(wait, since: asked, height: height,
                                       now: asked.addingTimeInterval(wait + 60), tip: height + 10))
        // The blocks are there but the clock is not: not open either.
        XCTAssertFalse(TimeLock.passed(wait, since: asked, height: height,
                                       now: asked.addingTimeInterval(3600), tip: height + blocks24h))
        // Both: open.
        XCTAssertTrue(TimeLock.passed(wait, since: asked, height: height,
                                      now: asked.addingTimeInterval(wait), tip: height + blocks24h))
        // Height not known: never open.
        XCTAssertFalse(TimeLock.passed(wait, since: asked, height: nil, now: asked.addingTimeInterval(wait * 2), tip: height))
        XCTAssertFalse(TimeLock.passed(wait, since: asked, height: height, now: asked.addingTimeInterval(wait * 2), tip: 0))
        // How long the blocks still need: half of them is half of the wait.
        XCTAssertEqual(TimeLock.blocksLeft(wait, height: height, tip: height + blocks24h / 2), wait / 2, accuracy: 25)
        XCTAssertEqual(TimeLock.blocksLeft(wait, height: height, tip: height + blocks24h + 5), 0)
    }

    /// Seen 21 Nov 2026: a TEX payment priced right after starting, with the
    /// wallet about 1,000 blocks behind, had expired before it was sent.
    func testNoPaymentIsBuiltBeforeTheWalletIsUpToDate() {
        XCTAssertNil(WalletEngine.caughtUpProblem(network: 3_597_825, wallet: 3_597_825))
        XCTAssertNil(WalletEngine.caughtUpProblem(network: 3_597_825, wallet: 3_597_822), "a few blocks behind counts as up to date")
        let behind = WalletEngine.caughtUpProblem(network: 3_597_825, wallet: 3_596_744)
        XCTAssertNotNil(behind)
        XCTAssertEqual(behind.map { String(describing: $0) },
                       "Lock it is still catching up (block 3,596,744 of 3,597,825). You can send once it says Up to date. Nothing was sent.")
        // Not known yet (just started): not up to date either.
        XCTAssertNotNil(WalletEngine.caughtUpProblem(network: 0, wallet: 0))
        XCTAssertNotNil(WalletEngine.caughtUpProblem(network: 3_597_825, wallet: 0))
    }

    /// A wallet just added checks its history in the background (newest
    /// blocks first). Once the newest blocks are checked, sending from the
    /// other wallets goes on; a gap near the tip still holds it up.
    func testOlderBlocksForANewWalletDoNotHoldUpSending() {
        let tip = 3_608_126
        // Pairing on 24 Nov: open from the old checkpoint to 1,700 blocks below the tip.
        let history = [(first: 3_550_000, end: tip - 1_700)]
        XCTAssertTrue(SyncMath.newestChecked(toScan: history, network: tip))
        XCTAssertNil(WalletEngine.caughtUpProblem(network: tip, wallet: 3_550_000, newestCheckedAt: tip))
        XCTAssertNil(WalletEngine.caughtUpProblem(network: tip + 2, wallet: 3_550_000, newestCheckedAt: tip), "a block or two later still counts")
        XCTAssertNotNil(WalletEngine.caughtUpProblem(network: tip + 40, wallet: 3_550_000, newestCheckedAt: tip), "seen too long ago")
        // Back after a night away: the newest blocks are open.
        XCTAssertFalse(SyncMath.newestChecked(toScan: [(first: tip - 1_000, end: tip + 1)], network: tip))
        XCTAssertNotNil(WalletEngine.caughtUpProblem(network: tip, wallet: tip - 1_000, newestCheckedAt: nil))
        // A gap 50 blocks below the tip holds it up; the newest 3 blocks do not.
        XCTAssertFalse(SyncMath.newestChecked(toScan: [(first: tip - 50, end: tip - 40)], network: tip))
        XCTAssertTrue(SyncMath.newestChecked(toScan: [(first: tip - 2, end: tip + 1)], network: tip))
        XCTAssertTrue(SyncMath.newestChecked(toScan: [], network: tip))
        XCTAssertFalse(SyncMath.newestChecked(toScan: [], network: 0))
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

    /// v3 (issue #3): where the answer came from is signed, in the bytes the
    /// verifier rebuilds.
    func testStatementClientDataV3SignsWhereTheAnswerCameFrom() throws {
        let c = String(repeating: "ab", count: 32)
        let node = StatementClientData.NodeState(state: "up-to-date", tip: 3_579_600, estimate: 3_579_601)
        let from = StatementClientData.Provenance(
            createdAt: "2026-11-16T16:00:00Z", appId: "W2F7RNV886.app.zecky.lockit", lockItVersion: "0.2.0",
            lockItBuild: "10", onion: "abc.onion", nodeBuild: "v1.8.8", nodeSubversion: "/Zakura:1.8.8/", ownNode: true)
        let json = try StatementClientData.jsonV3(fingerprintSHA256: "", challenge: c, node: node, from: from)
        XCTAssertEqual(String(decoding: json, as: UTF8.self),
                       "{\"appId\":\"W2F7RNV886.app.zecky.lockit\",\"challenge\":\"\(c)\",\"createdAt\":\"2026-11-16T16:00:00Z\","
                       + "\"fingerprintSHA256\":\"\",\"lockIt\":{\"build\":\"10\",\"version\":\"0.2.0\"},"
                       + "\"node\":{\"build\":\"v1.8.8\",\"estimate\":3579601,\"state\":\"up-to-date\",\"subversion\":\"/Zakura:1.8.8/\",\"tip\":3579600},"
                       + "\"nodeCheck\":{\"dataUnchangedSinceLockIt\":false,\"executableSignedBySameTeamAsLockIt\":true,\"ownNode\":true},"
                       + "\"onion\":\"abc.onion\",\"purpose\":\"zecky-go-max-state\",\"v\":3}")
    }

    func testStatementSummaryForTheLog() throws {
        let syncing = try JSONSerialization.data(withJSONObject: [
            "nodeState": ["state": "syncing", "tip": 3_412_000, "estimate": 3_576_300], "fingerprintNote": "syncing"])
        XCTAssertEqual(AttestedStatementMaker.summary(of: syncing), " · syncing at block 3412000, no fingerprint (syncing)")
        let upToDate = try JSONSerialization.data(withJSONObject: [
            "nodeState": ["state": "up-to-date", "tip": 3_576_300, "estimate": 3_576_300],
            "fingerprintJSON": #"{"height":3576200,"v":0}"#])
        XCTAssertEqual(AttestedStatementMaker.summary(of: upToDate), " · up to date, fingerprint at 3576200")
    }

    /// A real answer kept on this Mac only, never in the repository (it
    /// carries an App Attest key ID): the newest asked-*.json in GoMax/logs,
    /// saved by "Check another node". Without one, these tests are skipped.
    private func localStatement() throws -> (data: Data, challenge: String) {
        let logs = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("GoMax/logs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // The newest answer a genuine node gave (a fake node's answer, saved
        // by the issue #5 test, is passed over).
        let byDate = files.filter { $0.lastPathComponent.hasPrefix("asked-") && $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for url in byDate {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let challenge = json["challenge"] as? String,
                  StatementCheck.check(data, expectedAppID: "W2F7RNV886.app.zecky.lockit", challenge: challenge).genuine
            else { continue }
            return (data, challenge)
        }
        throw XCTSkip("No answer from a genuine node in GoMax/logs yet (older formats no longer count): check a node first.")
    }

    // MARK: Andrew Miller's review (issues #4, #5), reproduced

    /// #5: a node that answers with hand-written JSON echoing the challenge
    /// must not count as genuine in "Check another node".
    func testIssue5AHandWrittenAnswerIsNotGenuine() throws {
        let challenge = String(repeating: "ab", count: 32)
        let client = String(decoding: try StatementClientData.jsonV3(
            fingerprintSHA256: "", challenge: challenge,
            node: .init(state: "up-to-date", tip: 3_579_000, estimate: 3_579_000),
            from: .init(createdAt: "2026-11-16T15:00:00Z", appId: "W2F7RNV886.app.zecky.lockit", lockItVersion: "0.2.0",
                        lockItBuild: "10", onion: "", nodeBuild: "v1.8.8", nodeSubversion: "", ownNode: true)), as: UTF8.self)
        let fake: [String: Any] = [
            "format": "zecky-attested-statement/v3", "challenge": challenge, "clientDataJSON": client,
            "fingerprintSHA256": "", "kind": "assertion", "keyAttestationClientDataJSON": client,
            "keyId": Data(repeating: 1, count: 32).base64EncodedString(),
            "assertion": Data("not a signature".utf8).base64EncodedString(),
            "keyAttestation": Data("not an attestation".utf8).base64EncodedString(),
            "createdAt": "2026-11-16T15:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: fake, options: [.sortedKeys])
        let result = StatementCheck.check(data, expectedAppID: "W2F7RNV886.app.zecky.lockit", challenge: challenge)
        XCTAssertFalse(result.genuine, "a hand-written answer passed: \(result.reason)")
    }

    /// #4: in an assertion answer, the key attestation's authData must be
    /// bound to Apple's certificate. Swapping the 16-byte environment
    /// (AAGUID) inside it must make the answer fail.
    func testIssue4AnEditedKeyAttestationIsNotGenuine() throws {
        let (data, challenge) = try localStatement()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard json["kind"] as? String == "assertion" else { throw XCTSkip("The saved answer is not an assertion.") }
        var attestation = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(json["keyAttestation"] as? String)))
        let production = Data("appattest".utf8) + Data(repeating: 0, count: 7)
        let development = Data("appattestdevelop".utf8)
        if let range = attestation.range(of: production) {
            attestation.replaceSubrange(range, with: development)
        } else if let range = attestation.range(of: development) {
            attestation.replaceSubrange(range, with: production)
        } else {
            return XCTFail("No App Attest environment found in the key attestation.")
        }
        json["keyAttestation"] = attestation.base64EncodedString()
        let edited = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let result = StatementCheck.check(edited, expectedAppID: "W2F7RNV886.app.zecky.lockit", challenge: challenge)
        XCTAssertFalse(result.genuine, "an edited key attestation passed")
    }

    /// #3: the fields that say where an answer came from are signed. Andrew's
    /// edit (lockIt.build "999-evil", node.build "my-own-fork") must fail.
    func testIssue3EditedProvenanceIsNotGenuine() throws {
        let (data, challenge) = try localStatement()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var client = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(json["clientDataJSON"] as? String).utf8)) as? [String: Any])
        var lockIt = try XCTUnwrap(client["lockIt"] as? [String: Any])
        lockIt["build"] = "999-evil"
        client["lockIt"] = lockIt
        var node = try XCTUnwrap(client["node"] as? [String: Any])
        node["build"] = "my-own-fork"
        client["node"] = node
        json["clientDataJSON"] = String(decoding: try StateFingerprint.canonicalJSON(client), as: UTF8.self)
        let edited = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(StatementCheck.check(edited, expectedAppID: "W2F7RNV886.app.zecky.lockit", challenge: challenge).genuine)
        // Unsigned copies next to the signed data are not read at all.
        var withCopies = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        withCopies["lockIt"] = ["build": "999-evil"]
        let copies = try JSONSerialization.data(withJSONObject: withCopies)
        let result = StatementCheck.check(copies, expectedAppID: "W2F7RNV886.app.zecky.lockit", challenge: challenge)
        XCTAssertTrue(result.genuine, result.reason)
    }

    /// #8 point 1, in "Finding other nodes": an answer relayed through
    /// another onion address names the genuine node's address, not the one
    /// asked, and is refused.
    func testIssue8ARelayedAnswerIsNotGenuine() throws {
        let (data, challenge) = try localStatement()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let client = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(json["clientDataJSON"] as? String).utf8)) as? [String: Any])
        let own = try XCTUnwrap(client["onion"] as? String)
        guard !own.isEmpty else { throw XCTSkip("The saved answer was made without Tor.") }
        let app = "W2F7RNV886.app.zecky.lockit"
        XCTAssertTrue(StatementCheck.check(data, expectedAppID: app, challenge: challenge, onion: own).genuine)
        let relay = String(repeating: "r", count: 56) + ".onion"
        XCTAssertFalse(StatementCheck.check(data, expectedAppID: app, challenge: challenge, onion: relay).genuine)
    }

    /// #6: before a fingerprint is vouched for, the node's tree state must
    /// equal an independent server's, exactly. Wrong chain data, however it
    /// got onto the Mac, disagrees.
    func testIssue6CrossCheckWithTheNetwork() {
        func tree(hash: String, sapling: String, orchard: String, ironwood: String?) -> [String: Any] {
            var t: [String: Any] = [
                "hash": hash, "height": 3_579_600,
                "sapling": ["commitments": ["finalRoot": "aa", "finalState": sapling]],
                "orchard": ["commitments": ["finalRoot": "bb", "finalState": orchard]],
            ]
            if let ironwood { t["ironwood"] = ["commitments": ["finalRoot": "cc", "finalState": ironwood]] }
            return t
        }
        let server = (hash: "00ab", saplingTree: "01ff", orchardTree: "02ee", ironwoodTree: "03dd")
        XCTAssertEqual(StateFingerprint.crossCheck(node: tree(hash: "00AB", sapling: "01ff", orchard: "02ee", ironwood: "03dd"), server: server), "agrees")
        // A different block, or one changed tree: disagrees.
        XCTAssertEqual(StateFingerprint.crossCheck(node: tree(hash: "00ac", sapling: "01ff", orchard: "02ee", ironwood: "03dd"), server: server), "disagrees")
        XCTAssertEqual(StateFingerprint.crossCheck(node: tree(hash: "00ab", sapling: "01ff", orchard: "02ef", ironwood: "03dd"), server: server), "disagrees")
        // A pool the node does not have yet is an empty tree, as on the server.
        XCTAssertEqual(StateFingerprint.crossCheck(node: tree(hash: "00ab", sapling: "01ff", orchard: "02ee", ironwood: nil),
                                                   server: (hash: "00ab", saplingTree: "01ff", orchardTree: "02ee", ironwoodTree: "")), "agrees")
        // Without the serialized tree, nothing can be compared: never "agrees".
        var noState = tree(hash: "00ab", sapling: "01ff", orchard: "02ee", ironwood: "03dd")
        noState["sapling"] = ["commitments": ["finalRoot": "aa"]]
        XCTAssertEqual(StateFingerprint.crossCheck(node: noState, server: server), "not-comparable")
    }

    /// #6, layer 1: the seal changes when a data file is added, removed or
    /// resized, or when the database's own index changes; RocksDB's text
    /// logs do not count.
    func testIssue6TheDataSealNoticesChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seal-\(UUID().uuidString)")
        let db = folder.appendingPathComponent("state/mainnet", isDirectory: true)
        try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("MANIFEST-000005\n".utf8).write(to: db.appendingPathComponent("CURRENT"))
        try Data(repeating: 1, count: 100).write(to: db.appendingPathComponent("MANIFEST-000005"))
        try Data(repeating: 2, count: 4096).write(to: db.appendingPathComponent("000007.sst"))
        let sealed = try XCTUnwrap(GoMaxNode.dataSeal(folder))
        XCTAssertEqual(GoMaxNode.dataSeal(folder), sealed, "the same data gives the same seal")
        try Data("log line".utf8).write(to: db.appendingPathComponent("LOG"))
        XCTAssertEqual(GoMaxNode.dataSeal(folder), sealed, "RocksDB's text log does not count")
        // Andrew's case: data from elsewhere. A swapped data file…
        try Data(repeating: 3, count: 4097).write(to: db.appendingPathComponent("000007.sst"))
        XCTAssertNotEqual(GoMaxNode.dataSeal(folder), sealed)
        try Data(repeating: 2, count: 4096).write(to: db.appendingPathComponent("000007.sst"))
        XCTAssertEqual(GoMaxNode.dataSeal(folder), sealed)
        // …an added one, or a changed index.
        try Data(repeating: 4, count: 10).write(to: db.appendingPathComponent("000009.sst"))
        XCTAssertNotEqual(GoMaxNode.dataSeal(folder), sealed)
        try FileManager.default.removeItem(at: db.appendingPathComponent("000009.sst"))
        try Data(repeating: 9, count: 100).write(to: db.appendingPathComponent("MANIFEST-000005"))
        XCTAssertNotEqual(GoMaxNode.dataSeal(folder), sealed)
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

/// Andrew Miller's correction on issues #3 and #8: Lock it checks a
/// signer-independent fingerprint of every helper before starting it, and
/// of its two libraries before making a Genuine node answer.
final class NestedCodeTests: XCTestCase {
    private func helperData(_ name: String) throws -> (URL, Data) {
        guard let url = GoMaxNode.helper(name) else { throw XCTSkip("this build has no \(name) inside") }
        return (url, try Data(contentsOf: url))
    }

    private func refusal(_ result: Result<Void, NestedCode.Refusal>) -> NestedCode.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    /// Where the signature starts (LC_CODE_SIGNATURE dataoff) in a thin file.
    private func signatureStart(_ d: Data) -> Int? {
        let b = [UInt8](d)
        func le32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        var offset = 32
        for _ in 0..<le32(16) {
            if le32(offset) == 0x1D { return le32(offset + 8) }
            offset += le32(offset + 4)
        }
        return nil
    }

    func testEverythingInsideThisBuildMatchesItsFingerprint() throws {
        var checked = 0
        for name in ["zakurad", "zainod", "arti"] {
            guard let url = GoMaxNode.helper(name) else { continue }
            XCTAssertEqual(GoMaxNode.verifiedHelper(name).map { $0.lastPathComponent }, .success(name))
            XCTAssertNoThrow(try NestedCode.check(name, at: url).get())
            checked += 1
        }
        if checked == 0 { throw XCTSkip("this build has no helpers inside") }
        XCTAssertNoThrow(try NestedCode.checkLibraries().get(),
                         "Frameworks changed: run scripts/nested-code-pins.py on the built app")
    }

    func testAChangedHelperIsRefused() throws {
        let (_, original) = try helperData("zakurad")
        let start = try XCTUnwrap(signatureStart(original))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("zakurad")

        // The same program, signed by someone else: only the signature
        // (after `start`) and its size fields differ. Still accepted.
        var resigned = original
        resigned.replaceSubrange(start..<resigned.count, with: Data(repeating: 0xAB, count: 1234))
        try resigned.write(to: copy)
        XCTAssertNoThrow(try NestedCode.check("zakurad", at: copy).get(), "a new signature alone must not matter")

        // One byte of the program changed: refused, before it can start.
        var changed = original
        changed[start / 2] ^= 0x01
        try changed.write(to: copy)
        XCTAssertEqual(refusal(NestedCode.check("zakurad", at: copy)), .changed("zakurad"))

        // Another helper in its place: refused.
        if let zainod = GoMaxNode.helper("zainod") {
            try FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: zainod, to: copy)
            XCTAssertEqual(refusal(NestedCode.check("zakurad", at: copy)), .changed("zakurad"))
        }

        // Not a program at all, or a name Lock it has no fingerprint for.
        try Data("#!/bin/sh\necho fake node\n".utf8).write(to: copy)
        XCTAssertEqual(refusal(NestedCode.check("zakurad", at: copy)), .changed("zakurad"))
        XCTAssertEqual(refusal(NestedCode.check("other", at: copy)), .changed("other"))
    }
}

/// Issue #2 with Andrew Miller's correction: each answer shows the code
/// identity of the running program, bound to the CDHash Apple attests.
final class CodeIdentityTests: XCTestCase {
    private func mine() throws -> (CodeIdentity.Parts, [String: Any], Data, String) {
        let parts = try XCTUnwrap(CodeIdentity.current(), "Lock it's own program has no readable code signature")
        let appID = try XCTUnwrap(CodeIdentity.applicationIdentifier(XCTUnwrap(CodeIdentity.entitlements(parts.entitlements))))
        return (parts, CodeIdentity.json(parts), Data(SHA256.hash(data: parts.codeDirectory)), appID)
    }

    func testItsOwnCodeIdentityChecksOut() throws {
        let (parts, fields, cdhash, appID) = try mine()
        let directory = try XCTUnwrap(CodeIdentity.directory(parts.codeDirectory))
        XCTAssertEqual(parts.page0.count, directory.pageSize)
        XCTAssertTrue(appID.hasSuffix(".app.zecky.lockit"), "the app ID in its entitlements is Lock it's")
        XCTAssertEqual(try CodeIdentity.check(fields, cdhash: cdhash, appID: appID).get(), parts)
        XCTAssertTrue(CodeIdentity.sameCode(parts, parts))
    }

    func testAShownCodeThatIsNotTheAttestedOneIsRefused() throws {
        let (parts, fields, cdhash, appID) = try mine()
        func reason(_ f: [String: Any], _ hash: Data = cdhash, _ app: String? = nil) -> String? {
            if case .failure(let p) = CodeIdentity.check(f, cdhash: hash, appID: app ?? appID) { return p.reason }
            return nil
        }
        // Apple attests other code than the answer shows.
        XCTAssertEqual(reason(fields, Data(repeating: 7, count: 32)), "the code it shows is not the code Apple attests (CDHash)")
        // A changed first page.
        var page = parts.page0; page[page.startIndex + 100] ^= 1
        var f = fields; f["page0"] = page.base64EncodedString()
        XCTAssertEqual(reason(f), "its first page is not the one its code hashes")
        // Other entitlements than the signature holds.
        var ent = parts.entitlements; ent[ent.count - 1] ^= 1
        f = fields; f["entitlements"] = ent.base64EncodedString()
        XCTAssertEqual(reason(f), "its entitlements are not the ones its code signature holds")
        // Entitlements of another app.
        XCTAssertEqual(reason(fields, cdhash, "ABCDE12345.other.app"), "its entitlements name another app")
        // Another code limit is other code, whoever signed it.
        var other = parts.codeDirectory; other[other.startIndex + 35] ^= 1
        XCTAssertFalse(CodeIdentity.sameCode(CodeIdentity.Parts(codeDirectory: other, page0: parts.page0, entitlements: parts.entitlements), parts))
    }

    /// Watch only: a mainnet viewing key is taken (spaces and newlines
    /// trimmed), anything else is refused with a clear reason, and the name
    /// is required and kept short. The QR scanner also takes a plain key.
    func testWatchOnlyTakesOnlyAMainnetViewingKey() throws {
        let tool = DerivationTool(networkType: .mainnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: [UInt8](repeating: 9, count: 32), accountIndex: Zip32AccountIndex(0))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk).stringEncoded
        XCTAssertEqual(try WatchOnly.cleaned("  \n\(ufvk)\n "), ufvk)

        let test = DerivationTool(networkType: .testnet)
        let tusk = try test.deriveUnifiedSpendingKey(seed: [UInt8](repeating: 9, count: 32), accountIndex: Zip32AccountIndex(0))
        let testKey = try test.deriveUnifiedFullViewingKey(from: tusk).stringEncoded
        XCTAssertThrowsError(try WatchOnly.cleaned(testKey)) { XCTAssertEqual($0 as? WatchOnly.Failure, .testnet) }
        for bad in ["", "uview1notakey", "u1abc", String(ufvk.dropLast())] {
            XCTAssertThrowsError(try WatchOnly.cleaned(bad)) { XCTAssertEqual($0 as? WatchOnly.Failure, .notAViewingKey, bad) }
        }

        let decoder = SealItURDecoder(expectedType: SealItURType.viewingKey)
        XCTAssertTrue(try decoder.receive(ufvk))
        XCTAssertEqual(String(decoding: try XCTUnwrap(decoder.message), as: UTF8.self), ufvk)

        XCTAssertNil(WatchOnly.name("   "))
        XCTAssertEqual(WatchOnly.name("  Shop \n"), "Shop")
        XCTAssertEqual(WatchOnly.name(String(repeating: "a", count: 60))?.count, 40)
    }
    /// The time left follows how fast blocks are checked, not how far the
    /// gap-free height climbs: after adding a wallet the engine re-checks
    /// older blocks and the height barely moves, which gave "8 days".
    func testTimeLeftFollowsBlocksChecked() {
        XCTAssertEqual(SyncMath.openCount(toScan: [(100, 200), (150, 250), (900, 1_200)], tip: 1_000), 250, "overlap once, clipped to the tip")
        XCTAssertEqual(SyncMath.openCount(toScan: [], tip: 1_000), 0)
        let t = Date(timeIntervalSince1970: 0)
        let samples = (0..<4).map { SyncMath.Sample(at: t.addingTimeInterval(Double($0) * 10), height: 1_300_000 - $0 * 3_000) }
        XCTAssertEqual(SyncMath.minutesLeft(open: 1_200_000, openSamples: samples), 67, "300 blocks a second")
        XCTAssertNil(SyncMath.minutesLeft(open: 1_200_000, openSamples: Array(samples.prefix(2))), "too few samples")
        XCTAssertNil(SyncMath.minutesLeft(open: 1_200_000, openSamples: Array(samples.prefix(3)).map { SyncMath.Sample(at: t, height: $0.height) }), "under 20 seconds")
        XCTAssertNil(SyncMath.minutesLeft(open: 1_200_000, openSamples: samples.reversed().enumerated().map { SyncMath.Sample(at: t.addingTimeInterval(Double($0.offset) * 10), height: $0.element.height) }), "not falling")
        XCTAssertNil(SyncMath.minutesLeft(open: 0, openSamples: samples))
    }
    /// Adding an older wallet finds its old payments while the others are
    /// up to date: those stay in Activity, only new ones get a message.
    func testOnlyNewPaymentsGetAMessage() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(WalletEngine.isNews(minedHeight: nil, blockTime: nil, network: 3_609_479, now: now), "waiting for a block")
        XCTAssertTrue(WalletEngine.isNews(minedHeight: 3_609_400, blockTime: nil, network: 3_609_479, now: now), "one of the last 100 blocks")
        XCTAssertTrue(WalletEngine.isNews(minedHeight: 3_500_000, blockTime: now.timeIntervalSince1970 - 600, network: 0, now: now), "network unknown, block 10 minutes old")
        XCTAssertFalse(WalletEngine.isNews(minedHeight: 2_400_000, blockTime: now.timeIntervalSince1970 - 86_400 * 600, network: 3_609_479, now: now), "a payment from 2024")
        XCTAssertFalse(WalletEngine.isNews(minedHeight: 3_609_000, blockTime: nil, network: 3_609_479, now: now), "older than 100 blocks, no time")
    }
    /// CSV for bookkeeping: exact amounts, standard quoting, and a memo
    /// (anyone can send one) never runs as a spreadsheet formula.
    func testActivityCSV() throws {
        XCTAssertEqual(ActivityCSV.zec(123_456_789), "1.23456789")
        XCTAssertEqual(ActivityCSV.zec(10_000), "0.00010000")
        XCTAssertEqual(ActivityCSV.zec(2_100_000_000_000_000), "21000000.00000000")
        XCTAssertEqual(ActivityCSV.zec(0), "0.00000000")

        XCTAssertEqual(ActivityCSV.field("Order 42"), "Order 42")
        XCTAssertEqual(ActivityCSV.field("a, b"), "\"a, b\"")
        XCTAssertEqual(ActivityCSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ActivityCSV.field("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(ActivityCSV.field("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        for bad in ["+1", "-1", "@SUM(A1)", "\tx"] { XCTAssertTrue(ActivityCSV.field(bad).contains("'"), bad) }

        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        let when = Date(timeIntervalSince1970: 1_795_589_352) // 2026-11-25 06:49:12 UTC
        XCTAssertEqual(ActivityCSV.date(when, zone: zone), "2026-11-25 07:49:12 +01:00")
        let row = ActivityCSV.Row(date: when, received: false, description: "Sent", amount: 50_000_000, fee: 10_000, status: "confirmed",
                                  block: 3_609_479, memo: "Coffee, 2x", txid: "ab12")
        XCTAssertEqual(ActivityCSV.line(row, zone: zone),
                       "2026-11-25 07:49:12 +01:00,sent,Sent,0.50000000,0.00010000,confirmed,3609479,\"Coffee, 2x\",ab12")
        let waiting = ActivityCSV.Row(date: nil, received: true, description: "Received", amount: 1, fee: nil, status: "waiting", block: nil, memo: nil, txid: "cd")
        XCTAssertEqual(ActivityCSV.line(waiting, zone: zone), ",received,Received,0.00000001,,waiting,,,cd")

        // From Activity: a send's fee comes out of the amount, once.
        let sent = WalletEngine.ActivityItem(id: Data([1]), kind: .sent, amount: 110_000, date: when, state: .confirmed,
                                             minedHeight: 3_597_827, fee: 10_000)
        let sentRow = ActivityCSV.row(sent, memo: nil)
        XCTAssertEqual(sentRow.amount, 100_000)
        XCTAssertEqual(sentRow.fee, 10_000)
        XCTAssertEqual(sentRow.description, "Sent")
        let forwarding = WalletEngine.ActivityItem(id: Data([2]), kind: .sent, amount: 15_000, date: when, state: .confirmed,
                                                   fee: 15_000, texReceiver: "tex1x", texStep: 2)
        let fwdRow = ActivityCSV.row(forwarding, memo: nil)
        XCTAssertEqual(fwdRow.amount, 0, "only the fee left")
        XCTAssertEqual(fwdRow.fee, 15_000)
        XCTAssertEqual(fwdRow.description, "TEX payment · forwarding fee")
        let got = WalletEngine.ActivityItem(id: Data([3]), kind: .received, amount: 180_000, date: when, state: .waiting)
        XCTAssertEqual(ActivityCSV.row(got, memo: "=1+1").amount, 180_000)
        XCTAssertNil(ActivityCSV.row(got, memo: nil).fee)
        XCTAssertEqual(ActivityCSV.row(got, memo: nil).status, "waiting")

        let data = ActivityCSV.file([row], zone: zone)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 byte order mark")
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(ActivityCSV.header + "\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n"))

        XCTAssertEqual(ActivityCSV.fileName(wallet: "My Shop · Café", now: when, zone: zone), "zecky-my-shop-caf-2026-11-25.csv")
        XCTAssertEqual(ActivityCSV.fileName(wallet: "", now: when, zone: zone), "zecky-wallet-2026-11-25.csv")
    }
    /// Settings › Business: the row's summary, and a viewing key fits a QR
    /// code with high error correction (as on Receive).
    func testBusinessPage() throws {
        XCTAssertEqual(WatchOnly.summary(count: 0), "Watch only · viewing key · CSV")
        XCTAssertEqual(WatchOnly.summary(count: 1), "1 watch-only wallet")
        XCTAssertEqual(WatchOnly.summary(count: 3), "3 watch-only wallets")
        let tool = DerivationTool(networkType: .mainnet)
        let usk = try tool.deriveUnifiedSpendingKey(seed: [UInt8](repeating: 5, count: 32), accountIndex: Zip32AccountIndex(0))
        let ufvk = try tool.deriveUnifiedFullViewingKey(from: usk).stringEncoded
        XCTAssertNotNil(QRCode.image(for: ufvk))
    }
    /// Audit 25 Nov: a wallet sends once its own blocks are checked, the
    /// others meanwhile; the engine's refusal of a known key is plain; a move
    /// inside the wallet is named; a payment during sleep still gets news.
    func testAuditBeforeSaturday() throws {
        // 1. Newest checked, older open below 3,524,536 for another wallet.
        let open = [(first: 2_306_540, end: 3_200_000)]
        XCTAssertTrue(SyncMath.ownChecked(toScan: open, start: 3_524_536, network: 3_609_479))
        XCTAssertFalse(SyncMath.ownChecked(toScan: open, start: 2_306_540, network: 3_609_479))
        XCTAssertTrue(SyncMath.ownChecked(toScan: [(first: 3_609_478, end: 3_609_480)], start: 3_524_536, network: 3_609_479), "the newest 3 may be new")
        XCTAssertNil(WalletEngine.caughtUpProblem(network: 3_609_479, wallet: 2_306_540, newestCheckedAt: 3_609_478,
                                                  ownStart: 3_524_536, openRanges: open), "the main wallet sends")
        guard case .olderBlocks(let since)? = WalletEngine.caughtUpProblem(network: 3_609_479, wallet: 2_306_540, newestCheckedAt: 3_609_478,
                                                                         ownStart: 2_306_540, openRanges: open) else {
            return XCTFail("a wallet with an older start waits")
        }
        XCTAssertEqual(since, 2_306_540)
        // 3.
        XCTAssertTrue(WatchOnly.isCollision("rustImportAccountUfvk(\"Account collision with existing account\")"))
        XCTAssertFalse(WatchOnly.isCollision("The server is unavailable"))
        // 4.
        let move = WalletEngine.ActivityItem(id: Data([9]), kind: .sent, amount: 15_000, date: nil, state: .confirmed, fee: 15_000)
        XCTAssertEqual(ActivityCSV.row(move, memo: nil).description, "Moved inside the wallet · fee")
        // 6. Up to date at 22:00, asleep, payment at 23:00, awake at 07:00.
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let lastUp = now.addingTimeInterval(-9 * 3_600)
        let paid = now.addingTimeInterval(-8 * 3_600).timeIntervalSince1970
        XCTAssertTrue(WalletEngine.isNews(minedHeight: 3_608_000, blockTime: paid, network: 3_609_479, since: lastUp, now: now))
        XCTAssertFalse(WalletEngine.isNews(minedHeight: 3_608_000, blockTime: paid, network: 3_609_479, now: now), "fresh start: history")
        XCTAssertFalse(WalletEngine.isNews(minedHeight: 2_400_000, blockTime: lastUp.timeIntervalSince1970 - 86_400 * 300,
                                           network: 3_609_479, since: lastUp, now: now), "old payment for a new wallet")
        // 7.
        XCTAssertTrue(WatchOnly.addressProblem("no Orchard receiver").contains("no Orchard part"))
    }
}
