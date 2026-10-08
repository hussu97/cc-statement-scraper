#if os(macOS)
import AppKit
import SwiftUI

// `Tokens.swift` is generated for UIKit (`UIColor { traits in … }`,
// `Color(uiColor:)`). LedgerKit also builds for macOS so `swift test` needs no
// simulator; this shim gives that file the three UIKit names it uses, backed by
// a dynamic `NSColor`. It is compiled on macOS only and never ships.

struct UIColorShimTraits {
    enum Style { case light, dark }
    let userInterfaceStyle: Style
}

final class UIColor: @unchecked Sendable {
    let nsColor: NSColor

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        nsColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    init(dynamicProvider: @escaping @Sendable (UIColorShimTraits) -> UIColor) {
        nsColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dynamicProvider(UIColorShimTraits(userInterfaceStyle: dark ? .dark : .light)).nsColor
        }
    }
}

extension Color {
    init(uiColor: UIColor) { self.init(nsColor: uiColor.nsColor) }
}
#endif
