import Foundation

/// Persists app-to-monitor/space assignments as JSON in Application Support.
class AssignmentStore: ObservableObject {
    @Published var database: AssignmentDatabase

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("DeskMem", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        self.fileURL = appDir.appendingPathComponent("assignments.json")

        if let data = try? Data(contentsOf: fileURL),
           let db = try? JSONDecoder().decode(AssignmentDatabase.self, from: data) {
            self.database = db
        } else {
            self.database = AssignmentDatabase()
        }
    }

    func update(assignment: AppMonitorAssignment) {
        database.assignments[assignment.bundleIdentifier] = assignment
        persist()
    }

    func assignment(for bundleID: String) -> AppMonitorAssignment? {
        database.assignments[bundleID]
    }

    func allAssignments() -> [AppMonitorAssignment] {
        Array(database.assignments.values).sorted { $0.appName < $1.appName }
    }

    func remove(bundleID: String) {
        database.assignments.removeValue(forKey: bundleID)
        persist()
    }

    func clearAll() {
        database.assignments.removeAll()
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(database) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
