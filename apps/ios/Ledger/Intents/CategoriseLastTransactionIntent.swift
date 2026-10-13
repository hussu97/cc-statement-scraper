import AppIntents
import LedgerKit

/// A Bank Ledger category of the ledger on screen, for Shortcuts and Spotlight
/// (BACKLOG N-3). Listed by `LedgerQuestions.categories()` (not archived).
struct CategoryEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static let defaultQuery = CategoryQuery()

    /// The opaque `category_code`.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CategoryQuery: EntityStringQuery {
    private func all() async throws -> [CategoryEntity] {
        guard let services = AppServices.shared else { return [] }
        return try await services.questions().categories().map { CategoryEntity(id: $0.categoryCode, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CategoryEntity] {
        try await all().filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        try await all()
    }
}

/// "Categorise Last Transaction": files the newest purchase of the ledger on
/// screen under a category, for that transaction only (`LedgerQuestions.categoriseLast`).
/// Owners only, as in the app; a viewer hears why it can't.
struct CategoriseLastTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Categorise Last Transaction"
    static let description = IntentDescription(
        "Files your most recent card purchase in Bank Ledger under the category you choose.")
    static let openAppWhenRun = false
    static let isDiscoverable = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Category", description: "Where the purchase belongs.",
               requestValueDialog: IntentDialog("Which category?"))
    var category: CategoryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Categorise the last purchase as \(\.$category)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let services = AppServices.shared else {
            return .result(value: "", dialog: "Bank Ledger isn't configured.")
        }
        Telemetry.start(target: .intent, config: services.config, isDebugBuild: BuildFlavor.isDebug)
        let answer = await services.questions().categoriseLast(categoryCode: category.id, categoryName: category.name)
        Telemetry.breadcrumb("categorise_last", outcome: answer.txnCode == nil ? "not_filed" : "filed")
        return .result(value: answer.txnCode ?? "", dialog: IntentDialog(stringLiteral: answer.dialog))
    }
}
