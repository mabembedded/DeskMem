import AppKit
import ApplicationServices
import Combine

/// Polls running apps to detect which monitor and desktop their windows are on.
/// Updates assignments when an app's windows move.
class WindowWatcher: ObservableObject {
    @Published var lastPoll: Date?

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
            guard result == .success, let windows = windowsRef as? [AXUIElement] else { continue }

            var windowAssignments: [WindowAssignment] = []
            var monitorCounts: [Int: Int] = [:]

            for (index, window) in windows.enumerated() {
                guard let frame = windowFrame(window) else { continue }
                guard frame.width > 50, frame.height > 50 else { continue }

                let center = CGPoint(x: frame.midX, y: frame.midY)
                guard let monIdx = monitorService.monitorIndex(for: center) else { continue }

                monitorCounts[monIdx, default: 0] += 1

                // Get the window title
                let title = windowTitle(window) ?? ""

                // Get space index for this window
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
}
