import SwiftUI

/// A small colored pill showing a running/stopped/online status string.
struct StatusBadge: View {
    let status: String?

    private var text: String {
        guard let status = status, !status.isEmpty else { return "unknown" }
        return status
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

#Preview {
    VStack(spacing: 12) {
        StatusBadge(status: "running")
        StatusBadge(status: "stopped")
        StatusBadge(status: "paused")
        StatusBadge(status: nil)
    }
    .padding()
}
