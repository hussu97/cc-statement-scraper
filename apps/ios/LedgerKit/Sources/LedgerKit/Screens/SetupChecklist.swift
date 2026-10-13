import Foundation

/// `list_profile_members`, counted: members (the owner included) and pending invites.
public struct MemberCount: Sendable, Equatable {
    public let members: Int
    public let pendingInvites: Int

    public init(members: Int, pendingInvites: Int = 0) {
        self.members = members
        self.pendingInvites = pendingInvites
    }
}

/// What Overview shows for a ledger with no transactions and no cards, instead
/// of a hero that asserts "AED 0 · Same as this time last month" (BACKLOG
/// IOS-23): three steps that get a ledger going, each ticked only when the
/// server's data proves it.
public struct SetupChecklist: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case sms, statement, invite }

    public enum Status: Sendable, Equatable {
        case done, todo
        /// The data couldn't be read: neither ticked nor claimed undone.
        case unknown

        /// VoiceOver's value for the row.
        public var spoken: String {
            switch self {
            case .done: "Done"
            case .todo: "To do"
            case .unknown: "Not known"
            }
        }
    }

    public struct Step: Sendable, Equatable, Identifiable {
        public var id: Kind { kind }
        public let kind: Kind
        public let status: Status
        public let title: String
        public let detail: String
    }

    public let steps: [Step]

    public static let title = "Set up this ledger"
    public static let intro = "No cards or transactions yet. These three steps get it going."
    public static let viewerNote = "Only the ledger's owners can do these."

    /// `"1 of 3 done"`.
    public var progress: String { "\(steps.filter { $0.status == .done }.count) of \(steps.count) done" }

    /// Nil unless the ledger has no transactions and no cards: any other
    /// ledger shows the usual hero.
    /// - Parameters:
    ///   - uploads: statements uploaded to the ledger (`documents`), nil when unknown.
    ///   - members: people with access and pending invites (`list_profile_members`), nil when unknown.
    public static func make(overview: Overview, uploads: Int?, members: MemberCount?) -> SetupChecklist? {
        guard isEmptyLedger(overview) else { return nil }
        let sms: Status = overview.lastSmsAt != nil ? .done : .todo
        let statement: Status = uploads.map { $0 > 0 ? .done : .todo } ?? .unknown
        // Only a member who accepted has access; a pending invite is an invite sent.
        let hasOtherMember = (members?.members ?? 0) > 1
        let invited = (members?.pendingInvites ?? 0) > 0
        let invite: Status = members == nil ? .unknown : (hasOtherMember || invited ? .done : .todo)
        let inviteDetail =
            if hasOtherMember { "Someone else has access to this ledger." }
            else if invited { "Invite sent. They get access once they accept it." }
            else { "Invite someone from Bank Ledger on the web: Settings → Members." }
        return SetupChecklist(steps: [
            Step(kind: .sms, status: sms, title: "Set up SMS capture",
                 detail: sms == .done
                    ? "Card alerts are reaching this ledger."
                    : "A Shortcuts automation sends each bank SMS here as it arrives."),
            Step(kind: .statement, status: statement, title: "Upload a statement",
                 detail: statement == .done
                    ? "A statement is in. Its cards show here once it has been read."
                    : "Add a PDF under Settings → Statements, or share one to “Add to Bank Ledger”."),
            Step(kind: .invite, status: invite, title: "Invite a member", detail: inviteDetail),
        ])
    }

    /// No transaction at all (`recent` is the ledger's latest, not the
    /// month's) and no card.
    public static func isEmptyLedger(_ overview: Overview) -> Bool {
        overview.recent.isEmpty && overview.accounts.isEmpty
    }
}
