import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selection: LibrarySection? = .albums

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 220)
        } detail: {
            AlbumGridView(
                library: appModel.library,
                openSettings: appModel.showSettings
            )
        }
    }
}
