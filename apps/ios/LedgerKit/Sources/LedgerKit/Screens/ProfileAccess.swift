import Foundation

/// What the signed-in user may do in one ledger. RLS decides it on the server
/// (`profile_members` for members; a super admin also reads every active
/// ledger but writes only where it is an owner); this mirrors it so screens hide
/// the edits the server would refuse.
public enum ProfileAccess: Sendable, Equatable {
    /// An owner in `profile_members`: reads and writes.
    case owner
    /// A viewer in `profile_members`: reads only.
    case viewer
    /// Not a member at all (a super admin's view of someone else's ledger): reads only.
    case viewOnly

    public static func of(_ code: String?, memberships: [ProfileMembership]) -> ProfileAccess {
        guard let member = memberships.first(where: { $0.profileCode == code }) else { return .viewOnly }
        return member.isOwner ? .owner : .viewer
    }

    /// SMS, uploads, review decisions, categories, budgets and insight dismissals.
    public var canWrite: Bool { self == .owner }

    /// The label a ledger row carries, or nil for the user's own ledgers.
    public var label: String? { self == .viewOnly ? "View only" : nil }

    var rank: Int {
        switch self {
        case .owner: 0
        case .viewer: 1
        case .viewOnly: 2
        }
    }

    /// The user's own ledgers first, then shared ones, then view-only ones;
    /// the server's order within each group.
    public static func ordered(_ profiles: [LedgerProfile], memberships: [ProfileMembership]) -> [LedgerProfile] {
        profiles.enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (of(lhs.element.profileCode, memberships: memberships).rank,
                              of(rhs.element.profileCode, memberships: memberships).rank)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
