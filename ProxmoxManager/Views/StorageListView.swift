import SwiftUI

/// Lists storage on a node with capacity and content breakdown.
struct StorageListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var storages: [ProxmoxStorage] = []
    @State private var isLoading = true
    @State private var error: String?

    let node: String

    var body: some View {
        Group {
            if isLoading && storages.isEmpty {
                ProgressView("Loading storage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, storages.isEmpty {
                ErrorStateView(message: error) {
                    Task { await load() }
                }
            } else {
                List {
                    if storages.isEmpty {
                        ContentUnavailableCompat(
                            title: "No Storage",
                            systemImage: "externaldrive",
                            description: "No storage configured on this node."
                        )
                    } else {
                        ForEach(storages) { storage in
                            NavigationLink {
                                StorageDetailView(node: node, storage: storage)
                            } label: {
                                StorageRow(storage: storage)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Storage")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        do {
            storages = try await service.fetchStorages(node: node)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

private struct StorageRow: View {
    let storage: ProxmoxStorage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .foregroundStyle(storage.isAvailable ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(storage.storage)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(storage.type)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    if let total = storage.total {
                        Text(total.formattedBytes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let used = storage.used, let total = storage.total, total > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(Double(used) / Double(total) * 100))%")
                        .font(.caption.weight(.medium))
                    ProgressView(value: Double(used) / Double(total))
                        .tint(Double(used) / Double(total) > 0.85 ? .red : .blue)
                        .frame(width: 60)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct StorageDetailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var content: [ProxmoxStorageContent] = []
    @State private var status: ProxmoxStorageStatus?
    @State private var isLoading = true

    let node: String
    let storage: ProxmoxStorage

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: storage.type)
                if let total = storage.total {
                    LabeledContent("Total", value: total.formattedBytes)
                }
                if let used = storage.used {
                    LabeledContent("Used", value: used.formattedBytes)
                }
                if let avail = storage.avail {
                    LabeledContent("Available", value: avail.formattedBytes)
                }
                LabeledContent("Content Types", value: storage.storageTypes.joined(separator: ", "))
            } header: {
                Text("Overview")
            }

            Section {
                if isLoading && content.isEmpty {
                    ProgressView()
                } else if content.isEmpty {
                    Text("No content")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(content) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName)
                                .font(.body)
                            HStack(spacing: 8) {
                                if let format = item.format {
                                    Text(format).font(.caption)
                                }
                                if let size = item.size {
                                    Text(size.formattedBytes).font(.caption)
                                }
                                if let content = item.content {
                                    Text(content).font(.caption)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Content (\(content.count))")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(storage.storage)
        .task { await load() }
    }

    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        async let contentTask = service.fetchStorageContent(node: node, storage: storage.storage)
        async let statusTask = service.fetchStorageStatus(node: node, storage: storage.storage)
        content = (try? await contentTask) ?? []
        status = try? await statusTask
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        StorageListView(node: "pve")
            .environmentObject(AppState())
    }
}
