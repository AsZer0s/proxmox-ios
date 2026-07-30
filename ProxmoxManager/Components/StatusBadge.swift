import SwiftUI

/// A small colored pill showing a running/stopped/online status string.
struct StatusBadge: View {
    let status: String?

    private var text: String {
        localizedProxmoxStatus(status)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.forStatus(status))
                .frame(width: 7, height: 7)
            Text(text.capitalized)
                .font(.caption2.weight(.medium))
                .foregroundColor(Color.forStatus(status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.forStatus(status).opacity(0.12))
        )
    }
}

func localizedProxmoxStatus(_ status: String?) -> String {
    switch status?.lowercased() {
    case "running": return String(localized: "Running")
    case "stopped": return String(localized: "Stopped")
    case "paused": return String(localized: "Paused")
    case "online": return String(localized: "Online")
    case "offline": return String(localized: "Offline")
    case .some(let value) where !value.isEmpty: return value.capitalized
    default: return String(localized: "Unknown")
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusBadge(status: "running")
        StatusBadge(status: "stopped")
        StatusBadge(status: "paused")
        StatusBadge(status: nil)
    }
    .padding()
}
