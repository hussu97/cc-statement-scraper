import LedgerKit
import SwiftUI

/// Routes on `AppModel.route` (decided in LedgerKit) and wires lifecycle events.
struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.route {
            case .restoring, .loadingProfiles:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.bg)
            case .signIn:
                SignInView(session: model.session)
            case .offerPasskey:
                PasskeyOfferView(session: model.session)
            case .pickProfile:
                ProfilePickerView(profiles: model.profiles, onSignOut: { Task { await model.signOut() } })
            case .main(let code):
                Group {
                    // Until the tabs point at this ledger, nothing of the previous one shows.
                    if model.screens.activeProfile == code {
                        MainTabs(model: model, profileCode: code)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.bg)
                    }
                }
                .task(id: code) { await model.profileSelected(code) }
            }
        }
        .task { model.start() }
        .task(id: model.session.phase) {
            await model.sessionChanged()
            #if DEBUG
            await DevSignIn.attemptIfConfigured(session: model.session)
            #endif
        }
    }
}

struct MainTabs: View {
    let model: AppModel
    let profileCode: String

    var body: some View {
        TabView {
            Tab("Overview", systemImage: "circle.grid.2x2") {
                NavigationStack {
                    OverviewView(model: model.overview, month: model.month, review: model.review,
                                 profileCode: profileCode, canResolve: model.profiles.canWrite)
                }
            }
            Tab("Activity", systemImage: "list.bullet.rectangle") {
                NavigationStack {
                    ActivityView(model: model.activity, months: model.month.range, profileCode: profileCode)
                }
            }
            Tab("Insights", systemImage: "chart.bar.xaxis") {
                NavigationStack { InsightsView(model: model.insights, month: model.month, profileCode: profileCode) }
            }
            Tab("Statements", systemImage: "doc.text") {
                NavigationStack {
                    StatementsView(model: model.statements, profileCode: profileCode, canUpload: model.profiles.canWrite)
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView(model: model) }
            }
        }
    }
}

#if DEBUG
/// Local development: `LEDGER_DEV_EMAIL` / `LEDGER_DEV_PASSWORD` in the launch
/// environment (`SIMCTL_CHILD_…` with `xcrun simctl launch`) sign the seeded
/// demo user in with a password. Debug builds only; never in Release.
enum DevSignIn {
    @MainActor
    static func attemptIfConfigured(session: SessionStore) async {
        guard session.phase == .signedOut,
              let email = ProcessInfo.processInfo.environment["LEDGER_DEV_EMAIL"],
              let password = ProcessInfo.processInfo.environment["LEDGER_DEV_PASSWORD"] else { return }
        await session.signIn(email: email, password: password)
    }
}
#endif
