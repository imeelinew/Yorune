import AppKit
import MacAppSettingsUI
import SwiftUI

@MainActor
final class YoruneSettingsWindowController {
    private let controller: SettingsWindowController

    init(
        configurationStore: ServerConfigurationStore,
        library: AlbumLibraryStore
    ) {
        let pane = SwiftUISettingsPaneController(
            tabName: "服务器",
            tabImage: NSImage(
                systemSymbolName: "externaldrive.connected.to.line.below",
                accessibilityDescription: nil
            ),
            tabIdentifier: "server"
        ) {
            ServerSettingsView(
                configurationStore: configurationStore,
                library: library
            )
        }

        let controller = SettingsWindowController(
            with: [pane],
            centersWindowPositionAlways: false,
            closesWindowWithEscapeKey: true
        )
        controller.settingsWindow.defaultWindowTitle = "Yorune 设置"
        self.controller = controller
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

private final class SwiftUISettingsPaneController: SettingsPaneViewController {
    private let rootView: AnyView

    init(
        tabName: String,
        tabImage: NSImage?,
        tabIdentifier: String,
        @ViewBuilder content: () -> some View
    ) {
        self.rootView = AnyView(
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        super.init(nibName: nil, bundle: nil)
        self.tabName = tabName
        self.tabImage = tabImage
        self.tabIdentifier = tabIdentifier
        self.isResizableView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        view = hosting
        preferredPaneSize = NSSize(width: 500, height: 250)
        view.setFrameSize(preferredPaneSize ?? .zero)
    }
}
