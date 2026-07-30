import SwiftUI

struct InstallationMediaManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let node: String
    let type: GuestType
    let storages: [ProxmoxStorage]
    let onDownloaded: (String?) -> Void

    @State private var selectedStorage = ""
    @State private var templates: [ApplianceTemplate] = []
    @State private var selectedTemplate = ""
    @State private var searchText = ""
    @State private var urlText = ""
    @State private var filename = ""
    @State private var checksum = ""
    @State private var checksumAlgorithm = "sha256"
    @State private var verifyCertificates = true
    @State private var isLoading = false
    @State private var isDownloading = false
    @State private var error: String?

    private var contentType: String {
        type == .qemu ? "iso" : "vztmpl"
    }

    private var downloadStorages: [ProxmoxStorage] {
        storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains(contentType) &&
            appState.hasPrivilege("Datastore.AllocateTemplate", on: "/storage/\($0.storage)")
        }
    }

    private var filteredTemplates: [ApplianceTemplate] {
        guard !searchText.trimmed.isEmpty else { return templates }
        return templates.filter {
            $0.template.localizedCaseInsensitiveContains(searchText) ||
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            ($0.headline?.localizedCaseInsensitiveContains(searchText) == true) ||
            ($0.section?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    private var canUseNodeNetwork: Bool {
        appState.hasPrivilege("Sys.AccessNetwork", on: "/nodes/\(node)") ||
        appState.hasPrivilege("Sys.Modify", on: "/") ||
        appState.hasPrivilege("Sys.Audit", on: "/")
    }

    private var validDownloadURL: URL? {
        guard let url = URL(string: urlText.trimmed),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private var canDownload: Bool {
        guard !isDownloading, !selectedStorage.isEmpty else { return false }
        if type == .lxc {
            return !selectedTemplate.isEmpty
        }
        return validDownloadURL != nil &&
            !filename.trimmed.isEmpty &&
            canUseNodeNetwork
    }

    var body: some View {
        NavigationStack {
            Group {
                if type == .qemu {
                    isoForm
                } else {
                    templateList
                        .searchable(text: $searchText, prompt: "Search templates")
                        .refreshable { await loadTemplates() }
                }
            }
            .navigationTitle(
                type == .qemu
                    ? String(localized: "Import ISO")
                    : String(localized: "Download Template")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDownloading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        Task { await download() }
                    }
                    .disabled(!canDownload)
                }
            }
            .overlay {
                if isLoading || isDownloading {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView(
                        isDownloading
                            ? String(localized: "Downloading…")
                            : String(localized: "Loading…")
                    )
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .task {
                selectDefaultStorage()
                if type == .lxc {
                    await loadTemplates()
                }
            }
        }
    }

    private var storagePicker: some View {
        Picker("Destination Storage", selection: $selectedStorage) {
            ForEach(downloadStorages) { storage in
                Text(storage.storage).tag(storage.storage)
            }
        }
    }

    private var isoForm: some View {
        Form {
            Section {
                storagePicker
                TextField("Download URL", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: urlText) { value in
                        guard filename.trimmed.isEmpty,
                              let candidate = URL(string: value)?.lastPathComponent,
                              !candidate.isEmpty else {
                            return
                        }
                        filename = candidate
                    }
                TextField("Filename", text: $filename)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Source")
            }

            Section {
                TextField("Checksum (optional)", text: $checksum)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !checksum.isEmpty {
                    Picker("Checksum Algorithm", selection: $checksumAlgorithm) {
                        Text("SHA-256").tag("sha256")
                        Text("SHA-512").tag("sha512")
                        Text("SHA-1").tag("sha1")
                        Text("MD5").tag("md5")
                    }
                }
                Toggle("Verify TLS certificates", isOn: $verifyCertificates)
            } header: {
                Text("Verification")
            }

            if !canUseNodeNetwork {
                Section {
                    Label(
                        "This account cannot start downloads from the node network.",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    )
                    .foregroundStyle(.red)
                }
            }

            statusSections
        }
    }

    private var templateList: some View {
        List {
            Section {
                storagePicker
            } header: {
                Text("Destination")
            }

            Section {
                if !isLoading && filteredTemplates.isEmpty {
                    Text("No appliance templates are available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredTemplates) { template in
                        Button {
                            selectedTemplate = template.template
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(
                                    systemName: selectedTemplate == template.template
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .foregroundStyle(
                                    selectedTemplate == template.template ? .blue : .secondary
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.displayName)
                                        .foregroundStyle(.primary)
                                    if let headline = template.headline, !headline.isEmpty {
                                        Text(headline)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 8) {
                                        if let version = template.version {
                                            Text(version)
                                        }
                                        if let section = template.section {
                                            Text(section)
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Available Templates")
            }

            statusSections
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if downloadStorages.isEmpty {
            Section {
                Text("No storage with template allocation permission supports this content type.")
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

    private func selectDefaultStorage() {
        if !downloadStorages.contains(where: { $0.storage == selectedStorage }) {
            selectedStorage = downloadStorages.first?.storage ?? ""
        }
    }

    @MainActor
    private func loadTemplates() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            templates = try await service.fetchApplianceTemplates(node: node)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func download() async {
        guard let service = appState.service, canDownload else { return }
        isDownloading = true
        error = nil
        defer { isDownloading = false }

        do {
            let taskTitle: String
            let object: String
            let upid: String
            if type == .lxc {
                taskTitle = String(localized: "Download container template")
                object = selectedTemplate
                upid = try await service.downloadApplianceTemplate(
                    node: node,
                    storage: selectedStorage,
                    template: selectedTemplate
                )
            } else {
                guard let validDownloadURL else { return }
                taskTitle = String(localized: "Import ISO")
                object = filename.trimmed
                upid = try await service.downloadStorageContent(
                    node: node,
                    storage: selectedStorage,
                    content: "iso",
                    url: validDownloadURL.absoluteString,
                    filename: filename.trimmed,
                    checksum: checksum.trimmed.isEmpty ? nil : checksum.trimmed,
                    checksumAlgorithm: checksum.trimmed.isEmpty ? nil : checksumAlgorithm,
                    verifyCertificates: verifyCertificates
                )
            }

            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: node,
                    title: taskTitle,
                    object: object,
                    service: service
                )
                _ = try await service.waitForTask(node: node, upid: upid)
            }

            let downloaded = try await service.fetchStorageContent(
                node: node,
                storage: selectedStorage,
                content: contentType
            )
            let expectedName = type == .lxc ? selectedTemplate : filename.trimmed
            let match = downloaded.first {
                $0.displayName.caseInsensitiveCompare(expectedName) == .orderedSame ||
                $0.volid.hasSuffix("/\(expectedName)")
            } ?? downloaded.max {
                ($0.ctime ?? 0) < ($1.ctime ?? 0)
            }
            onDownloaded(match?.volid)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
