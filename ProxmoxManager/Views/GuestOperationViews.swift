import SwiftUI

struct GuestBackupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM

    @State private var storages: [ProxmoxStorage] = []
    @State private var selectedStorage = ""
    @State private var mode = "snapshot"
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var compatibleStorages: [ProxmoxStorage] {
        storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains("backup") &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Guest", value: guest.displayName)
                    Picker("Storage", selection: $selectedStorage) {
                        ForEach(compatibleStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                    Picker("Backup Mode", selection: $mode) {
                        Text("Snapshot").tag("snapshot")
                        Text("Suspend").tag("suspend")
                        Text("Stop").tag("stop")
                    }
                } footer: {
                    Text("Snapshot mode minimizes downtime when supported by the guest and storage.")
                }

                if compatibleStorages.isEmpty, !isLoading {
                    Section {
                        Text("No accessible backup storage is available.")
                            .foregroundStyle(.red)
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Back Up Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Back Up") { Task { await runBackup() } }
                        .disabled(selectedStorage.isEmpty || isSaving)
                }
            }
            .overlay { if isLoading || isSaving { ProgressView() } }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            storages = try await service.fetchStorages(node: guest.node)
            selectedStorage = compatibleStorages.first?.storage ?? ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func runBackup() async {
        guard let service = appState.service, !selectedStorage.isEmpty else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let upid = try await service.runBackup(
                node: guest.node,
                vmid: guest.vmid,
                storage: selectedStorage,
                mode: mode
            )
            appState.taskCenter.track(
                upid: upid,
                node: guest.node,
                title: String(localized: "Back up guest"),
                object: guest.displayName,
                service: service
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RestoreBackupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let node: String
    let file: ProxmoxBackupFile
    let onRestored: () -> Void

    @State private var vmidText = ""
    @State private var storages: [ProxmoxStorage] = []
    @State private var selectedStorage = ""
    @State private var uniqueMAC = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var compatibleStorages: [ProxmoxStorage] {
        let content = file.guestType == .qemu ? "images" : "rootdir"
        return storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains(content) &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    private var canSave: Bool {
        Int(vmidText).map { (100...999_999_999).contains($0) } == true &&
        !selectedStorage.isEmpty &&
        !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Archive", value: file.volid)
                    LabeledContent("Type", value: file.guestType.label)
                    TextField("New VMID", text: $vmidText)
                        .keyboardType(.numberPad)
                    Picker("Target Storage", selection: $selectedStorage) {
                        ForEach(compatibleStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                    Toggle("Generate Unique MAC Addresses", isOn: $uniqueMAC)
                } footer: {
                    Text("Restore creates a new guest and keeps the backup archive.")
                }

                if compatibleStorages.isEmpty, !isLoading {
                    Section {
                        Text("No compatible target storage is available.")
                            .foregroundStyle(.red)
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { Task { await restore() } }
                        .disabled(!canSave)
                }
            }
            .overlay { if isLoading || isSaving { ProgressView() } }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let vmidRequest = service.fetchNextVMID()
            async let storageRequest = service.fetchStorages(node: node)
            let (vmid, loadedStorages) = try await (vmidRequest, storageRequest)
            vmidText = "\(vmid)"
            storages = loadedStorages
            selectedStorage = compatibleStorages.first?.storage ?? ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func restore() async {
        guard let service = appState.service,
              let vmid = Int(vmidText),
              canSave else {
            return
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let upid = try await service.restoreBackup(
                node: node,
                type: file.guestType,
                vmid: vmid,
                archive: file.volid,
                storage: selectedStorage,
                unique: uniqueMAC
            )
            appState.taskCenter.track(
                upid: upid,
                node: node,
                title: String(localized: "Restore backup"),
                object: "\(file.guestType.label) \(vmid)",
                service: service
            )
            onRestored()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GuestMigrationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let onMigrated: () -> Void

    @State private var nodes: [ProxmoxNode] = []
    @State private var targetStorages: [ProxmoxStorage] = []
    @State private var preconditions: GuestMigrationPreconditions?
    @State private var selectedTarget = ""
    @State private var selectedStorage = "1"
    @State private var online: Bool
    @State private var withLocalDisks = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    init(guest: ProxmoxVM, onMigrated: @escaping () -> Void) {
        self.guest = guest
        self.onMigrated = onMigrated
        _online = State(initialValue: guest.isRunning)
    }

    private var targetNodes: [ProxmoxNode] {
        let allowed = Set(preconditions?.allowedNodes ?? [])
        return nodes.filter {
            $0.isOnline &&
            $0.node != guest.node &&
            (allowed.isEmpty || allowed.contains($0.node))
        }
    }

    private var compatibleTargetStorages: [ProxmoxStorage] {
        let content = guest.type == .qemu ? "images" : "rootdir"
        return targetStorages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains(content) &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    private var canMigrate: Bool {
        !selectedTarget.isEmpty &&
        (preconditions?.localResources.isEmpty != false) &&
        !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Source Node", value: guest.node)
                    Picker("Target Node", selection: $selectedTarget) {
                        ForEach(targetNodes) { node in
                            Text(node.node).tag(node.node)
                        }
                    }
                    Toggle("Online Migration", isOn: $online)
                        .disabled(!guest.isRunning)
                    if guest.type == .qemu {
                        Toggle("Migrate Local Disks", isOn: $withLocalDisks)
                    }
                    Picker("Target Storage", selection: $selectedStorage) {
                        Text("Keep Storage Mapping").tag("1")
                        ForEach(compatibleTargetStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                }

                if let preconditions, !preconditions.localResources.isEmpty {
                    Section {
                        ForEach(preconditions.localResources, id: \.self) {
                            Label($0, systemImage: "exclamationmark.triangle")
                        }
                    } header: {
                        Text("Local Resources")
                    } footer: {
                        Text("Local devices may prevent migration.")
                    }
                }

                if targetNodes.isEmpty, !isLoading {
                    Section {
                        Text("No compatible online target node is available.")
                            .foregroundStyle(.red)
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Migrate Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Migrate") { Task { await migrate() } }
                        .disabled(!canMigrate)
                }
            }
            .overlay { if isLoading || isSaving { ProgressView() } }
            .task { await load() }
            .task(id: selectedTarget) {
                guard !selectedTarget.isEmpty else { return }
                await loadTargetContext()
            }
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let nodesRequest = service.fetchNodes()
            async let preconditionRequest = service.fetchMigrationPreconditions(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid
            )
            let (loadedNodes, loadedPreconditions) = try await (nodesRequest, preconditionRequest)
            nodes = loadedNodes
            preconditions = loadedPreconditions
            selectedTarget = targetNodes.first?.node ?? ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadTargetContext() async {
        guard let service = appState.service else { return }
        do {
            async let storageRequest = service.fetchStorages(node: selectedTarget)
            async let preconditionRequest = service.fetchMigrationPreconditions(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                target: selectedTarget
            )
            targetStorages = try await storageRequest
            preconditions = try await preconditionRequest
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func migrate() async {
        guard let service = appState.service, !selectedTarget.isEmpty else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let upid = try await service.migrateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                target: selectedTarget,
                online: online,
                targetStorage: selectedStorage,
                withLocalDisks: withLocalDisks
            )
            appState.taskCenter.track(
                upid: upid,
                node: guest.node,
                title: String(localized: "Migrate guest"),
                object: "\(guest.displayName) → \(selectedTarget)",
                service: service
            )
            onMigrated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddCloudInitDriveView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let config: GuestConfig
    let onSaved: () async -> Void

    @State private var storages: [ProxmoxStorage] = []
    @State private var selectedStorage = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var compatibleStorages: [ProxmoxStorage] {
        storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains("images") &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    private var slot: String? {
        let keys = Set(config.rawValues.keys)
        return (0...3).map { "ide\($0)" }.first { !keys.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Slot", value: slot?.uppercased() ?? "—")
                    Picker("Storage", selection: $selectedStorage) {
                        ForEach(compatibleStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                } footer: {
                    Text("The Cloud-Init drive stores generated user, network and metadata configuration.")
                }

                if slot == nil {
                    Section {
                        Text("No IDE slot is available for a Cloud-Init drive.")
                            .foregroundStyle(.red)
                    }
                }
                if compatibleStorages.isEmpty, !isLoading {
                    Section {
                        Text("No compatible storage is available.")
                            .foregroundStyle(.red)
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Cloud-Init Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(slot == nil || selectedStorage.isEmpty || isSaving)
                }
            }
            .overlay { if isLoading || isSaving { ProgressView() } }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            storages = try await service.fetchStorages(node: guest.node)
            selectedStorage = compatibleStorages.first?.storage ?? ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func add() async {
        guard let service = appState.service,
              let slot,
              !selectedStorage.isEmpty else {
            return
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let upid = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: [slot: "\(selectedStorage):cloudinit"]
            )
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: String(localized: "Add Cloud-Init drive"),
                    object: guest.displayName,
                    service: service
                )
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
