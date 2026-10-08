import LedgerKit
import SwiftUI

/// The live per-file log under the toolbar `+`: each PDF's latest step, the
/// server's message, and what to do when it failed. Statuses are
/// `UploadSession`'s; this only draws them.
struct UploadLogCard: View {
    let session: UploadSession

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Uploading").font(Typography.sectionTitle).foregroundStyle(Palette.ink)
                Spacer()
                if let summary = session.summary {
                    Text(summary).font(Typography.caption).foregroundStyle(Palette.muted)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(session.items) { item in
                if item.id != session.items.first?.id { Divider().overlay(Palette.border) }
                UploadItemRow(filename: item.filename, status: session.status(of: item), timeline: session.timeline(of: item))
            }
            if !session.isActive {
                Button("Clear") { session.clearFinished() }
                    .font(Typography.rowMeta)
                    .frame(minHeight: Metrics.tapMin)
                    .tint(Palette.accent)
            }
        }
    }
}

private struct UploadItemRow: View {
    let filename: String
    let status: UploadItemStatus
    let timeline: [DocumentEvent]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if status.inProgress { ProgressView().controlSize(.small) } else {
                        Image(systemName: status.systemImage).foregroundStyle(status.tone.color)
                    }
                }
                .frame(width: 22)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename).font(Typography.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                    Text(status.title).font(Typography.rowMeta.weight(.semibold)).foregroundStyle(status.tone.color)
                    if let detail = status.detail {
                        Text(detail).font(Typography.caption).foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let advice = status.advice { AdviceBox(text: advice) }
            if timeline.count > 1 {
                DisclosureGroup(isExpanded: $expanded) {
                    EventTimeline(events: timeline).padding(.top, 6)
                } label: {
                    Text(expanded ? "Hide steps" : "Show \(timeline.count) steps").font(Typography.caption)
                }
                .tint(Palette.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "What to do" under a failure, highlighted.
struct AdviceBox: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lightbulb").foregroundStyle(Palette.warn)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warnSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What to do: \(text)")
    }
}

/// Stage icon, time and message per event, oldest first.
struct EventTimeline: View {
    let events: [DocumentEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(events) { event in
                let stage = StagePresentation.of(event)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: stage.systemImage)
                        .foregroundStyle(stage.tone == .neutral ? Palette.subtle : stage.tone.color)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(stage.label).font(Typography.rowMeta.weight(.semibold))
                                .foregroundStyle(stage.tone == .neutral ? Palette.ink : stage.tone.color)
                            Spacer(minLength: 6)
                            Text(event.timeLabel()).font(Typography.caption).monospacedDigit().foregroundStyle(Palette.muted)
                        }
                        if !event.message.isEmpty {
                            Text(event.message).font(Typography.caption).foregroundStyle(Palette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One document's whole timeline (Statements → Uploads → a row), live.
struct DocumentLogView: View {
    let model: DocumentLogModel
    let profileCode: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Page {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.document.originalFilename).font(Typography.cardTitle).foregroundStyle(Palette.ink)
                    HStack(spacing: 8) {
                        if let bank = model.document.bankCode { BankLogo(bankCode: bank, size: 18) }
                        Chip(label: model.document.statusLabel, tone: model.document.tone)
                    }
                    if let failure = model.document.failureDetail {
                        Text(failure).font(Typography.caption).foregroundStyle(Palette.danger)
                    }
                }
                .padding(.top, 8)
                if let advice = model.advice { AdviceBox(text: advice) }
                StateContainer(state: model.state, retry: { Task { await model.load(profileCode: profileCode) } }) { events in
                    if let empty = model.emptyMessage {
                        EmptyCard(systemImage: "clock", message: empty)
                    } else {
                        Card { EventTimeline(events: events) }
                    }
                }
            }
            .navigationTitle("Processing log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.start(profileCode: profileCode) }
        .onDisappear { model.stop() }
        .presentationDetents([.medium, .large])
    }
}
