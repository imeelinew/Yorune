import SwiftUI

enum SettingsTab: Int, CaseIterable, Hashable, Identifiable {
    case general
    case appearance
    case server
    case about

    var id: Int { rawValue }

    var localizationKey: String.LocalizationValue {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .server: "Server"
        case .about: "About"
        }
    }

    var tabIdentifier: String {
        switch self {
        case .general: "general"
        case .appearance: "appearance"
        case .server: "server"
        case .about: "about"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "eyeglasses"
        case .server: "externaldrive.connected.to.line.below"
        case .about: "info.circle"
        }
    }

    var preferredPaneHeight: CGFloat {
        switch self {
        case .general: 190
        case .appearance: 150
        case .server: 250
        case .about: 300
        }
    }
}
