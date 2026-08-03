import SwiftUI

/// Shows cluster backup schedules relevant to a node and backup archives
/// stored on that node's backup-capable storage.
struct BackupsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var jobs: [ProxmoxBackupJob] = []
    @State private var files: [ProxmoxBackupFile] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var error: String?
    @State private var restoringFile: ProxmoxBackupFile?
    @State private var deletingFile: ProxmoxBackupFile?
    @State private var editingJob: ProxmoxBackupJob?
    @State private var deletingJob: ProxmoxBackupJob?
    @State private var showingAddJob = false

    let node: String

    var body: some View {
        Group {
            if isLoading && jobs.isEmpty && files.isEmpty {
                ProgressView("Loading backups…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, jobs.isEmpty && files.isEmpty {
                ErrorStateView(message: error) {
                    Task { await load() }
                }
            } else {
                List {
                    jobsSection
                    archivesSection
                    if let error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Backups")
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $restoringFile) { file in
            RestoreBackupView(node: node, file: file) {
                Task { await load() }
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showingAddJob) {
            BackupJobEditorView(node: node, job: nil) { await load() }
                .environmentObject(appState)
        }
        .sheet(item: $editingJob) { job in
            BackupJobEditorView(node: node, job: job) { await load() }
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete Backup Archive?",
            isPresented: Binding(
                get: { deletingFile != nil },
                set: { if !$0 { deletingFile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let file = deletingFile else { return }
                Task { await delete(file) }
            }
        } message: {
            Text("The backup archive will be permanently removed from storage.")
        }
        .confirmationDialog(
            "Delete Backup Schedule?",
            isPresented: Binding(
                get: { deletingJob != nil },
                set: { if !$0 { deletingJob = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let job = deletingJob else { return }
                Task { await delete(job) }
            }
        } message: {
            Text("The schedule definition will be removed. Existing backup archives are kept.")
        }
        .overlay {
            if isWorking {
                Color.black.opacity(0.08).ignoresSafeArea()
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var jobsSection: some View {
        Section {
            if jobs.isEmpty {
                Text("No backup schedules apply to this node.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(jobs) { job in
                    BackupJobRow(job: job)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if canManageSchedules { editingJob = job }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManageSchedules {
                                Button(role: .destructive) {
                                    deletingJob = job
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    Task { await toggle(job) }
                                } label: {
                                    Label(
                                        job.isEnabled ? "Disable" : "Enable",
                                        systemImage: job.isEnabled ? "pause.circle" : "play.circle"
                                    )
                                }
                                .tint(.orange)
                                Button {
                                    editingJob = job
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                }
            }
        } header: {
            HStack {
                Text("Schedules")
                Spacer()
                if canManageSchedules {
                    Button {
                        showingAddJob = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Backup Schedule")
                }
            }
        }
    }

    @ViewBuilder
    private var archivesSection: some View {
        Section {
            if files.isEmpty {
                Text("No backup archives were found on accessible storage.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    BackupFileRow(file: file)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManage(file) {
                                Button(role: .destructive) {
                                    deletingFile = file
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    Task { await toggleProtection(file) }
                                } label: {
                                    Label(
                                        file.isProtected ? "Unprotect" : "Protect",
                                        systemImage: file.isProtected ? "lock.open" : "lock"
                                    )
                                }
                                .tint(.orange)
                            }
                        }
                        .contextMenu {
                            if canRestore(file) {
                                Button {
                                    restoringFile = file
                                } label: {
                                    Label("Restore", systemImage: "arrow.counterclockwise")
                                }
                            }
                            if canManage(file) {
                                Button {
                                    Task { await toggleProtection(file) }
                                } label: {
                                    Label(
                                        file.isProtected ? "Unprotect" : "Protect",
                                        systemImage: file.isProtected ? "lock.open" : "lock"
                                    )
                                }
                                Button(role: .destructive) {
                                    deletingFile = file
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        } header: {
            Text("Archives (\(files.count))")
        }
    }

    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil

        async let jobsRequest = service.fetchBackupJobs(node: node)
        async let filesRequest = service.fetchBackupFiles(node: node)

        do {
            jobs = try await jobsRequest
        } catch {
            self.error = error.localizedDescription
        }

        do {
            files = try await filesRequest
        } catch {
            if self.error == nil {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func canRestore(_ file: ProxmoxBackupFile) -> Bool {
        appState.hasPrivilege("VM.Allocate", for: file.vmid ?? 0)
    }

    private var canManageSchedules: Bool {
        appState.hasPrivilege("Sys.Modify", on: "/")
    }

    @MainActor
    private func toggle(_ job: ProxmoxBackupJob) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await service.updateBackupJob(
                id: job.id,
                form: ["enabled": job.isEnabled ? "0" : "1"]
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ job: ProxmoxBackupJob) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer {
            isWorking = false
            deletingJob = nil
        }
        do {
            try await service.deleteBackupJob(id: job.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func canManage(_ file: ProxmoxBackupFile) -> Bool {
        let storagePath = "/storage/\(file.storage)"
        return appState.hasPrivilege("Datastore.Allocate", on: storagePath) ||
            (appState.hasPrivilege("Datastore.AllocateSpace", on: storagePath) &&
             appState.hasPrivilege("VM.Backup", for: file.vmid ?? 0))
    }

    @MainActor
    private func toggleProtection(_ file: ProxmoxBackupFile) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await service.updateStorageContent(
                node: node,
                storage: file.storage,
                volume: file.volid,
                protected: !file.isProtected
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ file: ProxmoxBackupFile) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer {
            isWorking = false
            deletingFile = nil
        }
        do {
            let upid = try await service.deleteStorageContent(
                node: node,
                storage: file.storage,
                volume: file.volid
            )
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: node,
                    title: String(localized: "Delete backup"),
                    object: file.volid,
                    service: service
                )
                _ = try await service.waitForTask(node: node, upid: upid)
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BackupJobRow: View {
    let job: ProxmoxBackupJob

    private var title: String {
        guard let comment = job.comment, !comment.isEmpty else { return job.id }
        return comment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: job.isEnabled ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
                    .foregroundStyle(job.isEnabled ? .blue : .secondary)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(job.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(job.isEnabled ? .green : .secondary)
            }

            if let schedule = job.schedule {
                Label(schedule, systemImage: "clock")
            }

            HStack(spacing: 12) {
                if let storage = job.storage {
                    Label(storage, systemImage: "externaldrive")
                }
                if job.all == true {
                    Text("All guests")
                } else if let vmid = job.vmid {
                    Text("VMIDs: \(vmid)")
                }
                if let mode = job.mode {
                    Text(mode.capitalized)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct BackupFileRow: View {
    let file: ProxmoxBackupFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: file.isProtected ? "lock.shield.fill" : "archivebox")
                    .foregroundStyle(file.isProtected ? .green : .blue)
                if let vmid = file.vmid {
                    Text("VM \(vmid)")
                        .font(.headline)
                } else {
                    Text(file.volid)
                        .font(.headline)
                }
                Spacer()
                if let size = file.size {
                    Text(size.formattedBytes)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(file.volid)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(file.storage, systemImage: "externaldrive")
                if let format = file.format {
                    Text(format.uppercased())
                }
                if let createdAt = file.createdAt {
                    Text(Date(timeIntervalSince1970: Double(createdAt)), style: .date)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let notes = file.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BackupJobEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let node: String
    let job: ProxmoxBackupJob?
    let onSaved: () async -> Void

    @State private var storages: [ProxmoxStorage] = []
    @State private var guests: [ProxmoxVM] = []
    @State private var selectedStorage: String
    @State private var schedule: String
    @State private var mode: String
    @State private var compression: String
    @State private var comment: String
    @State private var notesTemplate: String
    @State private var allNodes: Bool
    @State private var allGuests: Bool
    @State private var selectedVMIDs: Set<Int>
    @State private var enabled: Bool
    @State private var protectedBackups: Bool
    @State private var repeatMissed: Bool
    @State private var pruneAfterBackup: Bool
    @State private var overrideRetention: Bool
    @State private var keepLast: String
    @State private var keepDaily: String
    @State private var keepWeekly: String
    @State private var keepMonthly: String
    @State private var keepYearly: String
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    init(node: String, job: ProxmoxBackupJob?, onSaved: @escaping () async -> Void) {
        self.node = node
        self.job = job
        self.onSaved = onSaved
        _selectedStorage = State(initialValue: job?.storage ?? "")
        _schedule = State(initialValue: job?.schedule ?? "daily")
        _mode = State(initialValue: job?.mode ?? "snapshot")
        _compression = State(initialValue: job?.compress ?? "zstd")
        _comment = State(initialValue: job?.comment ?? "")
        _notesTemplate = State(initialValue: job?.notesTemplate ?? "{{guestname}}")
        _allNodes = State(initialValue: job?.node == nil)
        _allGuests = State(initialValue: job?.all ?? true)
        let ids = job?.vmid?
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .compactMap { Int($0) } ?? []
        _selectedVMIDs = State(initialValue: Set(ids))
        _enabled = State(initialValue: job?.isEnabled ?? true)
        _protectedBackups = State(initialValue: job?.protectedBackups ?? false)
        _repeatMissed = State(initialValue: job?.repeatMissed ?? true)
        _pruneAfterBackup = State(initialValue: job?.remove ?? true)

        let retention = Self.parseRetention(job?.pruneBackups)
        _overrideRetention = State(initialValue: job == nil || job?.pruneBackups != nil)
        _keepLast = State(initialValue: retention["keep-last"] ?? (job == nil ? "3" : ""))
        _keepDaily = State(initialValue: retention["keep-daily"] ?? (job == nil ? "7" : ""))
        _keepWeekly = State(initialValue: retention["keep-weekly"] ?? (job == nil ? "4" : ""))
        _keepMonthly = State(initialValue: retention["keep-monthly"] ?? (job == nil ? "6" : ""))
        _keepYearly = State(initialValue: retention["keep-yearly"] ?? (job == nil ? "1" : ""))
    }

    private var compatibleStorages: [ProxmoxStorage] {
        storages.filter {
            $0.isAvailable &&
            $0.storageTypes.contains("backup") &&
            appState.hasPrivilege("Datastore.Allocate", on: "/storage/\($0.storage)")
        }
    }

    private var canSave: Bool {
        !selectedStorage.isEmpty &&
        !schedule.trimmed.isEmpty &&
        (allGuests || !selectedVMIDs.isEmpty) &&
        (!overrideRetention || retentionValuesAreValid) &&
        !isSaving
    }

    private var retentionValuesAreValid: Bool {
        [keepLast, keepDaily, keepWeekly, keepMonthly, keepYearly].allSatisfy {
            $0.trimmed.isEmpty || (Int($0).map { $0 >= 0 } == true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Storage", selection: $selectedStorage) {
                        ForEach(compatibleStorages) { storage in
                            Text(storage.storage).tag(storage.storage)
                        }
                    }
                    TextField("Schedule", text: $schedule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Backup Mode", selection: $mode) {
                        Text("Snapshot").tag("snapshot")
                        Text("Suspend").tag("suspend")
                        Text("Stop").tag("stop")
                    }
                    Picker("Compression", selection: $compression) {
                        Text("Zstandard").tag("zstd")
                        Text("LZO").tag("lzo")
                        Text("Gzip").tag("gzip")
                        Text("None").tag("0")
                    }
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Repeat Missed Jobs", isOn: $repeatMissed)
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Examples: daily, hourly, mon..fri 22:00, or sun 03:30.")
                }

                Section {
                    Toggle("Run on All Nodes", isOn: $allNodes)
                    Toggle("Back Up All Guests", isOn: $allGuests)
                    if !allGuests {
                        ForEach(guests) { guest in
                            Toggle(isOn: Binding(
                                get: { selectedVMIDs.contains(guest.vmid) },
                                set: { selected in
                                    if selected {
                                        selectedVMIDs.insert(guest.vmid)
                                    } else {
                                        selectedVMIDs.remove(guest.vmid)
                                    }
                                }
                            )) {
                                Text("\(guest.displayName) · \(guest.vmid) · \(guest.node)")
                            }
                        }
                    }
                } header: {
                    Text("Guests")
                }

                Section {
                    Toggle("Prune After Backup", isOn: $pruneAfterBackup)
                    Toggle("Override Storage Retention", isOn: $overrideRetention)
                    if overrideRetention {
                        retentionField("Keep Last", text: $keepLast)
                        retentionField("Keep Daily", text: $keepDaily)
                        retentionField("Keep Weekly", text: $keepWeekly)
                        retentionField("Keep Monthly", text: $keepMonthly)
                        retentionField("Keep Yearly", text: $keepYearly)
                    }
                    Toggle("Protect New Backups", isOn: $protectedBackups)
                } header: {
                    Text("Retention")
                } footer: {
                    Text("Leave a retention field empty to inherit no value for that period.")
                }

                Section {
                    TextField("Comment (optional)", text: $comment)
                    TextField("Notes Template", text: $notesTemplate)
                } header: {
                    Text("Metadata")
                }

                if compatibleStorages.isEmpty, !isLoading {
                    Section {
                        Text("No accessible backup storage is available.")
                            .foregroundStyle(.red)
                    }
                }
                if overrideRetention, !retentionValuesAreValid {
                    Section {
                        Text("Retention values must be zero or greater.")
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
            .navigationTitle(job == nil ? "Add Backup Schedule" : "Edit Backup Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .overlay { if isLoading || isSaving { ProgressView() } }
            .task { await load() }
        }
    }

    private func retentionField(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .keyboardType(.numberPad)
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let storagesRequest = service.fetchStorages(node: node)
            async let resourcesRequest = service.fetchClusterResources()
            let (loadedStorages, resources) = try await (storagesRequest, resourcesRequest)
            storages = loadedStorages
            guests = resources.compactMap { resource in
                guard (resource.type == .qemu || resource.type == .lxc),
                      let vmid = resource.vmid,
                      let guestNode = resource.node else { return nil }
                var guest = ProxmoxVM(
                    vmid: vmid,
                    name: resource.name,
                    status: resource.status ?? "unknown",
                    cpu: resource.cpu,
                    cpus: resource.maxcpu,
                    mem: resource.mem,
                    maxmem: resource.maxmem,
                    disk: resource.disk,
                    maxdisk: resource.maxdisk,
                    uptime: resource.uptime
                )
                guest.node = guestNode
                guest.type = resource.type == .lxc ? .lxc : .qemu
                return guest
            }
            .sorted { $0.vmid < $1.vmid }
            if !compatibleStorages.contains(where: { $0.storage == selectedStorage }) {
                selectedStorage = compatibleStorages.first?.storage ?? ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, canSave else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        var form: [String: String] = [
            "storage": selectedStorage,
            "schedule": schedule.trimmed,
            "mode": mode,
            "compress": compression,
            "enabled": enabled ? "1" : "0",
            "all": allGuests ? "1" : "0",
            "protected": protectedBackups ? "1" : "0",
            "repeat-missed": repeatMissed ? "1" : "0",
            "remove": pruneAfterBackup ? "1" : "0",
            "notes-template": notesTemplate.trimmed,
            "comment": comment.trimmed,
        ]
        if overrideRetention { form["prune-backups"] = retentionForm }
        if !allNodes { form["node"] = node }
        if !allGuests {
            form["vmid"] = selectedVMIDs.sorted().map(String.init).joined(separator: ",")
        }

        if job != nil {
            var deleted: [String] = []
            if allNodes { deleted.append("node") }
            if allGuests { deleted.append("vmid") }
            if comment.trimmed.isEmpty { deleted.append("comment") }
            if notesTemplate.trimmed.isEmpty { deleted.append("notes-template") }
            if !overrideRetention, job?.pruneBackups != nil { deleted.append("prune-backups") }
            if !deleted.isEmpty { form["delete"] = deleted.joined(separator: ",") }
        }
        if comment.trimmed.isEmpty { form.removeValue(forKey: "comment") }
        if notesTemplate.trimmed.isEmpty { form.removeValue(forKey: "notes-template") }

        do {
            if let job {
                try await service.updateBackupJob(id: job.id, form: form)
            } else {
                try await service.createBackupJob(form: form)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var retentionForm: String {
        let value = [
            ("keep-last", keepLast),
            ("keep-daily", keepDaily),
            ("keep-weekly", keepWeekly),
            ("keep-monthly", keepMonthly),
            ("keep-yearly", keepYearly),
        ]
        .compactMap { key, value in
            value.trimmed.isEmpty ? nil : "\(key)=\(value.trimmed)"
        }
        .joined(separator: ",")
        return value.isEmpty ? "keep-all=1" : value
    }

    private static func parseRetention(_ value: String?) -> [String: String] {
        guard let value else { return [:] }
        return Dictionary(uniqueKeysWithValues: value.split(separator: ",").compactMap {
            let pair = $0.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
    }
}
