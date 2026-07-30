import SwiftUI

struct GuestHardwareEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let initialConfig: GuestConfig
    let onChanged: () -> Void

    @State private var config: GuestConfig
    @State private var resizingDisk: GuestHardwareDisk?
    @State private var showingAddDisk = false
    @State private var editingNetwork: GuestHardwareNetwork?
    @State private var showingAddNetwork = false
    @State private var deletingNetwork: GuestHardwareNetwork?
    @State private var isWorking = false
    @State private var error: String?

    init(guest: ProxmoxVM, config: GuestConfig, onChanged: @escaping () -> Void) {
        self.guest = guest
        self.initialConfig = config
        self.onChanged = onChanged
        _config = State(initialValue: config)
    }

    private var canEditDisks: Bool {
        appState.hasPrivilege("VM.Config.Disk", for: guest.vmid)
    }

    private var canEditNetworks: Bool {
        appState.hasPrivilege("VM.Config.Network", for: guest.vmid)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(config.disks(for: guest.type)) { disk in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(disk.key.uppercased())
                                    .font(.body.weight(.medium))
                                Text(disk.size ?? disk.value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if canEditDisks {
                                Button("Expand") {
                                    resizingDisk = disk
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 3)
                    }

                    if canEditDisks {
                        Button {
                            showingAddDisk = true
                        } label: {
                            Label(
                                guest.type == .qemu
                                    ? String(localized: "Add Disk")
                                    : String(localized: "Add Mount Point"),
                                systemImage: "plus.circle"
                            )
                        }
                    }
                } header: {
                    Text("Disks")
                } footer: {
                    Text("Disk shrinking and disk deletion are intentionally unavailable.")
                }

                Section {
                    ForEach(config.networks) { network in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "network")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(network.key.uppercased())
                                    .font(.body.weight(.medium))
                                Text(network.value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            Spacer()
                            if canEditNetworks {
                                Menu {
                                    Button("Edit") {
                                        editingNetwork = network
                                    }
                                    Button("Delete", role: .destructive) {
                                        deletingNetwork = network
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }

                    if canEditNetworks {
                        Button {
                            showingAddNetwork = true
                        } label: {
                            Label("Add Network Interface", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Network Interfaces")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Hardware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if isWorking {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView()
                }
            }
            .sheet(item: $resizingDisk) { disk in
                ResizeGuestDiskView(guest: guest, disk: disk) {
                    await reload()
                }
                .environmentObject(appState)
            }
            .sheet(isPresented: $showingAddDisk) {
                AddGuestDiskView(guest: guest, config: config) {
                    await reload()
                }
                .environmentObject(appState)
            }
            .sheet(item: $editingNetwork) { network in
                GuestNetworkEditorView(guest: guest, config: config, network: network) {
                    await reload()
                }
                .environmentObject(appState)
            }
            .sheet(isPresented: $showingAddNetwork) {
                GuestNetworkEditorView(guest: guest, config: config, network: nil) {
                    await reload()
                }
                .environmentObject(appState)
            }
            .confirmationDialog(
                "Delete Network Interface?",
                isPresented: Binding(
                    get: { deletingNetwork != nil },
                    set: { if !$0 { deletingNetwork = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let network = deletingNetwork else { return }
                    Task { await deleteNetwork(network) }
                }
            } message: {
                Text("The interface is removed from the guest configuration.")
            }
        }
    }

    @MainActor
    private func reload() async {
        guard let service = appState.service else { return }
        do {
            config = try await service.fetchGuestConfig(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid
            )
            onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func deleteNetwork(_ network: GuestHardwareNetwork) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer {
            isWorking = false
            deletingNetwork = nil
        }
        do {
            _ = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: ["delete": network.key]
            )
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ResizeGuestDiskView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let disk: GuestHardwareDisk
    let onSaved: () async -> Void

    @State private var growGiB = 8
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Disk", value: disk.key.uppercased())
                    if let size = disk.size {
                        LabeledContent("Current Size", value: size)
                    }
                    Stepper("Add \(growGiB) GiB", value: $growGiB, in: 1...1024)
                } footer: {
                    Text("Only expansion is supported. This operation cannot be undone.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Expand Disk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Expand") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .overlay { if isSaving { ProgressView() } }
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let upid = try await service.resizeGuestDisk(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                disk: disk.key,
                growGiB: growGiB
            )
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: String(localized: "Expand disk"),
                    object: "\(guest.displayName) · \(disk.key)",
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

private struct AddGuestDiskView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let config: GuestConfig
    let onSaved: () async -> Void

    @State private var storages: [ProxmoxStorage] = []
    @State private var selectedStorage = ""
    @State private var sizeGiB = 16
    @State private var mountPath = "/data"
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var error: String?

    private var compatibleStorages: [ProxmoxStorage] {
        let content = guest.type == .qemu ? "images" : "rootdir"
        return storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains(content) &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    private var nextKey: String? {
        let existing = Set(config.rawValues.keys)
        let prefix = guest.type == .qemu ? "scsi" : "mp"
        let limit = guest.type == .qemu ? 31 : 256
        return (0..<limit).map { "\(prefix)\($0)" }.first { !existing.contains($0) }
    }

    private var canSave: Bool {
        !selectedStorage.isEmpty &&
        nextKey != nil &&
        (guest.type == .qemu || mountPath.hasPrefix("/"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        guest.type == .qemu
                            ? String(localized: "Disk Slot")
                            : String(localized: "Mount Point Slot"),
                        value: nextKey?.uppercased() ?? "—"
                    )
                    Picker("Storage", selection: $selectedStorage) {
                        ForEach(compatibleStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                    Stepper("Size: \(sizeGiB) GiB", value: $sizeGiB, in: 1...4096)
                    if guest.type == .lxc {
                        TextField("Mount Path", text: $mountPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if compatibleStorages.isEmpty, !isLoading {
                    Section {
                        Text("No compatible storage is available with allocation permission.")
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
            .navigationTitle(
                guest.type == .qemu
                    ? String(localized: "Add Disk")
                    : String(localized: "Add Mount Point")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(!canSave || isSaving)
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
    private func save() async {
        guard let service = appState.service, let nextKey, canSave else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let value = guest.type == .qemu
            ? "\(selectedStorage):\(sizeGiB)"
            : "\(selectedStorage):\(sizeGiB),mp=\(mountPath.trimmed)"
        do {
            let upid = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: [nextKey: value]
            )
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: guest.type == .qemu
                        ? String(localized: "Add disk")
                        : String(localized: "Add mount point"),
                    object: "\(guest.displayName) · \(nextKey)",
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

private struct GuestNetworkEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let config: GuestConfig
    let network: GuestHardwareNetwork?
    let onSaved: () async -> Void

    @State private var model = "virtio"
    @State private var interfaceName = "eth0"
    @State private var bridge = "vmbr0"
    @State private var vlanTag = ""
    @State private var preservedComponents: [String] = []
    @State private var macAddress: String?
    @State private var isSaving = false
    @State private var error: String?

    private var key: String? {
        if let network { return network.key }
        let existing = Set(config.rawValues.keys)
        return (0..<32).map { "net\($0)" }.first { !existing.contains($0) }
    }

    private var canSave: Bool {
        key != nil &&
        !bridge.trimmed.isEmpty &&
        (vlanTag.isEmpty || (Int(vlanTag).map { (1...4094).contains($0) } == true)) &&
        (guest.type == .qemu || !interfaceName.trimmed.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Interface", value: key?.uppercased() ?? "—")
                    if guest.type == .qemu {
                        Picker("Model", selection: $model) {
                            Text("VirtIO").tag("virtio")
                            Text("Intel E1000").tag("e1000")
                            Text("VMware VMXNET3").tag("vmxnet3")
                            Text("Realtek RTL8139").tag("rtl8139")
                        }
                    } else {
                        TextField("Interface Name", text: $interfaceName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("Bridge", text: $bridge)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("VLAN Tag (optional)", text: $vlanTag)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Existing IP, firewall, rate limit and advanced options are preserved.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(
                network == nil
                    ? String(localized: "Add Network Interface")
                    : String(localized: "Edit Network Interface")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .task { parseExistingValue() }
        }
    }

    private func parseExistingValue() {
        guard let network else {
            if guest.type == .lxc,
               let key,
               let index = Int(key.dropFirst("net".count)) {
                interfaceName = "eth\(index)"
            }
            return
        }
        var components = network.value.split(separator: ",").map(String.init)
        if guest.type == .qemu {
            if let first = components.first {
                let pair = first.split(separator: "=", maxSplits: 1).map(String.init)
                model = pair[0]
                macAddress = pair.count > 1 ? pair[1] : nil
                components.removeFirst()
            }
            bridge = value(for: "bridge", in: components) ?? bridge
        } else {
            interfaceName = value(for: "name", in: components) ?? interfaceName
            bridge = value(for: "bridge", in: components) ?? bridge
        }
        vlanTag = value(for: "tag", in: components) ?? ""
        let replaced = guest.type == .qemu
            ? Set(["bridge", "tag"])
            : Set(["name", "bridge", "tag", "type"])
        preservedComponents = components.filter {
            guard let key = $0.split(separator: "=", maxSplits: 1).first else { return true }
            return !replaced.contains(String(key))
        }
    }

    private func value(for key: String, in components: [String]) -> String? {
        components.first(where: { $0.hasPrefix("\(key)=") })
            .map { String($0.dropFirst(key.count + 1)) }
    }

    private func encodedValue() -> String {
        var components: [String]
        if guest.type == .qemu {
            components = [macAddress.map { "\(model)=\($0)" } ?? model]
            components.append("bridge=\(bridge.trimmed)")
        } else {
            components = [
                "name=\(interfaceName.trimmed)",
                "bridge=\(bridge.trimmed)",
                "type=veth",
            ]
        }
        if !vlanTag.isEmpty {
            components.append("tag=\(vlanTag)")
        }
        components.append(contentsOf: preservedComponents)
        return components.joined(separator: ",")
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, let key, canSave else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            _ = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: [key: encodedValue()]
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
