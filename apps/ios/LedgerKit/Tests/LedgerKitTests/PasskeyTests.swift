import AuthenticationServices
import Foundation
import Supabase
import Testing
@testable import LedgerKit

@Suite("Passkeys: the sign-in offer, errors and routing")
struct PasskeyTests {
    @Test("offer only when the account has no passkeys and the person didn't say Not now")
    func offerRule() {
        #expect(PasskeyStore.shouldOffer(declined: false, passkeyCount: 0))
        #expect(!PasskeyStore.shouldOffer(declined: true, passkeyCount: 0))
        #expect(!PasskeyStore.shouldOffer(declined: false, passkeyCount: 2))
        // Couldn't list passkeys: don't nag.
        #expect(!PasskeyStore.shouldOffer(declined: false, passkeyCount: nil))
    }

    @Test("Not now is remembered per user on this device")
    @MainActor func declinedFlag() {
        let defaults = UserDefaults(suiteName: "ledger-passkey-\(UUID().uuidString)")!
        let client = SupabaseClient(supabaseURL: URL(string: "http://127.0.0.1:54321")!, supabaseKey: "sb_publishable_test")
        let store = PasskeyStore(auth: client.auth, defaults: defaults)
        #expect(!store.offerDeclined(userID: "u1"))
        store.setOfferDeclined(true, userID: "u1")
        #expect(store.offerDeclined(userID: "u1"))
        #expect(!store.offerDeclined(userID: "u2"))
        store.setOfferDeclined(false, userID: "u1")
        #expect(!store.offerDeclined(userID: "u1"))
    }

    @Test("cancelling the passkey sheet is not an error")
    func cancellation() {
        #expect(PasskeyStore.isCancellation(ASAuthorizationError(.canceled)))
        #expect(PasskeyStore.isCancellation(NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue)))
        #expect(!PasskeyStore.isCancellation(ASAuthorizationError(.failed)))
        #expect(!PasskeyStore.isCancellation(URLError(.notConnectedToInternet)))
    }

    @Test("GoTrue passkey codes read as sentences, matching the web app")
    func messages() {
        #expect(PasskeyStore.message(forCode: "webauthn_credential_not_found")?.contains("no longer on your Bank Ledger account") == true)
        #expect(PasskeyStore.message(forCode: "webauthn_challenge_expired") == "The passkey prompt timed out. Try again.")
        #expect(PasskeyStore.message(forCode: "other") == nil)
        let api = AuthError.api(message: "raw", errorCode: ErrorCode("webauthn_credential_exists"), underlyingData: Data(),
                                underlyingResponse: HTTPURLResponse())
        #expect(PasskeyStore.message(for: api) == "This iPhone already has a passkey for your account.")
    }

    @Test("a code sign-in holds on the passkey offer before the ledger loads")
    func routing() {
        let p = LedgerProfile(profileCode: "prf_a", key: "a", name: "A")
        let signedIn = SessionStore.Phase.signedIn(userID: "u", email: nil)
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loaded([p]), selected: "prf_a", passkeyOffer: .checking) == .offerPasskey)
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loaded([p]), selected: "prf_a", passkeyOffer: .offering(userID: "u")) == .offerPasskey)
        #expect(AppRoute.resolve(phase: signedIn, profiles: .loaded([p]), selected: "prf_a", passkeyOffer: .none) == .main(profileCode: "prf_a"))
        // While the code is being checked the code form stays up.
        #expect(AppRoute.resolve(phase: .awaitingCode(email: "a@b.c"), profiles: .idle, selected: nil, passkeyOffer: .checking) == .signIn)
        #expect(AppRoute.resolve(phase: .signedOut, profiles: .idle, selected: nil, passkeyOffer: .offering(userID: "u")) == .signIn)
    }
}
