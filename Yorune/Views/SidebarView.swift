import SwiftUI

enum LibrarySection: Hashable {
    case albums
    case downloads
}

struct SidebarView: View {
    @Binding var selection: LibrarySection?

    var body: some View {
        List {
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
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
        .navigationTitle("Yorune")
    }

    private func sidebarRow(
        _ section: LibrarySection,
        title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Button {
            selection = section
        } label: {
            Label {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(YoruneStyle.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background {
                if selection == section {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.22))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 10))
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }
}
