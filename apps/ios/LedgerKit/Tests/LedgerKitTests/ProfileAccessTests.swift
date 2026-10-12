import Foundation
import Testing
@testable import LedgerKit

@Suite("Ledger access — owner, viewer, view only (super admin)")
struct ProfileAccessTests {
    let personal = LedgerProfile(profileCode: "prf_personal", key: "personal", name: "Personal")
    let shared = LedgerProfile(profileCode: "prf_shared", key: "shared", name: "Brother's")
    let other = LedgerProfile(profileCode: "prf_other", key: "other", name: "Someone else's")
    let other2 = LedgerProfile(profileCode: "prf_other2", key: "other2", name: "Another")

    func member(_ code: String, _ role: String) -> ProfileMembership {
        try! LedgerJSON.decode(ProfileMembership.self, from: Data(#"{"profile_code":"\#(code)","role":"\#(role)"}"#.utf8))
    }

    var members: [ProfileMembership] { [member("prf_personal", "owner"), member("prf_shared", "viewer")] }

    @Test("membership decides access; a non-member only views")
    func access() {
        #expect(ProfileAccess.of("prf_personal", memberships: members) == .owner)
        #expect(ProfileAccess.of("prf_shared", memberships: members) == .viewer)
        #expect(ProfileAccess.of("prf_other", memberships: members) == .viewOnly)
        #expect(ProfileAccess.of(nil, memberships: members) == .viewOnly)
        #expect(ProfileAccess.owner.canWrite)
        #expect(!ProfileAccess.viewer.canWrite)
        #expect(!ProfileAccess.viewOnly.canWrite)
    }

    @Test("only a non-member ledger is labelled View only")
    func labels() {
        #expect(ProfileAccess.owner.label == nil)
        #expect(ProfileAccess.viewer.label == nil)
        #expect(ProfileAccess.viewOnly.label == "View only")
    }

    @Test("own ledgers first, then shared, then view only; server order within each")
    func order() {
        let list = [other, shared, other2, personal]
        #expect(ProfileAccess.ordered(list, memberships: members).map(\.profileCode)
                == ["prf_personal", "prf_shared", "prf_other", "prf_other2"])
        #expect(ProfileAccess.ordered([], memberships: members).isEmpty)
    }

    @Test("a super admin sees every ledger but writes and files SMS only in owned ones")
    @MainActor func store() async throws {
        let api = StubAPI()
        api.stubProfiles = [other, shared, personal]
        api.stubMemberships = members
        let defaults = try #require(UserDefaults(suiteName: "ledger-access-\(UUID().uuidString)"))
        let store = ProfileStore(api: api, selection: ProfileSelection(defaults: defaults),
                                 smsTargets: SMSTargetStore(defaults: defaults))
        await store.load()
        #expect(store.ordered(store.profiles).map(\.profileCode) == ["prf_personal", "prf_shared", "prf_other"])
        #expect(store.smsEligible.map(\.profileCode) == ["prf_personal"])
        #expect(store.smsTarget?.profileCode == "prf_personal")
        store.setSMSTarget("prf_other")
        #expect(store.smsTarget?.profileCode == "prf_personal")

        store.select("prf_other")
        #expect(store.access(of: store.selectedCode) == .viewOnly)
        #expect(!store.canWrite)
        store.select("prf_shared")
        #expect(!store.canWrite)
        store.select("prf_personal")
        #expect(store.canWrite)
        #expect(store.isOwner(of: "prf_personal"))
        #expect(!store.isOwner(of: "prf_other"))
    }
}
