import SwiftUI

@main
struct DeskMemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.monitorService)
                .environmentObject(appDelegate.assignmentStore)
                .environmentObject(appDelegate.windowWatcher)
                .environmentObject(appDelegate.windowMover)
        }
    }
}
