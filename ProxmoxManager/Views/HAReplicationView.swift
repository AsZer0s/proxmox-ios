import SwiftUI

struct HAReplicationView: View {
    @EnvironmentObject private var appState: AppState
    @State private var status: [ProxmoxHAStatus] = []
    @State private var resources: [ProxmoxHAResource] = []
    @State private var groups: [ProxmoxHAGroup] = []
    @State private var jobs: [ProxmoxReplicationJob] = []
    @State private var selection = 0
    @State private var isLoading = true
    @State private var error: String?
    @State private var editingResource: ProxmoxHAResource?
    @State private var editingGroup: ProxmoxHAGroup?
    @State private var editingJob: ProxmoxReplicationJob?
    @State private var creating: CreationKind?

    private enum CreationKind: String, Identifiable {
        case resource, group, replication
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if isLoading && resources.isEmpty && jobs.isEmpty {
                ProgressView("Loading HA and replication…")
            } else {
                List {
                    Picker("Section", selection: $selection) {
                        Text("HA").tag(0)
                        Text("Migration Policy").tag(1)
                        Text("Replication").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)

                    if selection == 0 { haContent }
                    else if selection == 1 { groupContent }
                    else { replicationContent }

                    if let error {
                        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("HA & Replication")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    creating = selection == 0 ? .resource : selection == 1 ? .group : .replication
                } label: { Image(systemName: "plus") }
                .disabled(!canModifyCurrentSection)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $creating) { kind in
            switch kind {
            case .resource:
                HAResourceEditor(resource: nil, groups: groups) { await load() }
            case .group:
                HAGroupEditor(group: nil) { await load() }
            case .replication:
                ReplicationJobEditor(job: nil) { await load() }
            }
        }
        .sheet(item: $editingResource) { item in
            HAResourceEditor(resource: item, groups: groups) { await load() }
        }
        .sheet(item: $editingGroup) { item in
            HAGroupEditor(group: item) { await load() }
        }
        .sheet(item: $editingJob) { item in
            ReplicationJobEditor(job: item) { await load() }
        }
    }

    @ViewBuilder private var haContent: some View {
        Section("Cluster State") {
            if status.isEmpty { Text("No HA status is available.").foregroundStyle(.secondary) }
            ForEach(status) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.sid ?? item.rawID ?? item.type ?? String(localized: "HA Service"))
                        Text([item.node, item.status ?? item.state, item.requestState].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let quorate = item.quorate {
                        Image(systemName: quorate ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(quorate ? .green : .red)
                    }
                }
            }
        }
        Section("HA Resources") {
            if resources.isEmpty { Text("No HA resources configured.").foregroundStyle(.secondary) }
            ForEach(resources) { item in
                Button { editingResource = item } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.sid).foregroundStyle(.primary)
                            Text([item.state, item.group].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }.disabled(!canModifyHA)
            }
        }
    }

    @ViewBuilder private var groupContent: some View {
        Section {
            Text("HA groups define preferred nodes, priority order, restriction, and failback behavior for managed guests.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("HA Groups") {
            if groups.isEmpty { Text("No HA groups configured.").foregroundStyle(.secondary) }
            ForEach(groups) { item in
                Button { editingGroup = item } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.group).foregroundStyle(.primary)
                        Text(item.nodes ?? String(localized: "No preferred nodes"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!canModifyHA)
            }
        }
    }

    @ViewBuilder private var replicationContent: some View {
        Section("Replication Jobs") {
            if jobs.isEmpty { Text("No replication jobs configured.").foregroundStyle(.secondary) }
            ForEach(jobs) { item in
                Button { editingJob = item } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.id).foregroundStyle(.primary)
                            Text("\(item.source ?? "—") → \(item.target ?? "—") · \(item.schedule ?? "—")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.disabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(!canModifyReplication)
            }
        }
    }

    private var canModifyHA: Bool { appState.hasPrivilege("Sys.Console", on: "/") }
    private var canModifyReplication: Bool { appState.hasPrivilege("VM.Replicate", on: "/") }
    private var canModifyCurrentSection: Bool { selection == 2 ? canModifyReplication : canModifyHA }

    @MainActor private func load() async {
        guard let service = appState.service else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        async let a = service.fetchHAStatus()
        async let b = service.fetchHAResources()
        async let c = service.fetchHAGroups()
        async let d = service.fetchReplicationJobs()
        do { (status, resources, groups, jobs) = try await (a, b, c, d) }
        catch { self.error = error.localizedDescription }
    }
}

private struct HAResourceEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let resource: ProxmoxHAResource?
    let groups: [ProxmoxHAGroup]
    let onSaved: () async -> Void
    @State private var sid: String
    @State private var state: String
    @State private var group: String
    @State private var maxRestart: Int
    @State private var maxRelocate: Int
    @State private var failback: Bool
    @State private var autoRebalance: Bool
    @State private var comment: String
    @State private var working = false
    @State private var error: String?

    init(resource: ProxmoxHAResource?, groups: [ProxmoxHAGroup], onSaved: @escaping () async -> Void) {
        self.resource = resource; self.groups = groups; self.onSaved = onSaved
        _sid = State(initialValue: resource?.sid ?? "")
        _state = State(initialValue: resource?.state ?? "started")
        _group = State(initialValue: resource?.group ?? "")
        _maxRestart = State(initialValue: resource?.maxRestart ?? 1)
        _maxRelocate = State(initialValue: resource?.maxRelocate ?? 1)
        _failback = State(initialValue: resource?.failback ?? true)
        _autoRebalance = State(initialValue: resource?.autoRebalance ?? true)
        _comment = State(initialValue: resource?.comment ?? "")
    }

    var body: some View {
        NavigationStack { Form {
            Section("Resource") {
                TextField("Service ID (vm:100 or ct:101)", text: $sid).disabled(resource != nil)
                Picker("Requested State", selection: $state) {
                    Text("Started").tag("started"); Text("Stopped").tag("stopped"); Text("Disabled").tag("disabled"); Text("Ignored").tag("ignored")
                }
                Picker("HA Group", selection: $group) {
                    Text("None").tag(""); ForEach(groups) { Text($0.group).tag($0.group) }
                }
                Stepper("Maximum Restarts: \(maxRestart)", value: $maxRestart, in: 0...10)
                Stepper("Maximum Relocations: \(maxRelocate)", value: $maxRelocate, in: 0...10)
                Toggle("Fail Back", isOn: $failback)
                Toggle("Automatic Rebalance", isOn: $autoRebalance)
                TextField("Comment", text: $comment)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if resource != nil { Section { Button("Remove from HA", role: .destructive) { Task { await remove() } } } }
        }
        .navigationTitle(resource == nil ? "Add HA Resource" : "Edit HA Resource")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar(canSave: !sid.trimmed.isEmpty, save: save, dismiss: dismiss) }
        .overlay { if working { ProgressView() } }
        }
    }

    @MainActor private func save() async {
        guard let service = appState.service else { return }; working = true; defer { working = false }
        var form = ["state": state, "max_restart": "\(maxRestart)", "max_relocate": "\(maxRelocate)", "failback": failback ? "1":"0", "auto-rebalance": autoRebalance ? "1":"0"]
        if !group.isEmpty { form["group"] = group }; if !comment.trimmed.isEmpty { form["comment"] = comment.trimmed }
        do { if let resource { try await service.updateHAResource(sid: resource.sid, form: form) } else { form["sid"] = sid.trimmed; try await service.createHAResource(form: form) }; await onSaved(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func remove() async { guard let service = appState.service, let resource else { return }; working = true; defer { working = false }; do { try await service.deleteHAResource(sid: resource.sid); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct HAGroupEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let group: ProxmoxHAGroup?; let onSaved: () async -> Void
    @State private var id: String; @State private var nodes: String; @State private var restricted: Bool; @State private var noFailback: Bool; @State private var comment: String
    @State private var working = false; @State private var error: String?
    init(group: ProxmoxHAGroup?, onSaved: @escaping () async -> Void) { self.group = group; self.onSaved = onSaved; _id = State(initialValue: group?.group ?? ""); _nodes = State(initialValue: group?.nodes ?? ""); _restricted = State(initialValue: group?.restricted ?? false); _noFailback = State(initialValue: group?.noFailback ?? false); _comment = State(initialValue: group?.comment ?? "") }
    var body: some View { NavigationStack { Form {
        Section("Migration Policy") { TextField("Group ID", text: $id).disabled(group != nil); TextField("Nodes (node:priority, …)", text: $nodes).textInputAutocapitalization(.never); Toggle("Restrict to These Nodes", isOn: $restricted); Toggle("Disable Automatic Failback", isOn: $noFailback); TextField("Comment", text: $comment) }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if group != nil { Section { Button("Delete HA Group", role: .destructive) { Task { await remove() } } } }
    }.navigationTitle(group == nil ? "Add HA Group" : "Edit HA Group").navigationBarTitleDisplayMode(.inline).toolbar { editorToolbar(canSave: !id.trimmed.isEmpty && !nodes.trimmed.isEmpty, save: save, dismiss: dismiss) }.overlay { if working { ProgressView() } } } }
    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; var form = ["nodes":nodes.trimmed,"restricted":restricted ? "1":"0","nofailback":noFailback ? "1":"0"]; if !comment.trimmed.isEmpty { form["comment"] = comment.trimmed }; do { if let group { try await service.updateHAGroup(id: group.group, form: form) } else { form["group"] = id.trimmed; try await service.createHAGroup(form: form) }; await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let group else { return }; working = true; defer { working = false }; do { try await service.deleteHAGroup(id: group.group); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct ReplicationJobEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let job: ProxmoxReplicationJob?; let onSaved: () async -> Void
    @State private var id: String; @State private var target: String; @State private var schedule: String; @State private var rate: String; @State private var comment: String; @State private var enabled: Bool
    @State private var nodes: [String] = []; @State private var working = false; @State private var error: String?
    init(job: ProxmoxReplicationJob?, onSaved: @escaping () async -> Void) { self.job = job; self.onSaved = onSaved; _id = State(initialValue: job?.id ?? ""); _target = State(initialValue: job?.target ?? ""); _schedule = State(initialValue: job?.schedule ?? "*/15"); _rate = State(initialValue: job?.rate.map(String.init) ?? ""); _comment = State(initialValue: job?.comment ?? ""); _enabled = State(initialValue: !(job?.disabled ?? false)) }
    var body: some View { NavigationStack { Form {
        Section("Replication Job") { TextField("Job ID (VMID-job number)", text: $id).disabled(job != nil); Picker("Target Node", selection: $target) { Text("Select").tag(""); ForEach(nodes, id: \.self) { Text($0).tag($0) } }; TextField("Schedule", text: $schedule); TextField("Rate Limit (MB/s, optional)", text: $rate).keyboardType(.decimalPad); Toggle("Enabled", isOn: $enabled); TextField("Comment", text: $comment) }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if job != nil { Section { Button("Delete Replication Job", role: .destructive) { Task { await remove() } } } }
    }.navigationTitle(job == nil ? "Add Replication Job" : "Edit Replication Job").navigationBarTitleDisplayMode(.inline).toolbar { editorToolbar(canSave: !id.trimmed.isEmpty && !target.isEmpty, save: save, dismiss: dismiss) }.overlay { if working { ProgressView() } }.task { nodes = (try? await appState.service?.fetchNodes())?.map(\.node) ?? [] } } }
    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; var form = ["target":target,"schedule":schedule.trimmed,"disable":enabled ? "0":"1"]; if !rate.trimmed.isEmpty { form["rate"] = rate.trimmed }; if !comment.trimmed.isEmpty { form["comment"] = comment.trimmed }; do { if let job { try await service.updateReplicationJob(id: job.id, form: form) } else { form["id"] = id.trimmed; try await service.createReplicationJob(form: form) }; await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let job else { return }; working = true; defer { working = false }; do { try await service.deleteReplicationJob(id: job.id); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct ClusterEditorToolbar: ToolbarContent {
    let canSave: Bool; let save: () -> Void; let dismiss: DismissAction
    var body: some ToolbarContent { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) } }
}

private func editorToolbar(canSave: Bool, save: @escaping () async -> Void, dismiss: DismissAction) -> ClusterEditorToolbar {
    ClusterEditorToolbar(canSave: canSave, save: { Task { await save() } }, dismiss: dismiss)
}
