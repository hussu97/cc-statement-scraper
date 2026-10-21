import LedgerKit
import SwiftUI

/// A holding's photo from the `investment-images` bucket (`HoldingImage`), filled into a rounded
/// frame; a neutral tile with the metal's glyph while it loads or when it can't. VoiceOver reads
/// the metal and form (`"Gold bar"`). URLSession's shared cache keeps each photo once fetched.
struct HoldingPhoto: View {
    let url: URL?
    let label: String
    /// Nil fills the width it is given.
    var width: CGFloat? = 44
    var height: CGFloat = 44
    var cornerRadius: CGFloat = Metrics.radiusMd

    var body: some View {
        // The tile sets the size; the photo fills it and is clipped, so it never pushes the layout.
        Rectangle().fill(Palette.surface3)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "circle.hexagongrid").foregroundStyle(Palette.subtle)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Palette.border, lineWidth: 0.5))
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
    }
}

extension HoldingPhoto {
    /// A row's thumbnail.
    init(holding: Holding, supabaseURL: URL?, side: CGFloat = 44) {
        self.init(url: holding.imageURL(supabaseURL: supabaseURL), label: holding.imageLabel, width: side, height: side)
    }
}
