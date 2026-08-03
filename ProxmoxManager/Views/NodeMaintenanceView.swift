import SwiftUI

struct NodeMaintenanceView: View {
    @EnvironmentObject private var appState: AppState

    let node: ProxmoxNode

    @State private var powerCommand: String?
    @State private var isWorking = false
    @State private var error: String?

    private var canUseConsole: Bool {
        appState.hasPrivilege("Sys.Console", on: "/nodes/\(node.node)")
    }

    private var canPowerManage: Bool {
        appState.hasPrivilege("Sys.PowerMgmt", on: "/nodes/\(node.node)")
    }

    private var canAudit: Bool {
        appState.hasPrivilege("Sys.Audit", on: "/nodes/\(node.node)") ||
        appState.hasPrivilege("Sys.Audit", on: "/")
    }

    var body: some View {
        List {
            Section {
                if canUseConsole {
                    NavigationLink {
                        NativeConsoleView(
                            target: .node(node: node.node, command: "login"),
                            title: String(localized: "Node Shell")
                        )
                        .environmentObject(appState)
                    } label: {
                        Label("Node Shell", systemImage: "terminal")
                    }
                }
                if canAudit {
                    NavigationLink {
                        NodeServicesView(node: node.node)
                            .environmentObject(appState)
                    } label: {
                        Label("Services", systemImage: "gearshape.2")
                    }
                    NavigationLink {
                        NodeUpdatesView(node: node.node)
                            .environmentObject(appState)
                    } label: {
                        Label("Software Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } header: {
                Text("Maintenance")
            }

            if canPowerManage {
                Section {
                    Button {
                        powerCommand = "reboot"
                    } label: {
                        Label("Reboot Node", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        powerCommand = "shutdown"
                    } label: {
                        Label("Shut Down Node", systemImage: "power")
                    }
                } header: {
                    Text("Power")
                } footer: {
                    Text("Running guests may be interrupted. Migrate or shut them down first.")
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Maintenance")
        .confirmationDialog(
            powerCommand == "reboot" ? "Reboot Node?" : "Shut Down Node?",
            isPresented: Binding(
                get: { powerCommand != nil },
                set: { if !$0 { powerCommand = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                powerCommand == "reboot" ? "Reboot" : "Shut Down",
                role: .destructive
            ) {
                guard let powerCommand else { return }
                Task { await performPowerAction(powerCommand) }
            }
        }
        .overlay { if isWorking { ProgressView() } }
    }

    @MainActor
    private func performPowerAction(_ command: String) async {
        guard let service = appState.service else { return }
        isWorking = true
        error = nil
        defer {
            isWorking = false
            powerCommand = nil
        }
        do {
            let upid = try await service.performNodePowerAction(node: node.node, command: command)
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: node.node,
                    title: command == "reboot"
                        ? String(localized: "Reboot node")
                        : String(localized: "Shut down node"),
                    object: node.node,
                    service: service
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NodeServicesView: View {
    @EnvironmentObject private var appState: AppState

    let node: String

    @State private var services: [ProxmoxNodeService] = []
    @State private var selectedAction: ServiceAction?
    @State private var isLoading = true
    @State private var error: String?

    private struct ServiceAction: Identifiable {
        let service: ProxmoxNodeService
        let command: String
        var id: String { "\(service.id)-\(command)" }
        var label: String {
            switch command {
            case "start": return String(localized: "Start")
            case "stop": return String(localized: "Stop")
            case "restart": return String(localized: "Restart")
            case "reload": return String(localized: "Reload")
            default: return command
            }
        }
    }

    private var canManage: Bool {
        appState.hasPrivilege("Sys.Modify", on: "/nodes/\(node)") ||
        appState.hasPrivilege("Sys.Modify", on: "/")
    }

    var body: some View {
        List {
            if services.isEmpty, !isLoading {
                Text("No services were returned by this node.")
                    .foregroundStyle(.secondary)
            }
            ForEach(services) { service in
                HStack(spacing: 12) {
                    Circle()
                        .fill(service.isRunning ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.service)
                            .font(.body.weight(.medium))
                        Text(service.description ?? service.activeState ?? service.state ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if canManage {
                        Menu {
                            if service.isRunning {
                                Button("Reload") { selectedAction = ServiceAction(service: service, command: "reload") }
                                Button("Restart") { selectedAction = ServiceAction(service: service, command: "restart") }
                                Button("Stop", role: .destructive) {
                                    selectedAction = ServiceAction(service: service, command: "stop")
                                }
                            } else {
                                Button("Start") { selectedAction = ServiceAction(service: service, command: "start") }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Services")
        .refreshable { await load() }
        .task { await load() }
        .overlay { if isLoading { ProgressView() } }
        .confirmationDialog(
            "Change Service State?",
            isPresented: Binding(
                get: { selectedAction != nil },
                set: { if !$0 { selectedAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = selectedAction {
                Button(action.label, role: action.command == "stop" ? .destructive : nil) {
                    Task { await perform(action) }
                }
            }
        } message: {
            if let action = selectedAction {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Confirm %@ for service %@?"),
                        action.label,
                        action.service.service
                    )
                )
            }
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            services = try await service.fetchNodeServices(node: node)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func perform(_ action: ServiceAction) async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        defer {
            isLoading = false
            selectedAction = nil
        }
        do {
            _ = try await service.performNodeServiceAction(
                node: node,
                service: action.service.service,
                command: action.command
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NodeUpdatesView: View {
    @EnvironmentObject private var appState: AppState

    let node: String

    @State private var updates: [ProxmoxPackageUpdate] = []
    @State private var isLoading = true
    @State private var error: String?

    private var canModify: Bool {
        appState.hasPrivilege("Sys.Modify", on: "/nodes/\(node)") ||
        appState.hasPrivilege("Sys.Modify", on: "/")
    }

    private var canOpenUpgradeConsole: Bool {
        appState.connectedServer?.authMethod == .ticket &&
        appState.connectedServer?.fullUsername == "root@pam" &&
        appState.hasPrivilege("Sys.Console", on: "/nodes/\(node)")
    }

    var body: some View {
        List {
            Section {
                Button("Refresh Package Index") {
                    Task { await refreshIndex() }
                }
                .disabled(!canModify)
                if canOpenUpgradeConsole {
                    NavigationLink {
                        NativeConsoleView(
                            target: .node(node: node, command: "upgrade"),
                            title: String(localized: "Upgrade Console")
                        )
                        .environmentObject(appState)
                    } label: {
                        Label("Open Upgrade Console", systemImage: "terminal")
                    }
                }
            }

            Section {
                if updates.isEmpty, !isLoading {
                    Text("No package updates are available.")
                        .foregroundStyle(.secondary)
                }
                ForEach(updates) { update in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(update.title ?? update.package)
                            .font(.body.weight(.medium))
                        Text("\(update.currentVersion ?? "—") → \(update.version ?? "—")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let description = update.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Available Updates: %lld"),
                        Int64(updates.count)
                    )
                )
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Software Updates")
        .refreshable { await load() }
        .task { await load() }
        .overlay { if isLoading { ProgressView() } }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            updates = try await service.fetchNodeUpdates(node: node)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func refreshIndex() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let upid = try await service.refreshNodePackageIndex(node: node)
            if !upid.isEmpty {
                appState.taskCenter.track(
                    upid: upid,
                    node: node,
                    title: String(localized: "Refresh package index"),
                    object: node,
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
