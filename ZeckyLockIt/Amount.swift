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
