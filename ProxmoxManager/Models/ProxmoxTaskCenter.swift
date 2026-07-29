import Foundation
import SwiftUI

struct ManagedProxmoxTask: Identifiable {
    enum State: Equatable {
        case running
        case succeeded
        case failed

        var label: String {
            switch self {
            case .running: return "Running"
            case .succeeded: return "Succeeded"
            case .failed: return "Failed"
            }
        }
    }

    let id: UUID
    let upid: String
    let node: String
    let title: String
    let object: String
    let startedAt: Date
    var finishedAt: Date?
    var state: State
    var message: String?
    var log: [String]
}

@MainActor
final class ProxmoxTaskCenter: ObservableObject {
    @Published private(set) var tasks: [ManagedProxmoxTask] = []

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
                startedAt: Date(),
                finishedAt: nil,
                state: .running,
                message: nil,
                log: []
            ),
            at: 0
        )

        Task { @MainActor [weak self] in
            do {
                _ = try await service.waitForTask(node: node, upid: upid)
                let log = (try? await service.fetchTaskLog(node: node, upid: upid)) ?? []
                self?.finish(id: id, state: .succeeded, message: nil, log: log.map(\.t))
            } catch is CancellationError {
                self?.finish(
                    id: id,
                    state: .failed,
                    message: "Task tracking was cancelled.",
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
    }
}

struct TaskCenterView: View {
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
                    List(taskCenter.tasks) { task in
                        TaskRow(task: task)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Tasks")
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
