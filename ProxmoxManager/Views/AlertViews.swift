import SwiftUI

struct OperationsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var alertCenter: ProxmoxAlertCenter

    var body: some View {
        NavigationStack {
            List {
                Section("Monitoring") {
                    NavigationLink {
                        AlertsView()
                    } label: {
                        operationLabel(
                            title: String(localized: "Alerts & Notifications"),
                            subtitle: String(localized: "Offline nodes, resource pressure, backup failures, and storage capacity"),
                            icon: "bell.badge",
                            color: .orange,
                            badge: alertCenter.alerts.filter { !$0.acknowledged }.count
                        )
                    }
                    NavigationLink {
                        PBSManagementView()
                    } label: {
                        operationLabel(
                            title: String(localized: "Backup Server"),
                            subtitle: String(localized: "Datastores, snapshots, garbage collection, verify, prune, and sync jobs"),
                            icon: "externaldrive.badge.timemachine",
                            color: .indigo
                        )
                    }
                }

                Section("Cluster") {
                    NavigationLink {
                        HAReplicationView()
                    } label: {
                        operationLabel(
                            title: String(localized: "HA & Replication"),
                            subtitle: String(localized: "HA state, groups, resources, and replication jobs"),
                            icon: "arrow.trianglehead.2.clockwise.rotate.90",
                            color: .purple
                        )
                    }
                    NavigationLink {
                        InfrastructureView()
                    } label: {
                        operationLabel(
                            title: String(localized: "Infrastructure"),
                            subtitle: String(localized: "Node networking, storage, Ceph, and SDN"),
                            icon: "network",
                            color: .blue
                        )
                    }
                }

                Section("Security") {
                    NavigationLink {
                        OperationSafetyView(center: appState.operationSafety)
                    } label: {
                        operationLabel(
                            title: String(localized: "Operation Safety"),
                            subtitle: String(localized: "Change previews, impact levels, audit, retries, and maintenance windows"),
                            icon: "lock.shield",
                            color: .red
                        )
                    }
                    NavigationLink {
                        AccessControlView()
                    } label: {
                        operationLabel(
                            title: String(localized: "Users & Permissions"),
                            subtitle: String(localized: "Users, roles, ACLs, and API tokens"),
                            icon: "person.badge.key",
                            color: .green
                        )
                    }
                }
            }
            .navigationTitle("Manage")
        }
    }

    private func operationLabel(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        badge: Int = 0
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.red, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

struct AlertsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var center: ProxmoxAlertCenter
    @State private var showingSettings = false

    var body: some View {
        Group {
            if center.alerts.isEmpty {
                ContentUnavailableCompat(
                    title: "No Alerts",
                    systemImage: "checkmark.shield",
                    description: "No node, resource, backup, or storage alerts have been detected."
                )
            } else {
                List {
                    ForEach(center.alerts) { alert in
                        AlertRow(alert: alert)
                            .swipeActions {
                                if !alert.acknowledged {
                                    Button("Acknowledge") { center.acknowledge(alert) }
                                        .tint(.blue)
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Alerts")
        .refreshable { await center.checkNow() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if center.alerts.contains(where: { !$0.acknowledged }) {
                    Button("Acknowledge All") { center.acknowledgeAll() }
                }
                Menu {
                    Button("Alert Settings") { showingSettings = true }
                    Button("Clear Acknowledged", role: .destructive) {
                        center.clearAcknowledged()
                    }
                    .disabled(!center.alerts.contains(where: \.acknowledged))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            AlertSettingsView()
                .environmentObject(appState)
        }
    }
}

private struct AlertRow: View {
    let alert: ProxmoxAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(alert.title).font(.headline)
                    Spacer()
                    Text(alert.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(alert.message).font(.subheadline)
                if alert.acknowledged {
                    Label("Acknowledged", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(alert.acknowledged ? 0.65 : 1)
    }

    private var icon: String {
        switch alert.severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch alert.severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct AlertSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var center: ProxmoxAlertCenter
    @Environment(\.dismiss) private var dismiss
    @State private var monitoring = true
    @State private var notifications = true
    @State private var cpu = 0.90
    @State private var memory = 0.90
    @State private var storage = 0.85
    @State private var relayURL = ""
    @State private var enrollmentToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Monitor Cluster", isOn: $monitoring)
                    Toggle("Local Notifications", isOn: $notifications)
                    if notifications && center.authorizationStatus != .authorized {
                        Button("Allow Notifications") {
                            Task { await center.requestNotificationAuthorization() }
                        }
                    }
                } footer: {
                    Text("Monitoring checks the connected cluster every minute while the app is active.")
                }

                Section("Warning Thresholds") {
                    thresholdRow("CPU", value: $cpu)
                    thresholdRow("Memory", value: $memory)
                    thresholdRow("Storage", value: $storage)
                }

                Section {
                    TextField("Relay URL", text: $relayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Enrollment Token", text: $enrollmentToken)
                    LabeledContent("Status", value: appState.remoteNotifications.registrationState)
                    Button("Enable Background Alerts") {
                        saveRelay()
                        Task { await appState.remoteNotifications.sync(servers: appState.servers) }
                    }
                    .disabled(relayURL.trimmed.isEmpty || enrollmentToken.isEmpty)
                    if let error = appState.remoteNotifications.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Background Alerts")
                } footer: {
                    Text("A self-hosted relay polls Proxmox and sends APNs notifications even when this app is closed. Proxmox credentials are never uploaded by the app.")
                }

                Section("Alert Rules") {
                    ForEach($appState.remoteNotifications.rules) { $rule in
                        NavigationLink {
                            AlertRuleEditor(rule: $rule)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(rule.kind.label)
                                    Text(rule.resourcePattern)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !rule.enabled { Text("Off").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Alert Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                monitoring = center.monitoringEnabled
                notifications = center.notificationsEnabled
                cpu = center.cpuThreshold
                memory = center.memoryThreshold
                storage = center.storageThreshold
                relayURL = appState.remoteNotifications.relayURL
                enrollmentToken = appState.remoteNotifications.enrollmentToken
            }
        }
    }

    private func thresholdRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            Slider(value: value, in: 0.50...0.99, step: 0.01)
        }
    }

    private func save() {
        center.monitoringEnabled = monitoring
        center.notificationsEnabled = notifications
        center.cpuThreshold = cpu
        center.memoryThreshold = memory
        center.storageThreshold = storage
        Task { await center.restartMonitoring() }
        dismiss()
    }

    private func saveRelay() {
        appState.remoteNotifications.relayURL = relayURL
        appState.remoteNotifications.enrollmentToken = enrollmentToken
    }
}

private struct AlertRuleEditor: View {
    @EnvironmentObject private var appState: AppState
    @Binding var rule: AlertRule

    var body: some View {
        Form {
            Toggle("Enabled", isOn: $rule.enabled)
            TextField("Resource Pattern", text: $rule.resourcePattern)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if rule.threshold != nil {
                VStack(alignment: .leading) {
                    LabeledContent("Threshold", value: (rule.threshold ?? 0).formatted(.percent.precision(.fractionLength(2))))
                    Slider(
                        value: Binding(get: { rule.threshold ?? 0.9 }, set: { rule.threshold = $0 }),
                        in: 0.5...0.99,
                        step: 0.01
                    )
                }
            }
            Stepper("Cooldown: \(rule.cooldownMinutes) min", value: $rule.cooldownMinutes, in: 1...1440)
            Section("Clusters") {
                Toggle("All Clusters", isOn: Binding(
                    get: { rule.serverIDs.isEmpty },
                    set: { if $0 { rule.serverIDs = [] } else if let first = appState.servers.first { rule.serverIDs = [first.id] } }
                ))
                if !rule.serverIDs.isEmpty {
                    ForEach(appState.servers) { server in
                        Toggle(server.name, isOn: Binding(
                            get: { rule.serverIDs.contains(server.id) },
                            set: { enabled in if enabled { rule.serverIDs.append(server.id) } else { rule.serverIDs.removeAll { $0 == server.id } } }
                        ))
                    }
                }
            }
        }
        .navigationTitle(rule.kind.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
