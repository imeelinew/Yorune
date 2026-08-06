import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .chinese: "Chinese"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .chinese: Locale(identifier: "zh-Hans")
        }
    }
}
