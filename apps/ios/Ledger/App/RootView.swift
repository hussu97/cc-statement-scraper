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
                .task(id: code) {
                    await model.profileSelected(code)
                    // A launch that came to the foreground before the profiles loaded replans now.
                    await LocalNotifications.refreshDueReminders(model.services, model.dueReminderRefresh)
                }
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

/// The tab bar of the mode on screen (`AppMode.tabs`), switched from the title menu in each root
/// screen. Overview and Settings are in both modes; Settings (cards, statements) is shared, so its
/// stack stays as it was across a switch.
struct MainTabs: View {
    let model: AppModel
    let profileCode: String

    var body: some View {
        @Bindable var tabs = model.tabs
        TabView(selection: $tabs.tab) {
            ForEach(tabs.mode.tabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) { screen(tab) }
                    // SMS that haven't reached the server for an hour (BACKLOG IOS-12r).
                    .badge(tab == .settings ? model.settings.outboxStatus.badgeCount : 0)
            }
        }
        // Screens link into Activity through it (`TabRouter.openActivity`, PAR-4).
        .environment(model.tabs)
        .environment(model.banks)
        .environment(model.spendSplit)
        .environment(model.screens.categoryDrillDowns)
        .environment(model.screens.analysis)
        .environment(model.notifications)
        // Worth a look and Unusual spending (PAR-9); who may dismiss reads the ledger's role.
        .environment(model.screens.feed)
        .environment(model.screens.anomalies)
        .environment(model.profiles)
        // Wealth mode: the bank accounts' balances and writes, and each account's ledger.
        .environment(model.screens.cash)
        .environment(model.screens.accountLedgers)
        // Structured notes, listed on the account that pays for them.
        .environment(model.screens.notes)
        // Holdings, opened from a broker account's Portfolio as well as from Investments.
        .environment(model.screens.investments)
    }

    @ViewBuilder private func screen(_ tab: LedgerTab) -> some View {
        @Bindable var tabs = model.tabs
        switch tab {
        case .overview where tabs.mode == .wealth:
            NavigationStack {
                WealthOverviewView(model: model.screens.wealthOverview, profileCode: profileCode,
                                   canEdit: model.profiles.canWrite)
            }
        case .overview:
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
        case .activity:
            NavigationStack {
                ActivityView(model: model.activity, months: model.month.range, profileCode: profileCode,
                             canEdit: model.profiles.canWrite, tabs: model.tabs)
            }
        case .insights:
            NavigationStack {
                InsightsView(model: model.insights, month: model.month, profileCode: profileCode,
                             showBudgets: { model.tabs.show(.budgets) })
            }
        case .budgets:
            NavigationStack {
                BudgetsView(model: model.budgets, month: model.month, profileCode: profileCode,
                            canEdit: model.profiles.canWrite)
            }
        case .accounts:
            NavigationStack {
                AccountsView(model: model.screens.cash, profileCode: profileCode, canEdit: model.profiles.canWrite)
            }
        case .investments:
            NavigationStack {
                InvestmentsView(model: model.screens.investments, notes: model.screens.notes, profileCode: profileCode,
                                canEdit: model.profiles.canWrite)
            }
        case .cashFlow:
            NavigationStack {
                CashFlowView(model: model.screens.cash, profileCode: profileCode)
            }
        case .settings:
            // Statements (cycles, uploads, share-sheet queue, processing logs) live under Settings;
            // ledger://add-statement pushes Statements here (TabRouter).
            NavigationStack(path: $tabs.settingsPath) { SettingsView(model: model, profileCode: profileCode) }
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
