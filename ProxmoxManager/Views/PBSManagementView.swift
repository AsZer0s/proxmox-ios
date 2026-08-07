import SwiftUI

struct PBSManagementView: View {
    @EnvironmentObject private var appState: AppState
    @State private var servers = PBSStore.load()
    @State private var service: PBSAPIService?
    @State private var connected: PBSServer?
    @State private var datastores: [PBSDatastore] = []
    @State private var pveNodes: [ProxmoxNode] = []
    @State private var adding = false
    @State private var editing: PBSServer?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let connected, let service {
                Section {
                    LabeledContent("Server", value: connected.name)
                    Button("Disconnect", role: .destructive) {
                        self.connected = nil
                        self.service = nil
                        datastores = []
                    }
                }
                Section("Datastores") {
                    ForEach(datastores) { store in
                        NavigationLink {
                            PBSDatastoreView(service: service, datastore: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.store)
                                Text(store.comment ?? store.path ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Jobs") {
                    NavigationLink("Prune, Verify & Sync") { PBSJobsView(service: service) }
                    NavigationLink("Task History") { PBSTasksView(service: service) }
                    if let node = pveNodes.first?.node {
                        NavigationLink("Restore Through PVE Storage") { BackupsView(node: node) }
                    } else {
                        Label("Restore Through PVE Storage", systemImage: "externaldrive.badge.xmark")
                            .foregroundStyle(.secondary)
                        Text("Connect to a PVE server to restore through its storage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Backup Servers") {
                    ForEach(servers) { server in
                        Button { Task { await connect(server) } } label: {
                            HStack {
                                Image(systemName: "externaldrive.badge.timemachine")
                                VStack(alignment: .leading) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text("\(server.host):\(server.port)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { remove(server) }
                            Button("Edit") { editing = server }
                                .tint(.blue)
                        }
                    }
                    Button { adding = true } label: { Label("Add Backup Server", systemImage: "plus") }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Proxmox Backup Server")
        .overlay { if loading { ProgressView() } }
        .refreshable { if let connected { await connect(connected) } }
        .task { await loadPVENodes() }
        .sheet(isPresented: $adding) {
            PBSServerEditor { server, secret in
                guard let secret else { return }
                servers.append(server)
                PBSStore.save(servers)
                _ = KeychainHelper.saveGenericSecret(secret, account: "pbs.\(server.id.uuidString)")
                Task { await connect(server) }
            }
        }
        .sheet(item: $editing) { server in
            PBSServerEditor(server: server) { updated, replacementSecret in
                guard let index = servers.firstIndex(where: { $0.id == updated.id }) else { return }
                servers[index] = updated
                PBSStore.save(servers)
                if let replacementSecret, !replacementSecret.isEmpty {
                    _ = KeychainHelper.saveGenericSecret(
                        replacementSecret,
                        account: "pbs.\(updated.id.uuidString)"
                    )
                }
                if connected?.id == updated.id {
                    Task { await connect(updated) }
                }
            }
        }
    }

    @MainActor private func connect(_ server: PBSServer) async {
        guard let secret = KeychainHelper.genericSecret(account: "pbs.\(server.id.uuidString)") else {
            error = String(localized: "No saved credentials for this backup server."); return
        }
        loading = true; error = nil; defer { loading = false }
        do {
            let service = PBSAPIService(server: server, secret: secret)
            try await service.authenticate()
            datastores = try await service.datastores()
            self.service = service
            connected = server
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func loadPVENodes() async {
        guard let pveService = appState.service else { return }
        pveNodes = (try? await pveService.fetchNodes()) ?? []
    }

    private func remove(_ server: PBSServer) {
        servers.removeAll { $0.id == server.id }
        PBSStore.save(servers)
        _ = KeychainHelper.deleteGenericSecret(account: "pbs.\(server.id.uuidString)")
        if connected?.id == server.id {
            connected = nil
            service = nil
            datastores = []
        }
    }
}

private struct PBSServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let existingServer: PBSServer?
    let onSave: (PBSServer, String?) -> Void
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var auth: PBSAuthMethod
    @State private var tokenID: String
    @State private var secret = ""
    @State private var insecure: Bool
    @State private var fingerprint: String

    init(server: PBSServer? = nil, onSave: @escaping (PBSServer, String?) -> Void) {
        existingServer = server
        self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: String(server?.port ?? 8007))
        _username = State(initialValue: server?.username ?? "root@pam")
        _auth = State(initialValue: server?.authMethod ?? .token)
        _tokenID = State(initialValue: server?.tokenID ?? "")
        _insecure = State(initialValue: server?.allowInsecureSSL ?? false)
        _fingerprint = State(initialValue: server?.certificateFingerprint ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host or IP", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                }
                Section("Authentication") {
                    Picker("Method", selection: $auth) { ForEach(PBSAuthMethod.allCases) { Text($0.label).tag($0) } }
                    if auth == .ticket { TextField("Username", text: $username) }
                    else { TextField("Token ID", text: $tokenID).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    SecureField(existingServer == nil ? (auth == .ticket ? String(localized: "Password") : String(localized: "Token Secret")) : String(localized: "New secret (optional)"), text: $secret)
                }
                Section {
                    Toggle("Allow self-signed certificate", isOn: $insecure)
                    if insecure { TextField("SHA-256 Certificate Fingerprint", text: $fingerprint).textInputAutocapitalization(.characters).autocorrectionDisabled() }
                } footer: { if insecure { Text("Copy the SHA-256 fingerprint from the PBS server and verify it through a separate trusted channel.") } }
            }
            .navigationTitle(existingServer == nil ? String(localized: "Add Backup Server") : String(localized: "Edit Backup Server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var server = PBSServer(name: name.trimmed, host: host.trimmed, port: Int(port) ?? 8007, username: username.trimmed, authMethod: auth, tokenID: tokenID.trimmed, allowInsecureSSL: insecure, certificateFingerprint: fingerprint.trimmed)
                        if let existingServer { server.id = existingServer.id }
                        onSave(server, secret.trimmed.isEmpty ? nil : secret)
                        dismiss()
                    }.disabled(name.trimmed.isEmpty || host.trimmed.isEmpty || (existingServer == nil && secret.isEmpty) || (auth == .token && tokenID.trimmed.isEmpty) || (insecure && fingerprint.filter(\.isHexDigit).count != 64))
                }
            }
        }
    }
}

private struct PBSDatastoreView: View {
    let service: PBSAPIService
    let datastore: PBSDatastore
    @State private var status: PBSDatastoreStatus?
    @State private var groups: [PBSBackupGroup] = []
    @State private var snapshots: [PBSBackupSnapshot] = []
    @State private var selectedGroup: PBSBackupGroup?
    @State private var snapshotToDelete: PBSBackupSnapshot?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section("Capacity") {
                LabeledContent("Used", value: byte(status?.used))
                LabeledContent("Available", value: byte(status?.available))
                if let used = status?.used, let total = status?.total, total > 0 {
                    ProgressView(value: Double(used), total: Double(total))
                    Text((Double(used) / Double(total)).formatted(.percent.precision(.fractionLength(2))))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Run Garbage Collection") { Task { await garbageCollect() } }
            }
            Section("Backup Groups") {
                ForEach(groups) { group in
                    Button { Task { await loadSnapshots(group) } } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(group.id).foregroundStyle(.primary)
                                Text("\(group.backupCount ?? 0) snapshots · \(group.owner ?? "—")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedGroup?.id == group.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            if selectedGroup != nil {
                Section("Snapshots") {
                    ForEach(snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(Date(timeIntervalSince1970: TimeInterval(snapshot.backupTime)), style: .date)
                            HStack {
                                Text(byte(snapshot.size)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(snapshot.verification?.state ?? String(localized: "Not Verified"))
                                    .font(.caption).foregroundStyle(snapshot.verification?.state == "ok" ? .green : .secondary)
                            }
                            Button("Verify Snapshot") { Task { await verify(snapshot) } }.font(.caption)
                            Button("Delete Snapshot", role: .destructive) { snapshotToDelete = snapshot }
                                .font(.caption)
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(datastore.store)
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .alert("Delete PBS Snapshot?", isPresented: Binding(
            get: { snapshotToDelete != nil },
            set: { if !$0 { snapshotToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let snapshotToDelete { Task { await delete(snapshotToDelete) } }
                snapshotToDelete = nil
            }
            Button("Cancel", role: .cancel) { snapshotToDelete = nil }
        } message: {
            Text("This permanently removes the selected backup snapshot.")
        }
    }

    private func byte(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .binary) } ?? "—" }
    @MainActor private func load() async {
        loading = true; defer { loading = false }
        do { async let s = service.status(store: datastore.store); async let g = service.groups(store: datastore.store); status = try await s; groups = try await g }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func loadSnapshots(_ group: PBSBackupGroup) async {
        selectedGroup = group; loading = true; defer { loading = false }
        do { snapshots = try await service.snapshots(store: datastore.store, group: group) } catch { self.error = error.localizedDescription }
    }
    @MainActor private func garbageCollect() async { do { _ = try await service.garbageCollect(store: datastore.store); await load() } catch { self.error = error.localizedDescription } }
    @MainActor private func verify(_ snapshot: PBSBackupSnapshot) async { do { _ = try await service.verify(store: datastore.store, snapshot: snapshot); if let group = selectedGroup { await loadSnapshots(group) } } catch { self.error = error.localizedDescription } }
    @MainActor private func delete(_ snapshot: PBSBackupSnapshot) async {
        do {
            try await service.deleteSnapshot(store: datastore.store, snapshot: snapshot)
            if let group = selectedGroup { await loadSnapshots(group) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct PBSJobsView: View {
    let service: PBSAPIService
    @State private var kind = "prune"
    @State private var jobs: [PBSJob] = []
    @State private var editing: PBSJob?
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        List {
            Picker("Job Type", selection: $kind) { Text("Prune").tag("prune"); Text("Verify").tag("verify"); Text("Sync").tag("sync") }
                .pickerStyle(.segmented).listRowBackground(Color.clear)
            ForEach(jobs) { job in
                Button { editing = job } label: {
                    VStack(alignment: .leading) {
                        Text(job.id).foregroundStyle(.primary)
                        Text([job.store, job.schedule, job.lastRunState].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("Run") { Task { await run(job) } }.tint(.green) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("PBS Jobs")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
        .task(id: kind) { await load() }
        .sheet(isPresented: $creating) { PBSJobEditor(service: service, kind: kind, job: nil) { await load() } }
        .sheet(item: $editing) { PBSJobEditor(service: service, kind: kind, job: $0) { await load() } }
    }
    @MainActor private func load() async { do { jobs = try await (kind == "prune" ? service.pruneJobs() : kind == "verify" ? service.verifyJobs() : service.syncJobs()) } catch { self.error = error.localizedDescription } }
    @MainActor private func run(_ job: PBSJob) async { do { _ = try await (kind == "prune" ? service.runPruneJob(id: job.id) : kind == "verify" ? service.runVerifyJob(id: job.id) : service.runSyncJob(id: job.id)); await load() } catch { self.error = error.localizedDescription } }
}

private struct PBSTasksView: View {
    let service: PBSAPIService
    @State private var tasks: [PBSTask] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if tasks.isEmpty && !loading { Text("No PBS tasks are available.").foregroundStyle(.secondary) }
            ForEach(tasks) { task in
                NavigationLink {
                    PBSTaskLogView(service: service, task: task)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.workerType ?? task.upid).foregroundStyle(.primary)
                        Text([task.status, task.user, task.startTime.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("PBS Tasks")
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor private func load() async {
        loading = true; defer { loading = false }
        do { tasks = try await service.tasks() }
        catch { self.error = error.localizedDescription }
    }
}

private struct PBSTaskLogView: View {
    let service: PBSAPIService
    let task: PBSTask
    @State private var entries: [PBSTaskLogEntry] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if entries.isEmpty && !loading { Text("No task log entries are available.").foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                Text(entry.t).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(task.workerType ?? "PBS Task")
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor private func load() async {
        loading = true; defer { loading = false }
        do { entries = try await service.taskLog(upid: task.upid) }
        catch { self.error = error.localizedDescription }
    }
}

private struct PBSJobEditor: View {
    @Environment(\.dismiss) private var dismiss
    let service: PBSAPIService; let kind: String; let job: PBSJob?; let onSaved: () async -> Void
    @State private var id = ""; @State private var store = ""; @State private var schedule = "daily"; @State private var comment = ""; @State private var disabled = false; @State private var remote = ""; @State private var remoteStore = ""; @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("ID", text: $id).disabled(job != nil)
                TextField("Datastore", text: $store)
                TextField("Schedule", text: $schedule)
                if kind == "sync" { TextField("Remote", text: $remote); TextField("Remote Datastore", text: $remoteStore) }
                TextField("Comment", text: $comment)
                Toggle("Disabled", isOn: $disabled)
                if let error { Text(error).foregroundStyle(.red) }
                if job != nil { Button("Delete Job", role: .destructive) { Task { await remove() } } }
            }
            .navigationTitle(job == nil ? String(localized: "Add Job") : String(localized: "Edit Job"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(id.trimmed.isEmpty || store.trimmed.isEmpty) } }
            .onAppear { if let job { id = job.id; store = job.store ?? ""; schedule = job.schedule ?? ""; comment = job.comment ?? ""; disabled = job.disable ?? false } }
        }
    }
    private var form: [String:String] { var f = ["store": store.trimmed, "schedule": schedule.trimmed, "comment": comment.trimmed, "disable": disabled ? "1":"0"]; if kind == "sync" { f["remote"] = remote.trimmed; f["remote-store"] = remoteStore.trimmed }; return f }
    @MainActor private func save() async { do { if let job { try await service.updateJob(kind: kind, id: job.id, form: form) } else { var f=form; f["id"]=id.trimmed; try await service.createJob(kind: kind, form: f) }; await onSaved(); dismiss() } catch { self.error=error.localizedDescription } }
    @MainActor private func remove() async { guard let job else { return }; do { try await service.deleteJob(kind: kind, id: job.id); await onSaved(); dismiss() } catch { self.error=error.localizedDescription } }
}
