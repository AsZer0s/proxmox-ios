import SwiftUI

/// A labeled icon button used for guest control actions (start/stop/etc.).
/// Shows a spinner while its action is in flight and disables itself.
struct ActionButton: View {
    let action: GuestAction
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(height: 22)

                Text(action.label)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(tint.opacity(0.12))
            .foregroundColor(tint)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var tint: Color {
        action.isDestructive ? .red : .accentColor
    }
}

#Preview {
    HStack(spacing: 12) {
        ActionButton(action: .start) {}
        ActionButton(action: .stop) {}
        ActionButton(action: .reboot, isBusy: true) {}
        ActionButton(action: .shutdown, isEnabled: false) {}
    }
    .padding()
}
