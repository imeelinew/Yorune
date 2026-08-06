import SwiftUI

enum PreferencesMetrics {
    static let labelWidth: CGFloat = 132
    static let gutter: CGFloat = 12
    static let contentPaddingH: CGFloat = 28
    static let contentPaddingV: CGFloat = 22
    static let rowSpacing: CGFloat = 18
}

struct PreferencesForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesMetrics.rowSpacing) {
            content
        }
        .padding(.horizontal, PreferencesMetrics.contentPaddingH)
        .padding(.vertical, PreferencesMetrics.contentPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PreferencesRow<Content: View>: View {
    let label: LocalizedStringKey
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: PreferencesMetrics.gutter) {
            Text(label)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .frame(width: PreferencesMetrics.labelWidth, alignment: .trailing)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
