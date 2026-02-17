import AppKit
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    let monitorService = MonitorService()
    let assignmentStore = AssignmentStore()
    let spaceService = SpaceService()
    lazy var windowWatcher = WindowWatcher(
        monitorService: monitorService,
        assignmentStore: assignmentStore,
        spaceService: spaceService
    )
    lazy var windowMover = WindowMover(
        monitorService: monitorService,
        assignmentStore: assignmentStore,
        spaceService: spaceService
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        windowMover.setWindowWatcher(windowWatcher)
        windowWatcher.startWatching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowWatcher.stopWatching()
    }
}
