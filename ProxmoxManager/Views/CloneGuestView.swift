import SwiftUI

struct CloneGuestView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let onCloned: () -> Void

    @State private var vmidText = ""
    @State private var name: String
    @State private var description = ""
    @State private var selectedStorage = ""
    @State private var storages: [ProxmoxStorage] = []
    @State private var isLoading = false
    @State private var isCloning = false
    @State private var error: String?

    init(guest: ProxmoxVM, onCloned: @escaping () -> Void) {
        self.guest = guest
        self.onCloned = onCloned
        _name = State(
            initialValue: guest.displayName
                .replacingOccurrences(of: " ", with: "-") + "-copy"
        )
    }

    private var nameLabel: String {
        guest.type == .qemu ? String(localized: "Name") : String(localized: "Hostname")
    }

    private var compatibleStorages: [ProxmoxStorage] {
        let requiredContent = guest.type == .qemu ? "images" : "rootdir"
        return storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains(requiredContent) &&
            appState.hasPrivilege("Datastore.AllocateSpace", on: "/storage/\($0.storage)")
        }
    }

    private var canClone: Bool {
        guard !isCloning,
              let vmid = Int(vmidText),
              (100...999_999_999).contains(vmid),
              !name.trimmed.isEmpty,
              !name.contains(where: \.isWhitespace),
              appState.hasPrivilege("VM.Allocate", on: "/vms/\(vmid)") else {
            return false
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Source", value: "\(guest.displayName) · \(guest.vmid)")
                    LabeledContent("Node", value: guest.node)
                    LabeledContent("Clone Type", value: String(localized: "Full clone"))
                } header: {
                    Text("Source Guest")
                }

                Section {
                    TextField("VMID", text: $vmidText)
                        .keyboardType(.numberPad)
                    TextField(nameLabel, text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("New Guest")
                } footer: {
                    Text("The new guest receives an independent copy of all disks.")
                }

                Section {
                    Picker("Target Storage", selection: $selectedStorage) {
                        Text("Same as source").tag("")
                        ForEach(compatibleStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Selecting a target storage places all cloned disks on that storage.")
                }

                if let vmid = Int(vmidText),
                   !appState.hasPrivilege("VM.Allocate", on: "/vms/\(vmid)") {
                    Section {
                        Label(
                            "This account cannot allocate the selected VMID.",
                            systemImage: "lock.trianglebadge.exclamationmark"
                        )
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
            .navigationTitle("Clone Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCloning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") {
                        Task { await clone() }
                    }
                    .disabled(!canClone)
                }
            }
            .overlay {
                if isLoading || isCloning {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView(
                        isCloning ? String(localized: "Cloning…") : String(localized: "Loading…")
                    )
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let vmidRequest = service.fetchNextVMID()
            async let storageRequest = service.fetchStorages(node: guest.node)
            let (nextVMID, loadedStorages) = try await (vmidRequest, storageRequest)
            vmidText = "\(nextVMID)"
            storages = loadedStorages
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func clone() async {
        guard let service = appState.service,
              let newVMID = Int(vmidText),
              canClone else {
            return
        }
        isCloning = true
        error = nil
        defer { isCloning = false }

        do {
            let request = GuestCloneRequest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                newVMID: newVMID,
                name: name.trimmed,
                description: description,
                storage: selectedStorage.isEmpty ? nil : selectedStorage,
                full: true
            )
            let upid = try await service.cloneGuest(request)
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: guest.node,
                    title: guest.type == .qemu
                        ? String(localized: "Clone virtual machine")
                        : String(localized: "Clone container"),
                    object: "\(name.trimmed) · \(newVMID)",
                    service: service
                )
                _ = try await service.waitForTask(node: guest.node, upid: upid)
            }
            onCloned()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
