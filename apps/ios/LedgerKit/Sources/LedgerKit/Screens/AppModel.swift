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
    /// Overview, Activity, Insights, Statements and Review for the selected ledger.
    public let screens: LedgerScreens
    public let settings: SettingsModel

    private var lastPhase: SessionStore.Phase = .restoring

    public init(services: LedgerServices) {
        self.services = services
        session = SessionStore(client: services.client, storage: services.sessionStorage)
        profiles = ProfileStore(api: services.api, selection: services.selection, smsTargets: services.smsTargets)
        screens = LedgerScreens(api: services.api)
        settings = SettingsModel(outbox: services.outbox, intake: services.smsIntake(), log: services.captureLog)
    }

    public var overview: OverviewModel { screens.overview }
    public var activity: ActivityModel { screens.activity }
    public var insights: InsightsModel { screens.insights }
    public var statements: StatementsModel { screens.statements }
    public var review: ReviewModel { screens.review }
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
        case .signedIn:
            if case .signedIn = lastPhase { return }
            await profiles.load()
            if profiles.sessionRejected {
                await session.signOut()
                return
            }
            await services.outbox.flush()
        case .signedOut:
            screens.stop()
        default:
            break
        }
    }

    /// Points every tab at the profile (clearing the previous ledger's data
    /// first) and follows Realtime changes.
    public func profileSelected(_ code: String) async {
        await screens.select(code)
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

    public func signOut() async {
        screens.stop()
        await session.signOut()
        profiles.reset()
    }
}
