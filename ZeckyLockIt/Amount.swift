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
