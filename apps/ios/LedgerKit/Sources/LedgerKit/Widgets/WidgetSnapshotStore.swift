import Foundation

/// The widgets' side of the App Group: the snapshot file and the Lock Screen
/// privacy flag. The app writes both; the widget extension only reads. Each
/// write that changes what a widget shows calls `reload` (WidgetCenter's
/// `reloadAllTimelines()` in the app, nothing in tests).
public struct WidgetSnapshotStore: @unchecked Sendable {
    // UserDefaults is documented thread-safe.
    public let fileURL: URL
    private let defaults: UserDefaults
    private let reload: @Sendable () -> Void

    static let fileName = "widget-snapshot.json"
    static let hideAmountsKey = "ledger.widgets.hideLockScreenAmounts"

    public init(container: URL, defaults: UserDefaults, reload: @escaping @Sendable () -> Void = {}) {
        fileURL = container.appendingPathComponent(Self.fileName)
        self.defaults = defaults
        self.reload = reload
    }

    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return WidgetSnapshot.decode(data)
    }

    /// Writes the snapshot and reloads the widgets when `needsReload` says so.
    /// Readable until first unlock after a restart only, so a Lock Screen
    /// widget can still draw it while the device is locked.
    @discardableResult
    public func write(_ snapshot: WidgetSnapshot) -> Bool {
        let previous = read()
        guard snapshot.needsReload(replacing: previous), let data = try? snapshot.encoded() else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        reload()
        return true
    }

    /// Sign-out: the widgets go back to "open Bank Ledger" with nothing of the
    /// last account on them.
    public func clear() {
        let existed = FileManager.default.fileExists(atPath: fileURL.path)
        try? FileManager.default.removeItem(at: fileURL)
        if existed { reload() }
    }

    /// Mirrors Settings → Require Face ID (`AppLock`, which keeps its setting in
    /// the app's own defaults, out of the extension's reach). Reloads on change.
    public var hidesLockScreenAmounts: Bool {
        get { defaults.bool(forKey: Self.hideAmountsKey) }
        nonmutating set {
            guard newValue != hidesLockScreenAmounts else { return }
            defaults.set(newValue, forKey: Self.hideAmountsKey)
            reload()
        }
    }
}
