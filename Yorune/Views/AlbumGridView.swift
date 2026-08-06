import SwiftUI

struct AlbumGridView: View {
    @ObservedObject var library: AlbumLibraryStore
    let openSettings: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 20)
    ]

    var body: some View {
        Group {
            switch library.state {
            case .needsConfiguration:
                VStack(spacing: 16) {
                    Text("Connect a server in Settings")
                        .font(.title3)
                    Button("Open Settings", action: openSettings)
                }
            case .loading:
                ProgressView("Loading")
            case .loaded:
                if library.albums.isEmpty {
                    Text("No Albums")
                        .font(.title3)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(library.albums) { album in
                                AlbumCardView(album: album)
                            }
                        }
                        .padding(24)
                    }
                }
            case .failed:
                VStack(spacing: 16) {
                    Text("Unable to Load Albums")
                        .font(.title3)
                    Button("Retry") {
                        Task {
                            await library.reload()
                        }
                    }
                    Button("Open Settings", action: openSettings)
                }
            }
        }
        .navigationTitle("Albums")
    }
}
