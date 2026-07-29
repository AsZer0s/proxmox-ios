import SwiftUI

/// A labeled horizontal usage bar with a trailing detail string, used for
/// CPU / memory / disk metrics on the node and guest screens.
struct MetricBar: View {
    let label: String
    /// 0...1 fraction.
    let value: Double
    /// Trailing detail text, e.g. "1.5 GB / 4 GB".
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1))
                .tint(barColor(for: value))
        }
    }

    private func barColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

/// Full-screen error state with a retry button, shown when a screen's initial
/// load fails and there is no cached data to display.
struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Empty-state placeholder using a hand-rolled layout for iOS 16 compatibility.
struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    VStack(spacing: 24) {
        MetricBar(label: "CPU", value: 0.42, detail: "42.0%")
        MetricBar(label: "Memory", value: 0.88, detail: "7 GB / 8 GB")
        ErrorStateView(message: "Could not reach the server.") {}
    }
    .padding()
}
