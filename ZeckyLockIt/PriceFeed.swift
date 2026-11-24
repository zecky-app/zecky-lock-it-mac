import Foundation

/// Optional value of the balance in USD, EUR or BTC. Off unless the owner
/// turns it on. The price service (CoinGecko) sees a price request, never
/// anything about the wallet; while Tor sending is on, it goes over the
/// engine's Tor, so it does not see this Mac's internet address either.
@MainActor
final class PriceFeed: ObservableObject {
    enum Currency: String, CaseIterable, Identifiable {
        case none, usd, eur, btc
        var id: Self { self }
        var short: String {
            switch self {
            case .none: return "None"
            case .usd: return "USD"
            case .eur: return "EUR"
            case .btc: return "BTC"
            }
        }
        var label: String {
            switch self {
            case .none: return "None"
            case .usd: return "US dollar (USD)"
            case .eur: return "Euro (EUR)"
            case .btc: return "Bitcoin (BTC)"
            }
        }
    }

    @Published var currency: Currency = Currency(rawValue: UserDefaults.standard.string(forKey: "value.currency") ?? "none") ?? .none {
        didSet {
            UserDefaults.standard.set(currency.rawValue, forKey: "value.currency")
            rates = [:]
            restart()
        }
    }
    /// Price of 1 ZEC per currency code ("usd", "eur", "btc").
    @Published private(set) var rates: [String: Double] = [:]

    private var task: Task<Void, Never>?
    nonisolated private static let refresh: UInt64 = 5 * 60 * 1_000_000_000
    private static let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=zcash&vs_currencies=usd,eur,btc")!

    /// No cookies, no cache, nothing kept between requests.
    private let session = URLSession(configuration: .ephemeral)

    /// The engine's Tor, set once the wallet engine runs. While Tor sending
    /// is on and this is not there yet, no price is asked (never in the clear).
    static var overTor: ((URLRequest) async throws -> (Data, HTTPURLResponse))?

    /// How the price is asked: over Tor, directly, or not at all for now.
    enum Road: Equatable { case tor, direct, wait }
    nonisolated static func road(torSending: Bool, torReady: Bool) -> Road {
        torSending ? (torReady ? .tor : .wait) : .direct
    }

    init() { restart() }

    func reset() { currency = .none }

    private func restart() {
        task?.cancel()
        task = nil
        guard currency != .none else { return }
        task = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                let got = await self?.fetch() ?? false
                misses = got ? 0 : misses + 1
                try? await Task.sleep(nanoseconds: Self.wait(afterMisses: misses))
            }
        }
    }

    /// How long until the next try. A price every 5 minutes; until one
    /// comes (Tor still starting, or CoinGecko turning a Tor exit away),
    /// sooner but patiently: 15 s, 30 s, 1 min, 2 min, then 5 min. The free
    /// API limits calls per address, and Tor exits are shared, so no hammering.
    nonisolated static func wait(afterMisses misses: Int) -> UInt64 {
        guard misses > 0 else { return refresh }
        let second: UInt64 = 1_000_000_000
        return min(refresh, 15 * second << UInt64(min(misses - 1, 10)))
    }

    /// True when a price came in. A miss keeps the last price on screen.
    @discardableResult
    private func fetch() async -> Bool {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = 20
        let answer: (Data, URLResponse)?
        switch Self.road(torSending: TorSending.isOn, torReady: Self.overTor != nil) {
        case .wait: return false
        case .tor:
            guard let overTor = Self.overTor else { return false }
            if let (data, response) = try? await overTor(request) { answer = (data, response) } else { answer = nil }
        case .direct:
            answer = try? await session.data(for: request)
        }
        guard let (data, response) = answer,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]],
              let zcash = json["zcash"], !zcash.isEmpty else { return false }
        rates = zcash
        return true
    }

    /// "≈ $34.12", "≈ €31.50", "≈ 0.00031200 BTC", or nil when off or unknown.
    func value(of zatoshi: Int64) -> String? {
        guard currency != .none, let rate = rates[currency.rawValue] else { return nil }
        let amount = Double(zatoshi) / 100_000_000 * rate
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        switch currency {
        case .btc:
            f.minimumFractionDigits = 8; f.maximumFractionDigits = 8
            return "≈ " + (f.string(from: NSNumber(value: amount)) ?? "") + " BTC"
        case .usd, .eur:
            f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
            let symbol = currency == .usd ? "$" : "€"
            if amount > 0 && amount < 0.01 { return "≈ <\(symbol)0.01" }
            return "≈ " + symbol + (f.string(from: NSNumber(value: amount)) ?? "")
        case .none:
            return nil
        }
    }
}
