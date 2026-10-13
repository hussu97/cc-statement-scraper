import LedgerKit
import SwiftUI
import UIKit

/// The privacy cover and lock screen (`AppLock`, BACKLOG IOS-22) in a window of
/// its own above the app's, so it covers every presentation too: sheets,
/// full-screen covers, alerts and menus. An overlay on the SwiftUI root sat
/// under them, so an open sheet showed in the app-switcher snapshot and stayed
/// usable without Face ID.
///
/// It follows `lock.showsCover`, and also covers straight from UIKit's
/// will-deactivate notification, which comes before SwiftUI's scene phase.
@MainActor
final class PrivacyCoverWindow {
    private let lock: AppLock
    private var window: UIWindow?
    private var observers: [NSObjectProtocol] = []

    init(lock: AppLock) { self.lock = lock }

    /// Called with the app's window scene once the root view is in a window.
    func attach(to scene: UIWindowScene) {
        guard window?.windowScene !== scene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: PrivacyCover(lock: lock))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        self.window = window

        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = [
            // queue nil: UIKit posts this on the main thread, and running it inline covers before the snapshot.
            center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.show(true) }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            },
        ]
        track()
        sync()
    }

    /// Re-arms after every change (Observation reports one change per registration).
    private func track() {
        withObservationTracking {
            _ = lock.showsCover
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.track()
            }
        }
    }

    private func sync() { show(lock.showsCover) }

    private func show(_ on: Bool) {
        guard let window, window.isHidden == on else { return }
        window.isHidden = !on
    }
}

/// Hands the root view's `UIWindowScene` to `PrivacyCoverWindow`.
struct WindowSceneReader: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneView { SceneView(found: found) }
    func updateUIView(_ view: SceneView, context: Context) {}

    final class SceneView: UIView {
        let found: (UIWindowScene) -> Void
        init(found: @escaping (UIWindowScene) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found(scene) }
        }
    }
}

/// Opaque, so nothing of the app shows through in the snapshot.
private struct PrivacyCover: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
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
        // VoiceOver stays on the cover, not the app content in the window below.
        .accessibilityAddTraits(.isModal)
    }
}
