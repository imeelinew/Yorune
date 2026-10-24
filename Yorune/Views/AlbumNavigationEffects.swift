import SwiftUI

/// Each section animates once when it appears, including after an uncached load.
struct AlbumDetailEntrance: ViewModifier {
    var delay: Double = 0
    var isArtwork = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible || reduceMotion ? 1 : (isArtwork ? 0.92 : 1), anchor: .topLeading)
            .offset(y: isVisible || reduceMotion ? 0 : (isArtwork ? 12 : 18))
            .animation(
                reduceMotion ? .easeOut(duration: 0.15) :
                    .spring(response: 0.48, dampingFraction: 0.8).delay(delay),
                value: isVisible
            )
            .onAppear { isVisible = true }
    }
}
