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
        Button {
            selection = section
        } label: {
            // Match Obelisk's professional sidebar geometry without opting
            // into the system source-list selection tint.
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(YoruneStyle.accent)
                    .frame(width: 18, height: 18)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background {
                if selection == section {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.22))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 3))
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }
}
