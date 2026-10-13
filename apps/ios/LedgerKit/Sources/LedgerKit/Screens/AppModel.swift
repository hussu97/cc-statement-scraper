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
    /// The widgets mirror its setting to hide Lock Screen amounts (N-2).
    public let lock: AppLock

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
        let widgets = services.widgets
        lock = AppLock(defaults: .standard, authenticator: LocalDeviceAuthenticator(),
                       onRequireChanged: { widgets.hidesLockScreenAmounts = $0 })
        // The current month of the ledger on screen feeds the widgets (N-2).
        let profiles = self.profiles
        screens.overview.onLoaded = { overview, code in
            guard profiles.selectedCode == code,
                  let snapshot = WidgetSnapshot.make(overview: overview, profileCode: code,
                                                     ledgerName: profiles.selected?.name) else { return }
            widgets.write(snapshot)
        }
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
            tabs.signedOut()   // a pending ledger://review must not open for the next account
            screens.stop()
            services.widgets.clear()   // nothing of this account stays on the Home or Lock Screen
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
        if screens.activeProfile == code { tabs.ledgerShown() }
        await logos
    }

    /// A `ledger://` deep link (a Shortcut's "Open URL ledger://review"). It opens
    /// now when a ledger is on screen; otherwise once one is (after restoring
    /// the session, signing in or picking a ledger). False for a URL the app
    /// doesn't handle.
    @discardableResult
    public func open(url: URL) -> Bool {
        guard let link = AppLink(url: url) else { return false }
        open(link)
        return true
    }

    /// A link from a URL or from a Control's intent (`AppLinkInbox`).
    public func open(_ link: AppLink) {
        tabs.open(link, ledgerOnScreen: ledgerOnScreen)
    }

    /// Takes the links the Controls' intents deliver (N-4). Called once by the app.
    public func receiveIntentLinks() {
        AppLinkInbox.attach { [weak self] link in self?.open(link) }
    }

    /// The main tabs are showing the selected ledger.
    var ledgerOnScreen: Bool { Self.ledgerOnScreen(route: route, activeProfile: screens.activeProfile) }

    /// Until the tabs point at the selected ledger, a deep link waits.
    nonisolated static func ledgerOnScreen(route: AppRoute, activeProfile: String?) -> Bool {
        guard case .main(let code) = route else { return false }
        return activeProfile == code
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

    /// Step one of signing out: what would be deleted from this phone. Its
    /// `warning` is the confirmation; nil means sign out straight away.
    public func prepareSignOut() async -> SignOutPlan {
        await services.signOutPlan()
    }

    /// Set when sign-out couldn't delete everything it counted; the root view shows it.
    public var signOutError: String?

    /// Signs out, then deletes exactly what `plan` counted (BACKLOG IOS-12r).
    /// The order matters: "SMS go to" is cleared and the session ended first,
    /// so an intent running meanwhile saves without a ledger, stamped with this
    /// account, rather than filing in its ledger after the outbox was emptied.
    /// A session the server rejects signs out without deleting anything.
    public func signOut(deleting plan: SignOutPlan) async {
        profiles.clearSMSTarget()
        screens.stop()
        tabs.signedOut()
        services.widgets.clear()
        await session.signOut()
        profiles.reset()
        do {
            try await services.delete(plan)
        } catch {
            signOutError = SignOutPlan.deleteFailedMessage
        }
        await settings.refresh()
    }
}
