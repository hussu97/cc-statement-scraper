import Testing
@testable import LedgerKit

@Suite("Password sign-in (the App Review demo account)")
struct PasswordSignInTests {
    @Test("Sign in is enabled only for a plausible email and a password")
    func canSubmit() {
        #expect(SessionStore.canSubmitPassword(email: "review@example.com", password: "x"))
        #expect(SessionStore.canSubmitPassword(email: "  review@example.com ", password: "x"))
        #expect(!SessionStore.canSubmitPassword(email: "review@example.com", password: ""))
        #expect(!SessionStore.canSubmitPassword(email: "review", password: "secret"))
        #expect(!SessionStore.canSubmitPassword(email: "", password: "secret"))
    }
}
