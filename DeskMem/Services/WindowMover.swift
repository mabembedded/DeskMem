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
    private weak var windowWatcher: WindowWatcher?
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

    /// Must be called after init to link the watcher (avoids circular init dependency).
    func setWindowWatcher(_ watcher: WindowWatcher) {
        self.windowWatcher = watcher
    }

    private func onScreenChange() {
        debounceTimer?.invalidate()

        // Immediately pause the watcher so it doesn't overwrite good assignments
        // with the scrambled positions macOS just created.
        windowWatcher?.paused = true
        lastRestore = "Display change detected, waiting..."

        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Only prompt when we have 2+ monitors and saved assignments to restore
            guard self.monitorService.screens.count >= 2,
                  !self.assignmentStore.allAssignments().isEmpty else {
                self.windowWatcher?.paused = false
                self.lastRestore = "Idle"
                return
            }
            self.promptRestore()
        }
    }

    private func promptRestore() {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Restore Window Layout?"
            alert.informativeText = "Multiple monitors detected. Would you like to restore your saved window positions?"
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "No, Learn Current Layout")
            alert.alertStyle = .informational

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self?.restoreAll()
                // Keep watcher paused briefly so restored positions settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self?.windowWatcher?.paused = false
                }
            } else {
                // User wants to keep current layout — unpause watcher so it learns
                self?.windowWatcher?.paused = false
                self?.lastRestore = "Learning current layout..."
            }
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

        // Get available spaces per display for clamping
        let allSpaces = spaceService.allSpaces()

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
            let axResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            let axWindows = (axResult == .success) ? (windowsRef as? [AXUIElement]) : nil

            if let windows = axWindows {
                // AXUIElement path - can move windows across monitors and spaces
                for (index, window) in windows.enumerated() {
                    guard let currentFrame = windowFrame(window) else { continue }
                    guard currentFrame.width > 50, currentFrame.height > 50 else { continue }

                    let savedWindow = matchWindow(index: index, window: window, in: assignment.windows)
                        ?? assignment.windows.first

                    guard let target = savedWindow else { continue }
                    guard let targetScreenFrame = monitorService.frame(for: target.monitorIndex) else { continue }

                    let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
                    let currentMonitor = monitorService.monitorIndex(for: center)

                    if currentMonitor != target.monitorIndex {
                        moveWindow(window, currentFrame: currentFrame, to: targetScreenFrame)
                        movedWindows += 1
                    }

                    if let wid = cgWindowID(for: window, pid: pid) {
                        let currentSpaces = spaceService.spacesForWindow(wid)
                        let clampedSpaceIndex = clampSpaceIndex(target.spaceIndex, monitorIndex: target.monitorIndex, allSpaces: allSpaces)

                        if let targetSpaceID = spaceService.spaceID(displayIndex: target.monitorIndex, spaceIndex: clampedSpaceIndex) {
                            if !currentSpaces.contains(targetSpaceID) {
                                spaceService.moveWindow(wid, toSpace: targetSpaceID)
                                movedSpaces += 1
                            }
                        }
                    }
                }
            } else {
                // CGWindowList fallback - can only move between spaces (no AX position control)
                let cgWindows = cgWindowsForPID(pid)
                for (index, info) in cgWindows.enumerated() {
                    guard info.frame.width > 50, info.frame.height > 50 else { continue }

                    let savedWindow = matchWindowByInfo(index: index, name: info.name, in: assignment.windows)
                        ?? assignment.windows.first

                    guard let target = savedWindow else { continue }

                    // Move to correct space
                    let currentSpaces = spaceService.spacesForWindow(info.windowID)
                    let clampedSpaceIndex = clampSpaceIndex(target.spaceIndex, monitorIndex: target.monitorIndex, allSpaces: allSpaces)

                    if let targetSpaceID = spaceService.spaceID(displayIndex: target.monitorIndex, spaceIndex: clampedSpaceIndex) {
                        if !currentSpaces.contains(targetSpaceID) {
                            spaceService.moveWindow(info.windowID, toSpace: targetSpaceID)
                            movedSpaces += 1
                        }
                    }
                }
            }
        }

        lastRestore = "Moved \(movedWindows) windows, \(movedSpaces) to different desktops, skipped \(skippedApps) apps"
        isRestoring = false

        // Also unpause the watcher when manually restoring (in case it was stuck)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.windowWatcher?.paused = false
        }
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

    private func clampSpaceIndex(_ spaceIndex: Int, monitorIndex: Int, allSpaces: [DisplaySpaces]) -> Int {
        if monitorIndex < allSpaces.count {
            let availableCount = allSpaces[monitorIndex].spaceIDs.count
            return min(spaceIndex, max(availableCount - 1, 0))
        }
        return 0
    }

    /// Match a window by index/name when we only have CGWindowList info (no AXUIElement).
    private func matchWindowByInfo(index: Int, name: String, in saved: [WindowAssignment]) -> WindowAssignment? {
        if let match = saved.first(where: { $0.windowIndex == index && $0.windowTitle == name }) {
            return match
        }
        if let match = saved.first(where: { $0.windowTitle == name && !name.isEmpty }) {
            return match
        }
        if let match = saved.first(where: { $0.windowIndex == index }) {
            return match
        }
        return nil
    }

    // MARK: - CGWindowList fallback

    private struct CGWindowInfo {
        let windowID: CGWindowID
        let name: String
        let frame: CGRect
    }

    private func cgWindowsForPID(_ pid: pid_t) -> [CGWindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [CGWindowInfo] = []
        for info in windowList {
            guard let windowPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }

            let name = info[kCGWindowName as String] as? String ?? ""
            let frame = CGRect(x: x, y: y, width: w, height: h)
            results.append(CGWindowInfo(windowID: windowID, name: name, frame: frame))
        }
        return results
    }
}
