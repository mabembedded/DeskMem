import AppKit
import ApplicationServices
import Combine

/// Moves app windows to their assigned monitors and desktops when display configuration changes.
class WindowMover: ObservableObject {
    @Published var lastRestore: String = "Idle"
    @Published var isRestoring: Bool = false

    private let monitorService: MonitorService
    private let assignmentStore: AssignmentStore
    private let spaceService: SpaceService
    private var debounceTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let debounceInterval: TimeInterval = 3.0

    init(monitorService: MonitorService, assignmentStore: AssignmentStore, spaceService: SpaceService) {
        self.monitorService = monitorService
        self.assignmentStore = assignmentStore
        self.spaceService = spaceService

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.onScreenChange()
            }
            .store(in: &cancellables)
    }

    private func onScreenChange() {
        debounceTimer?.invalidate()
        lastRestore = "Display change detected, waiting..."

        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.restoreAll()
        }
    }

    /// Restore all apps to their assigned monitors and desktops.
    func restoreAll() {
        guard monitorService.screens.count >= 2 else {
            lastRestore = "Only 1 monitor connected, skipping restore"
            return
        }

        isRestoring = true
        let assignments = assignmentStore.allAssignments()
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var movedWindows = 0
        var movedSpaces = 0
        var skippedApps = 0

        for assignment in assignments {
            guard let app = runningApps.first(where: { $0.bundleIdentifier == assignment.bundleIdentifier }) else {
                skippedApps += 1
                continue
            }

            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let windows = windowsRef as? [AXUIElement] else {
                skippedApps += 1
                continue
            }

            for (index, window) in windows.enumerated() {
                guard let currentFrame = windowFrame(window) else { continue }
                guard currentFrame.width > 50, currentFrame.height > 50 else { continue }

                // Find the matching saved window assignment
                let savedWindow = matchWindow(index: index, window: window, in: assignment.windows)
                    ?? assignment.windows.first  // fallback: use the app's primary assignment

                guard let target = savedWindow else { continue }
                guard let targetScreenFrame = monitorService.frame(for: target.monitorIndex) else { continue }

                // Step 1: Move to correct monitor if needed
                let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
                let currentMonitor = monitorService.monitorIndex(for: center)

                if currentMonitor != target.monitorIndex {
                    moveWindow(window, currentFrame: currentFrame, to: targetScreenFrame)
                    movedWindows += 1
                }

                // Step 2: Move to correct space if needed
                if let wid = cgWindowID(for: window, pid: pid) {
                    let currentSpaces = spaceService.spacesForWindow(wid)
                    if let targetSpaceID = spaceService.spaceID(displayIndex: target.monitorIndex, spaceIndex: target.spaceIndex) {
                        if !currentSpaces.contains(targetSpaceID) {
                            spaceService.moveWindow(wid, toSpace: targetSpaceID)
                            movedSpaces += 1
                        }
                    }
                }
            }
        }

        lastRestore = "Moved \(movedWindows) windows, \(movedSpaces) to different desktops, skipped \(skippedApps) apps"
        isRestoring = false
    }

    /// Match a current window to a saved window assignment.
    private func matchWindow(index: Int, window: AXUIElement, in saved: [WindowAssignment]) -> WindowAssignment? {
        let title = windowTitle(window) ?? ""

        // Try matching by index + title
        if let match = saved.first(where: { $0.windowIndex == index && $0.windowTitle == title }) {
            return match
        }
        // Try by title alone
        if let match = saved.first(where: { $0.windowTitle == title && !title.isEmpty }) {
            return match
        }
        // Try by index alone
        if let match = saved.first(where: { $0.windowIndex == index }) {
            return match
        }
        return nil
    }

    private func moveWindow(_ window: AXUIElement, currentFrame: CGRect, to targetScreen: CGRect) {
        let newX = targetScreen.origin.x + (targetScreen.width - currentFrame.width) / 2
        let newY = targetScreen.origin.y + (targetScreen.height - currentFrame.height) / 2
        var newOrigin = CGPoint(x: newX, y: newY)

        if let posValue = AXValueCreate(.cgPoint, &newOrigin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
    }

    private func windowFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    private func windowTitle(_ element: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }
}
