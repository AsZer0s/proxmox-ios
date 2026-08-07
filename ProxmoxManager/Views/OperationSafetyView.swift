import SwiftUI

struct OperationSafetyView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var center: OperationSafetyCenter
    @State private var adding = false
    @State private var expanded: UUID?

    init(center: OperationSafetyCenter) { self.center = center }

    var body: some View {
        List {
            Section("Maintenance Window") {
                Toggle("Restrict Scheduled Operations", isOn: $center.maintenanceWindowEnabled)
                if center.maintenanceWindowEnabled {
                    Stepper("Start: \(center.maintenanceStartHour):00", value: $center.maintenanceStartHour, in: 0...23)
                    Stepper("End: \(center.maintenanceEndHour):00", value: $center.maintenanceEndHour, in: 0...23)
                }
                Button("Save Window") { center.saveMaintenanceWindow() }
            }

            Section("Scheduled Operations") {
                Text("Scheduled commands run only while the app is active. A local notification reminds you when the operation is due.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(center.scheduled) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(operation.kind.label) · \(operation.guestType.rawValue.uppercased()) \(operation.vmid)")
                            Spacer()
                            Image(systemName: operation.completed ? "checkmark.circle.fill" : "clock")
                                .foregroundStyle(operation.completed ? .green : .orange)
                        }
                        Text("\(operation.node) · \(operation.executeAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = operation.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
                .onDelete { center.removeScheduled(at: $0) }
                Button { adding = true } label: { Label("Schedule Operation", systemImage: "calendar.badge.plus") }
            }

            Section("Audit Trail") {
                ForEach(center.audits) { entry in
                    Button { expanded = expanded == entry.id ? nil : entry.id } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(entry.method) \(impact(entry))")
                                    .font(.caption.bold())
                                    .foregroundStyle(impactColor(entry))
                                Spacer()
                                Text(entry.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.path).font(.caption.monospaced()).foregroundStyle(.primary)
                            if expanded == entry.id {
                                Divider()
                                Text("Change Preview").font(.caption.bold())
                                if entry.changes.isEmpty { Text("No parameters").font(.caption).foregroundStyle(.secondary) }
                                ForEach(entry.changes.keys.sorted(), id: \.self) { key in
                                    LabeledContent(key, value: entry.changes[key] ?? "")
                                        .font(.caption.monospaced())
                                }
                                Button("Retry") { Task { try? await center.retry(entry) } }
                                    .font(.caption)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                Button("Clear Audit Log", role: .destructive) { center.clearAudit() }
            }
        }
        .navigationTitle("Operation Safety")
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) { ScheduleOperationView(center: center) }
    }

    private func impact(_ entry: OperationAuditEntry) -> String {
        let path = entry.path.lowercased()
        if entry.method == "DELETE" || path.contains("/stop") || path.contains("cluster/config") { return String(localized: "High Impact") }
        if entry.method == "POST" || entry.method == "PUT" { return String(localized: "Configuration Change") }
        return String(localized: "Scheduled")
    }
    private func impactColor(_ entry: OperationAuditEntry) -> Color { impact(entry) == String(localized: "High Impact") ? .red : .orange }
}

private struct ScheduleOperationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var center: OperationSafetyCenter
    @State private var date = Date().addingTimeInterval(300)
    @State private var kind = ScheduledOperation.Kind.shutdown
    @State private var node = ""
    @State private var vmid = ""
    @State private var type = GuestType.qemu
    @State private var retries = 2
    @State private var previewing = false
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Execute At", selection: $date)
                Picker("Operation", selection: $kind) { ForEach(ScheduledOperation.Kind.allCases) { Text($0.label).tag($0) } }
                Picker("Guest Type", selection: $type) { Text("VM").tag(GuestType.qemu); Text("CT").tag(GuestType.lxc) }
                TextField("Node", text: $node)
                TextField("VMID", text: $vmid).keyboardType(.numberPad)
                Stepper("Retries: \(retries)", value: $retries, in: 0...5)
            }
            .navigationTitle("Schedule Operation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { previewing = true }.disabled(node.trimmed.isEmpty || Int(vmid) == nil) }
            }
            .alert("Operation Preview", isPresented: $previewing) {
                Button("Authorize & Schedule") { Task { await authorizeAndSave() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(kind.label) \(type.rawValue.uppercased()) \(vmid) on \(node) at \(date.formatted()). This may interrupt service. The device owner must authorize it.")
            }
        }
    }
    @MainActor private func authorizeAndSave() async {
        guard let serverID = appState.connectedServer?.id, let id = Int(vmid),
              await center.authorizeCriticalAction(reason: String(localized: "Authorize scheduled Proxmox operation")) else { return }
        center.schedule(ScheduledOperation(serverID: serverID, executeAt: date, kind: kind, node: node.trimmed, guestType: type, vmid: id, retryCount: 0, maximumRetries: retries, completed: false))
        dismiss()
    }
}
