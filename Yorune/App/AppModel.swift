import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let configurationStore: ServerConfigurationStore
    let library: AlbumLibraryStore

    private var cancellables = Set<AnyCancellable>()

    private lazy var settingsWindowController = YoruneSettingsWindowController(
        settings: settings,
        configurationStore: configurationStore,
        library: library
    )

    init() {
        let settings = AppSettings()
        let configurationStore = ServerConfigurationStore()
        self.settings = settings
        self.configurationStore = configurationStore
        self.library = AlbumLibraryStore(configurationStore: configurationStore)

        settings.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        settings.appearance.apply()
    }

    func showSettings() {
        settingsWindowController.show()
    }
}
