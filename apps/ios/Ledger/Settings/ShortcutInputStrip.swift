import LedgerKit
import SwiftUI

/// Step 5 of the SMS guide in pictures (IOS-06g): picking "Shortcut Input"
/// and its Content in the Shortcuts editor. Frames and captions are
/// `SMSAutomationGuide.shortcutInputFrames`; the images are in
/// `Assets.xcassets/Guide`.
struct ShortcutInputStrip: View {
    let frames: [SMSAutomationGuide.Frame]
    @ScaledMetric(relativeTo: .body) private var frameWidth: CGFloat = 220

    var body: some View {
        Card {
            Label("Step 5 in pictures", systemImage: "photo.on.rectangle").font(Typography.cardTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(frames) { frame in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(frame.image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
                                .accessibilityHidden(true)
                            Text(frame.caption)
                                .font(Typography.caption).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: frameWidth)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("Then set Sender the same way, choosing Sender.")
                .font(Typography.caption).foregroundStyle(Palette.muted)
        }
    }
}
