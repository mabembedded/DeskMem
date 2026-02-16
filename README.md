# DeskMem

A macOS app that remembers which monitor and desktop each app belongs on, and automatically restores them when your display configuration changes.

## The Problem

If you use multiple monitors at different locations (e.g., office and home), macOS scrambles your window positions every time you dock or undock. Apps that were on your second monitor get dumped onto your primary display, and windows move between desktops.

## How It Works

1. **Watches** your running apps every 5 seconds, tracking which monitor and desktop (Space) each window is on
2. **Learns** automatically — just arrange your apps the way you like them
3. **Restores** windows to their correct monitor and desktop when displays change

Monitors are identified by position (bottom/top or left/right), so it works across different physical monitors at different locations.

## Features

- Automatic monitoring — no manual configuration needed
- Supports vertical (stacked) and horizontal (side-by-side) monitor arrangements
- Tracks per-window desktop (Space) assignments
- Auto-restores on display connect/disconnect with 3-second debounce
- Manual "Restore Now" button for on-demand restore
- Persists assignments across app restarts

## Requirements

- macOS 13.0+
- Accessibility permission (prompted on first launch)

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project DeskMem.xcodeproj -scheme DeskMem -configuration Debug build
```

Or open `DeskMem.xcodeproj` in Xcode and hit Run.

## Installing

Copy the built app to Applications:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/DeskMem-*/Build/Products/Debug/DeskMem.app /Applications/
```

Grant Accessibility permission in System Settings > Privacy & Security > Accessibility.

To launch at login: System Settings > General > Login Items > add DeskMem.

## How Data Is Stored

Assignments are saved as JSON at:

```
~/Library/Application Support/DeskMem/assignments.json
```

## Technical Notes

- Uses the Accessibility API (`AXUIElement`) to read and set window positions
- Uses private CoreGraphics APIs (`CGSCopyManagedDisplaySpaces`, `CGSAddWindowsToSpaces`, etc.) for desktop/Space tracking and restoration — the same APIs used by [yabai](https://github.com/koekeishiya/yabai) and [Amethyst](https://github.com/ianyh/Amethyst)
- Cannot be sandboxed (Accessibility API requirement), so it must be distributed outside the Mac App Store
- The private Space APIs may break with future macOS updates
