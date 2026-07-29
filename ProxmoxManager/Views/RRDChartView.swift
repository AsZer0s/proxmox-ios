import SwiftUI

/// Historical CPU / memory / disk / network charts from RRD data.
/// Uses a native SwiftUI Canvas-based line chart with gradient fill.
struct RRDChartView: View {
    @EnvironmentObject private var appState: AppState
    @State private var dataPoints: [RRDDataPoint] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedTimeframe = "hour"
    @State private var selectedMetric = "cpu"

    let node: String
    var guest: (type: GuestType, vmid: Int)? = nil

    private let timeframes = ["hour", "day", "week"]
    private let metrics = ["cpu", "memory", "network", "disk"]

    private var metricLabel: String {
        switch selectedMetric {
        case "cpu": return "CPU"
        case "memory": return "Memory"
        case "network": return "Network I/O"
        case "disk": return "Disk I/O"
        default: return selectedMetric
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Timeframe picker
            Picker("Timeframe", selection: $selectedTimeframe) {
                ForEach(timeframes, id: \.self) { tf in
                    Text(tf.capitalized).tag(tf)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // Metric picker
            Picker("Metric", selection: $selectedMetric) {
                ForEach(metrics, id: \.self) { m in
                    Text(metricDisplayName(m)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // Chart area
            Group {
                if isLoading && dataPoints.isEmpty {
                    ProgressView("Loading data…")
                        .frame(maxHeight: .infinity)
                } else if let error, dataPoints.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await load() }
                    }
                } else if dataPoints.isEmpty {
                    ContentUnavailableCompat(
                        title: "No Data",
                        systemImage: "chart.xyaxis.line",
                        description: "No RRD data available for this timeframe."
                    )
                } else {
                    chartContent
                }
            }
        }
        .navigationTitle(metricLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedTimeframe) { await load() }
    }

    @ViewBuilder
    private var chartContent: some View {
        let values = chartValues()
        let maxValue = values.max() ?? 1
        let minValue: Double = 0

        VStack(spacing: 8) {
            // Line chart canvas
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height - 20
                let chartWidth = width - 16  // padding

                ZStack(alignment: .topLeading) {
                    // Grid lines
                    ForEach(0..<5, id: \.self) { i in
                        let y = height * Double(i) / 4
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: width, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)

                        Text(formattedGridValue(maxValue * (1 - Double(i) / 4)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .position(x: width - 30, y: y)
                    }

                    // Line path
                    if values.count > 1 {
                        let stepX = chartWidth / Double(values.count - 1)
                        let range = max(maxValue - minValue, 0.001)

                        // Gradient fill
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: height))
                            for (i, val) in values.enumerated() {
                                let x = Double(i) * stepX
                                let y = height - (val - minValue) / range * height
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                            path.addLine(to: CGPoint(x: Double(values.count - 1) * stepX, y: height))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [chartColor(0.5).opacity(0.3), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        // Line stroke
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: height - (values[0] - minValue) / range * height))
                            for (i, val) in values.enumerated() {
                                let x = Double(i) * stepX
                                let y = height - (val - minValue) / range * height
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        .stroke(chartColor(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }

                    // Time labels
                    HStack {
                        if let first = dataPoints.first {
                            Text(formattedTime(for: 0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if dataPoints.count > 1 {
                            Text(formattedTime(for: dataPoints.count - 1))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, height + 4)
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 220)

            // Legend / stats
            HStack(spacing: 16) {
                Label(
                    "Avg: \(formattedValue(chartAverage(values)))",
                    systemImage: "circle.fill"
                )
                .font(.caption)
                .foregroundStyle(chartColor(0.5))

                Label(
                    "Max: \(formattedValue(maxValue))",
                    systemImage: "circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        do {
            if let guest {
                dataPoints = try await service.fetchGuestRRDData(
                    node: node, type: guest.type, vmid: guest.vmid,
                    timeframe: selectedTimeframe
                )
            } else {
                dataPoints = try await service.fetchRRDData(
                    node: node, timeframe: selectedTimeframe
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func chartValues() -> [Double] {
        dataPoints.map { dp in
            switch selectedMetric {
            case "cpu": return dp.cpu ?? 0
            case "memory": return dp.mem ?? 0  // absolute byte value
            case "network": return (dp.netin ?? 0) + (dp.netout ?? 0)
            case "disk": return (dp.diskread ?? 0) + (dp.diskwrite ?? 0)
            default: return dp.value ?? 0
            }
        }
    }

    private func chartAverage(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func formattedValue(_ val: Double) -> String {
        switch selectedMetric {
        case "cpu":
            // RRD cpu for node is fraction 0-1, for guest is fraction 0-1
            return String(format: "%.1f%%", val * 100)
        case "memory":
            return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .memory)
        case "network":
            return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .binary)
        case "disk":
            return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .binary)
        default:
            return String(format: "%.1f", val)
        }
    }

    private func formattedGridValue(_ val: Double) -> String {
        switch selectedMetric {
        case "cpu":
            return String(format: "%.0f%%", val * 100)
        case "memory", "network", "disk":
            return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .binary)
        default:
            return String(format: "%.1f", val)
        }
    }

    private func formattedTime(for index: Int) -> String {
        guard index < dataPoints.count else { return "" }
        let time = dataPoints[index].time
        let date = Date(timeIntervalSince1970: Double(time))
        let formatter = DateFormatter()
        formatter.dateFormat = selectedTimeframe == "hour" ? "HH:mm" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func chartColor(_ fraction: Double) -> Color {
        fraction > 0.8 ? .red : fraction > 0.5 ? .orange : .blue
    }

    private func metricDisplayName(_ m: String) -> String {
        switch m {
        case "cpu": return "CPU"
        case "memory": return "Memory"
        case "network": return "Network"
        case "disk": return "Disk"
        default: return m
        }
    }
}

#Preview {
    NavigationStack {
        RRDChartView(node: "pve")
            .environmentObject(AppState())
    }
}
