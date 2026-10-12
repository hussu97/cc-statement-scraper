import Foundation
import Observation

/// One row of `public.banks` as the app reads it. `logo_path` names an object
/// in the public `bank-logos` bucket (`"FAB.png"`); `sms_senders` lets a parked
/// SMS show its bank.
public struct BankInfo: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { bankCode }
    public let bankCode: String
    public let name: String
    public let logoPath: String?
    public let smsSenders: [String]

    public init(bankCode: String, name: String, logoPath: String? = nil, smsSenders: [String] = []) {
        self.bankCode = bankCode
        self.name = name
        self.logoPath = logoPath
        self.smsSenders = smsSenders
    }

    enum CodingKeys: String, CodingKey { case bankCode, name, logoPath, smsSenders }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bankCode = try c.decode(String.self, forKey: .bankCode)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? bankCode
        logoPath = (try? c.decodeIfPresent(String.self, forKey: .logoPath)) ?? nil
        smsSenders = (try? c.decodeIfPresent([String].self, forKey: .smsSenders)) ?? []
    }
}

/// Where a bank's logo comes from. The app bundles every seeded bank
/// (`assets/banks/*.png`, asset names `Bank/<CODE>`) so logos draw offline and
/// without a request; any other bank falls back to its `bank-logos` URL, and a
/// bank with neither shows a monogram.
public enum BankLogoSource: Sendable, Hashable {
    case bundled(assetName: String)
    case remote(URL)
    case monogram(String)
}

/// Pure lookups: names, bundled assets, URLs and the dark-mode chip.
public enum BankDirectory {
    /// Bank codes with a bundled asset in `Assets.xcassets/Bank/`.
    public static let bundledCodes: Set<String> = ["ADCB", "EIB", "ENBD", "FAB", "MASHREQ", "SIB", "WIO"]

    /// Marks with too little contrast on a dark surface (navy, blue, purple):
    /// in dark mode they sit on a light chip (assets/banks/README.md).
    public static let darkMarks: Set<String> = ["ENBD", "SIB", "EIB", "FAB", "WIO"]

    /// Names from the seed (`public.banks`), used until the table has been read
    /// and when the phone is offline.
    public static let knownNames: [String: String] = [
        "FAB": "First Abu Dhabi Bank",
        "ADCB": "Abu Dhabi Commercial Bank",
        "ENBD": "Emirates NBD",
        "EIB": "Emirates Islamic",
        "SIB": "Sharjah Islamic Bank",
        "MASHREQ": "Mashreq",
        "WIO": "Wio Bank",
    ]

    /// `{supabaseURL}/storage/v1/object/public/bank-logos/{logo_path}`.
    public static func logoURL(supabaseURL: URL, logoPath: String) -> URL? {
        guard !logoPath.isEmpty, !logoPath.contains("/"), !logoPath.contains("..") else { return nil }
        return supabaseURL.appendingPathComponent("storage/v1/object/public/bank-logos")
            .appendingPathComponent(logoPath)
    }

    /// The bundled asset first, then the bucket, then a monogram.
    public static func source(bankCode: String, logoPath: String?, supabaseURL: URL?) -> BankLogoSource {
        let code = bankCode.uppercased()
        if bundledCodes.contains(code) { return .bundled(assetName: "Bank/\(code)") }
        if let logoPath, let supabaseURL, let url = logoURL(supabaseURL: supabaseURL, logoPath: logoPath) {
            return .remote(url)
        }
        return .monogram(monogram(code))
    }

    /// Whether the logo needs the light rounded chip behind it.
    public static func needsLightChip(bankCode: String, darkMode: Bool) -> Bool {
        darkMode && darkMarks.contains(bankCode.uppercased())
    }

    /// `"MASHREQ"` → `"MA"`, `"FAB"` → `"FA"`: two letters fit a 20 pt circle.
    public static func monogram(_ code: String) -> String {
        String(code.uppercased().prefix(2))
    }
}

/// The banks table, read once per sign-in, with the seed as a fallback. Views
/// ask it for a bank's name (the accessibility label of every logo) and logo.
@MainActor
@Observable
public final class BankCatalog {
    public private(set) var banks: [String: BankInfo] = [:]
    public let supabaseURL: URL?
    private let load: (@Sendable () async throws -> [BankInfo])?
    private var loaded = false

    public init(supabaseURL: URL?, load: (@Sendable () async throws -> [BankInfo])? = nil) {
        self.supabaseURL = supabaseURL
        self.load = load
    }

    public convenience init(api: any LedgerAPI, supabaseURL: URL) {
        self.init(supabaseURL: supabaseURL, load: { try await api.banks() })
    }

    /// Reads `public.banks` once; a failure keeps the seed names and bundled logos.
    public func refresh(force: Bool = false) async {
        guard let load, force || !loaded else { return }
        if let rows = try? await load() {
            banks = Dictionary(rows.map { ($0.bankCode, $0) }, uniquingKeysWith: { a, _ in a })
            loaded = true
        }
    }

    /// `"First Abu Dhabi Bank"`; the code itself for a bank nobody has named.
    public func name(for bankCode: String) -> String {
        banks[bankCode]?.name ?? BankDirectory.knownNames[bankCode.uppercased()] ?? bankCode
    }

    public func source(for bankCode: String) -> BankLogoSource {
        BankDirectory.source(bankCode: bankCode, logoPath: banks[bankCode]?.logoPath, supabaseURL: supabaseURL)
    }

    /// The bank whose SMS sender id this is (`"ADCBAlert"` → `"ADCB"`), case-insensitive.
    public func bankCode(forSender sender: String) -> String? {
        let s = sender.lowercased()
        return banks.values.first { $0.smsSenders.contains { $0.lowercased() == s } }?.bankCode
    }
}
