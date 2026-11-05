import CryptoKit
import XCTest
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
        let received = Item(id: Data([1]), kind: .received, amount: 1, date: Date(), state: .confirmed, minedHeight: 100)
        let own = Item(id: Data([2]), kind: .sent, amount: 1, date: Date(), state: .confirmed, minedHeight: 100)
        let pending = Item(id: Data([3]), kind: .received, amount: 1, date: nil, state: .waiting, minedHeight: nil)

        // In block 100, network at 103: 4 of 10, 6 blocks × 75 s ≈ 8 minutes.
        XCTAssertEqual(WalletEngine.slowestWaiting([received], networkHeight: 103),
                       .init(confirmations: 4, needed: 10, minutes: 8))
        XCTAssertEqual(WalletEngine.waitingText(.init(confirmations: 4, needed: 10, minutes: 8)),
                       "usable in about 8 minutes · 4/10 confirmations")
        // Own change needs 3: at 102 it is done.
        XCTAssertNil(WalletEngine.slowestWaiting([own], networkHeight: 102))
        // Not in a block yet: the slowest wins.
        XCTAssertEqual(WalletEngine.slowestWaiting([received, pending], networkHeight: 103)?.confirmations, 0)
        XCTAssertEqual(WalletEngine.waitingText(nil), "usable within about 12 minutes")
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
        XCTAssertThrowsError(try PaymentRequest.parse("zcash:u1abc?req-unknown=1"))
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
        let r = SecurityKeys.Removal(startedAt: Date(timeIntervalSince1970: 0), startHeight: 1000)
        XCTAssertFalse(LockRules.removalDue(r, now: Date(timeIntervalSince1970: 47 * 3600), networkHeight: 5000))
        XCTAssertFalse(LockRules.removalDue(r, now: Date(timeIntervalSince1970: 49 * 3600), networkHeight: 3000))
        XCTAssertTrue(LockRules.removalDue(r, now: Date(timeIntervalSince1970: 49 * 3600), networkHeight: 3304))
    }
}
