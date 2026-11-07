import Foundation

/// Amounts the way the iPhone app shows them: US style, ZEC with 3 decimals.
enum Amount {
    private static func group(_ digits: String) -> String {
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }

    enum Unit: String { case zec = "ZEC", zats }

    /// The owner's choices, kept like on iPhone: unit and hidden amounts.
    static var unit: Unit {
        get { Unit(rawValue: UserDefaults.standard.string(forKey: "amount.unit") ?? "ZEC") ?? .zec }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "amount.unit") }
    }
    static var hidden: Bool {
        get { UserDefaults.standard.bool(forKey: "amount.hidden") }
        set { UserDefaults.standard.set(newValue, forKey: "amount.hidden") }
    }
    static func resetChoices() {
        UserDefaults.standard.removeObject(forKey: "amount.unit")
        UserDefaults.standard.removeObject(forKey: "amount.hidden")
    }

    static let hiddenText = "••••••"

    /// Whole zats with thousands separators.
    static func zats(_ zatoshi: Int64) -> String {
        (zatoshi < 0 ? "-" : "") + group(String(zatoshi.magnitude))
    }

    /// The number alone, in `unit`.
    static func number(_ zatoshi: Int64, _ unit: Unit) -> String {
        unit == .zec ? zec(zatoshi) : zats(zatoshi)
    }

    /// Number plus unit, e.g. "0.001 ZEC" or "100,000 zats".
    static func text(_ zatoshi: Int64, _ unit: Unit) -> String {
        number(zatoshi, unit) + " " + unit.rawValue
    }

    /// "1,234.567", or "<0.001" for a tiny non-zero amount.
    static func zec(_ zatoshi: Int64) -> String {
        let sign = zatoshi < 0 ? "-" : ""
        let abs = zatoshi.magnitude
        let thousandths = abs / 100_000
        if thousandths == 0 && abs > 0 { return "<0.001" }
        let whole = group(String(thousandths / 1000))
        let fraction = String(thousandths % 1000)
        return sign + whole + "." + String(repeating: "0", count: 3 - fraction.count) + fraction
    }
}

/// Reading a typed amount, as on the iPhone (src/lib/zec.ts, audit C-19).
enum AmountInput {
    /// "1,500" could be 1.5 (comma as the decimal key, as on a Dutch
    /// keyboard) or fifteen hundred (US thousands), so it is refused with a
    /// question rather than guessed. "0,001", "1,5" or "12,34" can only mean
    /// one thing and are read as decimals.
    static func ambiguous(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[1-9]\d{0,2},\d{3}$"#, options: .regularExpression) != nil
    }

    /// The question to ask for an ambiguous amount, in `unit`.
    static func question(_ text: String, unit: String) -> String {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ",")
        let whole = String(parts[0]), part = String(parts[1])
        var short = part
        while short.hasSuffix("0") { short.removeLast() }
        if short.isEmpty { short = "0" }
        return "Is that \(whole).\(short) \(unit) or \(whole)\(part) \(unit)? Type \(whole).\(part) or \(whole)\(part)."
    }

    /// ZEC typed as "1.5" or "1,5", at most 8 decimals, above zero.
    static func zec(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !ambiguous(t),
              let m = t.range(of: #"^\d*([.,]\d{0,8})?$"#, options: .regularExpression), m == t.startIndex..<t.endIndex
        else { return nil }
        let pieces = t.split(separator: t.contains(",") ? "," : ".", omittingEmptySubsequences: false)
        let whole = pieces.first.map(String.init) ?? ""
        let fraction = pieces.count > 1 ? String(pieces[1]) : ""
        guard !(whole.isEmpty && fraction.isEmpty), whole.count <= 10 else { return nil }
        let w = Int64(whole.isEmpty ? "0" : whole) ?? 0
        let f = Int64(fraction.padding(toLength: 8, withPad: "0", startingAt: 0)) ?? 0
        let z = w * 100_000_000 + f
        return z > 0 ? z : nil
    }

    /// Whole zats; comma thousands separators and spaces are ignored. A dot
    /// is refused: "1.5" zats is not 15 zats.
    static func zats(_ text: String) -> Int64? {
        guard !text.contains(".") else { return nil }
        let digits = text.filter { $0 != "," && !$0.isWhitespace }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let v = Int64(digits), v > 0 else { return nil }
        return v
    }

    /// Money typed as "25", "25.50" or "25,50" (at most 2 decimals).
    static func fiat(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !ambiguous(t),
              let m = t.range(of: #"^\d+([.,]\d{0,2})?$"#, options: .regularExpression), m == t.startIndex..<t.endIndex,
              let v = Double(t.replacingOccurrences(of: ",", with: ".")), v > 0
        else { return nil }
        return v
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
