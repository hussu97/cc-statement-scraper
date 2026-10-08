import LedgerKit
import SwiftUI

/// A surface card: hairline border, no shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.gutter
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusLg))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusLg).stroke(Palette.border, lineWidth: 0.5))
    }
}

/// Section heading in the serif display face.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typography.sectionTitle).foregroundStyle(Palette.ink)
            Spacer()
            if let trailing {
                Text(trailing).font(Typography.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// A small status pill.
struct Chip: View {
    let label: String
    var tone: Tone = .neutral

    var body: some View {
        Text(label)
            .font(Typography.chip)
            // Wraps between words when a long chip (the hero comparison) meets
            // a narrow screen; short status chips get their own row at large
            // sizes (AdaptiveRow), so they are never squeezed mid-word.
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.softColor, in: Capsule())
    }
}

/// A title block beside a trailing block (amount, chip) — side by side at
/// regular sizes, stacked from xxxLarge up so neither truncates.
struct AdaptiveRow<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var alignment: VerticalAlignment = .top
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if typeSize.prefersStackedRows {
            VStack(alignment: .leading, spacing: 6) {
                leading
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: alignment, spacing: 12) {
                leading
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

extension View {
    /// Money never wraps mid-number: one line, tabular digits, shrinks a
    /// little before it would truncate, and wins space over labels.
    func moneyLine() -> some View {
        monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
    }
}

/// A coloured dot for a category token.
struct CategoryDot: View {
    let token: String?
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(ChartPalette.color(for: token)).frame(width: size, height: size)
    }
}

/// Loading, failed and empty states, used by every list and chart.
struct LoadingCard: View {
    var label = "Loading…"
    var body: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView()
                Text(label).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
        }
    }
}

struct FailedCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Card {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.danger)
            Text(message).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .tint(Palette.accent)
        }
    }
}

struct EmptyCard: View {
    let systemImage: String
    let message: String

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(Palette.subtle)
                Text(message).font(Typography.rowMeta).foregroundStyle(Palette.muted)
            }
        }
    }
}

/// Renders a `LoadState`: content when there is a value (even while
/// refreshing), a spinner on first load, an error card on first failure.
struct StateContainer<Value: Sendable, Content: View>: View {
    let state: LoadState<Value>
    let retry: () -> Void
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        if let value = state.value {
            content(value)
            if let error = state.errorMessage {
                Text(error).font(Typography.caption).foregroundStyle(Palette.danger)
            }
        } else if let error = state.errorMessage {
            FailedCard(message: error, retry: retry)
        } else {
            LoadingCard()
        }
    }
}

/// The standard scrolling page: linen background, gutters, serif title.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 32)
        }
        .background(Palette.bg)
        .scrollContentBackground(.hidden)
    }
}

extension View {
    /// Navigation styling shared by every tab.
    func ledgerNavigation(_ title: String) -> some View {
        navigationTitle(title)
            .toolbarBackground(Palette.bg, for: .navigationBar)
    }
}
