import SwiftUI

struct NodeDetailView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = NodeDetailViewModel()

    let node: ProxmoxNode

    var body: some View {
        Group {
            if model.isLoading && model.status == nil && model.guests.isEmpty {
                ProgressView("Loading node…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error, model.status == nil && model.guests.isEmpty {
                ErrorStateView(message: error) {
                    Task { await model.load(service: appState.service, node: node) }
                }
            } else {
                List {
                    overviewSection
                    guestsSection

                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(node.node)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(service: appState.service, node: node) }
        .task(id: node.node) { await model.load(service: appState.service, node: node) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.isLoading {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private var overviewSection: some View {
        Section("Resources") {
            let cpu = model.status?.cpu ?? node.cpu
            let memoryUsed = model.status?.memory?.used ?? node.mem
            let memoryTotal = model.status?.memory?.total ?? node.maxmem
            let diskUsed = model.status?.rootfs?.used ?? node.disk
            let diskTotal = model.status?.rootfs?.total ?? node.maxdisk

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                if let cpu {
                    ResourceCard(
                        title: "CPU",
                        value: cpu.asPercent,
                        systemImage: "cpu",
                        fraction: cpu
                    )
                }

                if let memoryUsed, let memoryTotal, memoryTotal > 0 {
                    ResourceCard(
                        title: "Memory",
                        value: memoryUsed.formattedBytes,
                        subtitle: "of \(memoryTotal.formattedBytes)",
                        systemImage: "memorychip",
                        fraction: Double(memoryUsed) / Double(memoryTotal)
                    )
                }

                if let diskUsed, let diskTotal, diskTotal > 0 {
                    ResourceCard(
                        title: "Root disk",
                        value: diskUsed.formattedBytes,
                        subtitle: "of \(diskTotal.formattedBytes)",
                        systemImage: "internaldrive",
                        fraction: Double(diskUsed) / Double(diskTotal)
                    )
                }
            }
            .listRowInsets(EdgeInsets())
            .padding(.vertical, 4)

            LabeledContent("Status", value: node.status.capitalized)
            LabeledContent("Uptime", value: (model.status?.uptime ?? node.uptime).formattedUptime)

            if let loadavg = model.status?.loadavg, !loadavg.isEmpty {
                LabeledContent("Load average", value: loadavg.joined(separator: "  "))
            }
        }
    }

    @ViewBuilder
    private var guestsSection: some View {
        Section("Guests (\(model.guests.count))") {
            if model.guests.isEmpty {
                Text("No VMs or containers are assigned to this node.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.guests) { guest in
                    NavigationLink {
                        VMDetailView(guest: guest)
                    } label: {
                        NodeGuestRow(guest: guest)
                    }
                }
            }
        }
    }
}

private struct NodeGuestRow: View {
    let guest: ProxmoxVM

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(status: guest.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.displayName)
                Text("\(guest.type.label) \(guest.vmid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if guest.isRunning, let cpu = guest.cpu {
                Text(cpu.asPercent)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class NodeDetailViewModel: ObservableObject {
    @Published private(set) var status: NodeStatus?
    @Published private(set) var guests: [ProxmoxVM] = []
    @Published var isLoading = false
    @Published var error: String?

    func load(service: ProxmoxAPIService?, node: ProxmoxNode) async {
        guard let service else { return }
        isLoading = true
        error = nil

        do {
            status = try await service.fetchNodeStatus(node: node.node)
        } catch {
            self.error = error.localizedDescription
        }

        do {
            guests = try await service.fetchGuests(node: node.node)
        } catch {
            if self.error == nil {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }
}

#Preview {
    NavigationStack {
        NodeDetailView(node: ProxmoxNode(
            node: "pve1",
            status: "online",
            cpu: 0.42,
            maxcpu: 8,
            mem: 6_000_000_000,
            maxmem: 16_000_000_000,
            disk: 80_000_000_000,
            maxdisk: 256_000_000_000,
            uptime: 90_000,
            level: nil
        ))
    }
    .environmentObject(AppState())
}
