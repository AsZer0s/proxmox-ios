import SwiftUI

/// Lists every VM and container across all nodes, backed by
/// `/cluster/resources`. Tapping a guest opens its detail/control screen.
/// Supports search/filter by name, VMID, node, status.
struct VMListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = VMListViewModel()

    @State private var searchText = ""
    @State private var selectedStatus: String?
    @State private var selectedNode: String?
    @State private var showingFilters = false

    private var filteredGuests: [ProxmoxVM] {
        var result = model.guests
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                "\($0.vmid)".contains(searchText) ||
                $0.node.localizedCaseInsensitiveContains(searchText)
            }
        }
        if let status = selectedStatus {
            result = result.filter { $0.status.lowercased() == status.lowercased() }
        }
        if let node = selectedNode {
            result = result.filter { $0.node == node }
        }
        return result
    }

    private var availableNodes: [String] {
        Array(Set(model.guests.map(\.node))).sorted()
    }

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
                            let items = filteredGuests.filter { $0.type == type }
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
                    .searchable(text: $searchText, prompt: "Search by name, VMID, or node")
                }
            }
            .navigationTitle("VMs & CTs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                filterSheet
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

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Status", selection: $selectedStatus) {
                        Text("All").tag(nil as String?)
                        Text("Running").tag("running" as String?)
                        Text("Stopped").tag("stopped" as String?)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Filter by Status")
                }

                if !availableNodes.isEmpty {
                    Section {
                        Picker("Node", selection: $selectedNode) {
                            Text("All").tag(nil as String?)
                            ForEach(availableNodes, id: \.self) { node in
                                Text(node).tag(node as String?)
                            }
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("Filter by Node")
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingFilters = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        selectedStatus = nil
                        selectedNode = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
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

    private var refreshTask: Task<Void, Never>?

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
    VMListView()
        .environmentObject(AppState())
}
