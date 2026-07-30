import SwiftUI

struct GuestEditorView: View {
    enum Mode {
        case create
        case edit(guest: ProxmoxVM, config: GuestConfig)
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSaved: () -> Void

    @State private var selectedType: GuestType = .qemu
    @State private var selectedNode = ""
    @State private var vmidText = ""
    @State private var name = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var cores = 2
    @State private var sockets = 1
    @State private var memoryMiBText = "2048"
    @State private var swapMiBText = "512"
    @State private var selectedStorage = ""
    @State private var diskSizeGiBText = "32"
    @State private var bridge = "vmbr0"
    @State private var osType = "l26"
    @State private var selectedInstallationVolume = ""
    @State private var rootPassword = ""
    @State private var unprivileged = true
    @State private var onBoot = false
    @State private var startAfterCreation = false

    @State private var nodes: [ProxmoxNode] = []
    @State private var storages: [ProxmoxStorage] = []
    @State private var installationMedia: [ProxmoxStorageContent] = []
    @State private var isLoadingContext = false
    @State private var loadingResourcesForNode: String?
    @State private var isSaving = false
    @State private var error: String?

    init(mode: Mode, onSaved: @escaping () -> Void) {
        self.mode = mode
        self.onSaved = onSaved

        if case .edit(let guest, let config) = mode {
            _selectedType = State(initialValue: guest.type)
            _selectedNode = State(initialValue: guest.node)
            _vmidText = State(initialValue: "\(guest.vmid)")
            _name = State(initialValue: config.name ?? config.hostname ?? guest.displayName)
            _description = State(initialValue: config.description ?? "")
            _tags = State(initialValue: config.tags ?? "")
            _cores = State(initialValue: config.cores ?? config.vcpus ?? Int(guest.cpus ?? 1))
            _sockets = State(initialValue: config.sockets ?? 1)
            _memoryMiBText = State(initialValue: "\(config.memory ?? 512)")
            _swapMiBText = State(initialValue: "\(config.swap ?? 512)")
            _osType = State(initialValue: config.ostype ?? "l26")
            _unprivileged = State(initialValue: config.unprivileged != 0)
            _onBoot = State(initialValue: config.onboot == 1)
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var isLoading: Bool {
        isLoadingContext || loadingResourcesForNode != nil
    }

    private var guestNameLabel: String {
        selectedType == .qemu ? String(localized: "Name") : String(localized: "Hostname")
    }

    private var editedGuest: ProxmoxVM? {
        if case .edit(let guest, _) = mode { return guest }
        return nil
    }

    private var originalConfig: GuestConfig? {
        if case .edit(_, let config) = mode { return config }
        return nil
    }

    private var compatibleStorages: [ProxmoxStorage] {
        let requiredContent = selectedType == .qemu ? "images" : "rootdir"
        return storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains(requiredContent) &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    private var compatibleMedia: [ProxmoxStorageContent] {
        let content = selectedType == .qemu ? "iso" : "vztmpl"
        return installationMedia
            .filter { $0.content == content }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var canEditOptions: Bool {
        guard let vmid = editedGuest?.vmid else { return true }
        return appState.hasPrivilege("VM.Config.Options", for: vmid)
    }

    private var canEditCPU: Bool {
        guard let vmid = editedGuest?.vmid else { return true }
        return appState.hasPrivilege("VM.Config.CPU", for: vmid)
    }

    private var canEditMemory: Bool {
        guard let vmid = editedGuest?.vmid else { return true }
        return appState.hasPrivilege("VM.Config.Memory", for: vmid)
    }

    private var canSave: Bool {
        guard !isSaving,
              let vmid = Int(vmidText),
              (100...999_999_999).contains(vmid),
              !name.trimmed.isEmpty,
              !name.contains(where: \.isWhitespace),
              let memory = Int(memoryMiBText), memory >= 128 else {
            return false
        }

        if isCreating {
            guard !selectedNode.isEmpty,
                  !selectedStorage.isEmpty,
                  let disk = Int(diskSizeGiBText), disk >= 1,
                  !bridge.trimmed.isEmpty else {
                return false
            }
            if selectedType == .lxc {
                return !selectedInstallationVolume.isEmpty &&
                    rootPassword.count >= 5 &&
                    (Int(swapMiBText) ?? -1) >= 0 &&
                    (unprivileged || appState.hasPrivilege("Sys.Modify", on: "/"))
            }
        }

        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreating {
                    creationIdentitySection
                    creationResourcesSection
                    installationSection
                    networkSection
                } else {
                    editIdentitySection
                    editResourcesSection
                }

                optionsSection

                if !isCreating, editedGuest?.isRunning == true {
                    Section {
                        Label(
                            "Some configuration changes may require a guest restart.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
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
            .navigationTitle(isCreating ? String(localized: "Create Guest") : String(localized: "Edit Guest"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? String(localized: "Create") : String(localized: "Save")) {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .overlay {
                if isLoading || isSaving {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView(
                        isSaving ? String(localized: "Saving…") : String(localized: "Loading…")
                    )
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .task {
                if isCreating {
                    await loadCreationContext()
                }
            }
            .task(id: selectedNode) {
                guard isCreating, !selectedNode.isEmpty else { return }
                await loadNodeResources(node: selectedNode)
            }
            .onChange(of: selectedType) { _ in
                selectCompatibleDefaults()
            }
        }
    }

    private var creationIdentitySection: some View {
        Section {
            Picker("Guest Type", selection: $selectedType) {
                Text("Virtual Machine").tag(GuestType.qemu)
                Text("Container").tag(GuestType.lxc)
            }

            Picker("Node", selection: $selectedNode) {
                ForEach(nodes.filter(\.isOnline)) { node in
                    Text(node.node).tag(node.node)
                }
            }

            TextField("VMID", text: $vmidText)
                .keyboardType(.numberPad)
            TextField(guestNameLabel, text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Identity")
        } footer: {
            Text("Names cannot contain spaces.")
        }
    }

    private var creationResourcesSection: some View {
        Section {
            Stepper("CPU cores: \(cores)", value: $cores, in: 1...128)
            if selectedType == .qemu {
                Stepper("CPU sockets: \(sockets)", value: $sockets, in: 1...4)
            }

            TextField("Memory (MiB)", text: $memoryMiBText)
                .keyboardType(.numberPad)
            if selectedType == .lxc {
                TextField("Swap (MiB)", text: $swapMiBText)
                    .keyboardType(.numberPad)
            }

            Picker("Storage", selection: $selectedStorage) {
                ForEach(compatibleStorages) { storage in
                    Text(storage.storage).tag(storage.storage)
                }
            }

            TextField("Disk size (GiB)", text: $diskSizeGiBText)
                .keyboardType(.numberPad)

            if compatibleStorages.isEmpty, !isLoading {
                Text("No compatible storage is available with allocation permission.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Resources")
        }
    }

    @ViewBuilder
    private var installationSection: some View {
        Section {
            if selectedType == .qemu {
                Picker("Operating System", selection: $osType) {
                    Text("Linux").tag("l26")
                    Text("Windows 11 / Server 2022").tag("win11")
                    Text("Windows 10 / Server 2016–2019").tag("win10")
                    Text("Other").tag("other")
                }

                Picker("Installation ISO", selection: $selectedInstallationVolume) {
                    Text("None").tag("")
                    ForEach(compatibleMedia) { item in
                        Text(item.displayName).tag(item.volid)
                    }
                }
            } else {
                Picker("Container Template", selection: $selectedInstallationVolume) {
                    ForEach(compatibleMedia) { item in
                        Text(item.displayName).tag(item.volid)
                    }
                }
                SecureField("Root password", text: $rootPassword)
                Text("The root password must be at least five characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Unprivileged container", isOn: $unprivileged)
                    .disabled(!appState.hasPrivilege("Sys.Modify", on: "/") && unprivileged)

                if compatibleMedia.isEmpty, !isLoading {
                    Text("No accessible container template was found on this node.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Installation")
        }
    }

    private var networkSection: some View {
        Section {
            TextField("Bridge", text: $bridge)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Network")
        } footer: {
            Text("The selected account also needs permission to use this bridge.")
        }
    }

    private var editIdentitySection: some View {
        Section {
            LabeledContent("Type", value: selectedType.label)
            LabeledContent("Node", value: selectedNode)
            LabeledContent("VMID", value: vmidText)
            TextField(guestNameLabel, text: $name)
                .disabled(!canEditOptions)
            TextField("Description", text: $description, axis: .vertical)
                .lineLimit(2...5)
                .disabled(!canEditOptions)
            TextField("Tags", text: $tags)
                .disabled(!canEditOptions)
        } header: {
            Text("Identity")
        }
    }

    private var editResourcesSection: some View {
        Section {
            Stepper("CPU cores: \(cores)", value: $cores, in: 1...128)
                .disabled(!canEditCPU)
            if selectedType == .qemu {
                Stepper("CPU sockets: \(sockets)", value: $sockets, in: 1...4)
                    .disabled(!canEditCPU)
            }
            TextField("Memory (MiB)", text: $memoryMiBText)
                .keyboardType(.numberPad)
                .disabled(!canEditMemory)
            if selectedType == .lxc {
                TextField("Swap (MiB)", text: $swapMiBText)
                    .keyboardType(.numberPad)
                    .disabled(!canEditMemory)
            }
        } header: {
            Text("Resources")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Start on boot", isOn: $onBoot)
                .disabled(!isCreating && !canEditOptions)
            if isCreating {
                Toggle("Start after creation", isOn: $startAfterCreation)
            }
        } header: {
            Text("Options")
        }
    }

    @MainActor
    private func loadCreationContext() async {
        guard let service = appState.service else { return }
        isLoadingContext = true
        error = nil
        defer { isLoadingContext = false }
        do {
            async let nodesRequest = service.fetchNodes()
            async let vmidRequest = service.fetchNextVMID()
            let (loadedNodes, nextVMID) = try await (nodesRequest, vmidRequest)
            nodes = loadedNodes
            vmidText = "\(nextVMID)"
            if selectedNode.isEmpty {
                selectedNode = loadedNodes.first(where: \.isOnline)?.node ?? ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadNodeResources(node: String) async {
        guard let service = appState.service else { return }
        loadingResourcesForNode = node
        error = nil
        defer {
            if loadingResourcesForNode == node {
                loadingResourcesForNode = nil
            }
        }
        do {
            let loadedStorages = try await service.fetchStorages(node: node)
            var media: [ProxmoxStorageContent] = []
            for storage in loadedStorages where
                storage.isAvailable &&
                (storage.storageTypes.contains("iso") || storage.storageTypes.contains("vztmpl")) {
                if let content = try? await service.fetchStorageContent(
                    node: node,
                    storage: storage.storage
                ) {
                    media.append(contentsOf: content.filter {
                        $0.content == "iso" || $0.content == "vztmpl"
                    })
                }
            }
            guard node == selectedNode else { return }
            storages = loadedStorages
            installationMedia = media
            selectCompatibleDefaults()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func selectCompatibleDefaults() {
        if !compatibleStorages.contains(where: { $0.storage == selectedStorage }) {
            selectedStorage = compatibleStorages.first?.storage ?? ""
        }
        if selectedType == .lxc {
            if !compatibleMedia.contains(where: { $0.volid == selectedInstallationVolume }) {
                selectedInstallationVolume = compatibleMedia.first?.volid ?? ""
            }
            if memoryMiBText == "2048" { memoryMiBText = "512" }
            if diskSizeGiBText == "32" { diskSizeGiBText = "8" }
        } else {
            if !compatibleMedia.contains(where: { $0.volid == selectedInstallationVolume }) {
                selectedInstallationVolume = ""
            }
            if memoryMiBText == "512" { memoryMiBText = "2048" }
            if diskSizeGiBText == "8" { diskSizeGiBText = "32" }
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        do {
            if isCreating {
                try await createGuest(service: service)
            } else {
                try await updateGuest(service: service)
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createGuest(service: ProxmoxAPIService) async throws {
        guard let vmid = Int(vmidText),
              let memory = Int(memoryMiBText),
              let diskSize = Int(diskSizeGiBText) else {
            return
        }

        let request = GuestCreateRequest(
            node: selectedNode,
            type: selectedType,
            vmid: vmid,
            name: name.trimmed,
            cores: cores,
            sockets: sockets,
            memoryMiB: memory,
            onBoot: onBoot,
            startAfterCreation: startAfterCreation,
            storage: selectedStorage,
            diskSizeGiB: diskSize,
            bridge: bridge.trimmed,
            osType: osType,
            installationVolume: selectedInstallationVolume.isEmpty ? nil : selectedInstallationVolume,
            rootPassword: selectedType == .lxc ? rootPassword : nil,
            swapMiB: Int(swapMiBText) ?? 0,
            unprivileged: unprivileged
        )

        let upid = try await service.createGuest(request)
        if !upid.isEmpty {
            appState.taskCenter.track(
                upid: upid,
                node: selectedNode,
                title: selectedType == .qemu
                    ? String(localized: "Create virtual machine")
                    : String(localized: "Create container"),
                object: "\(name.trimmed) · \(vmid)",
                service: service
            )
            _ = try await service.waitForTask(node: selectedNode, upid: upid)
        }
    }

    private func updateGuest(service: ProxmoxAPIService) async throws {
        guard let guest = editedGuest, let original = originalConfig else { return }
        var form: [String: String] = [:]
        var deletedOptions: [String] = []

        if canEditOptions {
            let originalName = original.name ?? original.hostname ?? guest.displayName
            if name.trimmed != originalName {
                form[selectedType == .qemu ? "name" : "hostname"] = name.trimmed
            }
            if description.trimmed != (original.description ?? "") {
                if description.trimmed.isEmpty {
                    deletedOptions.append("description")
                } else {
                    form["description"] = description.trimmed
                }
            }
            if tags.trimmed != (original.tags ?? "") {
                if tags.trimmed.isEmpty {
                    deletedOptions.append("tags")
                } else {
                    form["tags"] = tags.trimmed
                }
            }
            if onBoot != (original.onboot == 1) {
                form["onboot"] = onBoot ? "1" : "0"
            }
        }

        if canEditCPU {
            if cores != (original.cores ?? original.vcpus ?? 1) {
                form["cores"] = "\(cores)"
            }
            if selectedType == .qemu, sockets != (original.sockets ?? 1) {
                form["sockets"] = "\(sockets)"
            }
        }

        if canEditMemory {
            if let memory = Int(memoryMiBText), memory != Int(original.memory ?? 512) {
                form["memory"] = "\(memory)"
            }
            if selectedType == .lxc,
               let swap = Int(swapMiBText),
               swap != Int(original.swap ?? 512) {
                form["swap"] = "\(swap)"
            }
        }

        if !deletedOptions.isEmpty {
            form["delete"] = deletedOptions.joined(separator: ",")
        }

        _ = try await service.updateGuest(
            node: guest.node,
            type: guest.type,
            vmid: guest.vmid,
            form: form
        )
    }
}
