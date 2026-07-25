import SwiftUI

/// Lists the cluster's nodes with live CPU / memory / uptime, backed by
/// `/nodes`. Pull to refresh; auto-loads on appear.
struct NodesView: View {
    @EnvironmentObject private var appState: AppState
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
                        NodeRow(node: node)
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
            .task { await model.load(service: appState.service) }
        }
    }
}

private struct NodeRow: View {
    let node: ProxmoxNode

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

            if let cpu = node.cpu {
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

    func load(service: ProxmoxAPIService?) async {
        guard let service = service else { return }
        isLoading = true
        error = nil
        do {
            nodes = try await service.fetchNodes()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    NodesView()
        .environmentObject(AppState())
}
