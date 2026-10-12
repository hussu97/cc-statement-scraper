import LedgerKit
import SwiftUI

/// Covers the app while the scene isn't active (the app-switcher snapshot) and
/// while it is locked (`AppLock`, BACKLOG IOS-22). The content underneath is
/// blurred too, so nothing readable shows through the material.
struct PrivacyCovered: ViewModifier {
    let lock: AppLock

    func body(content: Content) -> some View {
        content
            .blur(radius: lock.showsCover ? 24 : 0)
            .accessibilityHidden(lock.showsCover)
            .overlay {
                if lock.showsCover { PrivacyCover(lock: lock) }
            }
    }
}

private struct PrivacyCover: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.thickMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: lock.isLocked ? "lock.fill" : "eye.slash")
                    .font(.system(size: 40)).foregroundStyle(Palette.accent)
                Text("Bank Ledger").font(Typography.display).foregroundStyle(Palette.ink)
                if lock.showsUnlock {
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label(lock.unlockTitle, systemImage: lock.method == .passcode ? "lock.open" : "faceid")
                            .frame(minHeight: Metrics.tapMin)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }
            }
            .padding(Metrics.gutter)
        }
    }
}

extension View {
    func privacyCovered(by lock: AppLock?) -> some View {
        Group {
            if let lock { modifier(PrivacyCovered(lock: lock)) } else { self }
        }
    }
}
