import SwiftUI

struct AlbumCardView: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(url: album.artworkURL)
                .aspectRatio(1, contentMode: .fit)

            Text(album.title)
                .font(.headline)
                .lineLimit(1)
        }
    }
}
