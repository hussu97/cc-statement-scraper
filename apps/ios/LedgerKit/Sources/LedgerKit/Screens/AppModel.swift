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

    public static func resolve(phase: SessionStore.Phase, profiles: LoadState<[LedgerProfile]>,
                               selected: String?) -> AppRoute {
        switch phase {
        case .restoring: return .restoring
        case .signedOut, .awaitingCode: return .signIn
        case .signedIn:
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
    public let overview: OverviewModel
    public let activity: ActivityModel
    public let insights: InsightsModel
    public let statements: StatementsModel
    public let settings: SettingsModel
    public let review: ReviewModel

    private let live: LiveUpdates
    private var liveProfile: String?
    private var lastPhase: SessionStore.Phase = .restoring

    public init(services: LedgerServices) {
        self.services = services
        session = SessionStore(client: services.client, storage: services.sessionStorage)
        profiles = ProfileStore(api: services.api, selection: services.selection, smsTargets: services.smsTargets)
        overview = OverviewModel(api: services.api)
        activity = ActivityModel(api: services.api)
        insights = InsightsModel(api: services.api)
        statements = StatementsModel(api: services.api)
        settings = SettingsModel(outbox: services.outbox, intake: services.smsIntake(), log: services.captureLog)
        review = ReviewModel(api: services.api)
        live = LiveUpdates(api: services.api)
    }

    public var route: AppRoute {
        AppRoute.resolve(phase: session.phase, profiles: profiles.state, selected: profiles.selectedCode)
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
            await services.outbox.flush()
        case .signedOut:
            live.stop()
            liveProfile = nil
        default:
            break
        }
    }

    /// Loads every tab for the profile and follows Realtime changes.
    public func profileSelected(_ code: String) async {
        if liveProfile != code {
            liveProfile = code
            live.start(profileCode: code) { [weak self] tables in
                await self?.refresh(after: tables, profileCode: code)
            }
        }
        async let a: Void = overview.load(profileCode: code)
        async let b: Void = activity.load(profileCode: code)
        _ = await (a, b)
    }

    /// The app came to the foreground: send anything the intent or the Share
    /// Extension queued.
    public func becameActive() async {
        await services.outbox.flush()
        if await services.flushPendingUploads() > 0, case .main(let code) = route {
            await statements.load(profileCode: code)
        }
        await settings.refresh()
        if case .main(let code) = route { await overview.load(profileCode: code) }
    }

    public func signOut() async {
        live.stop()
        liveProfile = nil
        await session.signOut()
        profiles.reset()
    }

    func refresh(after tables: Set<String>, profileCode: String) async {
        if !tables.isDisjoint(with: ["transactions", "sms_messages", "insights"]) {
            await overview.load(profileCode: profileCode)
        }
        if tables.contains("transactions") { await activity.load(profileCode: profileCode) }
        if tables.contains("documents") { await statements.load(profileCode: profileCode) }
    }
}
