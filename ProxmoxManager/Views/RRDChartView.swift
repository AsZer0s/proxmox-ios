import SwiftUI

/// Historical CPU / memory / disk / network charts from RRD data.
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
        .task(id: selectedMetric) { /* visual only */ }
    }

    @ViewBuilder
    private var chartContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Simple bar chart representation using progress bars
                let values = chartValues()
                let maxValue = values.max() ?? 1
                let labelCount = min(values.count, 12)

                ForEach(0..<labelCount, id: \.self) { i in
                    let idx = max(0, values.count - labelCount + i)
                    let val = values[idx]
                    let fraction = maxValue > 0 ? val / maxValue : 0

                    HStack(spacing: 8) {
                        Text(formattedTime(for: idx))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)

                        ProgressView(value: fraction)
                            .tint(chartColor(fraction))

                        Text(formattedValue(val))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
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
            case "memory": return (dp.mem ?? 0) / max(dp.maxmem ?? 1, 1)
            case "network": return (dp.netin ?? 0) + (dp.netout ?? 0)
            case "disk": return (dp.diskread ?? 0) + (dp.diskwrite ?? 0)
            default: return dp.value ?? 0
            }
        }
    }

    private func formattedValue(_ val: Double) -> String {
        switch selectedMetric {
        case "cpu": return "\(Int(val * 100))%"
        case "memory": return "\(Int(val * 100))%"
        case "network": return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .binary)
        case "disk": return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .binary)
        default: return String(format: "%.1f", val)
        }
    }

    private func formattedTime(for index: Int) -> String {
        guard index < dataPoints.count else { return "" }
        let time = dataPoints[index].time
        let date = Date(timeIntervalSince1970: Double(time))
        let formatter = DateFormatter()
        formatter.dateFormat = selectedTimeframe == "hour" ? "HH:mm" : "MM/dd"
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
