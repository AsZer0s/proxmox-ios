import SwiftUI

struct GuestHardwareEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let initialConfig: GuestConfig
    let onChanged: () -> Void

    @State private var config: GuestConfig
    @State private var resizingDisk: GuestHardwareDisk?
    @State private var movingDisk: GuestHardwareDisk?
    @State private var diskToDetach: GuestHardwareDisk?
    @State private var diskToDelete: GuestHardwareDisk?
    @State private var showingAddDisk = false
    @State private var editingNetwork: GuestHardwareNetwork?
    @State private var showingAddNetwork = false
    @State private var showingAddCloudInitDrive = false
    @State private var editingCDROM: GuestHardwareDevice?
    @State private var showingAddCDROM = false
    @State private var showingBootOrder = false
    @State private var addingAdvancedDevice: GuestAdvancedDeviceKind?
    @State private var deletingAdvancedDevice: GuestHardwareDevice?
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

    private var canEditCloudInitDrive: Bool {
        appState.hasAnyPrivilege(
            ["VM.Config.Cloudinit", "VM.Config.CDROM"],
            for: guest.vmid
        )
    }

    private var canEditCDROM: Bool {
        appState.hasPrivilege("VM.Config.CDROM", for: guest.vmid)
    }

    private var canEditAdvancedDevices: Bool {
        appState.hasPrivilege("VM.Config.HWType", for: guest.vmid)
    }

    private var canEditBootOrder: Bool {
        appState.hasPrivilege("VM.Config.Options", for: guest.vmid)
    }

    private var cdroms: [GuestHardwareDevice] {
        config.rawValues.compactMap { key, value in
            guard key.range(
                of: #"^(ide|sata|scsi)\d+$"#,
                options: .regularExpression
            ) != nil, value.contains("media=cdrom") else { return nil }
            return GuestHardwareDevice(key: key, value: value, kind: .cdrom)
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private var advancedDevices: [GuestHardwareDevice] {
        config.rawValues.compactMap { key, value in
            let kind: GuestAdvancedDeviceKind?
            if key == "efidisk0" { kind = .efi }
            else if key == "tpmstate0" { kind = .tpm }
            else if key.hasPrefix("hostpci") { kind = .pci }
            else if key.hasPrefix("usb") { kind = .usb }
            else if key.hasPrefix("serial") { kind = .serial }
            else { kind = nil }
            return kind.map { GuestHardwareDevice(key: key, value: value, kind: $0) }
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private var cloudInitDrive: GuestHardwareDisk? {
        config.rawValues.first { key, value in
            key.range(
                of: #"^(ide|sata|scsi)\d+$"#,
                options: .regularExpression
            ) != nil && value.lowercased().contains("cloudinit")
        }
        .map { GuestHardwareDisk(key: $0.key, value: $0.value) }
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
                                Menu {
                                    Button("Expand") { resizingDisk = disk }
                                    Button("Move to Storage") { movingDisk = disk }
                                    if guest.type == .qemu {
                                        Button("Detach") { diskToDetach = disk }
                                    }
                                    Button("Delete Permanently", role: .destructive) {
                                        diskToDelete = disk
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
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

                if guest.type == .qemu {
                    Section {
                        ForEach(cdroms) { device in
                            hardwareDeviceRow(device) {
                                editingCDROM = device
                            }
                        }
                        if canEditCDROM {
                            Button {
                                showingAddCDROM = true
                            } label: {
                                Label("Add CD/DVD Drive", systemImage: "plus.circle")
                            }
                        }
                    } header: {
                        Text("CD/DVD Drives")
                    }

                    Section {
                        if let cloudInitDrive {
                            HStack(spacing: 12) {
                                Image(systemName: "cloud")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cloudInitDrive.key.uppercased())
                                        .font(.body.weight(.medium))
                                    Text(cloudInitDrive.value)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if canEditCloudInitDrive {
                            Button {
                                showingAddCloudInitDrive = true
                            } label: {
                                Label("Add Cloud-Init Drive", systemImage: "plus.circle")
                            }
                        } else {
                            Text("No Cloud-Init drive")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Cloud-Init Drive")
                    }

                    Section {
                        if canEditBootOrder {
                            Button {
                                showingBootOrder = true
                            } label: {
                                Label("Edit Boot Order", systemImage: "list.number")
                            }
                        }
                        ForEach(advancedDevices) { device in
                            hardwareDeviceRow(device) {
                                deletingAdvancedDevice = device
                            }
                        }
                        if canEditDisks || canEditAdvancedDevices {
                            Menu {
                                if canEditDisks, !advancedDevices.contains(where: { $0.kind == .efi }) {
                                    Button("EFI Disk") { addingAdvancedDevice = .efi }
                                }
                                if canEditDisks, !advancedDevices.contains(where: { $0.kind == .tpm }) {
                                    Button("TPM State") { addingAdvancedDevice = .tpm }
                                }
                                if canEditAdvancedDevices {
                                    Button("PCI Device") { addingAdvancedDevice = .pci }
                                    Button("USB Device") { addingAdvancedDevice = .usb }
                                    Button("Serial Port") { addingAdvancedDevice = .serial }
                                }
                            } label: {
                                Label("Add Advanced Device", systemImage: "plus.circle")
                            }
                        }
                    } header: {
                        Text("Boot & Advanced Devices")
                    }
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
            .sheet(item: $movingDisk) { disk in
                MoveGuestDiskView(guest: guest, disk: disk) { await reload() }
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
            .sheet(isPresented: $showingAddCloudInitDrive) {
                AddCloudInitDriveView(guest: guest, config: config) {
                    await reload()
                }
                .environmentObject(appState)
            }
            .sheet(item: $editingCDROM) { device in
                GuestCDROMEditorView(guest: guest, config: config, device: device) {
                    await reload()
                }
                .environmentObject(appState)
            }
            .sheet(isPresented: $showingAddCDROM) {
                GuestCDROMEditorView(guest: guest, config: config, device: nil) {
                    await reload()
                }
                .environmentObject(appState)
            }
            .sheet(isPresented: $showingBootOrder) {
                GuestBootOrderEditorView(guest: guest, config: config) { await reload() }
                    .environmentObject(appState)
            }
            .sheet(item: $addingAdvancedDevice) { kind in
                AddGuestAdvancedDeviceView(guest: guest, config: config, kind: kind) {
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
            .confirmationDialog(
                "Detach Disk?",
                isPresented: Binding(
                    get: { diskToDetach != nil },
                    set: { if !$0 { diskToDetach = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Detach") {
                    guard let disk = diskToDetach else { return }
                    Task { await unlink(disk, permanentlyDelete: false) }
                }
            } message: {
                Text("The disk is detached and kept as an unused volume.")
            }
            .confirmationDialog(
                "Delete Disk Permanently?",
                isPresented: Binding(
                    get: { diskToDelete != nil },
                    set: { if !$0 { diskToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    guard let disk = diskToDelete else { return }
                    Task { await unlink(disk, permanentlyDelete: true) }
                }
            } message: {
                Text("The disk volume and all data on it will be permanently deleted.")
            }
            .confirmationDialog(
                "Remove Hardware Device?",
                isPresented: Binding(
                    get: { deletingAdvancedDevice != nil },
                    set: { if !$0 { deletingAdvancedDevice = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    guard let device = deletingAdvancedDevice else { return }
                    Task { await removeAdvancedDevice(device) }
                }
            }
        }
    }

    private func hardwareDeviceRow(
        _ device: GuestHardwareDevice,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.kind.systemImage)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.key.uppercased())
                    .font(.body.weight(.medium))
                Text(device.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if canEdit(device) {
                Button(action: action) {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func canEdit(_ device: GuestHardwareDevice) -> Bool {
        switch device.kind {
        case .cdrom: return canEditCDROM
        case .efi, .tpm: return canEditDisks
        case .pci, .usb, .serial: return canEditAdvancedDevices
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

    @MainActor
    private func unlink(_ disk: GuestHardwareDisk, permanentlyDelete: Bool) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer {
            isWorking = false
            diskToDetach = nil
            diskToDelete = nil
        }
        do {
            let upid: String
            if guest.type == .lxc {
                upid = try await service.deleteLXCVolume(
                    node: guest.node,
                    vmid: guest.vmid,
                    volume: disk.key
                )
            } else {
                upid = try await service.unlinkGuestDisk(
                    node: guest.node,
                    vmid: guest.vmid,
                    disk: disk.key,
                    permanentlyDelete: permanentlyDelete
                )
            }
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: permanentlyDelete
                        ? String(localized: "Delete disk")
                        : String(localized: "Detach disk"),
                    object: "\(guest.displayName) · \(disk.key)",
                    service: service
                )
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func removeAdvancedDevice(_ device: GuestHardwareDevice) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer {
            isWorking = false
            deletingAdvancedDevice = nil
        }
        do {
            _ = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: ["delete": device.key]
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

    @State private var settings: GuestNetworkSettings
    @State private var isSaving = false
    @State private var error: String?

    init(
        guest: ProxmoxVM,
        config: GuestConfig,
        network: GuestHardwareNetwork?,
        onSaved: @escaping () async -> Void
    ) {
        self.guest = guest
        self.config = config
        self.network = network
        self.onSaved = onSaved

        let key = network?.key ?? (0..<32)
            .map { "net\($0)" }
            .first { !config.rawValues.keys.contains($0) }
        let index = key.flatMap { Int($0.dropFirst("net".count)) } ?? 0
        _settings = State(initialValue: GuestNetworkSettings(
            type: guest.type,
            value: network?.value,
            interfaceName: "eth\(index)"
        ))
    }

    private var key: String? {
        if let network { return network.key }
        let existing = Set(config.rawValues.keys)
        return (0..<32).map { "net\($0)" }.first { !existing.contains($0) }
    }

    private var canSave: Bool {
        key != nil && settings.isValid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Interface", value: key?.uppercased() ?? "—")
                    if guest.type == .qemu {
                        Picker("Model", selection: $settings.model) {
                            Text("VirtIO").tag("virtio")
                            Text("Intel E1000").tag("e1000")
                            Text("VMware VMXNET3").tag("vmxnet3")
                            Text("Realtek RTL8139").tag("rtl8139")
                        }
                    } else {
                        TextField("Interface Name", text: $settings.interfaceName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("Bridge", text: $settings.bridge)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("VLAN Tag (optional)", text: $settings.vlanTag)
                        .keyboardType(.numberPad)
                }

                if guest.type == .lxc {
                    containerIPSection
                }

                Section {
                    TextField("MAC Address (optional)", text: $settings.macAddress)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Toggle("Firewall", isOn: $settings.firewall)
                    Toggle("Disconnected", isOn: $settings.linkDown)
                    TextField("Rate Limit (MB/s, optional)", text: $settings.rateLimit)
                        .keyboardType(.decimalPad)
                    TextField("MTU (optional)", text: $settings.mtu)
                        .keyboardType(.numberPad)
                    if guest.type == .qemu {
                        TextField("Multiqueue (optional)", text: $settings.queues)
                            .keyboardType(.numberPad)
                    }
                    TextField("VLAN Trunks (optional)", text: $settings.trunks)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Use semicolons between VLAN trunk IDs.")
                }

                if !settings.isValid {
                    Section {
                        Label(
                            "Check the MAC, IP/CIDR, gateway, VLAN, rate limit, MTU and queue values.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
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
        }
    }

    private var containerIPSection: some View {
        Section {
            Picker("IPv4 Configuration", selection: $settings.ipv4Mode) {
                Text("No Configuration").tag(GuestNetworkSettings.IPMode.unspecified)
                Text("DHCP").tag(GuestNetworkSettings.IPMode.dhcp)
                Text("Static").tag(GuestNetworkSettings.IPMode.static)
                Text("Manual").tag(GuestNetworkSettings.IPMode.manual)
            }
            if settings.ipv4Mode == .static {
                TextField("IPv4 Address / CIDR", text: $settings.ipv4Address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("IPv4 Gateway (optional)", text: $settings.ipv4Gateway)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Picker("IPv6 Configuration", selection: $settings.ipv6Mode) {
                Text("No Configuration").tag(GuestNetworkSettings.IPMode.unspecified)
                Text("Automatic").tag(GuestNetworkSettings.IPMode.automatic)
                Text("DHCP").tag(GuestNetworkSettings.IPMode.dhcp)
                Text("Static").tag(GuestNetworkSettings.IPMode.static)
                Text("Manual").tag(GuestNetworkSettings.IPMode.manual)
            }
            if settings.ipv6Mode == .static {
                TextField("IPv6 Address / CIDR", text: $settings.ipv6Address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("IPv6 Gateway (optional)", text: $settings.ipv6Gateway)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("IP Configuration")
        }
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
                form: [key: settings.encodedValue]
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
