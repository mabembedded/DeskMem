import AppKit
import Combine

/// Tracks connected monitors sorted by position.
/// Handles both horizontal (left/right) and vertical (bottom/top) arrangements.
class MonitorService: ObservableObject {
    @Published var screens: [NSScreen] = []
    @Published var screenCount: Int = 0
    @Published var arrangement: Arrangement = .horizontal

    enum Arrangement {
        case horizontal  // side by side
        case vertical    // stacked
    }

    private var cancellable: AnyCancellable?

    init() {
        updateScreens()

        cancellable = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.updateScreens()
            }
    }

    private func updateScreens() {
        let allScreens = NSScreen.screens
        guard allScreens.count >= 2 else {
            screens = allScreens
            screenCount = allScreens.count
            arrangement = .horizontal
            return
        }

        // Determine arrangement by checking how much the screens overlap in each axis.
        // Stacked monitors overlap significantly in x. Side-by-side monitors overlap in y.
        // This handles offset stacking (e.g., smaller monitor centered or right-aligned above a wider one).
        let frames = allScreens.map { $0.frame }

        // For 2 monitors: check overlap between them
        let a = frames[0]
        let b = frames[1]

        let xOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let yOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))

        // Normalize overlap by the smaller screen's dimension
        let xOverlapRatio = xOverlap / min(a.width, b.width)
        let yOverlapRatio = yOverlap / min(a.height, b.height)

        if xOverlapRatio > yOverlapRatio {
            arrangement = .vertical
            // In Cocoa coords, higher y = higher on screen. We want index 0 = bottom.
            screens = allScreens.sorted { $0.frame.origin.y < $1.frame.origin.y }
        } else {
            arrangement = .horizontal
            // Sort left-to-right (lower x = index 0 = left)
            screens = allScreens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        }

        screenCount = screens.count
    }

    /// Returns the monitor index for a point in CG/AX coordinate space (top-left origin, y increases downward).
    /// NSScreen.frame uses Cocoa coordinates (bottom-left origin, y increases upward), so we convert.
    func monitorIndex(for cgPoint: CGPoint) -> Int? {
        for (index, screen) in screens.enumerated() {
            if cgFrame(for: screen).contains(cgPoint) {
                return index
            }
        }
        return nil
    }

    /// Returns the monitor frame in CG coordinate space (top-left origin) for use with AXUIElement.
    func frame(for monitorIndex: Int) -> CGRect? {
        guard monitorIndex >= 0, monitorIndex < screens.count else { return nil }
        return cgFrame(for: screens[monitorIndex])
    }

    /// Convert an NSScreen frame (Cocoa coords: bottom-left origin) to CG coords (top-left origin).
    /// AXUIElement positions use CG coordinates, so all comparisons must use this.
    private func cgFrame(for screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgY = mainHeight - screen.frame.origin.y - screen.frame.height
        return CGRect(x: screen.frame.origin.x, y: cgY, width: screen.frame.width, height: screen.frame.height)
    }

    /// Human-readable label for a monitor index.
    func label(for monitorIndex: Int) -> String {
        guard monitorIndex >= 0, monitorIndex < screens.count else { return "Unknown" }
        if screens.count == 2 {
            switch arrangement {
            case .vertical:
                return monitorIndex == 0 ? "Bottom" : "Top"
            case .horizontal:
                return monitorIndex == 0 ? "Left" : "Right"
            }
        }
        return "Monitor \(monitorIndex + 1)"
    }
}
