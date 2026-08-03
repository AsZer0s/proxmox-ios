import SwiftUI

enum GuestAdvancedDeviceKind: String, Identifiable {
    case cdrom
    case efi
    case tpm
    case pci
    case usb
    case serial

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cdrom: return String(localized: "CD/DVD Drive")
        case .efi: return String(localized: "EFI Disk")
        case .tpm: return String(localized: "TPM State")
        case .pci: return String(localized: "PCI Device")
        case .usb: return String(localized: "USB Device")
        case .serial: return String(localized: "Serial Port")
        }
    }

    var systemImage: String {
        switch self {
        case .cdrom: return "opticaldiscdrive"
        case .efi: return "memorychip"
        case .tpm: return "lock.shield"
        case .pci: return "rectangle.connected.to.line.below"
        case .usb: return "cable.connector"
        case .serial: return "terminal"
        }
    }
}

struct GuestHardwareDevice: Identifiable {
    let key: String
    let value: String
    let kind: GuestAdvancedDeviceKind

    var id: String { key }
}

struct MoveGuestDiskView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let disk: GuestHardwareDisk
    let onSaved: () async -> Void

    @State private var storages: [ProxmoxStorage] = []
    @State private var selectedStorage = ""
    @State private var deleteSource = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var currentStorage: String {
        disk.value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    }

    private var compatibleStorages: [ProxmoxStorage] {
        storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains("images") &&
            $0.storage != currentStorage &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Disk", value: disk.key.uppercased())
                    LabeledContent("Current Storage", value: currentStorage)
                    Picker("Target Storage", selection: $selectedStorage) {
                        ForEach(compatibleStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                    Toggle("Delete Source After Move", isOn: $deleteSource)
                } footer: {
                    Text("Keeping the source leaves it attached as an unused disk after the copy completes.")
                }
                if compatibleStorages.isEmpty, !isLoading {
                    Text("No other compatible storage is available.")
                        .foregroundStyle(.red)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Move Disk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { Task { await move() } }
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
    private func move() async {
        guard let service = appState.service, !selectedStorage.isEmpty else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let upid = try await service.moveGuestDisk(
                node: guest.node,
                vmid: guest.vmid,
                disk: disk.key,
                storage: selectedStorage,
                deleteSource: deleteSource
            )
            appState.taskCenter.track(
                upid: upid,
                node: guest.node,
                title: String(localized: "Move disk"),
                object: "\(guest.displayName) · \(disk.key)",
                service: service
            )
            _ = try await service.waitForTask(node: guest.node, upid: upid)
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GuestCDROMEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let config: GuestConfig
    let device: GuestHardwareDevice?
    let onSaved: () async -> Void

    @State private var media: [ProxmoxStorageContent] = []
    @State private var selectedVolume: String
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    init(
        guest: ProxmoxVM,
        config: GuestConfig,
        device: GuestHardwareDevice?,
        onSaved: @escaping () async -> Void
    ) {
        self.guest = guest
        self.config = config
        self.device = device
        self.onSaved = onSaved
        let current = device?.value.split(separator: ",").first.map(String.init) ?? ""
        _selectedVolume = State(initialValue: current == "none" ? "" : current)
    }

    private var slot: String? {
        if let device { return device.key }
        let keys = Set(config.rawValues.keys)
        let candidates = (0...3).map { "ide\($0)" } + (0...5).map { "sata\($0)" }
        return candidates.first { !keys.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Slot", value: slot?.uppercased() ?? "—")
                    Picker("Installation Media", selection: $selectedVolume) {
                        Text("Empty Drive").tag("")
                        ForEach(media) { item in
                            Text(item.displayName).tag(item.volid)
                        }
                    }
                }
                if media.isEmpty, !isLoading {
                    Text("No ISO images are available on accessible storage.")
                        .foregroundStyle(.secondary)
                }
                if device != nil {
                    Section {
                        Button("Remove CD/DVD Drive", role: .destructive) {
                            Task { await remove() }
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(device == nil ? "Add CD/DVD Drive" : "Edit CD/DVD Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(slot == nil || isSaving)
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
            let storages = try await service.fetchStorages(node: guest.node)
            var loaded: [ProxmoxStorageContent] = []
            for storage in storages where storage.isAvailable && storage.storageTypes.contains("iso") {
                let values = try? await service.fetchStorageContent(
                    node: guest.node,
                    storage: storage.storage,
                    content: "iso"
                )
                loaded.append(contentsOf: values ?? [])
            }
            media = loaded.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, let slot else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            _ = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: [slot: "\(selectedVolume.isEmpty ? "none" : selectedVolume),media=cdrom"]
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func remove() async {
        guard let service = appState.service, let device else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: ["delete": device.key]
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GuestBootOrderEditorView: View {
    private struct BootItem: Identifiable {
        let id: String
        var enabled: Bool
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let onSaved: () async -> Void
    @State private var items: [BootItem]
    @State private var isSaving = false
    @State private var error: String?

    init(guest: ProxmoxVM, config: GuestConfig, onSaved: @escaping () async -> Void) {
        self.guest = guest
        self.onSaved = onSaved
        let eligible = config.rawValues.keys.filter {
            $0.range(of: #"^(scsi|virtio|sata|ide|net)\d+$"#, options: .regularExpression) != nil
        }
        let configured = config.boot?
            .split(separator: ";")
            .map(String.init)
            .map { $0.replacingOccurrences(of: "order=", with: "") } ?? []
        var ordered = configured.filter { eligible.contains($0) }
        ordered.append(contentsOf: eligible.filter { !ordered.contains($0) }.sorted())
        _items = State(initialValue: ordered.map { BootItem(id: $0, enabled: configured.contains($0)) })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($items) { $item in
                    Toggle(item.id.uppercased(), isOn: $item.enabled)
                }
                .onMove { source, destination in
                    items.move(fromOffsets: source, toOffset: destination)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Boot Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!items.contains(where: \.enabled) || isSaving)
                }
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
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
            let order = items.filter(\.enabled).map(\.id).joined(separator: ";")
            _ = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: ["boot": "order=\(order)"]
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddGuestAdvancedDeviceView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let config: GuestConfig
    let kind: GuestAdvancedDeviceKind
    let onSaved: () async -> Void

    @State private var storages: [ProxmoxStorage] = []
    @State private var pciDevices: [ProxmoxPCIDevice] = []
    @State private var usbDevices: [ProxmoxUSBDevice] = []
    @State private var selection = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var key: String? {
        let keys = Set(config.rawValues.keys)
        switch kind {
        case .efi: return keys.contains("efidisk0") ? nil : "efidisk0"
        case .tpm: return keys.contains("tpmstate0") ? nil : "tpmstate0"
        case .pci: return (0..<16).map { "hostpci\($0)" }.first { !keys.contains($0) }
        case .usb: return (0..<15).map { "usb\($0)" }.first { !keys.contains($0) }
        case .serial: return (0..<4).map { "serial\($0)" }.first { !keys.contains($0) }
        case .cdrom: return nil
        }
    }

    private var imageStorages: [ProxmoxStorage] {
        storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains("images") &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Device", value: key?.uppercased() ?? "—")
                    selectionView
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(String(localized: "Add Device: \(kind.label)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(key == nil || selection.isEmpty || isSaving)
                }
            }
            .overlay { if isLoading || isSaving { ProgressView() } }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var selectionView: some View {
        switch kind {
        case .efi, .tpm:
            Picker("Storage", selection: $selection) {
                ForEach(imageStorages) { storage in
                    Text(storage.storage).tag(storage.storage)
                }
            }
        case .pci:
            Picker("PCI Device", selection: $selection) {
                ForEach(pciDevices) { device in
                    Text([device.vendorName, device.deviceName, device.id]
                        .compactMap { $0 }.joined(separator: " · "))
                        .tag(device.id)
                }
            }
        case .usb:
            Picker("USB Device", selection: $selection) {
                ForEach(usbDevices) { device in
                    Text([device.manufacturer, device.product, "\(device.vendorID):\(device.productID)"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .tag(device.selector)
                }
            }
        case .serial:
            Picker("Serial Backend", selection: $selection) {
                Text("Socket").tag("socket")
            }
        case .cdrom:
            EmptyView()
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch kind {
            case .efi, .tpm:
                storages = try await service.fetchStorages(node: guest.node)
                selection = imageStorages.first?.storage ?? ""
            case .pci:
                pciDevices = try await service.fetchNodePCIDevices(node: guest.node)
                selection = pciDevices.first?.id ?? ""
            case .usb:
                usbDevices = try await service.fetchNodeUSBDevices(node: guest.node)
                selection = usbDevices.first?.selector ?? ""
            case .serial:
                selection = "socket"
            case .cdrom:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, let key, !selection.isEmpty else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let value: String
        switch kind {
        case .efi:
            value = "\(selection):1,efitype=4m,pre-enrolled-keys=1"
        case .tpm:
            value = "\(selection):1,version=v2.0"
        case .pci:
            value = "\(selection),pcie=1"
        case .usb, .serial:
            value = selection
        case .cdrom:
            return
        }
        do {
            let upid = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: [key: value]
            )
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: String(localized: "Add hardware device"),
                    object: "\(guest.displayName) · \(key)",
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
