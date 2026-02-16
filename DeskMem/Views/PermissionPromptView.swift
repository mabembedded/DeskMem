import SwiftUI

struct PermissionPromptView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Accessibility Permission Required")
                .font(.title2.weight(.semibold))

            Text("DeskMem needs Accessibility access to read and move window positions for other applications.\n\nGo to System Settings > Privacy & Security > Accessibility, then enable DeskMem.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button("Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: 400)
    }
}
