import SwiftUI

/// A card that shows a single metric with an icon, a title, a primary value,
/// and an optional usage bar (0...1 fraction).
struct ResourceCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var systemImage: String
    var fraction: Double? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundColor(tint)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let fraction = fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(barColor(for: fraction))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func barColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ResourceCard(title: "CPU", value: "42%", systemImage: "cpu", fraction: 0.42)
        ResourceCard(title: "Memory", value: "6.1 GB", subtitle: "of 16 GB", systemImage: "memorychip", fraction: 0.38)
    }
    .padding()
}
