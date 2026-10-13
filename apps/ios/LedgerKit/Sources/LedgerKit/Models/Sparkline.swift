import Foundation

/// A sparkline's shape (PAR-13), the web's `sparkLine` (`apps/web/src/components/charts/spark.ts`)
/// in a unit box: x runs 0…1 left to right, y 0…1 top to bottom, points evenly spaced. The values
/// are the server's amounts; this only turns them into drawing positions, so `Double` is fine
/// here and nowhere near money arithmetic.
public struct Sparkline: Sendable, Hashable {
    public struct Point: Sendable, Hashable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Runs of consecutive values; a missing value breaks the line. A run of one point is a dot.
    public let segments: [[Point]]
    /// The last drawn point, for the end marker.
    public var last: Point? { segments.last?.last }
    public var isEmpty: Bool { segments.isEmpty }

    /// The vertical domain is the values' own range, widened to include `min` / `max` when given
    /// (0–1 for utilisation, so the height reads as a share of the limit). A flat series sits in
    /// the middle; nil values are gaps.
    public init(_ values: [Decimal?], min: Decimal? = nil, max: Decimal? = nil) {
        let nums = values.map { $0.map { NSDecimalNumber(decimal: $0).doubleValue } }
        let present = nums.compactMap { $0 }.filter(\.isFinite)
        guard !present.isEmpty else {
            segments = []
            return
        }
        var lo = Swift.min(present.min()!, min.map { NSDecimalNumber(decimal: $0).doubleValue } ?? .infinity)
        var hi = Swift.max(present.max()!, max.map { NSDecimalNumber(decimal: $0).doubleValue } ?? -.infinity)
        if hi == lo {
            lo -= 1
            hi += 1
        }
        let n = nums.count
        var out: [[Point]] = []
        var run: [Point] = []
        for (i, value) in nums.enumerated() {
            guard let value, value.isFinite else {
                if !run.isEmpty { out.append(run) }
                run = []
                continue
            }
            let x = n == 1 ? 0.5 : Double(i) / Double(n - 1)
            run.append(Point(x: x, y: (hi - value) / (hi - lo)))
        }
        if !run.isEmpty { out.append(run) }
        segments = out
    }
}
