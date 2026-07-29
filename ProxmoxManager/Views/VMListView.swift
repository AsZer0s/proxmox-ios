import SwiftUI

/// Lists every VM and container across all nodes, backed by
/// `/cluster/resources`. Tapping a guest opens its detail/control screen.
struct VMListView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = VMListViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.guests.isEmpty {
                    ProgressView("Loading guests…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error, model.guests.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await model.load(service: appState.service) }
                    }
                } else if model.guests.isEmpty {
                    ContentUnavailableCompat(
                        title: "No Guests",
                        systemImage: "square.stack.3d.up",
                        description: "No VMs or containers were found."
                    )
                } else {
                    List {
                        ForEach(GuestType.allCases, id: \.self) { type in
                            let items = model.guests(ofType: type)
                            if !items.isEmpty {
                                Section(type == .qemu ? "Virtual Machines" : "Containers") {
                                    ForEach(items) { guest in
                                        NavigationLink {
                                            VMDetailView(guest: guest)
                                        } label: {
                                            GuestRow(guest: guest)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("VMs & CTs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let lastUpdated = model.lastUpdated {
                        Text(lastUpdated, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable { await model.load(service: appState.service) }
            .task {
                await model.load(service: appState.service)
                await model.refreshLoop(service: appState.service)
            }
        }
    }
}

private struct GuestRow: View {
    let guest: ProxmoxVM

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(status: guest.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.displayName)
                    .font(.body)
                Text("\(guest.type.label) \(guest.vmid) · \(guest.node)")
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
        .padding(.vertical, 4)
    }
}

@MainActor
final class VMListViewModel: ObservableObject {
    @Published private(set) var guests: [ProxmoxVM] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var lastUpdated: Date?

    func guests(ofType type: GuestType) -> [ProxmoxVM] {
        guests.filter { $0.type == type }
    }

    func load(service: ProxmoxAPIService?) async {
        guard let service = service else { return }
        isLoading = true
        error = nil
        do {
            let resources = try await service.fetchClusterResources()
            let guestResources = resources.filter { $0.type == .qemu || $0.type == .lxc }
            self.guests = guestResources.compactMap { res in
                guard let vmid = res.vmid, let node = res.node else { return nil }
                var vm = ProxmoxVM(
                    vmid: vmid,
                    name: res.name,
                    status: res.status ?? "unknown",
                    cpu: res.cpu,
                    cpus: res.maxcpu,
                    mem: res.mem,
                    maxmem: res.maxmem,
                    disk: res.disk,
                    maxdisk: res.maxdisk,
                    uptime: res.uptime
                )
                vm.node = node
                vm.type = res.type == .lxc ? .lxc : .qemu
                return vm
            }
            .sorted { $0.vmid < $1.vmid }
            lastUpdated = Date()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func refreshLoop(service: ProxmoxAPIService?) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await load(service: service)
        }
    }
}

#Preview {
    VMListView()
        .environmentObject(AppState())
}
