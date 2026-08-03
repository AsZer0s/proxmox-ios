import Foundation
import SwiftUI

struct ManagedProxmoxTask: Identifiable, Codable {
    enum State: String, Codable, Equatable {
        case running
        case succeeded
        case failed

        var label: String {
            switch self {
            case .running: return String(localized: "Running")
            case .succeeded: return String(localized: "Succeeded")
            case .failed: return String(localized: "Failed")
            }
        }
    }

    let id: UUID
    let upid: String
    let node: String
    let title: String
    let object: String
    let taskType: String?
    let user: String?
    let startedAt: Date
    var finishedAt: Date?
    var state: State
    var message: String?
    var log: [String]

    init(
        id: UUID = UUID(),
        upid: String,
        node: String,
        title: String,
        object: String,
        taskType: String? = nil,
        user: String? = nil,
        startedAt: Date,
        finishedAt: Date? = nil,
        state: State,
        message: String? = nil,
        log: [String] = []
    ) {
        self.id = id
        self.upid = upid
        self.node = node
        self.title = title
        self.object = object
        self.taskType = taskType
        self.user = user
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.message = message
        self.log = log
    }

    init(serverTask: ProxmoxNodeTask) {
        id = UUID()
        upid = serverTask.upid
        node = serverTask.node
        title = Self.title(for: serverTask.taskType)
        object = serverTask.idValue.isEmpty ? serverTask.taskType : serverTask.idValue
        taskType = serverTask.taskType
        user = serverTask.user
        startedAt = Date(timeIntervalSince1970: TimeInterval(serverTask.startTime))
        finishedAt = serverTask.endTime.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        if serverTask.isRunning {
            state = .running
            message = nil
        } else if serverTask.succeeded {
            state = .succeeded
            message = nil
        } else {
            state = .failed
            message = serverTask.status
        }
        log = []
    }

    private static func title(for type: String) -> String {
        switch type.lowercased() {
        case "qmstart", "vzstart": return String(localized: "Start guest")
        case "qmstop", "vzstop": return String(localized: "Stop guest")
        case "qmshutdown", "vzshutdown": return String(localized: "Shut down guest")
        case "qmreboot", "vzreboot": return String(localized: "Reboot guest")
        case "vzdump": return String(localized: "Back up guest")
        case "qmrestore", "vzrestore": return String(localized: "Restore backup")
        case "qmmigrate", "vzmigrate": return String(localized: "Migrate guest")
        case "download": return String(localized: "Download content")
        case "aptupdate": return String(localized: "Refresh package index")
        case "vncshell": return String(localized: "Console session")
        default: return type
        }
    }
}

@MainActor
final class ProxmoxTaskCenter: ObservableObject {
    @Published private(set) var tasks: [ManagedProxmoxTask] = []

    private var serverID: UUID?
    private var service: ProxmoxAPIService?
    private var nodes: [String] = []
    private var refreshTask: Task<Void, Never>?

    func activate(
        serverID: UUID,
        nodes: [String],
        service: ProxmoxAPIService
    ) async {
        refreshTask?.cancel()
        self.serverID = serverID
        self.nodes = nodes
        self.service = service
        tasks = loadPersistedTasks(serverID: serverID)
        await refresh()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func deactivate() {
        refreshTask?.cancel()
        refreshTask = nil
        serverID = nil
        service = nil
        nodes = []
        tasks = []
    }

    func refresh() async {
        guard let service, !nodes.isEmpty else { return }
        let nodeTasks = await withTaskGroup(of: [ProxmoxNodeTask].self) { group in
            for node in nodes {
                group.addTask {
                    (try? await service.fetchNodeTasks(
                        node: node,
                        source: "all",
                        limit: 100
                    )) ?? []
                }
            }
            var values: [ProxmoxNodeTask] = []
            for await result in group {
                values.append(contentsOf: result)
            }
            return values
        }

        var merged = Dictionary(uniqueKeysWithValues: tasks.map { ($0.upid, $0) })
        for serverTask in nodeTasks {
            let remote = ManagedProxmoxTask(serverTask: serverTask)
            if var existing = merged[serverTask.upid] {
                existing.finishedAt = remote.finishedAt
                existing.state = remote.state
                existing.message = remote.message
                merged[serverTask.upid] = existing
            } else {
                merged[serverTask.upid] = remote
            }
        }
        tasks = merged.values
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(200)
            .map { $0 }
        persist()
    }

    func track(
        upid: String,
        node: String,
        title: String,
        object: String,
        service: ProxmoxAPIService
    ) {
        guard !upid.isEmpty,
              !tasks.contains(where: { $0.upid == upid && $0.state == .running }) else {
            return
        }

        let id = UUID()
        tasks.insert(
            ManagedProxmoxTask(
                id: id,
                upid: upid,
                node: node,
                title: title,
                object: object,
                taskType: nil,
                user: nil,
                startedAt: Date(),
                finishedAt: nil,
                state: .running,
                message: nil,
                log: []
            ),
            at: 0
        )
        persist()

        Task { @MainActor [weak self] in
            do {
                _ = try await service.waitForTask(node: node, upid: upid)
                let log = (try? await service.fetchTaskLog(node: node, upid: upid)) ?? []
                self?.finish(id: id, state: .succeeded, message: nil, log: log.map(\.t))
            } catch is CancellationError {
                self?.finish(
                    id: id,
                    state: .failed,
                    message: String(localized: "Task tracking was cancelled."),
                    log: []
                )
            } catch {
                let log = (try? await service.fetchTaskLog(node: node, upid: upid)) ?? []
                self?.finish(
                    id: id,
                    state: .failed,
                    message: error.localizedDescription,
                    log: log.map(\.t)
                )
            }
        }
    }

    func clearFinished() {
        tasks.removeAll { $0.state != .running }
        persist()
    }

    /// Cancel a running task via the PVE API and mark it as failed.
    func cancel(
        upid: String,
        node: String,
        service: ProxmoxAPIService
    ) async {
        guard let index = tasks.firstIndex(where: { $0.upid == upid && $0.state == .running }) else { return }
        do {
            try await service.cancelTask(node: node, upid: upid)
            tasks[index].finishedAt = Date()
            tasks[index].state = .failed
            tasks[index].message = String(localized: "Cancelled by user.")
            persist()
        } catch {
            tasks[index].message = String(
                localized: "Cancel failed: \(error.localizedDescription)"
            )
            persist()
        }
    }

    func loadLog(for task: ManagedProxmoxTask) async {
        guard let service,
              let index = tasks.firstIndex(where: { $0.upid == task.upid }) else {
            return
        }
        do {
            let entries = try await service.fetchTaskLog(node: task.node, upid: task.upid)
            tasks[index].log = entries.map(\.t)
        } catch {
            tasks[index].message = error.localizedDescription
        }
    }

    private func finish(
        id: UUID,
        state: ManagedProxmoxTask.State,
        message: String?,
        log: [String]
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].finishedAt = Date()
        tasks[index].state = state
        tasks[index].message = message
        tasks[index].log = log
        persist()
    }

    private func persistenceKey(serverID: UUID) -> String {
        "ProxmoxTaskCenter.\(serverID.uuidString)"
    }

    private func loadPersistedTasks(serverID: UUID) -> [ManagedProxmoxTask] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey(serverID: serverID)),
              let decoded = try? JSONDecoder().decode([ManagedProxmoxTask].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist() {
        guard let serverID else { return }
        let withoutLogs = tasks.map {
            ManagedProxmoxTask(
                id: $0.id,
                upid: $0.upid,
                node: $0.node,
                title: $0.title,
                object: $0.object,
                taskType: $0.taskType,
                user: $0.user,
                startedAt: $0.startedAt,
                finishedAt: $0.finishedAt,
                state: $0.state,
                message: $0.message,
                log: []
            )
        }
        if let data = try? JSONEncoder().encode(withoutLogs) {
            UserDefaults.standard.set(data, forKey: persistenceKey(serverID: serverID))
        }
    }
}

struct TaskCenterView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var taskCenter: ProxmoxTaskCenter

    var body: some View {
        NavigationStack {
            Group {
                if taskCenter.tasks.isEmpty {
                    ContentUnavailableCompat(
                        title: "No Tasks",
                        systemImage: "checkmark.circle",
                        description: "Completed and running Proxmox tasks will appear here."
                    )
                } else {
                    List {
                        ForEach(taskCenter.tasks) { task in
                            Section {
                                TaskRow(task: task)
                                if task.log.isEmpty {
                                    Button("Load Task Log") {
                                        Task { await taskCenter.loadLog(for: task) }
                                    }
                                }
                                if task.state == .running, let service = appState.service {
                                    Button(role: .destructive) {
                                        Task {
                                            await taskCenter.cancel(
                                                upid: task.upid,
                                                node: task.node,
                                                service: service
                                            )
                                        }
                                    } label: {
                                        Label("Cancel Task", systemImage: "xmark.circle")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Tasks")
            .refreshable { await taskCenter.refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if taskCenter.tasks.contains(where: { $0.state == .running }) {
                        ProgressView()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        taskCenter.clearFinished()
                    }
                    .disabled(!taskCenter.tasks.contains(where: { $0.state != .running }))
                }
            }
        }
    }
}

private struct TaskRow: View {
    let task: ManagedProxmoxTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(task.title)
                    .font(.headline)
                Spacer()
                Text(task.state.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
            }

            Text(task.object)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text(task.node)
                Spacer()
                Text(task.startedAt, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let message = task.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if let user = task.user {
                Text(user)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !task.log.isEmpty {
                DisclosureGroup("Task log") {
                    ForEach(Array(task.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch task.state {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch task.state {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    TaskCenterView()
        .environmentObject(ProxmoxTaskCenter())
}
