import SwiftUI

struct NodeDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
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
                    nodeActionsSection

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
        .task(id: node.node) {
            await model.load(service: appState.service, node: node)
            await model.refreshLoop(service: appState.service, node: node)
        }
        .onDisappear {
            model.stopRefresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task {
                    await model.load(service: appState.service, node: node)
                    await model.refreshLoop(service: appState.service, node: node)
                }
            } else if phase == .background {
                model.stopRefresh()
            }
        }
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
        Section {
            // PVE returns node CPU utilization as a 0...1 fraction.
            let rawCPU = model.status?.cpu ?? node.cpu
            let cpuFraction = rawCPU.map { min(max($0, 0), 1) } ?? 0

            let memoryUsed = model.status?.memory?.used ?? node.mem
            let memoryTotal = model.status?.memory?.total ?? node.maxmem
            let diskUsed = model.status?.rootfs?.used ?? node.disk
            let diskTotal = model.status?.rootfs?.total ?? node.maxdisk

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                if rawCPU != nil {
                    ResourceCard(
                        title: "CPU",
                        value: cpuFraction.asPercent,
                        systemImage: "cpu",
                        fraction: cpuFraction
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

            LabeledContent("Status", value: localizedProxmoxStatus(node.status))
            LabeledContent("Uptime", value: (model.status?.uptime ?? node.uptime).formattedUptime)

            if let loadavg = model.status?.loadavg, !loadavg.isEmpty {
                LabeledContent("Load average", value: loadavg.joined(separator: "  "))
            }
        } header: {
            Text("Resources")
        }
    }

    @ViewBuilder
    private var nodeActionsSection: some View {
        Section {
            NavigationLink {
                StorageListView(node: node.node)
            } label: {
                Label("Storage", systemImage: "externaldrive")
            }

            NavigationLink {
                BackupsView(node: node.node)
            } label: {
                Label("Backups", systemImage: "clock.arrow.circlepath")
            }

            NavigationLink {
                RRDChartView(node: node.node)
            } label: {
                Label("Charts", systemImage: "chart.xyaxis.line")
            }
        }
    }

    @ViewBuilder
    private var guestsSection: some View {
        Section {
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
        } header: {
            Text("Guests (\(model.guests.count))")
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
    @Published private(set) var lastUpdated: Date?

    private var refreshTask: Task<Void, Never>?

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

        lastUpdated = Date()
        isLoading = false
    }

    func refreshLoop(service: ProxmoxAPIService?, node: ProxmoxNode) async {
        stopRefresh()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await load(service: service, node: node)
            }
        }
    }

    func stopRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
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
