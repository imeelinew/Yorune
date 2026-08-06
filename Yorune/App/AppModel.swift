import Foundation

@MainActor
final class AppModel: ObservableObject {
    let configurationStore: ServerConfigurationStore
    let library: AlbumLibraryStore

    private lazy var settingsWindowController = YoruneSettingsWindowController(
        configurationStore: configurationStore,
        library: library
    )

    init() {
        let configurationStore = ServerConfigurationStore()
        self.configurationStore = configurationStore
        self.library = AlbumLibraryStore(configurationStore: configurationStore)
    }

    func showSettings() {
        settingsWindowController.show()
    }
}
