import AppKit
import ApplicationServices
import Combine

/// Polls running apps to detect which monitor and desktop their windows are on.
/// Updates assignments when an app's windows move.
class WindowWatcher: ObservableObject {
    @Published var lastPoll: Date?

    /// When true, polling still runs but won't save changes. Used during display transitions
    /// to prevent the watcher from overwriting good assignments with scrambled positions.
    var paused: Bool = false

    private let monitorService: MonitorService
    private let assignmentStore: AssignmentStore
    private let spaceService: SpaceService
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 5.0

    init(monitorService: MonitorService, assignmentStore: AssignmentStore, spaceService: SpaceService) {
        self.monitorService = monitorService
        self.assignmentStore = assignmentStore
        self.spaceService = spaceService
    }

    func startWatching() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollWindows()
        }
        pollWindows()
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func pollWindows() {
        guard !paused else { return }
        guard monitorService.screens.count >= 2 else { return }

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let appName = app.localizedName ?? bundleID
            let pid = app.processIdentifier

            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            let axWindows = (result == .success) ? (windowsRef as? [AXUIElement]) : nil

            var windowAssignments: [WindowAssignment] = []
            var monitorCounts: [Int: Int] = [:]

            if let windows = axWindows {
                // AXUIElement path - works for most apps
                for (index, window) in windows.enumerated() {
                    guard let frame = windowFrame(window) else { continue }
                    guard frame.width > 50, frame.height > 50 else { continue }

                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    guard let monIdx = monitorService.monitorIndex(for: center) else { continue }

                    monitorCounts[monIdx, default: 0] += 1

                    let title = windowTitle(window) ?? ""

                    var spaceIdx = 0
                    if let wid = cgWindowID(for: window, pid: pid) {
                        let spaces = spaceService.spacesForWindow(wid)
                        if let firstSpace = spaces.first,
                           let indices = spaceService.indices(for: firstSpace) {
                            spaceIdx = indices.spaceIndex
                        }
                    }

                    windowAssignments.append(WindowAssignment(
                        windowTitle: title,
                        windowIndex: index,
                        monitorIndex: monIdx,
                        spaceIndex: spaceIdx
                    ))
                }
            } else {
                // Fallback: CGWindowList path for apps that block AXUIElement (e.g. Teams)
                let cgWindows = cgWindowsForPID(pid)
                for (index, info) in cgWindows.enumerated() {
                    guard info.frame.width > 50, info.frame.height > 50 else { continue }

                    let center = CGPoint(x: info.frame.midX, y: info.frame.midY)
                    guard let monIdx = monitorService.monitorIndex(for: center) else { continue }

                    monitorCounts[monIdx, default: 0] += 1

                    var spaceIdx = 0
                    let spaces = spaceService.spacesForWindow(info.windowID)
                    if let firstSpace = spaces.first,
                       let indices = spaceService.indices(for: firstSpace) {
                        spaceIdx = indices.spaceIndex
                    }

                    windowAssignments.append(WindowAssignment(
                        windowTitle: info.name,
                        windowIndex: index,
                        monitorIndex: monIdx,
                        spaceIndex: spaceIdx
                    ))
                }
            }

            guard !windowAssignments.isEmpty else { continue }

            let primaryMonitor = monitorCounts.max(by: { $0.value < $1.value })?.key ?? 0

            let newAssignment = AppMonitorAssignment(
                bundleIdentifier: bundleID,
                appName: appName,
                monitorIndex: primaryMonitor,
                windows: windowAssignments
            )

            // Check if anything changed before saving
            let existing = assignmentStore.assignment(for: bundleID)
            if existing == nil || assignmentChanged(existing!, newAssignment) {
                assignmentStore.update(assignment: newAssignment)
            }
        }

        lastPoll = Date()
    }

    private func assignmentChanged(_ old: AppMonitorAssignment, _ new: AppMonitorAssignment) -> Bool {
        if old.monitorIndex != new.monitorIndex { return true }
        if old.windows.count != new.windows.count { return true }
        // Check if any window moved monitor or space
        for newWin in new.windows {
            if let oldWin = old.windows.first(where: { $0.windowIndex == newWin.windowIndex }) {
                if oldWin.monitorIndex != newWin.monitorIndex || oldWin.spaceIndex != newWin.spaceIndex {
                    return true
                }
            } else {
                return true
            }
        }
        return false
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

    // MARK: - CGWindowList fallback

    private struct CGWindowInfo {
        let windowID: CGWindowID
        let name: String
        let frame: CGRect
    }

    /// Get window info via CGWindowListCopyWindowInfo for a given PID.
    /// Used as fallback when AXUIElement access is blocked (e.g. Teams returns -25211).
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

            // Skip windows at layer != 0 (menus, tooltips, etc.)
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }

            let name = info[kCGWindowName as String] as? String ?? ""
            let frame = CGRect(x: x, y: y, width: w, height: h)
            results.append(CGWindowInfo(windowID: windowID, name: name, frame: frame))
        }
        return results
    }
}
