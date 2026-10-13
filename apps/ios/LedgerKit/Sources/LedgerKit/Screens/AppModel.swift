import Foundation
import Observation

/// Which top-level screen the app shows. A pure function of session and
/// profile state so the routing rule is testable and lives outside the views.
public enum AppRoute: Equatable, Sendable {
    case restoring
    case signIn
    case loadingProfiles
    case pickProfile
    case main(profileCode: String)
    /// Just signed in with an email code: offer to add a passkey (or decide whether to).
    case offerPasskey

    public static func resolve(phase: SessionStore.Phase, profiles: LoadState<[LedgerProfile]>,
                               selected: String?, passkeyOffer: SessionStore.PasskeyOffer = .none) -> AppRoute {
        switch phase {
        case .restoring: return .restoring
        case .signedOut, .awaitingCode: return .signIn
        case .signedIn:
            if passkeyOffer != .none { return .offerPasskey }
            if let selected, profiles.value?.contains(where: { $0.profileCode == selected }) == true {
                return .main(profileCode: selected)
            }
            switch profiles {
            case .idle, .loading: return .loadingProfiles
            case .loaded, .failed: return .pickProfile
            }
        }
    }
}

/// Owns every screen model and keeps them pointed at the selected profile.
@MainActor
@Observable
public final class AppModel {
    public let services: LedgerServices
    public let session: SessionStore
    public let profiles: ProfileStore
    /// Overview, Activity, Insights, Budgets, Statements and Review for the selected ledger.
    public let screens: LedgerScreens
    public let settings: SettingsModel
    /// Bank names and logos for every screen (environment object).
    public let banks: BankCatalog
    /// Insights' Monthly spend split (environment object).
    public let spendSplit: SpendSplitModel
    /// The selected tab.
    public let tabs = TabRouter()
    /// The app-switcher cover and the optional Face ID lock (this device only).
    public let lock = AppLock(defaults: .standard, authenticator: LocalDeviceAuthenticator())

    private var lastPhase: SessionStore.Phase = .restoring

    public init(services: LedgerServices) {
        self.services = services
        session = SessionStore(client: services.client, storage: services.sessionStorage)
        profiles = ProfileStore(api: services.api, selection: services.selection, smsTargets: services.smsTargets)
        screens = LedgerScreens(api: services.api, pendingUploads: services.pendingUploads,
                                flushPending: { await services.flushPendingUploads() })
        banks = BankCatalog(api: services.api, supabaseURL: services.config.supabaseURL)
        spendSplit = SpendSplitModel(api: services.api)
        settings = SettingsModel(outbox: services.outbox, intake: services.smsIntake(), log: services.captureLog)
    }

    public var overview: OverviewModel { screens.overview }
    public var activity: ActivityModel { screens.activity }
    public var insights: InsightsModel { screens.insights }
    public var statements: StatementsModel { screens.statements }
    public var review: ReviewModel { screens.review }
    public var budgets: BudgetsModel { screens.budgets }
    public var month: MonthSelection { screens.month }

    public var route: AppRoute {
        AppRoute.resolve(phase: session.phase, profiles: profiles.state, selected: profiles.selectedCode,
                         passkeyOffer: session.passkeyOffer)
    }

    public func start() {
        session.start()
    }

    /// Called whenever the session phase changes.
    public func sessionChanged() async {
        let phase = session.phase
        defer { lastPhase = phase }
        switch phase {
        case .signedIn(let userID, _):
            if case .signedIn = lastPhase { return }
            // Stamped on what the intents capture from now on, and kept after
            // sign-out: only this account adopts what it captured (IOS-12r audit).
            services.deviceUser.userID = userID
            await profiles.load()
            if profiles.sessionRejected {
                profiles.clearSMSTarget()
                await session.signOut()
                return
            }
            // Sends what waited for the sign-in, including SMS saved before a
            // ledger was known (the outbox files them in "SMS go to").
            await services.outbox.flush()
            await settings.refresh()
        case .signedOut:
            // Every way of being signed out (the button, a rejected session, a
            // refresh that failed): nothing is filed in the last ledger any more.
            profiles.clearSMSTarget()
            screens.stop()
        default:
            break
        }
    }

    /// Points every tab at the profile (clearing the previous ledger's data
    /// first) and follows Realtime changes.
    public func profileSelected(_ code: String) async {
        if screens.activeProfile != code { tabs.reset() }
        async let logos: Void = banks.refresh()
        await screens.select(code)
        await logos
    }

    /// The app came to the foreground: send anything the intent or the Share
    /// Extension queued, then refresh every tab that has been opened.
    public func becameActive() async {
        await services.outbox.flush()
        _ = await services.flushPendingUploads()
        await settings.refresh()
        guard case .main = route else { return }
        await screens.refreshAll()
    }

    /// The "SMS go to" ledger changed (loaded, created or picked): SMS saved
    /// while there was none can go now.
    public func smsTargetChanged() async {
        guard profiles.smsTarget != nil else { return }
        await services.outbox.flush()
        await settings.refresh()
    }

    /// Step one of signing out: the confirmation naming what would be deleted
    /// from this phone, or nil when nothing would be (sign out straight away).
    public func signOutWarning() async -> String? {
        await services.deviceQueue().signOutWarning
    }

    /// Signs out and deletes the SMS outbox and the share extension's PDFs
    /// (after the person confirmed `signOutWarning`), so nothing is sent under
    /// whoever signs in next (BACKLOG IOS-12r). A session the server rejects
    /// signs out without this and keeps them.
    public func signOut() async {
        await services.clearDeviceQueue()
        await settings.refresh()
        screens.stop()
        tabs.reset()
        await session.signOut()
        profiles.reset()
    }
}
