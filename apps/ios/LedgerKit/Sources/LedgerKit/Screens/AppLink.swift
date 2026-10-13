import Foundation

/// Deep links into the app: `ledger://review`, `ledger://settings`. The scheme is registered in
/// `project.yml` (`CFBundleURLTypes`) and `AppModel.open(url:)` routes them
/// (IOS-07r). The App Intents don't open them (they run in the background for
/// every alert); a Shortcut can, with "Open URL ledger://review".
public enum AppLink: String, Equatable, Sendable, CaseIterable {
    /// Overview → Needs attention → Review.
    case review
    /// The Settings tab (outbox, Not sent, Card names): where a notification
    /// about a capture that is waiting, or a card name, lands (N-1).
    case settings

    public static let scheme = "ledger"

    /// `ledger://review` (also `ledger:///review`, any case, trailing slash,
    /// query or fragment ignored). Nil for another scheme or an unknown screen.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let host = url.host(percentEncoded: false) ?? ""
        let name = host.isEmpty ? url.path(percentEncoded: false) : host
        self.init(rawValue: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased())
    }

    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }
}

extension SMSIntakeOutcome {
    /// Where the Shortcut result points: the Review screen for a message only
    /// a review resolves (a card Ledger doesn't know yet, or one held for a
    /// check). Nil when there is nothing to do in the app.
    public var link: AppLink? {
        switch self {
        case .delivered(let status) where ["unknown_card", "held"].contains(status): .review
        default: nil
        }
    }
}

extension WalletIntake {
    /// `SMSIntakeOutcome.link` for a card payment, except an unknown card: for
    /// a payment that means no card has this name yet, which Settings → Card
    /// names fixes, not Review.
    public static func link(_ outcome: SMSIntakeOutcome) -> AppLink? {
        if case .delivered(status: "unknown_card") = outcome { return nil }
        return outcome.link
    }
}
