import SwiftUI

@main
struct YoruneApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .environment(\.locale, appModel.settings.language.locale)
                .task {
                    await appModel.library.reload()
                }
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appModel.updateService.checkForUpdates()
                }
                .disabled(!appModel.updateService.canCheckForUpdates)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    appModel.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Playback") {
                Button("Play or Pause") {
                    appModel.playback.togglePlayback()
                }
                .disabled(appModel.playback.currentSong == nil)

                Button("Previous") {
                    appModel.playback.playPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!appModel.playback.canGoPrevious)

                Button("Next") {
                    appModel.playback.playNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!appModel.playback.canGoNext)

                Divider()

                Button("Queue") {
                    appModel.playback.toggleQueueInspector()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(appModel.playback.currentSong == nil)
            }
        }
    }
}
