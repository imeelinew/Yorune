import SwiftUI

struct AlbumCardView: View {
    let album: Album
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AlbumArtworkView(url: album.artworkURL, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .shadow(
                    color: .black.opacity(
                        colorScheme == .dark
                            ? (isHovering ? 0.42 : 0.26)
                            : (isHovering ? 0.16 : 0.08)
                    ),
                    radius: isHovering ? 16 : 8,
                    x: 0,
                    y: isHovering ? 7 : 3
                )
                .scaleEffect(isHovering ? 1.014 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !album.artist.isEmpty {
                    Text(album.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
