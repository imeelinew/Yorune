import SwiftUI

enum LibrarySection: Hashable {
    case albums
    case downloads
}

struct SidebarView: View {
    @Binding var selection: LibrarySection?

    var body: some View {
        List(selection: $selection) {
            sidebarRow(
                .albums,
                title: "Albums",
                systemImage: "square.stack"
            )
            sidebarRow(
                .downloads,
                title: "Downloaded",
                systemImage: "arrow.down.circle"
            )
        }
        .listStyle(.sidebar)
        .contentMargins(.horizontal, 8, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 30)
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
        .navigationTitle("Yorune")
    }

    private func sidebarRow(
        _ section: LibrarySection,
        title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        // Match Obelisk's professional sidebar: 3 pt leading inset,
        // 18 pt icon slot, 8 pt title gap, and a 30 pt row.
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(YoruneStyle.accent)
                .frame(width: 18, height: 18)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 3))
        .tag(section)
    }
}
