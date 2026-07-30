import SwiftUI

/// Shows live status for a single guest and exposes start / stop / shutdown /
/// reboot actions with a confirmation for destructive ones.
struct VMDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VMDetailViewModel()

    let guest: ProxmoxVM

    @State private var pendingAction: GuestAction?
    @State private var pendingSnapshotAction: SnapshotAction?
    @State private var showingCreateSnapshot = false
    @State private var showingEditGuest = false
    @State private var showingDeleteGuest = false
    @State private var showingCloneGuest = false
    @State private var showingHardwareEditor = false
    @State private var showingCloudInitEditor = false
    @State private var showingBackup = false
    @State private var showingMigration = false

    var body: some View {
        List {
            statusSection
            resourceSection
            configurationSection
            snapshotsSection
            actionSection
            nodeLinksSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(guest.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManageGuest {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if canEditGuest {
                            Button {
                                showingEditGuest = true
                            } label: {
                                Label("Edit Guest", systemImage: "pencil")
                            }
                        }

                        if canCloneGuest {
                            Button {
                                showingCloneGuest = true
                            } label: {
                                Label("Clone Guest", systemImage: "square.on.square")
                            }
                        }

                        if canEditHardware {
                            Button {
                                showingHardwareEditor = true
                            } label: {
                                Label("Edit Hardware", systemImage: "cpu")
                            }
                        }

                        if canEditCloudInit {
                            Button {
                                showingCloudInitEditor = true
                            } label: {
                                Label("Cloud-Init", systemImage: "cloud")
                            }
                        }

                        if canBackUpGuest {
                            Button {
                                showingBackup = true
                            } label: {
                                Label("Back Up", systemImage: "externaldrive.badge.timemachine")
                            }
                        }

                        if canMigrateGuest {
                            Button {
                                showingMigration = true
                            } label: {
                                Label("Migrate", systemImage: "arrow.right.arrow.left")
                            }
                        }

                        if canDeleteGuest {
                            Button(role: .destructive) {
                                showingDeleteGuest = true
                            } label: {
                                Label("Delete Guest", systemImage: "trash")
                            }
                            .disabled(isRunning)

                            if isRunning {
                                Text("Stop the guest before deleting it.")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .refreshable { await model.refresh(service: appState.service, guest: guest) }
        .task {
            await model.refresh(service: appState.service, guest: guest)
            await model.refreshLoop(service: appState.service, guest: guest)
        }
        .onDisappear {
            model.stopRefresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task {
                    await model.refresh(service: appState.service, guest: guest)
                    await model.refreshLoop(service: appState.service, guest: guest)
                }
            } else if phase == .background {
                model.stopRefresh()
            }
        }
        .confirmationDialog(
            pendingAction.map { "\($0.label) \(guest.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                if action == .stop {
                    Text("Forcing stop may cause data loss. Consider Shutdown instead.")
                }
                Button(action.label, role: action.isDestructive ? .destructive : nil) {
                    Task {
                        await model.perform(
                            action,
                            service: appState.service,
                            taskCenter: appState.taskCenter,
                            guest: guest
                        )
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
                    Text("Rollback will revert \(guest.displayName) to the state captured in \"\(snapshot.name)\". Any changes made after the snapshot will be lost.")
                    Button("Rollback", role: .destructive) {
                        pendingSnapshotAction = nil
                        Task {
                            await model.rollbackSnapshot(
                                snapshot,
                                service: appState.service,
                                taskCenter: appState.taskCenter,
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
                                taskCenter: appState.taskCenter,
                                guest: guest
                            )
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingSnapshotAction = nil }
        }
        .sheet(isPresented: $showingCreateSnapshot) {
            CreateSnapshotView { name, description, includeVMState in
                Task {
                    await model.createSnapshot(
                        name: name,
                        description: description,
                        includeVMState: includeVMState,
                        service: appState.service,
                        taskCenter: appState.taskCenter,
                        guest: guest
                    )
                }
            }
        }
        .sheet(isPresented: $showingEditGuest) {
            if let config = model.config {
                GuestEditorView(mode: .edit(guest: guest, config: config)) {
                    Task {
                        await model.refresh(service: appState.service, guest: guest)
                    }
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showingDeleteGuest) {
            DeleteGuestConfirmationView(guest: guest) {
                try await deleteGuest()
            } onDeleted: {
                dismiss()
            }
        }
        .sheet(isPresented: $showingCloneGuest) {
            CloneGuestView(guest: guest) {}
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingHardwareEditor) {
            if let config = model.config {
                GuestHardwareEditorView(guest: guest, config: config) {
                    Task {
                        await model.refresh(service: appState.service, guest: guest)
                    }
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showingCloudInitEditor) {
            if let config = model.config {
                CloudInitEditorView(guest: guest, config: config) {
                    Task {
                        await model.refresh(service: appState.service, guest: guest)
                    }
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showingBackup) {
            GuestBackupView(guest: guest)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingMigration) {
            GuestMigrationView(guest: guest) {
                dismiss()
            }
            .environmentObject(appState)
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

    private var canEditGuest: Bool {
        model.config != nil && appState.hasAnyPrivilege(
            ["VM.Config.Options", "VM.Config.CPU", "VM.Config.Memory"],
            for: guest.vmid
        )
    }

    private var canDeleteGuest: Bool {
        appState.hasPrivilege("VM.Allocate", for: guest.vmid)
    }

    private var canCloneGuest: Bool {
        appState.hasPrivilege("VM.Clone", for: guest.vmid)
    }

    private var canEditHardware: Bool {
        model.config != nil && appState.hasAnyPrivilege(
            ["VM.Config.Disk", "VM.Config.Network"],
            for: guest.vmid
        )
    }

    private var canEditCloudInit: Bool {
        guest.type == .qemu &&
        model.config != nil &&
        appState.hasPrivilege("VM.Config.Cloudinit", for: guest.vmid)
    }

    private var canBackUpGuest: Bool {
        appState.hasPrivilege("VM.Backup", for: guest.vmid)
    }

    private var canMigrateGuest: Bool {
        appState.hasPrivilege("VM.Migrate", for: guest.vmid)
    }

    private var canManageGuest: Bool {
        canEditGuest || canEditHardware || canEditCloudInit || canBackUpGuest ||
        canMigrateGuest || canCloneGuest || canDeleteGuest
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
            Section {
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
            } header: {
                Text("Resources")
            }
        }
    }

    @ViewBuilder
    private var nodeLinksSection: some View {
        Section {
            if appState.hasPrivilege("VM.Console", for: guest.vmid) {
                NavigationLink {
                    GuestConsoleView(guest: guest)
                        .environmentObject(appState)
                } label: {
                    Label(
                        guest.type == .qemu
                            ? String(localized: "Console")
                            : String(localized: "Terminal"),
                        systemImage: "terminal"
                    )
                }
                .disabled(!isRunning)
            }

            NavigationLink {
                RRDChartView(
                    node: guest.node,
                    guest: (type: guest.type, vmid: guest.vmid)
                )
            } label: {
                Label("Charts", systemImage: "chart.xyaxis.line")
            }

            NavigationLink {
                GuestFirewallView(guest: guest)
                    .environmentObject(appState)
            } label: {
                Label("Firewall", systemImage: "shield")
            }
        }
    }

    @ViewBuilder
    private var snapshotsSection: some View {
        Section {
            if model.isLoadingSnapshots && model.snapshots.isEmpty {
                ProgressView("Loading snapshots…")
            } else if let snapError = model.snapshotError {
                Label(snapError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Snapshot feature may be unavailable due to insufficient permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                if appState.hasPrivilege("VM.Snapshot", for: guest.vmid) {
                    Button {
                        showingCreateSnapshot = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create snapshot")
                }
            }
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        if let config = model.config {
            Section {
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
            } header: {
                Text("Configuration")
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
        if appState.hasPrivilege("VM.PowerMgmt", for: guest.vmid) {
            Section {
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
            } header: {
                Text("Actions")
            }
        }
    }

    private func deleteGuest() async throws {
        guard let service = appState.service else { return }
        let upid = try await service.deleteGuest(
            node: guest.node,
            type: guest.type,
            vmid: guest.vmid
        )
        if !upid.isEmpty {
            appState.taskCenter.track(
                upid: upid,
                node: guest.node,
                title: guest.type == .qemu
                    ? String(localized: "Delete virtual machine")
                    : String(localized: "Delete container"),
                object: "\(guest.displayName) · \(guest.vmid)",
                service: service
            )
            _ = try await service.waitForTask(node: guest.node, upid: upid)
        }
    }
}

private enum SnapshotAction {
    case rollback(GuestSnapshot)
    case delete(GuestSnapshot)

    var title: String {
        switch self {
        case .rollback(let snapshot): return "Rollback \"\(snapshot.name)\"?\nThis will revert the guest to the snapshot state. Any data changes after the snapshot will be lost."
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

            if let vmstate = snapshot.vmstate {
                Text(vmstate == 1 ? "Includes RAM state" : "Disk-only snapshot")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Rollback", action: onRollback)
                    .buttonStyle(.bordered)
                    .tint(.orange)
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
    @State private var includeVMState = true

    let onCreate: (String, String, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    Toggle("Include memory state", isOn: $includeVMState)
                } header: {
                    Text("Snapshot")
                } footer: {
                    Text("Including memory state creates a full VM snapshot (slower, larger). Disable for a disk-only snapshot.")
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
                        onCreate(name.trimmed, description.trimmed, includeVMState)
                        dismiss()
                    }
                    .disabled(name.trimmed.isEmpty)
                }
            }
        }
    }
}

private struct DeleteGuestConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var error: String?

    let guest: ProxmoxVM
    let onDelete: () async throws -> Void
    let onDeleted: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(guest.displayName, systemImage: guest.type == .qemu ? "desktopcomputer" : "shippingbox")
                    LabeledContent("VMID", value: "\(guest.vmid)")
                    LabeledContent("Node", value: guest.node)
                }

                Section {
                    Text("This permanently deletes the guest configuration and owned disks.")
                        .foregroundStyle(.red)
                    TextField("Type \(guest.vmid) to confirm", text: $confirmation)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Confirmation")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Delete Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        Task { await delete() }
                    }
                    .disabled(confirmation != "\(guest.vmid)" || isDeleting)
                }
            }
            .overlay {
                if isDeleting {
                    ProgressView("Deleting…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    @MainActor
    private func delete() async {
        isDeleting = true
        error = nil
        do {
            try await onDelete()
            dismiss()
            onDeleted()
        } catch {
            self.error = error.localizedDescription
            isDeleting = false
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
    @Published private(set) var lastUpdated: Date?
    @Published var error: String?
    @Published var snapshotError: String?
    @Published var configError: String?

    private var refreshTask: Task<Void, Never>?

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
            configError = nil
        } catch {
            configError = error.localizedDescription
            // Permission denied for config is fine; some accounts have limited access.
            if !(error is ProxmoxError) || (error as? ProxmoxError).map({ if case .requestFailed(let s, _) = $0, s == 403 { return true }; return false }) != true {
                // Only show non-permission errors
            }
        }

        await loadSnapshots(service: service, guest: guest)
        lastUpdated = Date()
    }

    func refreshLoop(service: ProxmoxAPIService?, guest: ProxmoxVM) async {
        stopRefresh()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                await refresh(service: service, guest: guest)
            }
        }
    }

    func stopRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func loadSnapshots(service: ProxmoxAPIService, guest: ProxmoxVM) async {
        isLoadingSnapshots = true
        defer { isLoadingSnapshots = false }
        do {
            snapshots = try await service.fetchSnapshots(
                node: guest.node, type: guest.type, vmid: guest.vmid
            )
            snapshotError = nil
        } catch {
            snapshotError = error.localizedDescription
        }
    }

    func createSnapshot(
        name: String,
        description: String,
        includeVMState: Bool,
        service: ProxmoxAPIService?,
        taskCenter: ProxmoxTaskCenter,
        guest: ProxmoxVM
    ) async {
        guard let service, !name.isEmpty else { return }
        isPerformingAction = true
        taskMessage = String(localized: "Creating snapshot…")
        defer { isPerformingAction = false }
        do {
            let upid = try await service.createSnapshot(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                name: name,
                description: description,
                includeVMState: includeVMState
            )
            if !upid.isEmpty {
                taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: String(localized: "Create snapshot"),
                    object: guest.displayName,
                    service: service
                )
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
        taskCenter: ProxmoxTaskCenter,
        guest: ProxmoxVM
    ) async {
        guard let service else { return }
        isPerformingAction = true
        taskMessage = String(localized: "Rolling back snapshot…")
        defer { isPerformingAction = false }
        do {
            let upid = try await service.rollbackSnapshot(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                snapshot: snapshot.name
            )
            if !upid.isEmpty {
                taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: String(localized: "Rollback snapshot"),
                    object: "\(guest.displayName) · \(snapshot.name)",
                    service: service
                )
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
        taskCenter: ProxmoxTaskCenter,
        guest: ProxmoxVM
    ) async {
        guard let service else { return }
        isPerformingAction = true
        taskMessage = String(localized: "Deleting snapshot…")
        defer { isPerformingAction = false }
        do {
            let upid = try await service.deleteSnapshot(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                snapshot: snapshot.name
            )
            if !upid.isEmpty {
                taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: String(localized: "Delete snapshot"),
                    object: "\(guest.displayName) · \(snapshot.name)",
                    service: service
                )
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            snapshots.removeAll { $0.id == snapshot.id }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func perform(
        _ action: GuestAction,
        service: ProxmoxAPIService?,
        taskCenter: ProxmoxTaskCenter,
        guest: ProxmoxVM
    ) async {
        guard let service = service else { return }
        isPerformingAction = true
        taskMessage = String(localized: "Submitting action…")
        defer { isPerformingAction = false }
        do {
            let upid = try await service.performAction(action, node: guest.node, type: guest.type, vmid: guest.vmid)
            if !upid.isEmpty {
                taskMessage = String(localized: "Waiting for Proxmox task…")
                taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: action.label,
                    object: guest.displayName,
                    service: service
                )
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
