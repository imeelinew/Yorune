import SwiftUI

@main
struct YoruneApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .task {
                    await appModel.library.reload()
                }
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置") {
                    appModel.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
