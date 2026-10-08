import LedgerKit
import SwiftUI

/// A bank's mark in place of its name. The bundled asset first (offline, no
/// request), then the `bank-logos` URL, then a monogram; which one is
/// `BankDirectory`'s decision. VoiceOver reads the bank's name.
struct BankLogo: View {
    let bankCode: String
    var size: CGFloat = 20
    @Environment(BankCatalog.self) private var catalog: BankCatalog?
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var side: CGFloat { (size * min(scale, 1.6)).rounded() }
    private var name: String { catalog?.name(for: bankCode) ?? BankDirectory.knownNames[bankCode] ?? bankCode }
    private var source: BankLogoSource {
        catalog?.source(for: bankCode) ?? BankDirectory.source(bankCode: bankCode, logoPath: nil, supabaseURL: nil)
    }
    private var onChip: Bool { BankDirectory.needsLightChip(bankCode: bankCode, darkMode: scheme == .dark) }

    var body: some View {
        // On the chip the mark shrinks so the chip keeps the logo's footprint.
        mark
            .frame(width: onChip ? side * 0.78 : side, height: onChip ? side * 0.78 : side)
            .padding(onChip ? side * 0.11 : 0)
            .background {
                // Dark marks (ENBD, SIB, EIB, FAB) sit on a light chip in dark mode.
                if onChip { RoundedRectangle(cornerRadius: side * 0.22).fill(Color.white) }
            }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder private var mark: some View {
        switch source {
        case .bundled(let asset):
            Image(asset).resizable().interpolation(.high).scaledToFit()
        case .remote(let url):
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.high).scaledToFit()
                } else {
                    monogram(BankDirectory.monogram(bankCode))
                }
            }
        case .monogram(let letters):
            monogram(letters)
        }
    }

    private func monogram(_ letters: String) -> some View {
        Text(letters)
            .font(.system(size: side * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.ink2)
            .frame(width: side, height: side)
            .background(Palette.surface3, in: Circle())
    }
}

/// A logo beside a card label: `[FAB] •1234`.
struct BankCardLabel: View {
    let bankCode: String
    let label: String?
    var size: CGFloat = 16
    var font: Font = Typography.caption
    var color: Color = Palette.muted

    var body: some View {
        HStack(spacing: 5) {
            BankLogo(bankCode: bankCode, size: size)
            if let label { Text(label).font(font).foregroundStyle(color) }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Bank logos") {
    let catalog = BankCatalog(supabaseURL: nil)
    return VStack(alignment: .leading, spacing: 12) {
        ForEach(["ADCB", "EIB", "ENBD", "FAB", "MASHREQ", "SIB", "CBD"], id: \.self) { code in
            HStack { BankLogo(bankCode: code, size: 28); Text(catalog.name(for: code)) }
        }
    }
    .padding()
    .environment(catalog)
}
