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
                    Text("请先连接服务器")
                        .font(.title3)
                    Button("打开设置", action: openSettings)
                }
            case .loading:
                ProgressView("正在载入")
            case .loaded:
                if library.albums.isEmpty {
                    Text("没有专辑")
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
                    Text("无法载入专辑")
                        .font(.title3)
                    Button("重试") {
                        Task {
                            await library.reload()
                        }
                    }
                    Button("打开设置", action: openSettings)
                }
            }
        }
        .navigationTitle("专辑")
    }
}
