import LedgerKit
import SwiftUI

/// The SMS format the AI proposed for an unparsed message (PAR-14, the web's TemplateProposal):
/// its name, bank, kind, pattern and the fields it reads. Accept / Reject are the review's options.
struct FormatProposalView: View {
    let proposal: SMSFormatProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(proposal.title).font(Typography.rowTitle).foregroundStyle(Palette.ink)
            HStack(spacing: 6) {
                BankLogo(bankCode: proposal.bankCode, size: 16)
                Chip(label: proposal.bankCode, tone: .info)
                Chip(label: proposal.kindLabel)
                if proposal.isFromAI { Chip(label: "Suggested by AI", tone: .info) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(proposal.bodyPattern)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
            .accessibilityLabel("Pattern")
            .accessibilityValue(proposal.bodyPattern)
            if let reads = proposal.readsLabel {
                Text(reads).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMd).stroke(Palette.border, lineWidth: 0.5))
    }
}

/// "Show message": the reviewed SMS's text, read from the server only when asked (the web's
/// SmsSubject). Shown on screen, never logged.
struct SMSTextToggle: View {
    let smsCode: String
    let profileCode: String
    let messages: SMSTextReveal

    var body: some View {
        Button {
            Task { await messages.toggle(smsCode, profileCode: profileCode) }
        } label: {
            Label(messages.toggleLabel(smsCode), systemImage: messages.isOpen(smsCode) ? "chevron.up" : "chevron.down")
                .font(Typography.caption)
                .frame(minHeight: Metrics.tapMin, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.accent)
        if let text = messages.open[smsCode] {
            Group {
                switch text {
                case .loaded(let body): Text(body).textSelection(.enabled)
                case .failed(let message, _): Text(message)
                default: Text("Loading…")
                }
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.ink)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.radiusMd))
        }
    }
}
