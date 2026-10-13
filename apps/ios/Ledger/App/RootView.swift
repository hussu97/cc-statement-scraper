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
                ProfilePickerView(profiles: model.profiles, model: model)
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
        // SMS saved while no ledger was set go as soon as "SMS go to" is known.
        .task(id: model.profiles.smsTarget?.profileCode) { await model.smsTargetChanged() }
        .task(id: model.session.phase) {
            await model.sessionChanged()
            #if DEBUG
            await DevSignIn.attemptIfConfigured(session: model.session)
            #endif
        }
        .alert("Not everything was deleted", isPresented: Binding(
            get: { model.signOutError != nil }, set: { if !$0 { model.signOutError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.signOutError ?? "")
        }
    }
}

struct MainTabs: View {
    let model: AppModel
    let profileCode: String

    var body: some View {
        @Bindable var tabs = model.tabs
        TabView(selection: $tabs.tab) {
            Tab(LedgerTab.overview.title, systemImage: LedgerTab.overview.systemImage, value: .overview) {
                NavigationStack {
                    OverviewView(model: model.overview, month: model.month, review: model.review,
                                 profileCode: profileCode, canResolve: model.profiles.canWrite,
                                 outboxAlert: model.settings.outboxStatus.staleAlert,
                                 openSettings: { model.tabs.show(.settings) },
                                 settings: model.settings, statements: model.statements)
                    // ledger://review (a Shortcut result) pushes Review here.
                    .navigationDestination(isPresented: $tabs.showingReview) {
                        ReviewView(model: model.review, profileCode: profileCode, canResolve: model.profiles.canWrite)
                    }
                }
            }
            Tab(LedgerTab.activity.title, systemImage: LedgerTab.activity.systemImage, value: .activity) {
                NavigationStack {
                    ActivityView(model: model.activity, months: model.month.range, profileCode: profileCode,
                                 canEdit: model.profiles.canWrite)
                }
            }
            Tab(LedgerTab.insights.title, systemImage: LedgerTab.insights.systemImage, value: .insights) {
                NavigationStack {
                    InsightsView(model: model.insights, month: model.month, profileCode: profileCode,
                                 showBudgets: { model.tabs.show(.budgets) })
                }
            }
            Tab(LedgerTab.budgets.title, systemImage: LedgerTab.budgets.systemImage, value: .budgets) {
                NavigationStack {
                    BudgetsView(model: model.budgets, month: model.month, profileCode: profileCode,
                                canEdit: model.profiles.canWrite)
                }
            }
            // Statements (cycles, uploads, share-sheet queue, processing logs) live under Settings.
            Tab(LedgerTab.settings.title, systemImage: LedgerTab.settings.systemImage, value: .settings) {
                NavigationStack { SettingsView(model: model, profileCode: profileCode) }
            }
            // SMS that haven't reached the server for an hour (BACKLOG IOS-12r).
            .badge(model.settings.outboxStatus.badgeCount)
        }
        .environment(model.banks)
        .environment(model.spendSplit)
        .environment(model.notifications)
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
