import SwiftUI
import AppKit

@main
struct JTimerApp: App {
    @StateObject private var menuBarManager = MenuBarManager()
    @StateObject private var timerManager = TimerManager()
    @StateObject private var jiraAPI = JiraAPI()

    var body: some Scene {
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
                .onAppear {
                    setupMenuBarApp()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(jiraAPI)
        }
    }

    private func setupMenuBarApp() {
        NSApp.setActivationPolicy(.accessory)
        menuBarManager.setup(timerManager: timerManager, jiraAPI: jiraAPI)

        // Hide the main window immediately
        if let window = NSApp.windows.first {
            window.orderOut(nil)
        }
    }
}