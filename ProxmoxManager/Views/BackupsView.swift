import SwiftUI

/// Shows backup jobs and history for a node.
struct BackupsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var backups: [ProxmoxBackup] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedBackupID: String?
    @State private var backupLog: [String] = []

    let node: String

    var body: some View {
        Group {
            if isLoading && backups.isEmpty {
                ProgressView("Loading backups…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, backups.isEmpty {
                ErrorStateView(message: error) {
                    Task { await load() }
                }
            } else if backups.isEmpty {
                ContentUnavailableCompat(
                    title: "No Backups",
                    systemImage: "clock.arrow.circlepath",
                    description: "No backup jobs configured on this node."
                )
            } else {
                List(backups) { backup in
                    Section {
                        BackupRow(backup: backup)
                            .onTapGesture {
                                selectedBackupID = backup.id
                                Task { await loadLog(id: backup.id) }
                            }
                        if selectedBackupID == backup.id && !backupLog.isEmpty {
                            DisclosureGroup("Task Log", isExpanded: .constant(true)) {
                                ForEach(Array(backupLog.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption.monospaced())
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Backups")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        do {
            backups = try await service.fetchBackups(node: node)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadLog(id: String) async {
        guard let service = appState.service else { return }
        do {
            let entries = try await service.fetchBackupLog(node: node, id: id)
            backupLog = entries.map(\.t)
        } catch {
            backupLog = ["Could not load log: \(error.localizedDescription)"]
        }
    }
}

private struct BackupRow: View {
    let backup: ProxmoxBackup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(backup.status == "running" ? .blue : .secondary)

                Text("VM \(backup.vmid)")
                    .font(.headline)

                Spacer()

                if let status = backup.status {
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status == "running" ? .blue : .secondary)
                }
            }

            HStack(spacing: 12) {
                if let storage = Optional(backup.storage) {
                    Label(storage, systemImage: "externaldrive")
                }
                if let mode = backup.mode {
                    Text(mode)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let starttime = backup.starttime {
                HStack {
                    Text("Started: \(Date(timeIntervalSince1970: Double(starttime)), style: .date)")
                    if let endtime = backup.endtime {
                        Text("· \(Date(timeIntervalSince1970: Double(endtime)), style: .time)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let size = backup.size {
                HStack {
                    Text("Size: \(size.formattedBytes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
