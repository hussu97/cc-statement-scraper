// swift-tools-version: 6.0
import PackageDescription

/// LedgerKit holds every decision the iPhone app makes: models, money and date
/// formatting, the API client, auth/session sharing, the SMS filter, the outbox,
/// telemetry and the screen models. Views in `Ledger/` are layout only.
///
/// It also compiles for macOS so `swift test` runs without a simulator; the
/// generated `Theme/Tokens.swift` resolves colours via UIKit on iOS and AppKit on macOS.
let package = Package(
    name: "LedgerKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LedgerKit", targets: ["LedgerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.3"),
        // 9.31.0 at least: older SDKs started from `LedgerApp.init` took a background launch (an SMS
        // intent) for an active app, and reported the suspension as an hours-long app hang.
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.31.0"),
    ],
    targets: [
        .target(
            name: "LedgerKit",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .testTarget(
            name: "LedgerKitTests",
            dependencies: ["LedgerKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
