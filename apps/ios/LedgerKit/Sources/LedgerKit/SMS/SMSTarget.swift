import Foundation

/// The ledger SMS (and PDFs shared to "Add to Bank Ledger") are filed in. It is an
/// explicit setting, separate from the ledger the app happens to show, so
/// browsing a shared ledger never redirects your own card alerts there. Only a
/// ledger the user owns can be chosen: `ingest_sms` and `statements-upload`
/// refuse viewers.
public struct SMSTarget: Codable, Sendable, Equatable {
    public let profileCode: String
    public let name: String

    public init(profileCode: String, name: String) {
        self.profileCode = profileCode
        self.name = name
    }

    /// Profiles the user may file SMS in, in the profiles' display order.
    public static func eligible(profiles: [LedgerProfile], memberships: [ProfileMembership]) -> [LedgerProfile] {
        let owned = Set(memberships.filter(\.isOwner).map(\.profileCode))
        return profiles.filter { owned.contains($0.profileCode) }
    }

    /// Keeps the stored choice while the user still owns it (refreshing its
    /// name); otherwise the first owned ledger; nil when they own none.
    public static func resolve(stored: SMSTarget?, profiles: [LedgerProfile],
                               memberships: [ProfileMembership]) -> SMSTarget? {
        let owned = eligible(profiles: profiles, memberships: memberships)
        if let stored, let match = owned.first(where: { $0.profileCode == stored.profileCode }) {
            return SMSTarget(profileCode: match.profileCode, name: match.name)
        }
        return owned.first.map { SMSTarget(profileCode: $0.profileCode, name: $0.name) }
    }
}

/// `SMSTarget` in the App Group defaults, shared by the app, the App Intent and
/// the Share Extension.
public struct SMSTargetStore: @unchecked Sendable {
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults
    static let key = "ledger.smsTarget"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var target: SMSTarget? {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return nil }
            return try? JSONDecoder().decode(SMSTarget.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// One run of "Log Bank SMS", so Settings can show that the automation fires
/// and what it handed over ("Today 14:05 · Logged to Personal."). Holds the
/// outcome, the sender and the text's length, never the text: an empty sender
/// or a 10-character "message" shows a Shortcut passing the wrong field.
public struct CaptureRecord: Codable, Sendable, Equatable {
    public let at: Date
    /// `SMSIntakeOutcome.telemetryOutcome` — an opaque word.
    public let outcome: String
    /// The line Shortcuts showed.
    public let message: String
    public let isTest: Bool
    /// The Sender the Shortcut passed (nil in records saved before it was kept).
    public let sender: String?
    /// Characters in the trimmed Message the Shortcut passed.
    public let length: Int?

    public init(at: Date, outcome: String, message: String, isTest: Bool, sender: String? = nil, length: Int? = nil) {
        self.at = at
        self.outcome = outcome
        self.message = message
        self.isTest = isTest
        self.sender = sender.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)) }
        self.length = length
    }

    /// `"EmiratesNBD · 98 characters"`, or nil for a test or an old record.
    public var input: String? {
        guard let length else { return nil }
        let who = sender.flatMap { $0.isEmpty ? nil : $0 } ?? "No sender"
        return "\(who) · \(length) character\(length == 1 ? "" : "s")"
    }

    /// `"Today 14:05 · Logged to Personal."`
    public func label(today: CalendarDay = LedgerDates.today()) -> String {
        let day = CalendarDay(date: at)
        let when = day == today ? "Today \(LedgerDates.timeLabel(at))" : LedgerDates.dayLabel(day, today: today)
        return "\(when) · \(message)"
    }
}

public struct CaptureLog: @unchecked Sendable {
    private let defaults: UserDefaults
    static let lastKey = "ledger.capture.last"
    static let testKey = "ledger.capture.lastTest"
    static let recentKey = "ledger.capture.recent"
    /// How many real captures Settings keeps.
    public static let recentLimit = 20

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The last real message the automation handed over.
    public var last: CaptureRecord? { read(Self.lastKey) }
    /// The last in-app "Send test".
    public var lastTest: CaptureRecord? { read(Self.testKey) }
    /// The last `recentLimit` real captures, newest first.
    public var recent: [CaptureRecord] {
        guard let data = defaults.data(forKey: Self.recentKey) else { return last.map { [$0] } ?? [] }
        return (try? JSONDecoder().decode([CaptureRecord].self, from: data)) ?? []
    }

    public func record(_ record: CaptureRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: record.isTest ? Self.testKey : Self.lastKey)
        guard !record.isTest else { return }
        let list = Array(([record] + recent).prefix(Self.recentLimit))
        if let encoded = try? JSONEncoder().encode(list) { defaults.set(encoded, forKey: Self.recentKey) }
    }

    public func clear() {
        defaults.removeObject(forKey: Self.lastKey)
        defaults.removeObject(forKey: Self.testKey)
        defaults.removeObject(forKey: Self.recentKey)
    }

    private func read(_ key: String) -> CaptureRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CaptureRecord.self, from: data)
    }
}
