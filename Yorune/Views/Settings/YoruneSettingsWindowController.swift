import AppKit
import Combine
import MacAppSettingsUI
import SwiftUI

@MainActor
final class YoruneSettingsWindowController {
    private let settings: AppSettings
    private let configurationStore: ServerConfigurationStore
    private let library: AlbumLibraryStore

    private var controller: SettingsWindowController?
    private var builtLanguage: AppLanguage?
    private var languageObserver: AnyCancellable?

    init(
        settings: AppSettings,
        configurationStore: ServerConfigurationStore,
        library: AlbumLibraryStore
    ) {
        self.settings = settings
        self.configurationStore = configurationStore
        self.library = library

        languageObserver = settings.$language
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleLanguageChange()
            }
    }

    func show(tab: SettingsTab = .general) {
        if controller == nil || builtLanguage != settings.language {
            rebuildController(preservingTab: tab, makeVisible: false)
        }
        guard let controller else { return }

        select(tab, in: controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func handleLanguageChange() {
        guard controller != nil else {
            builtLanguage = nil
            return
        }

        rebuildController(
            preservingTab: selectedTab() ?? .general,
            makeVisible: controller?.window?.isVisible == true
        )
    }

    private func rebuildController(preservingTab tab: SettingsTab, makeVisible: Bool) {
        let frame = controller?.window?.frame
        controller?.close()
        builtLanguage = settings.language
        controller = makeController()
        guard let controller else { return }

        select(tab, in: controller)
        if let frame {
            controller.window?.setFrame(frame, display: false)
        }

        guard makeVisible else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeController() -> SettingsWindowController {
        let panes = SettingsTab.allCases.map { tab in
            SwiftUISettingsPaneController(tab: tab, settings: settings) {
                switch tab {
                case .general:
                    GeneralSettingsView(settings: settings)
                case .appearance:
                    AppearanceSettingsView(settings: settings)
                case .server:
                    ServerSettingsView(
                        configurationStore: configurationStore,
                        library: library
                    )
                case .about:
                    AboutSettingsView(settings: settings)
                }
            }
        }

        let controller = SettingsWindowController(
            with: panes,
            centersWindowPositionAlways: false,
            closesWindowWithEscapeKey: true
        )
        controller.settingsWindow.defaultWindowTitle = String(
            localized: "Yorune Settings",
            locale: settings.language.locale
        )
        return controller
    }

    private func selectedTab() -> SettingsTab? {
        guard let controller,
              let index = controller.tabViewController.selectedTabIndex,
              controller.tabViewController.panes.indices.contains(index) else {
            return nil
        }

        let identifier = controller.tabViewController.panes[index].tabIdentifier
        return SettingsTab.allCases.first { $0.tabIdentifier == identifier }
    }

    private func select(_ tab: SettingsTab, in controller: SettingsWindowController) {
        let panes = controller.tabViewController.panes
        guard let index = panes.firstIndex(where: { $0.tabIdentifier == tab.tabIdentifier }) else {
            return
        }
        controller.tabViewController.selectedTabIndex = index
    }
}

private final class SwiftUISettingsPaneController: SettingsPaneViewController {
    private let rootView: AnyView
    private let paneHeight: CGFloat
    private static let paneWidth: CGFloat = 500

    init(
        tab: SettingsTab,
        settings: AppSettings,
        @ViewBuilder content: () -> some View
    ) {
        self.rootView = AnyView(
            SettingsPaneLocalizedRoot(settings: settings, content: content())
        )
        self.paneHeight = tab.preferredPaneHeight
        super.init(nibName: nil, bundle: nil)
        tabName = String(localized: tab.localizationKey, locale: settings.language.locale)
        tabImage = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil)
        tabIdentifier = tab.tabIdentifier
        isResizableView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        view = hosting
        preferredPaneSize = NSSize(width: Self.paneWidth, height: paneHeight)
        view.setFrameSize(preferredPaneSize ?? .zero)
    }
}

private struct SettingsPaneLocalizedRoot<Content: View>: View {
    @ObservedObject var settings: AppSettings
    let content: Content

    var body: some View {
        content
            .environment(\.locale, settings.language.locale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
