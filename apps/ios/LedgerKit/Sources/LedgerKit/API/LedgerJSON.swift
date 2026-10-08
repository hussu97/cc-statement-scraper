import Foundation

/// The one decoder/encoder every API response goes through. Snake-case keys map
/// to camelCase properties; timestamps accept every shape Postgres emits;
/// `Decimal` accepts both numbers and strings (see `DecimalParsing.swift`).
public enum LedgerJSON {
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = LedgerDates.parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "'\(raw)' is not a timestamp")
            }
            return date
        }
        return d
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LedgerDates.isoTimestamp(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }
}
