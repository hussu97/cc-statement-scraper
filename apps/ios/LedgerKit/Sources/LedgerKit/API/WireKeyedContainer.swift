import Foundation

/// Reads a JSON object by its exact wire keys (`spend_avg_3m`), whatever key
/// strategy the decoder runs (audit X-33r).
///
/// `LedgerJSON` decodes with `.convertFromSnakeCase`, which rewrites every key
/// before lookup: `spend_avg_3m` becomes `spendAvg3M`, the digit's neighbour
/// capitalised by Foundation's word rules. A model that names `spendAvg3M`
/// silently depends on that rule. Here a key is matched on its letters and
/// digits alone (lowercased, underscores dropped), so the snake_case name in
/// a `CodingKeys` raw value is all a model states, and both strategies agree.
struct WireKeyedContainer<Key: CodingKey> {
    private let container: KeyedDecodingContainer<AnyWireKey>
    private let keys: [String: AnyWireKey]

    init(_ decoder: any Decoder, keyedBy: Key.Type) throws {
        container = try decoder.container(keyedBy: AnyWireKey.self)
        keys = Dictionary(container.allKeys.map { (Self.fold($0.stringValue), $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// `spend_avg_3m` and `spendAvg3M` both fold to `spendavg3m`.
    static func fold(_ key: String) -> String { key.lowercased().filter { $0 != "_" } }

    func contains(_ key: Key) -> Bool { keys[Self.fold(key.stringValue)] != nil }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try container.decode(type, forKey: wireKey(key))
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let wire = keys[Self.fold(key.stringValue)] else { return nil }
        return try container.decodeIfPresent(type, forKey: wire)
    }

    /// Money: a decimal string or a JSON number (`DecimalParsing.swift`).
    func decode(_ type: Decimal.Type, forKey key: Key) throws -> Decimal {
        try container.decode(Decimal.self, forKey: wireKey(key))
    }

    func decodeIfPresent(_ type: Decimal.Type, forKey key: Key) throws -> Decimal? {
        guard let wire = keys[Self.fold(key.stringValue)] else { return nil }
        return try container.decodeIfPresent(Decimal.self, forKey: wire)
    }

    private func wireKey(_ key: Key) throws -> AnyWireKey {
        guard let wire = keys[Self.fold(key.stringValue)] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: container.codingPath,
                                                       debugDescription: "No value for '\(key.stringValue)'"))
        }
        return wire
    }
}

struct AnyWireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
