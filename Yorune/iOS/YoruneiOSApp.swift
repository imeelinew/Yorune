import SwiftUI

@main
struct YoruneiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environmentObject(appModel)
                .environment(\.locale, appModel.settings.language.locale)
                .preferredColorScheme(appModel.settings.appearance.colorScheme)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await appModel.library.runAutomaticSync()
                }
        }
    }
}
