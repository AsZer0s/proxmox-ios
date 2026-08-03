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
    @State private var showingCreateGuest = false
    @State private var isSelecting = false
    @State private var selectedVMIDs: Set<Int> = []
    @State private var batchAction: BatchGuestAction?

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
                                        if isSelecting {
                                            Button {
                                                toggleSelection(guest)
                                            } label: {
                                                HStack {
                                                    Image(systemName: selectedVMIDs.contains(guest.vmid) ? "checkmark.circle.fill" : "circle")
                                                        .foregroundStyle(selectedVMIDs.contains(guest.vmid) ? .blue : .secondary)
                                                    GuestRow(guest: guest)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        } else {
                                            NavigationLink {
                                                VMDetailView(guest: guest)
                                            } label: {
                                                GuestRow(guest: guest)
                                            }
                                            .contextMenu {
                                                if let serverID = appState.connectedServer?.id {
                                                    Button {
                                                        appState.dashboard.toggle(serverID: serverID, guest: guest)
                                                    } label: {
                                                        Label(
                                                            appState.dashboard.isFavorite(serverID: serverID, guest: guest) ? "Remove Favorite" : "Add Favorite",
                                                            systemImage: appState.dashboard.isFavorite(serverID: serverID, guest: guest) ? "star.slash" : "star"
                                                        )
                                                    }
                                                }
                                            }
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selectedVMIDs.removeAll() }
                    }

                    if appState.hasPrivilege("VM.Allocate", on: "/vms") {
                        Button {
                            showingCreateGuest = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create guest")
                    }

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
            .sheet(isPresented: $showingCreateGuest) {
                GuestEditorView(mode: .create) {
                    Task { await model.load(service: appState.service) }
                }
                .environmentObject(appState)
            }
            .sheet(item: $batchAction) { action in
                BatchGuestActionView(
                    action: action,
                    guests: model.guests.filter { selectedVMIDs.contains($0.vmid) }
                ) {
                    selectedVMIDs.removeAll()
                    isSelecting = false
                    await model.load(service: appState.service)
                }
                .environmentObject(appState)
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    batchToolbar
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

    private var batchToolbar: some View {
        HStack {
            Text("\(selectedVMIDs.count) selected")
                .font(.subheadline.weight(.medium))
            Spacer()
            Menu {
                Button { batchAction = .start } label: { Label("Start", systemImage: "play.fill") }
                Button { batchAction = .shutdown } label: { Label("Shutdown", systemImage: "power") }
                Button { batchAction = .stop } label: { Label("Force Stop", systemImage: "stop.fill") }
                Button { batchAction = .migrate } label: { Label("Migrate", systemImage: "arrow.right") }
                Button { batchAction = .backup } label: { Label("Back Up", systemImage: "externaldrive.badge.timemachine") }
            } label: {
                Label("Batch Actions", systemImage: "ellipsis.circle")
            }
            .disabled(selectedVMIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleSelection(_ guest: ProxmoxVM) {
        if selectedVMIDs.contains(guest.vmid) { selectedVMIDs.remove(guest.vmid) }
        else { selectedVMIDs.insert(guest.vmid) }
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

private enum BatchGuestAction: String, Identifiable {
    case start, shutdown, stop, migrate, backup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: return String(localized: "Start Guests")
        case .shutdown: return String(localized: "Shut Down Guests")
        case .stop: return String(localized: "Force Stop Guests")
        case .migrate: return String(localized: "Migrate Guests")
        case .backup: return String(localized: "Back Up Guests")
        }
    }
}

private struct BatchGuestActionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let action: BatchGuestAction
    let guests: [ProxmoxVM]
    let onFinished: () async -> Void
    @State private var nodes: [String] = []
    @State private var storages: [ProxmoxStorage] = []
    @State private var targetNode = ""
    @State private var storage = ""
    @State private var backupMode = "snapshot"
    @State private var online = true
    @State private var running = false
    @State private var completed = 0
    @State private var failures: [String] = []

    private var canRun: Bool {
        !guests.isEmpty && (action != .migrate || !targetNode.isEmpty) && (action != .backup || !storage.isEmpty) && !running
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Selected Guests") {
                    ForEach(guests) { guest in
                        LabeledContent(guest.displayName, value: "\(guest.vmid) · \(guest.node)")
                    }
                }
                if action == .migrate {
                    Section("Migration") {
                        Picker("Target Node", selection: $targetNode) {
                            Text("Select").tag("")
                            ForEach(nodes, id: \.self) { Text($0).tag($0) }
                        }
                        Toggle("Online Migration Where Possible", isOn: $online)
                    }
                }
                if action == .backup {
                    Section("Backup") {
                        Picker("Storage", selection: $storage) {
                            ForEach(storages.filter { $0.storageTypes.contains("backup") && $0.isAvailable }) {
                                Text($0.storage).tag($0.storage)
                            }
                        }
                        Picker("Mode", selection: $backupMode) {
                            Text("Snapshot").tag("snapshot"); Text("Suspend").tag("suspend"); Text("Stop").tag("stop")
                        }
                    }
                }
                if running { Section { ProgressView(value: Double(completed), total: Double(max(guests.count, 1))) { Text("Processing \(completed) of \(guests.count)") } } }
                if !failures.isEmpty { Section("Failed") { ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) } } }
                if action == .stop { Section { Label("Force stop may cause data loss inside running guests.", systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(running) }
                ToolbarItem(placement: .confirmationAction) { Button("Run") { Task { await run() } }.disabled(!canRun) }
            }
            .task { await loadOptions() }
        }
    }

    @MainActor private func loadOptions() async {
        guard let service = appState.service else { return }
        nodes = (try? await service.fetchNodes())?.filter(\.isOnline).map(\.node) ?? []
        if action == .migrate {
            let sourceNodes = Set(guests.map(\.node))
            if sourceNodes.count == 1 { nodes.removeAll { sourceNodes.contains($0) } }
            targetNode = nodes.first ?? ""
        } else if action == .backup, let node = guests.first?.node {
            storages = (try? await service.fetchStorages(node: node)) ?? []
            storage = storages.first { $0.storageTypes.contains("backup") && $0.isAvailable }?.storage ?? ""
        }
    }

    @MainActor private func run() async {
        guard let service = appState.service, canRun else { return }
        running = true; failures = []; completed = 0
        for guest in guests {
            do {
                let upid: String
                let title: String
                switch action {
                case .start:
                    upid = try await service.performAction(.start, node: guest.node, type: guest.type, vmid: guest.vmid); title = String(localized: "Start guest")
                case .shutdown:
                    upid = try await service.performAction(.shutdown, node: guest.node, type: guest.type, vmid: guest.vmid); title = String(localized: "Shut down guest")
                case .stop:
                    upid = try await service.performAction(.stop, node: guest.node, type: guest.type, vmid: guest.vmid); title = String(localized: "Stop guest")
                case .migrate:
                    if guest.node == targetNode { throw BatchActionError.sameNode }
                    upid = try await service.migrateGuest(node: guest.node, type: guest.type, vmid: guest.vmid, target: targetNode, online: online && guest.isRunning, targetStorage: nil, withLocalDisks: true); title = String(localized: "Migrate guest")
                case .backup:
                    upid = try await service.runBackup(node: guest.node, vmid: guest.vmid, storage: storage, mode: backupMode); title = String(localized: "Back up guest")
                }
                appState.taskCenter.track(upid: upid, node: guest.node, title: title, object: guest.displayName, service: service)
            } catch {
                failures.append("\(guest.displayName): \(error.localizedDescription)")
            }
            completed += 1
        }
        running = false
        if failures.isEmpty { await onFinished(); dismiss() }
    }

    private enum BatchActionError: LocalizedError {
        case sameNode
        var errorDescription: String? { String(localized: "The guest is already on the target node.") }
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
