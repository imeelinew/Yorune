import SwiftUI

struct AlbumCardView: View {
    let album: Album
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: album.artworkURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !album.artist.isEmpty {
                    Text(album.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .scaleEffect(isHovering ? 1.02 : 1)
        .shadow(
            color: isHovering ? .black.opacity(0.15) : .clear,
            radius: isHovering ? 12 : 0,
            x: 0,
            y: isHovering ? 4 : 0
        )
        .animation(YoruneStyle.springAnimation, value: isHovering)
        .onHover { hovering in
            withAnimation(YoruneStyle.quickAnimation) {
                isHovering = hovering
            }
        }
    }
}
