import SwiftUI

/// Shows live status for a single guest and exposes start / stop / shutdown /
/// reboot actions with a confirmation for destructive ones.
struct VMDetailView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = VMDetailViewModel()

    let guest: ProxmoxVM

    @State private var pendingAction: GuestAction?
    @State private var pendingSnapshotAction: SnapshotAction?
    @State private var showingCreateSnapshot = false

    var body: some View {
        List {
            statusSection
            resourceSection
            configurationSection
            snapshotsSection
            actionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(guest.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(service: appState.service, guest: guest) }
        .task { await model.refresh(service: appState.service, guest: guest) }
        .confirmationDialog(
            pendingAction.map { "\($0.label) \(guest.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.label, role: action.isDestructive ? .destructive : nil) {
                    Task {
                        await model.perform(action, service: appState.service, guest: guest)
                        pendingAction = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
        .confirmationDialog(
            pendingSnapshotAction.map { $0.title } ?? "",
            isPresented: Binding(
                get: { pendingSnapshotAction != nil },
                set: { if !$0 { pendingSnapshotAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let snapshotAction = pendingSnapshotAction {
                switch snapshotAction {
                case .rollback(let snapshot):
                    Button("Rollback", role: .destructive) {
                        pendingSnapshotAction = nil
                        Task {
                            await model.rollbackSnapshot(
                                snapshot,
                                service: appState.service,
                                guest: guest
                            )
                        }
                    }
                case .delete(let snapshot):
                    Button("Delete", role: .destructive) {
                        pendingSnapshotAction = nil
                        Task {
                            await model.deleteSnapshot(
                                snapshot,
                                service: appState.service,
                                guest: guest
                            )
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingSnapshotAction = nil }
        }
        .sheet(isPresented: $showingCreateSnapshot) {
            CreateSnapshotView { name, description in
                Task {
                    await model.createSnapshot(
                        name: name,
                        description: description,
                        service: appState.service,
                        guest: guest
                    )
                }
            }
        }
        .overlay {
            if model.isPerformingAction {
                Color.black.opacity(0.1).ignoresSafeArea()
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text(model.taskMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .alert("Error", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var currentStatus: String {
        model.status?.status ?? guest.status
    }

    private var isRunning: Bool {
        model.status?.isRunning ?? guest.isRunning
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                StatusBadge(status: currentStatus)
            }
            LabeledContent("ID", value: "\(guest.type.label) \(guest.vmid)")
            LabeledContent("Node", value: guest.node)
            if let uptime = model.status?.uptime, uptime > 0 {
                LabeledContent("Uptime", value: uptime.formattedUptime)
            }
        }
    }

    @ViewBuilder
    private var resourceSection: some View {
        if let status = model.status, status.isRunning {
            Section("Resources") {
                if let cpu = status.cpu {
                    MetricBar(label: "CPU", value: cpu, detail: cpu.asPercentDetailed)
                        .padding(.vertical, 4)
                }
                if let used = status.mem, let total = status.maxmem, total > 0 {
                    MetricBar(
                        label: "Memory",
                        value: Double(used) / Double(total),
                        detail: "\(used.formattedBytes) / \(total.formattedBytes)"
                    )
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var snapshotsSection: some View {
        Section {
            if model.isLoadingSnapshots && model.snapshots.isEmpty {
                ProgressView("Loading snapshots…")
            } else if model.snapshots.isEmpty {
                Text("No snapshots")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshots) { snapshot in
                    SnapshotRow(snapshot: snapshot) {
                        pendingSnapshotAction = .rollback(snapshot)
                    } onDelete: {
                        pendingSnapshotAction = .delete(snapshot)
                    }
                }
            }
        } header: {
            HStack {
                Text("Snapshots")
                Spacer()
                Button {
                    showingCreateSnapshot = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create snapshot")
            }
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        if let config = model.config {
            Section("Configuration") {
                if let name = config.name ?? config.hostname, !name.isEmpty {
                    LabeledContent("Name", value: name)
                }
                if guest.type == .qemu {
                    if let cores = config.cores {
                        LabeledContent("CPU cores", value: "\(cores)")
                    }
                    if let sockets = config.sockets {
                        LabeledContent("CPU sockets", value: "\(sockets)")
                    }
                } else if let vcpus = config.vcpus {
                    LabeledContent("vCPUs", value: "\(vcpus)")
                }
                if let memory = config.memory {
                    LabeledContent("Memory", value: "\(memory) MB")
                }
                if let swap = config.swap {
                    LabeledContent("Swap", value: "\(swap) MB")
                }
                if let boot = config.boot {
                    LabeledContent("Boot order", value: boot)
                }
                if let onboot = config.onboot {
                    LabeledContent("Start on boot", value: onboot == 1 ? "Yes" : "No")
                }
                if let ostype = config.ostype {
                    LabeledContent("OS type", value: ostype)
                }
                if let agent = config.agent {
                    LabeledContent("Guest agent", value: agent == "1" ? "Enabled" : agent)
                }
                if let unprivileged = config.unprivileged {
                    LabeledContent("Unprivileged", value: unprivileged == 1 ? "Yes" : "No")
                }

                storageRows(config)
                networkRows(config)

                if let tags = config.tags, !tags.isEmpty {
                    LabeledContent("Tags", value: tags)
                }
                if let description = config.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func storageRows(_ config: GuestConfig) -> some View {
        if let value = config.rootfs {
            LabeledContent("Root disk", value: value)
        }
        if let value = config.scsi0 {
            LabeledContent("SCSI 0", value: value)
        }
        if let value = config.virtio0 {
            LabeledContent("VirtIO 0", value: value)
        }
        if let value = config.sata0 {
            LabeledContent("SATA 0", value: value)
        }
        if let value = config.ide0 {
            LabeledContent("IDE 0", value: value)
        }
        if let value = config.mp0 {
            LabeledContent("Mount point 0", value: value)
        }
        if let value = config.mp1 {
            LabeledContent("Mount point 1", value: value)
        }
    }

    @ViewBuilder
    private func networkRows(_ config: GuestConfig) -> some View {
        if let value = config.net0 {
            LabeledContent("Network 0", value: value)
        }
        if let value = config.net1 {
            LabeledContent("Network 1", value: value)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section("Actions") {
            HStack(spacing: 12) {
                ActionButton(action: .start, isBusy: model.isPerformingAction, isEnabled: !isRunning) {
                    pendingAction = .start
                }
                ActionButton(action: .reboot, isBusy: model.isPerformingAction, isEnabled: isRunning) {
                    pendingAction = .reboot
                }
            }
            HStack(spacing: 12) {
                ActionButton(action: .shutdown, isBusy: model.isPerformingAction, isEnabled: isRunning) {
                    pendingAction = .shutdown
                }
                ActionButton(action: .stop, isBusy: model.isPerformingAction, isEnabled: isRunning) {
                    pendingAction = .stop
                }
            }
        }
    }
}

private enum SnapshotAction {
    case rollback(GuestSnapshot)
    case delete(GuestSnapshot)

    var title: String {
        switch self {
        case .rollback(let snapshot): return "Rollback \"\(snapshot.name)\"?"
        case .delete(let snapshot): return "Delete \"\(snapshot.name)\"?"
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: GuestSnapshot
    let onRollback: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.name)
                    .font(.body.weight(.medium))
                Spacer()
                if let snaptime = snapshot.snaptime {
                    Text(Date(timeIntervalSince1970: Double(snaptime)), style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let description = snapshot.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button("Rollback", action: onRollback)
                    .buttonStyle(.bordered)
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CreateSnapshotView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""

    let onCreate: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Snapshot") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Create Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name.trimmed, description.trimmed)
                        dismiss()
                    }
                    .disabled(name.trimmed.isEmpty)
                }
            }
        }
    }
}

@MainActor
final class VMDetailViewModel: ObservableObject {
    @Published var status: VMStatus?
    @Published var config: GuestConfig?
    @Published var snapshots: [GuestSnapshot] = []
    @Published var isLoadingSnapshots = false
    @Published var isPerformingAction = false
    @Published var taskMessage = ""
    @Published var error: String?

    func refresh(service: ProxmoxAPIService?, guest: ProxmoxVM) async {
        guard let service = service else { return }
        do {
            status = try await service.fetchGuestStatus(
                node: guest.node, type: guest.type, vmid: guest.vmid
            )
        } catch {
            self.error = error.localizedDescription
        }

        do {
            config = try await service.fetchGuestConfig(
                node: guest.node, type: guest.type, vmid: guest.vmid
            )
        } catch {
            // Some restricted PVE accounts can read status without config access.
        }

        await loadSnapshots(service: service, guest: guest)
    }

    private func loadSnapshots(service: ProxmoxAPIService, guest: ProxmoxVM) async {
        isLoadingSnapshots = true
        defer { isLoadingSnapshots = false }
        do {
            snapshots = try await service.fetchSnapshots(
                node: guest.node, type: guest.type, vmid: guest.vmid
            )
        } catch {
            // Snapshot permission is independent from guest status permission.
        }
    }

    func createSnapshot(
        name: String,
        description: String,
        service: ProxmoxAPIService?,
        guest: ProxmoxVM
    ) async {
        guard let service, !name.isEmpty else { return }
        isPerformingAction = true
        taskMessage = "Creating snapshot…"
        defer { isPerformingAction = false }
        do {
            let upid = try await service.createSnapshot(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                name: name,
                description: description
            )
            if !upid.isEmpty {
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            await loadSnapshots(service: service, guest: guest)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rollbackSnapshot(
        _ snapshot: GuestSnapshot,
        service: ProxmoxAPIService?,
        guest: ProxmoxVM
    ) async {
        guard let service else { return }
        isPerformingAction = true
        taskMessage = "Rolling back snapshot…"
        defer { isPerformingAction = false }
        do {
            let upid = try await service.rollbackSnapshot(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                snapshot: snapshot.name
            )
            if !upid.isEmpty {
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            await refresh(service: service, guest: guest)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteSnapshot(
        _ snapshot: GuestSnapshot,
        service: ProxmoxAPIService?,
        guest: ProxmoxVM
    ) async {
        guard let service else { return }
        isPerformingAction = true
        taskMessage = "Deleting snapshot…"
        defer { isPerformingAction = false }
        do {
            let upid = try await service.deleteSnapshot(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                snapshot: snapshot.name
            )
            if !upid.isEmpty {
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            snapshots.removeAll { $0.id == snapshot.id }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func perform(_ action: GuestAction, service: ProxmoxAPIService?, guest: ProxmoxVM) async {
        guard let service = service else { return }
        isPerformingAction = true
        taskMessage = "Submitting action…"
        defer { isPerformingAction = false }
        do {
            let upid = try await service.performAction(action, node: guest.node, type: guest.type, vmid: guest.vmid)
            if !upid.isEmpty {
                taskMessage = "Waiting for Proxmox task…"
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            await refresh(service: service, guest: guest)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        VMDetailView(guest: ProxmoxVM(
            vmid: 100, name: "test-vm", status: "running",
            cpu: 0.12, cpus: 2, mem: 1_073_741_824, maxmem: 2_147_483_648,
            disk: nil, maxdisk: nil, uptime: 90_000
        ))
    }
    .environmentObject(AppState())
}
