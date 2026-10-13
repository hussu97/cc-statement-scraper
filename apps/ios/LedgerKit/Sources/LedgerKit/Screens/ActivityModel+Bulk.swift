import Foundation

/// Activity's bulk select glue (PAR-11): the selection acts on the rows listed for
/// `listedQuery`, and a finished action shows its effect in the list.
extension ActivityModel {
    /// The loaded rows' codes, in list order (what "All" ticks).
    public var loadedCodes: [String] { rows.map(\.txnCode) }

    /// Whether the toolbar offers "Select" (owners, with rows on screen).
    public func offersSelection(canEdit: Bool) -> Bool {
        ActivitySelection.offersSelection(canEdit: canEdit, hasRows: !rows.isEmpty)
    }

    /// The bar's figures for the current selection.
    public func loadSelectionSummary(profileCode: String) async {
        await selection.loadSummary(profileCode: profileCode, query: listedQuery)
    }

    /// Categorise or Exclude / Include the selection, then refresh what it changed: ticked rows
    /// are re-read where they are (scroll position and pages kept); "all matching" may have
    /// changed any loaded row, so the list reloads. Totals and the header refresh either way.
    public func applyBulk(_ patch: ActivityBulkPatch, profileCode: String) async {
        guard let acted = await selection.apply(patch, profileCode: profileCode, query: listedQuery) else { return }
        switch acted {
        case .codes(let codes): await reread(codes, profileCode: profileCode)
        case .matching: await load(profileCode: profileCode)
        }
    }
}
