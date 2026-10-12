import LedgerKit
import SwiftUI

/// An empty ledger's first steps (`SetupChecklist`, BACKLOG IOS-23), in place
/// of the hero, the ring, the cards and the latest transactions. Owners can
/// open the SMS guide and Statements from here.
struct SetupChecklistCard: View {
    let checklist: SetupChecklist
    let settings: SettingsModel
    let statements: StatementsModel
    let profileCode: String
    let canWrite: Bool

    var body: some View {
        Card {
            SectionHeader(title: SetupChecklist.title, trailing: checklist.progress)
            Text(SetupChecklist.intro).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            ForEach(checklist.steps) { step in
                Divider().overlay(Palette.border)
                if canWrite, let destination = destination(step.kind) {
                    NavigationLink { destination } label: { row(step, linked: true) }
                        .buttonStyle(.plain)
                } else {
                    row(step, linked: false)
                }
            }
            if !canWrite {
                Text(SetupChecklist.viewerNote).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private func destination(_ kind: SetupChecklist.Kind) -> AnyView? {
        switch kind {
        case .sms: AnyView(SMSSetupGuideView(settings: settings))
        case .statement: AnyView(StatementsView(model: statements, profileCode: profileCode, canUpload: canWrite))
        case .invite: nil   // members are managed on the web
        }
    }

    private func row(_ step: SetupChecklist.Step, linked: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(step.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                    .strikethrough(step.status == .done, color: Palette.muted)
                Text(step.detail).font(Typography.caption).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if linked {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.status.spoken)
    }

    @ViewBuilder private func statusIcon(_ status: SetupChecklist.Status) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Palette.positive)
        case .todo: Image(systemName: "circle").font(.title3).foregroundStyle(Palette.subtle)
        case .unknown: Image(systemName: "questionmark.circle").font(.title3).foregroundStyle(Palette.subtle)
        }
    }
}
