import SwiftUI

// MARK: - Line Chart View

/// Reusable line chart component with smooth curves, gradient fill, and
/// axis labels. Renders on a card with rounded corners and shadow.
struct LineChart: View {
    let values: [Double]
    let timeLabels: [String]
    let yLabel: (Double) -> String
    let accentColor: Color

    private let gridLines = 4

    var body: some View {
        let maxVal = values.max() ?? 1
        let minVal: Double = 0
        let range = max(maxVal - minVal, 0.001)

        VStack(alignment: .leading, spacing: 10) {
            // Chart
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack(alignment: .topLeading) {
                    // Horizontal grid + Y labels
                    ForEach(0...gridLines, id: \.self) { i in
                        let y = h * Double(i) / Double(gridLines)
                        let val = maxVal * (1.0 - Double(i) / Double(gridLines))

                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)

                        Text(yLabel(val))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .position(x: w - 5, y: y)
                    }

                    // Line + fill
                    if values.count >= 2 {
                        let stepX = w / Double(values.count - 1)

                        // Fill
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: h))
                            for (i, v) in values.enumerated() {
                                let px = Double(i) * stepX
                                let py = h - ((v - minVal) / range) * h
                                p.addLine(to: CGPoint(x: px, y: py))
                            }
                            p.addLine(to: CGPoint(x: Double(values.count - 1) * stepX, y: h))
                            p.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: accentColor.opacity(0.35), location: 0),
                                    .init(color: accentColor.opacity(0.05), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        // Stroke
                        Path { p in
                            p.move(to: firstPoint(values, stepX, h, range, minVal))
                            for (i, v) in values.enumerated().dropFirst() {
                                let px = Double(i) * stepX
                                let py = h - ((v - minVal) / range) * h
                                p.addLine(to: CGPoint(x: px, y: py))
                            }
                        }
                        .stroke(accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(height: 200)

            // Time axis
            if let first = timeLabels.first, let last = timeLabels.last {
                HStack {
                    Text(first)
                    Spacer()
                    Text(last)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func firstPoint(_ vals: [Double], _ step: Double, _ h: Double, _ range: Double, _ minVal: Double) -> CGPoint {
        let py = h - ((vals[0] - minVal) / range) * h
        return CGPoint(x: 0, y: py)
    }
}

// MARK: - Stat Card

/// Small card with label, value, and optional trend indicator.
struct StatCard: View {
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.08))
        )
    }
}

// MARK: - RRD Chart View

/// Historical CPU / memory / disk / network charts from PVE RRD data.
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

    private var chartColor: Color {
        if let guest {
            return guest.type == .qemu ? .purple : .teal
        }
        return .blue
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Timeframe picker
                Picker("Timeframe", selection: $selectedTimeframe) {
                    ForEach(timeframes, id: \.self) { tf in
                        Text(timeframeLabel(tf)).tag(tf)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Metric picker
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(metrics, id: \.self) { m in
                        Text(metricDisplayName(m)).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Content
                Group {
                    if isLoading && dataPoints.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading data…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
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
                        chartSection
                        statsGrid
                    }
                }

                // Refresh info
                if !dataPoints.isEmpty {
                    HStack {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("\(dataPoints.count) data points")
                            .font(.caption)
                        Spacer()
                        Text(timeframeRangeLabel)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(metricLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let guest {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4) {
                        Image(systemName: guest.type == .qemu ? "desktopcomputer" : "square.grid.2x2")
                            .font(.caption)
                            Text("VM \(guest.vmid)")
                                .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: selectedTimeframe) { await load() }
        .refreshable { await load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var chartSection: some View {
        let values = chartValues()

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(metricLabel)
                    .font(.headline)
                Spacer()
                HStack(spacing: 2) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                    Text(metricUnit)
                }
                .font(.caption2)
                .foregroundStyle(chartColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            LineChart(
                values: values,
                timeLabels: timeAxisLabels(),
                yLabel: { formattedGridValue($0) },
                accentColor: chartColor
            )
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var statsGrid: some View {
        let values = chartValues()

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatCard(
                label: String(localized: "Average"),
                value: formattedValue(chartAverage(values)),
                accent: chartColor
            )
            StatCard(
                label: String(localized: "Maximum"),
                value: formattedValue(values.max() ?? 0),
                accent: .orange
            )
            StatCard(
                label: String(localized: "Current"),
                value: formattedValue(values.last ?? 0),
                accent: .green
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Data

    private var metricUnit: String {
        switch selectedMetric {
        case "cpu": return "%"
        case "memory": return "bytes"
        case "network": return "bytes/s"
        case "disk": return "bytes/s"
        default: return ""
        }
    }

    private var metricLabel: String {
        switch selectedMetric {
        case "cpu": return String(localized: "CPU Usage")
        case "memory": return String(localized: "Memory Usage")
        case "network": return String(localized: "Network I/O")
        case "disk": return String(localized: "Disk I/O")
        default: return selectedMetric
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
            case "cpu": return (dp.cpu ?? 0) * 100  // fraction → percent
            case "memory":
                let total = dp.maxmem ?? 1
                return total > 0 ? (dp.mem ?? 0) / total * 100 : 0  // percentage
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
        case "cpu", "memory":
            return String(format: "%.2f%%", val)
        case "network", "disk":
            return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .binary)
        default:
            return String(format: "%.2f", val)
        }
    }

    private func formattedGridValue(_ val: Double) -> String {
        switch selectedMetric {
        case "cpu", "memory":
            return String(format: "%.2f%%", val)
        case "network", "disk":
            return ByteCountFormatter.string(fromByteCount: Int64(val), countStyle: .binary)
        default:
            return String(format: "%.2f", val)
        }
    }

    private func timeAxisLabels() -> [String] {
        guard !dataPoints.isEmpty else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = selectedTimeframe == "hour" ? "HH:mm" : "MM/dd HH:mm"

        // Show ~5 labels evenly spaced
        let step = max(1, dataPoints.count / 5)
        var labels: [String] = []
        for i in stride(from: 0, to: dataPoints.count, by: step) {
            let t = dataPoints[i].time
            labels.append(formatter.string(from: Date(timeIntervalSince1970: Double(t))))
        }
        // Always include last
        if let last = dataPoints.last {
            let lastLabel = formatter.string(from: Date(timeIntervalSince1970: Double(last.time)))
            if labels.last != lastLabel {
                labels.append(lastLabel)
            }
        }
        return labels
    }

    private func metricDisplayName(_ m: String) -> String {
        switch m {
        case "cpu": return String(localized: "CPU")
        case "memory": return String(localized: "Memory")
        case "network": return String(localized: "Network")
        case "disk": return String(localized: "Disk")
        default: return m
        }
    }

    private func timeframeLabel(_ tf: String) -> String {
        switch tf {
        case "hour": return String(localized: "1h")
        case "day": return String(localized: "24h")
        case "week": return String(localized: "7d")
        default: return tf
        }
    }

    private var timeframeRangeLabel: String {
        switch selectedTimeframe {
        case "hour": return String(localized: "Past hour")
        case "day": return String(localized: "Past day")
        default: return String(localized: "Past week")
        }
    }
}

#Preview {
    NavigationStack {
        RRDChartView(node: "pve")
            .environmentObject(AppState())
    }
}
