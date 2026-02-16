import AppKit
import CoreGraphics

// MARK: - Private CoreGraphics Space APIs
// Used by tools like yabai and Amethyst. May break with macOS updates.

private typealias CGSConnectionID = UInt32
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: CGSConnectionID) -> CFArray

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: CGSConnectionID, _ mask: Int, _ windowIDs: CFArray) -> CFArray

@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ connection: CGSConnectionID, _ windowIDs: CFArray, _ spaceID: CGSSpaceID)

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ connection: CGSConnectionID, _ windowIDs: CFArray, _ spaceIDs: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ connection: CGSConnectionID, _ windowIDs: CFArray, _ spaceIDs: CFArray)

/// Provides access to macOS Spaces (virtual desktops) via private APIs.
class SpaceService {
    private let connection: CGSConnectionID

    init() {
        connection = _CGSDefaultConnection()
    }

    /// Get the space ID(s) a window is currently on.
    func spacesForWindow(_ windowID: CGWindowID) -> [UInt64] {
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        // mask 0x7 = all space types (user, fullscreen, system)
        guard let spaces = CGSCopySpacesForWindows(connection, 0x7, windowIDs) as? [UInt64] else {
            return []
        }
        return spaces
    }

    /// Get all space IDs organized by display.
    /// Returns an array of displays, each containing an array of (spaceID, index) pairs.
    func allSpaces() -> [DisplaySpaces] {
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else {
            return []
        }

        var result: [DisplaySpaces] = []
        for displayInfo in displaySpaces {
            let displayUUID = displayInfo["Display Identifier"] as? String ?? "unknown"
            guard let spaces = displayInfo["Spaces"] as? [[String: Any]] else { continue }

            var spaceIDs: [UInt64] = []
            for space in spaces {
                if let id = space["id64"] as? UInt64 {
                    spaceIDs.append(id)
                } else if let id = space["ManagedSpaceID"] as? Int {
                    spaceIDs.append(UInt64(id))
                }
            }

            let currentSpaceID: UInt64? = {
                if let current = displayInfo["Current Space"] as? [String: Any] {
                    if let id = current["id64"] as? UInt64 { return id }
                    if let id = current["ManagedSpaceID"] as? Int { return UInt64(id) }
                }
                return nil
            }()

            result.append(DisplaySpaces(
                displayUUID: displayUUID,
                spaceIDs: spaceIDs,
                currentSpaceID: currentSpaceID
            ))
        }
        return result
    }

    /// Move a window to a specific space.
    func moveWindow(_ windowID: CGWindowID, toSpace targetSpaceID: UInt64) {
        let windowIDs = [NSNumber(value: windowID)] as CFArray

        // Remove from current spaces, then add to target
        let currentSpaces = spacesForWindow(windowID)
        if !currentSpaces.isEmpty {
            let currentSpaceIDs = currentSpaces.map { NSNumber(value: $0) } as CFArray
            CGSRemoveWindowsFromSpaces(connection, windowIDs, currentSpaceIDs)
        }

        let targetSpaceIDs = [NSNumber(value: targetSpaceID)] as CFArray
        CGSAddWindowsToSpaces(connection, windowIDs, targetSpaceIDs)
    }

    /// Resolve the space index (0-based within a display) to a space ID.
    /// displayIndex: which display (matching MonitorService ordering)
    /// spaceIndex: which desktop on that display (0-based)
    func spaceID(displayIndex: Int, spaceIndex: Int) -> UInt64? {
        let displays = allSpaces()
        guard displayIndex >= 0, displayIndex < displays.count else { return nil }
        let spaces = displays[displayIndex].spaceIDs
        guard spaceIndex >= 0, spaceIndex < spaces.count else { return nil }
        return spaces[spaceIndex]
    }

    /// Convert a space ID back to (displayIndex, spaceIndex).
    func indices(for spaceID: UInt64) -> (displayIndex: Int, spaceIndex: Int)? {
        let displays = allSpaces()
        for (di, display) in displays.enumerated() {
            if let si = display.spaceIDs.firstIndex(of: spaceID) {
                return (di, si)
            }
        }
        return nil
    }
}

struct DisplaySpaces {
    let displayUUID: String
    let spaceIDs: [UInt64]
    let currentSpaceID: UInt64?
}

// MARK: - Get CGWindowID from AXUIElement

/// Extract the CGWindowID from an AXUIElement window.
/// Uses the CGWindowList API to match by PID + position + size.
func cgWindowID(for axWindow: AXUIElement, pid: pid_t) -> CGWindowID? {
    // Try to get position and size from the AXUIElement
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success
    else { return nil }

    var axPosition = CGPoint.zero
    var axSize = CGSize.zero
    AXValueGetValue(positionRef as! AXValue, .cgPoint, &axPosition)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)

    // Get all windows for this PID from CGWindowList
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    for windowInfo in windowList {
        guard let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
              windowPID == pid,
              let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat,
              let h = bounds["Height"] as? CGFloat,
              let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID
        else { continue }

        // Match by position and size (with small tolerance for rounding)
        if abs(x - axPosition.x) < 2, abs(y - axPosition.y) < 2,
           abs(w - axSize.width) < 2, abs(h - axSize.height) < 2 {
            return windowID
        }
    }

    return nil
}
