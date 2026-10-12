import Foundation
import Testing

/// IOS-19r: `Palette.subtle` is for glyphs and dividers only. Text (captions
/// included) uses `muted` or stronger, the pairs declared under
/// `packages/tokens/tokens.json#contrast.ios`.
@Suite("Palette usage in the app sources")
struct PaletteUsageTests {
    /// `apps/ios/`, from this file's path.
    static let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func appSources() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["Ledger", "ShareExtension"] {
            let root = iosRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append(("\(dir)/\(url.lastPathComponent)", try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    /// The view an occurrence styles: the last `Text(`, `Label(`, `TextField(`
    /// or `Image(` that starts before it.
    static func styledView(in source: String, before index: String.Index) -> String? {
        let head = source[..<index]
        return ["Text(", "Label(", "TextField(", "Image("]
            .compactMap { name in head.range(of: name, options: .backwards).map { (name, $0.lowerBound) } }
            .max { $0.1 < $1.1 }?.0
    }

    @Test("subtle never colours text")
    func subtleIsForGlyphsOnly() throws {
        let sources = try Self.appSources()
        #expect(sources.count > 10, "app sources not found under \(Self.iosRoot.path)")
        var offenders: [String] = []
        for (name, text) in sources {
            var from = text.startIndex
            while let hit = text.range(of: "Palette.subtle", range: from..<text.endIndex) {
                let view = Self.styledView(in: text, before: hit.lowerBound)
                if view != "Image(" {
                    let line = text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1
                    offenders.append("\(name):\(line) styles \(view ?? "?")")
                }
                from = hit.upperBound
            }
        }
        #expect(offenders.isEmpty, "use Palette.muted for text: \(offenders)")
    }

    @Test("the guard catches subtle text, single- and multi-line")
    func guardSelfTest() {
        let oneLine = #"Text("1").font(.caption).foregroundStyle(Palette.subtle)"#
        #expect(Self.styledView(in: oneLine, before: oneLine.range(of: "Palette.subtle")!.lowerBound) == "Text(")
        let glyph = "Image(systemName: \"chevron.right\")\n    .foregroundStyle(ok ? Palette.accent : Palette.subtle)"
        #expect(Self.styledView(in: glyph, before: glyph.range(of: "Palette.subtle")!.lowerBound) == "Image(")
    }
}
