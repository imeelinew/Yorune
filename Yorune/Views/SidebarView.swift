import SwiftUI

enum LibrarySection: Hashable {
    case albums
}

struct SidebarView: View {
    @Binding var selection: LibrarySection?

    var body: some View {
        List(selection: $selection) {
            Label("Albums", systemImage: "square.stack")
                .tag(LibrarySection.albums)
        }
        .listStyle(.sidebar)
        .navigationTitle("Yorune")
    }
}
