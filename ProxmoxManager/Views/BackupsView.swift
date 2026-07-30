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
                }
            }
        } header: {
            Text("Schedules")
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
