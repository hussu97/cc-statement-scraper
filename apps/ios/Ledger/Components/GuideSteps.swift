import LedgerKit
import SwiftUI

/// The numbered step cards of a setup guide (SMS capture, card payments).
struct GuideSteps: View {
    let steps: [SMSAutomationGuide.Step]

    var body: some View {
        ForEach(steps) { step in
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Text("\(step.number)")
                        .font(.system(.title3, design: .serif))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(Palette.accentInk)
                        .frame(width: 32, height: 32)
                        .background(Palette.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).font(Typography.cardTitle)
                        Text(step.detail).font(Typography.rowMeta).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }
}

/// The "Open Shortcuts" button at the foot of a guide.
struct OpenShortcutsButton: View {
    var body: some View {
        Link(destination: URL(string: "shortcuts://")!) {
            Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity, minHeight: Metrics.tapMin)
        }
        .buttonStyle(.borderedProminent)
    }
}
