import SwiftUI

enum YoruneStyle {
    static let accent = Color(red: 1, green: 0, blue: 0.337)
    static let quickAnimation = Animation.easeOut(duration: 0.15)
    static let springAnimation = Animation.spring(response: 0.35, dampingFraction: 0.7)
}

enum LibrarySection: Hashable {
    case albums
}

struct SidebarView: View {
    @Binding var selection: LibrarySection?

    var body: some View {
        List {
            Button {
                selection = .albums
            } label: {
                Label {
                    Text("Albums")
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "square.stack")
                        .foregroundStyle(YoruneStyle.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if selection == .albums {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.22))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
            .accessibilityAddTraits(selection == .albums ? .isSelected : [])
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
        .navigationTitle("Yorune")
    }
}
