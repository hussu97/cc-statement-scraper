import LedgerKit
import SwiftUI

/// A credit-linked note's reference entity, in place of the stocks: who it is, the bond it points
/// at, and what a credit event would cost today. The words are LedgerKit's (`creditEntity`).
struct CreditEntityCard: View {
    let entity: NoteCreditEntity

    var body: some View {
        Card {
            SectionHeader(title: "Reference entity")
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name).font(Typography.rowTitle).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = entity.detail {
                        Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let risk = entity.risk {
                    Text(risk).font(Typography.rowMeta).foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entity.accessibilityLabel)
        }
    }
}

/// "Coupon schedule": the schedule in one line, then each coupon with its date, amount and what
/// became of it.
struct CreditScheduleContent: View {
    let note: NoteDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.couponScheduleCaption).font(Typography.caption).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(note.couponRows) { row in
                Divider().overlay(Palette.border)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.date).font(Typography.rowMeta).foregroundStyle(Palette.ink)
                        if let detail = row.detail {
                            Text(detail).font(Typography.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.amount).font(Typography.rowMeta).foregroundStyle(Palette.ink).moneyLine()
                        Text(row.status).font(Typography.caption.weight(row.isNext ? .semibold : .regular))
                            .foregroundStyle(row.tone == .neutral ? (row.isNext ? Palette.ink2 : Palette.muted) : row.tone.color)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "Issuer call dates": each date the issuer may repay it early, the next one marked.
struct CreditCallDatesContent: View {
    let note: NoteDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.callDatesNote).font(Typography.caption).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(note.callDateRows()) { row in
                Divider().overlay(Palette.border)
                HStack(alignment: .firstTextBaseline) {
                    Text(row.date).font(Typography.rowMeta)
                        .foregroundStyle(row.isPast ? Palette.muted : Palette.ink)
                    Spacer(minLength: 8)
                    if let mark = row.mark {
                        if row.tone == .neutral {
                            Text(mark).font(Typography.caption).foregroundStyle(Palette.muted)
                        } else {
                            Chip(label: mark, tone: row.tone)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
