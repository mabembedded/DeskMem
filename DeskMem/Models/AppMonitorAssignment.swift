import Foundation

/// Tracks where a single window should be: which monitor and which desktop (space).
struct WindowAssignment: Codable, Hashable {
    let windowTitle: String
    let windowIndex: Int
    var monitorIndex: Int   // 0 = bottom/left, 1 = top/right
    var spaceIndex: Int     // 0-based desktop index on that monitor
}

/// All tracked window assignments for an app.
struct AppMonitorAssignment: Codable, Identifiable {
    let bundleIdentifier: String
    let appName: String
    var monitorIndex: Int       // Primary monitor (where most windows are)
    var windows: [WindowAssignment]

    var id: String { bundleIdentifier }
}

struct AssignmentDatabase: Codable {
    var assignments: [String: AppMonitorAssignment] = [:]  // keyed by bundleID
}
