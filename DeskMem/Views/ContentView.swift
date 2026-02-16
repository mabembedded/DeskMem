import SwiftUI

struct ContentView: View {
    @EnvironmentObject var monitorService: MonitorService
    @EnvironmentObject var assignmentStore: AssignmentStore
    @EnvironmentObject var windowWatcher: WindowWatcher
    @EnvironmentObject var windowMover: WindowMover

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var expandedApps: Set<String> = []
    @State private var showQuitApps = false
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !accessibilityGranted {
                PermissionPromptView()
            } else {
                statusBar
                Divider()
                monitorInfo
                    .padding()
                Divider()
                assignmentsList
            }
        }
        .frame(minWidth: 520, minHeight: 450)
        .onReceive(permissionTimer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
            Text("Monitoring active")
                .font(.caption)

            Spacer()

            if windowMover.isRestoring {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Text(windowMover.lastRestore)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var monitorInfo: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(monitorService.screenCount) Monitor(s) Connected")
                    .font(.headline)

                if monitorService.screenCount >= 2 {
                    HStack(spacing: 12) {
                        ForEach(Array(monitorService.screens.enumerated()), id: \.offset) { index, screen in
                            HStack(spacing: 4) {
                                Image(systemName: monitorService.arrangement == .vertical
                                    ? (index == 0 ? "rectangle.bottomhalf.filled" : "rectangle.tophalf.filled")
                                    : (index == 0 ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled"))
                                    .foregroundColor(index == 0 ? .blue : .purple)
                                Text("\(monitorService.label(for: index)): \(Int(screen.frame.width))x\(Int(screen.frame.height))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Text("Arrangement: \(monitorService.arrangement == .vertical ? "Stacked (Bottom/Top)" : "Side by side (Left/Right)")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Restore Now") {
                windowMover.restoreAll()
            }
            .disabled(monitorService.screenCount < 2)
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private var assignmentsList: some View {
        List {
            let assignments = assignmentStore.allAssignments()
            let filtered = showQuitApps ? assignments : assignments.filter { isRunning($0.bundleIdentifier) }
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No apps tracked yet")
                        .font(.headline)
                    Text("Arrange your apps across monitors and desktops.\nDeskMem will learn their positions automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ForEach(filtered) { assignment in
                    let running = isRunning(assignment.bundleIdentifier)
                    appRow(assignment)
                        .opacity(running ? 1.0 : 0.5)
                }
            }
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle("Show quit apps", isOn: $showQuitApps)
                    .toggleStyle(.checkbox)
            }
            ToolbarItem(placement: .automatic) {
                Button("Clear All") {
                    assignmentStore.clearAll()
                }
                .disabled(assignmentStore.allAssignments().isEmpty)
            }
        }
    }

    private func appRow(_ assignment: AppMonitorAssignment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: assignment.bundleIdentifier).first,
                   let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.fill")
                        .frame(width: 24, height: 24)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading) {
                    Text(assignment.appName)
                        .font(.body.weight(.medium))
                }

                Spacer()

                // Monitor badge
                Text(monitorService.label(for: assignment.monitorIndex))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        assignment.monitorIndex == 0
                            ? Color.blue.opacity(0.15)
                            : Color.purple.opacity(0.15)
                    )
                    .cornerRadius(6)

                // Window count + expand toggle
                if assignment.windows.count > 0 {
                    Button {
                        if expandedApps.contains(assignment.bundleIdentifier) {
                            expandedApps.remove(assignment.bundleIdentifier)
                        } else {
                            expandedApps.insert(assignment.bundleIdentifier)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text("\(assignment.windows.count)")
                                .font(.caption)
                            Image(systemName: expandedApps.contains(assignment.bundleIdentifier) ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(role: .destructive) {
                    assignmentStore.remove(bundleID: assignment.bundleIdentifier)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)

            // Expanded window details
            if expandedApps.contains(assignment.bundleIdentifier) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(assignment.windows.enumerated()), id: \.element.hashValue) { _, win in
                        HStack(spacing: 6) {
                            Image(systemName: "macwindow")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(win.windowTitle.isEmpty ? "Untitled" : win.windowTitle)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(monitorService.label(for: win.monitorIndex)) - Desktop \(win.spaceIndex + 1)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, 32)
                .padding(.vertical, 4)
            }
        }
    }
}
