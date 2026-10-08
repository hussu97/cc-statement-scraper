// swift-tools-version: 6.0
import PackageDescription

/// LedgerKit holds every decision the iPhone app makes: models, money and date
/// formatting, the API client, auth/session sharing, the SMS filter, the outbox,
/// telemetry and the screen models. Views in `Ledger/` are layout only.
///
/// It also compiles for macOS so `swift test` runs without a simulator. The one
/// UIKit-only file (`Theme/Tokens.swift`, generated) gets a macOS shim in
/// `Theme/MacColorShim.swift`.
let package = Package(
    name: "LedgerKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LedgerKit", targets: ["LedgerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.3"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.30.1"),
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
