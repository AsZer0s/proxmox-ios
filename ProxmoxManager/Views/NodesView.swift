import SwiftUI

/// Lists the cluster's nodes with live CPU / memory / uptime, backed by
/// `/nodes`. Pull to refresh; auto-loads on appear with 30s foreground refresh.
struct NodesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = NodesViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.nodes.isEmpty {
                    ProgressView("Loading nodes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error, model.nodes.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await model.load(service: appState.service) }
                    }
                } else if model.nodes.isEmpty {
                    ContentUnavailableCompat(
                        title: "No Nodes",
                        systemImage: "server.rack",
                        description: "This cluster reported no nodes."
                    )
                } else {
                    List(model.nodes) { node in
                        NavigationLink {
                            NodeDetailView(node: node)
                        } label: {
                            NodeRow(node: node)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Nodes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.isLoading && !model.nodes.isEmpty {
                        ProgressView()
                    }
                }
            }
            .refreshable { await model.load(service: appState.service) }
            .task {
                await model.load(service: appState.service)
                await model.refreshLoop(service: appState.service)
            }
            .onDisappear {
                model.stopRefresh()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await model.load(service: appState.service)
                        await model.refreshLoop(service: appState.service)
                    }
                } else if phase == .background {
                    model.stopRefresh()
                }
            }
        }
    }
}

private struct NodeRow: View {
    let node: ProxmoxNode

    /// PVE reports CPU utilization as a 0...1 fraction for the whole node.
    private var cpuFraction: Double? {
        node.cpuFraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(status: node.status)
                Text(node.node)
                    .font(.headline)
                Spacer()
                Text(node.uptime.formattedUptime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let cpu = cpuFraction {
                MetricBar(label: "CPU", value: cpu, detail: cpu.asPercentDetailed)
            }

            if let used = node.mem, let total = node.maxmem, total > 0 {
                MetricBar(
                    label: "Memory",
                    value: Double(used) / Double(total),
                    detail: "\(used.formattedBytes) / \(total.formattedBytes)"
                )
            }

            if let used = node.disk, let total = node.maxdisk, total > 0 {
                MetricBar(
                    label: "Disk",
                    value: Double(used) / Double(total),
                    detail: "\(used.formattedBytes) / \(total.formattedBytes)"
                )
            }
        }
        .padding(.vertical, 6)
    }
}

@MainActor
final class NodesViewModel: ObservableObject {
    @Published var nodes: [ProxmoxNode] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var lastUpdated: Date?

    private var refreshTask: Task<Void, Never>?

    func load(service: ProxmoxAPIService?) async {
        guard let service = service else { return }
        isLoading = true
        error = nil
        do {
            nodes = try await service.fetchNodes()
            lastUpdated = Date()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func refreshLoop(service: ProxmoxAPIService?) async {
        stopRefresh()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await load(service: service)
            }
        }
    }

    func stopRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

#Preview {
    NodesView()
        .environmentObject(AppState())
}
