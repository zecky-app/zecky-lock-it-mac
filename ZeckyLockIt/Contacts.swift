import SwiftUI
import ZcashLightClientKit

/// Saved, trusted addresses: release by picking a name instead of pasting
/// a long address, which also helps against malware that swaps a copied
/// address. Kept in the Keychain, this Mac only, never synced.
///
/// Optional rule: only release to saved addresses. While it is on, adding
/// an address and turning the rule off both need the owner (code / Touch
/// ID), so nobody can quietly add their own address first.
enum Contacts {
    struct Contact: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var address: String
        var added = Date()
    }

    private struct Book: Codable {
        var contacts: [Contact] = []
        var onlySaved = false
    }

    private static let service = "app.zecky.lockit.mac.contacts"
    static let maxName = 32

    private static var book: Book {
        get {
            guard let data = (try? KeyStore.read(service: service)) ?? nil,
                  let book = try? JSONDecoder().decode(Book.self, from: data) else { return Book() }
            return book
        }
        set { try? KeyStore.save(try JSONEncoder().encode(newValue), service: service) }
    }

    static var all: [Contact] {
        book.contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var onlySaved: Bool { book.onlySaved }

    static func name(for address: String) -> String? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return book.contacts.first { $0.address == a }?.name
    }

    static func isValid(_ address: String) -> Bool {
        (try? Recipient(address.trimmingCharacters(in: .whitespacesAndNewlines), network: .mainnet)) != nil
    }

    enum Problem: Error, CustomStringConvertible {
        case noName, badAddress, known(String)
        var description: String {
            switch self {
            case .noName: return "Give the address a name."
            case .badAddress: return "That is not a valid Zcash address."
            case .known(let name): return "This address is already saved as \(name)."
            }
        }
    }

    static func check(name: String, address: String) throws -> (String, String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw Problem.noName }
        guard isValid(a) else { throw Problem.badAddress }
        if let known = Contacts.name(for: a) { throw Problem.known(known) }
        return (n, a)
    }

    static func add(name: String, address: String) throws {
        let (n, a) = try check(name: name, address: address)
        var b = book
        b.contacts.append(Contact(name: n, address: a))
        book = b
        LockLog.add(.addressBook, "Saved \(n)")
    }

    static func rename(_ id: UUID, to name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        guard !n.isEmpty else { return }
        var b = book
        guard let i = b.contacts.firstIndex(where: { $0.id == id }) else { return }
        let old = b.contacts[i].name
        b.contacts[i].name = n
        book = b
        if old != n { LockLog.add(.addressBook, "Renamed \(old) to \(n)") }
    }

    static func remove(_ id: UUID) {
        var b = book
        guard let i = b.contacts.firstIndex(where: { $0.id == id }) else { return }
        let name = b.contacts[i].name
        b.contacts.remove(at: i)
        book = b
        LockLog.add(.addressBook, "Removed \(name)")
    }

    static func setOnlySaved(_ on: Bool) {
        var b = book
        b.onlySaved = on
        book = b
        LockLog.add(.addressBook, on ? "Only send to saved addresses: on" : "Only send to saved addresses: off")
    }

    static func erase() { try? KeyStore.delete(service: service) }

    /// Long addresses in groups of four, so a swapped character stands out.
    static func grouped(_ address: String) -> String {
        var out = ""
        for (i, ch) in address.enumerated() {
            if i > 0 && i % 4 == 0 { out += " " }
            out.append(ch)
        }
        return out
    }

    static func short(_ a: String) -> String {
        a.count > 28 ? String(a.prefix(10)) + "…" + String(a.suffix(10)) : a
    }
}

/// Settings › Address book: the list, adding, renaming, removing, and the
/// rule. `guarded` runs an action only after the owner confirmed it (code
/// and Touch ID), used while the rule is on.
struct ContactsCard: View {
    let guarded: (_ reason: String, _ action: @escaping () -> Void) -> Void
    let changed: () -> Void

    @State private var contacts = Contacts.all
    @State private var onlySaved = Contacts.onlySaved
    @State private var adding = false
    @State private var name = ""
    @State private var address = ""
    @State private var note: String?
    @State private var editing: UUID?
    @State private var editName = ""
    @State private var removing: Contacts.Contact?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved addresses you trust. Pick a name when sending instead of pasting an address, so a swapped address stands out.")
                .font(Theme.text(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !contacts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(contacts.enumerated()), id: \.element.id) { index, contact in
                        if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                        row(contact)
                    }
                }
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }

            if adding { form } else {
                HStack {
                    Toggle(isOn: Binding(get: { onlySaved }, set: { toggleRule($0) })) {
                        Text("Only send to saved addresses").font(Theme.text(13))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(contacts.isEmpty && !onlySaved)
                    Spacer()
                    SecondaryButton(title: "Add address") { note = nil; adding = true }.frame(width: 150)
                }
            }
            if let note { Text(note).font(Theme.text(12)).foregroundStyle(Theme.red) }
        }
        .alert("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let r = removing { Contacts.remove(r.id); reload() }
                removing = nil
            }
        } message: {
            Text("The address is removed from this Mac's address book.")
        }
    }

    private func row(_ contact: Contacts.Contact) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.gold.opacity(0.14))
                Text(String(contact.name.prefix(1)).uppercased())
                    .font(Theme.serif(15, weight: .medium)).foregroundStyle(Theme.gold)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                if editing == contact.id {
                    TextField("Name", text: $editName)
                        .textFieldStyle(.plain).font(Theme.text(13, weight: .medium))
                        .onSubmit { Contacts.rename(contact.id, to: editName); editing = nil; reload() }
                } else {
                    Text(contact.name).font(Theme.text(13, weight: .medium))
                }
                Text(Contacts.short(contact.address))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    .help(Contacts.grouped(contact.address))
            }
            Spacer()
            Button { editName = contact.name; editing = contact.id } label: {
                Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain).help("Rename")
            Button { removing = contact } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain).help("Remove")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Name, for example My exchange", $name)
            field("Zcash address", $address, mono: true)
            HStack {
                Text(onlySaved ? "Needs your Zecky code and Touch ID while the rule is on." : " ")
                    .font(Theme.text(11)).foregroundStyle(Theme.muted)
                Spacer()
                QuietButton(title: "Cancel") { adding = false; name = ""; address = ""; note = nil }.frame(width: 110)
                PrimaryButton(title: "Save") { save() }.frame(width: 110)
            }
        }
    }

    private func field(_ prompt: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundColor(Theme.muted))
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 12, design: .monospaced) : Theme.text(13))
            .autocorrectionDisabled()
            .padding(10)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func save() {
        note = nil
        do { _ = try Contacts.check(name: name, address: address) } catch { note = String(describing: error); return }
        let n = name, a = address
        let commit = {
            do { try Contacts.add(name: n, address: a); adding = false; name = ""; address = ""; reload() }
            catch { note = String(describing: error) }
        }
        if LockRules.addAddress(ruleOn: onlySaved) == .owner { guarded("save a new address", commit) } else { commit() }
    }

    private func toggleRule(_ on: Bool) {
        if LockRules.addressRule(on: on) == .nothing {
            Contacts.setOnlySaved(on); reload()
        } else {
            guarded("turn off the saved-addresses rule") { Contacts.setOnlySaved(false); reload() }
        }
    }

    private func reload() {
        contacts = Contacts.all
        onlySaved = Contacts.onlySaved
        changed()
    }
}

/// A ZIP-321 payment request ("zcash:<address>?amount=0.5&memo=…"), as made
/// by Lock more's Request an amount and by other Zcash wallets. Lock it
/// pays one recipient per release, so a request for several is refused
/// instead of quietly paying only the first (self-audit F4).
struct PaymentRequest: Equatable {
    var address: String
    var amount: String?
    var memo: String?
    var label: String?

    enum Problem: Error, Equatable, CustomStringConvertible {
        case notARequest, severalRecipients, noAddress, badAmount, badMemo
        var description: String {
            switch self {
            case .notARequest: return "That is not a Zcash payment request."
            case .severalRecipients: return "This request pays several recipients. Lock it sends to one at a time: ask for a request per recipient. Nothing was filled in."
            case .noAddress: return "This payment request has no address."
            case .badAmount: return "The amount in this payment request is not valid."
            case .badMemo: return "The note in this payment request could not be read."
            }
        }
    }

    static func isRequest(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("zcash:")
    }

    static func parse(_ text: String) throws -> PaymentRequest {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRequest(t) else { throw Problem.notARequest }
        let rest = String(t.dropFirst("zcash:".count))
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var address = String(parts.first ?? "")
        var amount: String?, memo: String?, label: String?
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawKey = String(kv[0])
                let value = kv.count > 1 ? String(kv[1]) : ""
                // An index (address.1, amount.2, …) means more than one recipient.
                if rawKey.contains(".") { throw Problem.severalRecipients }
                switch rawKey {
                case "address":
                    guard address.isEmpty else { throw Problem.severalRecipients }
                    address = value
                case "amount":
                    guard value.range(of: #"^\d+(\.\d{1,8})?$"#, options: .regularExpression) != nil,
                          let v = Decimal(string: value, locale: Locale(identifier: "en_US")), v > 0, v <= 21_000_000
                    else { throw Problem.badAmount }
                    amount = value
                case "memo":
                    var b64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    while b64.count % 4 != 0 { b64.append("=") }
                    guard let data = Data(base64Encoded: b64), data.count <= 512 else { throw Problem.badMemo }
                    memo = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                case "label", "message":
                    label = value.removingPercentEncoding ?? value
                default:
                    // Unknown "req-" parameters must be understood, others may be ignored.
                    if rawKey.hasPrefix("req-") { throw Problem.notARequest }
                }
            }
        }
        guard !address.isEmpty else { throw Problem.noAddress }
        return PaymentRequest(address: address, amount: amount, memo: memo?.isEmpty == true ? nil : memo, label: label)
    }
}
