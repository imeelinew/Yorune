import SwiftUI

@main
struct YoruneiOSApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environmentObject(appModel)
                .environment(\.locale, appModel.settings.language.locale)
                .preferredColorScheme(appModel.settings.appearance.colorScheme)
                .task {
                    await appModel.library.reload()
                }
        }
    }
}
