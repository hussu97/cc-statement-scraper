import LedgerKit
import SwiftUI

/// The row under a paged list: a spinner while the next page loads, a retry
/// row when it failed, and the end-of-list line. When it scrolls into view
/// with more to load it asks for the next page (and again if it is still in
/// view after that page arrived). What it says is `ListFooter`'s.
struct PagingFooter: View {
    let footer: ListFooter
    let endMessage: String
    let loadMore: () async -> Void
    @State private var visible = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: footer == .hidden ? 1 : Metrics.tapMin)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .task(id: Trigger(visible: visible, footer: footer)) {
                if visible, footer.loadsWhenVisible { await loadMore() }
            }
    }

    private struct Trigger: Hashable {
        let visible: Bool
        let footer: ListFooter
    }

    @ViewBuilder private var content: some View {
        switch footer {
        case .hidden:
            Color.clear.frame(height: 1).accessibilityHidden(true)
        case .more, .loading:
            ProgressView().accessibilityLabel("Loading more")
        case .failed(let message):
            VStack(spacing: 6) {
                Text("Couldn't load more. \(message)")
                    .font(Typography.caption).foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await loadMore() } }
                    .buttonStyle(.bordered).tint(Palette.accent)
                    .frame(minHeight: Metrics.tapMin)
            }
            .padding(.vertical, 8)
        case .end:
            Text(endMessage).font(Typography.caption).foregroundStyle(Palette.muted)
                .padding(.vertical, 8)
        }
    }
}
