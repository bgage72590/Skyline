import SwiftUI

/// "Readable glass": a blurred material under a dark tint that is opaque enough that nothing behind a
/// card (map, background animation, other cards) bleeds through charts or small text. A hairline edge
/// keeps the card shape visible on dark backgrounds.
enum Glass {
    /// Tint over the material for cards (≈ 70 % dark): text contrast stays above WCAG AA for captions.
    static let cardTint = Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.62)
    /// Panels that hold charts (detail inspector / sheet): effectively opaque.
    static let panelFill = Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.97)
    /// Small overlays on the radar map (chips, legend, timeline).
    static let chipTint = Color.black.opacity(0.55)
    static let edge = Color.white.opacity(0.10)
    /// Secondary text on glass (instead of 0.6–0.7 white, which fails contrast on light skies).
    static let secondaryText = Color.white.opacity(0.82)
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Glass.cardTint)
            }
        }
        .overlay(shape.strokeBorder(Glass.edge, lineWidth: 0.5))
    }

    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(Glass.panelFill))
            .overlay(shape.strokeBorder(Glass.edge, lineWidth: 0.5))
    }

    func glassChip<S: Shape>(_ shape: S) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Glass.chipTint)
            }
        }
    }
}
