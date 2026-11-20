import SwiftUI

/// Compatibility wrapper using Liquid Glass `GlassEffectContainer` on macOS 26+
/// and standard SwiftUI layout on macOS 15 Sequoia.
struct KadmosGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    /// Applies Liquid Glass on macOS 26+ and native Apple `.regularMaterial` glass fallback on macOS 15.
    @ViewBuilder
    func kadmosGlassSurface<S: Shape & InsettableShape>(
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(shape.fill(.regularMaterial))
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
        }
    }
}
