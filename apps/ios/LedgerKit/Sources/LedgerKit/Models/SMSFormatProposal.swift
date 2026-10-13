import Foundation

/// The SMS format the AI proposed for an unparsed message (PAR-14): `review_context.template`,
/// the client-visible columns of `public.sms_templates` (never `examples`, never
/// `scope_profile_code`). An owner accepts it (`set_sms_template_active(code, true)`: the
/// format goes live, waiting messages are read again and the reviews waiting on it close) or
/// rejects it (`false`: the reviews are dismissed and the proposal deleted once no ledger waits on it).
public struct SMSFormatProposal: Decodable, Sendable, Hashable {
    public let templateCode: String
    public let bankCode: String
    public let name: String
    /// The case-insensitive regex the body must match.
    public let bodyPattern: String
    /// Field → capture group (`{"amount": 2, "currency": 1, …}`).
    public let fieldGroups: [String: Int]
    /// `to_date()` format of the date group.
    public let dateFormat: String?
    /// purchase | preauth | refund | reversal | payment | declined | debit_card | other
    public let msgKind: String
    /// seed | manual | llm
    public let source: String
    public let active: Bool

    public init(templateCode: String, bankCode: String, name: String, bodyPattern: String,
                fieldGroups: [String: Int] = [:], dateFormat: String? = nil, msgKind: String,
                source: String = "llm", active: Bool = false) {
        self.templateCode = templateCode
        self.bankCode = bankCode
        self.name = name
        self.bodyPattern = bodyPattern
        self.fieldGroups = fieldGroups
        self.dateFormat = dateFormat
        self.msgKind = msgKind
        self.source = source
        self.active = active
    }

    enum CodingKeys: String, CodingKey {
        case templateCode, bankCode, name, bodyPattern, fieldGroups, dateFormat, msgKind, source, active
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateCode = try c.decode(String.self, forKey: .templateCode)
        bankCode = try c.decode(String.self, forKey: .bankCode)
        name = try c.decode(String.self, forKey: .name)
        bodyPattern = try c.decode(String.self, forKey: .bodyPattern)
        // Field names are data, not Swift properties: every key, one by one; a malformed map reads as none.
        fieldGroups = (try? c.decodeIfPresent(FieldGroups.self, forKey: .fieldGroups))?.groups ?? [:]
        dateFormat = (try? c.decodeIfPresent(String.self, forKey: .dateFormat)) ?? nil
        msgKind = try c.decode(String.self, forKey: .msgKind)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "manual"
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
    }

    /// `"Proposed format: FAB purchase"`.
    public var title: String { "Proposed format: \(name)" }

    /// The kind as a chip: `"Purchase"`, `"Debit card"`.
    public var kindLabel: String {
        let words = msgKind.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The web's "suggested by AI" chip.
    public var isFromAI: Bool { source == "llm" }

    /// `"Reads currency (group 1), amount (group 2) · dates as DD/MM/YYYY"`, in group order;
    /// nil when the format names no fields.
    public var readsLabel: String? {
        guard !fieldGroups.isEmpty else { return nil }
        let fields = fieldGroups.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
            .map { "\($0.key) (group \($0.value))" }
            .joined(separator: ", ")
        return "Reads \(fields)" + (dateFormat.map { " · dates as \($0)" } ?? "")
    }

    /// `field_groups` keyed by the field names as they are on the wire.
    private struct FieldGroups: Decodable {
        let groups: [String: Int]

        struct Key: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            var out: [String: Int] = [:]
            for key in c.allKeys {
                if let group = try? c.decode(Int.self, forKey: key) { out[key.stringValue] = group }
            }
            groups = out
        }
    }
}
