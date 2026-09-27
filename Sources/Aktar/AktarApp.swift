import SwiftData
import SwiftUI

@main
struct AktarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
                .environment(appDelegate.appState)
                .modelContext(appDelegate.appState.repository.modelContext)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Aktar") { AboutPanel.show() }
                Button("Check for Updates\u{2026}") { appDelegate.appState.updater.checkForUpdates() }
                    .disabled(!appDelegate.appState.updater.canCheckForUpdates)
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(appDelegate.appState)
        }

        Window("Welcome", id: "onboarding") {
            OnboardingView()
                .environment(appDelegate.appState)
        }
        .windowResizability(.contentSize)
    }
}
