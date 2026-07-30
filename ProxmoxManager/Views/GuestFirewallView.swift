import SwiftUI

struct GuestFirewallView: View {
    @EnvironmentObject private var appState: AppState

    let guest: ProxmoxVM

    @State private var rules: [GuestFirewallRule] = []
    @State private var options: GuestFirewallOptions?
    @State private var ipSets: [GuestFirewallIPSet] = []
    @State private var securityGroups: [FirewallSecurityGroup] = []
    @State private var log: [ProxmoxTaskLogEntry] = []
    @State private var editingRule: GuestFirewallRule?
    @State private var showingAddRule = false
    @State private var showingOptions = false
    @State private var showingAddIPSet = false
    @State private var deletingRule: GuestFirewallRule?
    @State private var deletingIPSet: GuestFirewallIPSet?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var error: String?

    private var canEdit: Bool {
        appState.hasPrivilege("VM.Config.Network", for: guest.vmid)
    }

    var body: some View {
        List {
            optionsSection
            rulesSection
            ipSetsSection
            securityGroupsSection
            logSection
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Firewall")
        .refreshable { await load() }
        .task { await load() }
        .overlay {
            if isLoading || isWorking {
                ProgressView()
            }
        }
        .sheet(isPresented: $showingOptions) {
            if let options {
                FirewallOptionsEditorView(guest: guest, options: options) {
                    await load()
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showingAddRule) {
            FirewallRuleEditorView(
                guest: guest,
                rule: nil,
                securityGroups: securityGroups
            ) {
                await load()
            }
            .environmentObject(appState)
        }
        .sheet(item: $editingRule) { rule in
            FirewallRuleEditorView(
                guest: guest,
                rule: rule,
                securityGroups: securityGroups
            ) {
                await load()
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showingAddIPSet) {
            CreateFirewallIPSetView(guest: guest) {
                await load()
            }
            .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete Firewall Rule?",
            isPresented: Binding(
                get: { deletingRule != nil },
                set: { if !$0 { deletingRule = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let rule = deletingRule else { return }
                Task { await delete(rule) }
            }
        }
        .confirmationDialog(
            "Delete IPSet?",
            isPresented: Binding(
                get: { deletingIPSet != nil },
                set: { if !$0 { deletingIPSet = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let ipSet = deletingIPSet else { return }
                Task { await delete(ipSet) }
            }
        } message: {
            Text("The IPSet and all of its entries will be removed.")
        }
    }

    private var optionsSection: some View {
        Section {
            if let options {
                LabeledContent(
                    "Firewall",
                    value: options.enabled
                        ? String(localized: "Enabled")
                        : String(localized: "Disabled")
                )
                LabeledContent("Input Policy", value: options.inputPolicy)
                LabeledContent("Output Policy", value: options.outputPolicy)
                if canEdit {
                    Button("Edit Firewall Options") {
                        showingOptions = true
                    }
                }
            } else {
                Text("Firewall options are unavailable.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Options")
        }
    }

    private var rulesSection: some View {
        Section {
            if rules.isEmpty {
                Text("No firewall rules")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    FirewallRuleRow(rule: rule)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if canEdit { editingRule = rule }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canEdit {
                                Button(role: .destructive) {
                                    deletingRule = rule
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editingRule = rule
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                }
            }
        } header: {
            HStack {
                Text("Rules")
                Spacer()
                if canEdit {
                    Button {
                        showingAddRule = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Firewall Rule")
                }
            }
        }
    }

    private var ipSetsSection: some View {
        Section {
            if ipSets.isEmpty {
                Text("No IPSets")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ipSets) { ipSet in
                    NavigationLink {
                        FirewallIPSetDetailView(guest: guest, ipSet: ipSet)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ipSet.name)
                            if let comment = ipSet.comment, !comment.isEmpty {
                                Text(comment)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        if canEdit {
                            Button(role: .destructive) {
                                deletingIPSet = ipSet
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("IPSets")
                Spacer()
                if canEdit {
                    Button {
                        showingAddIPSet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add IPSet")
                }
            }
        } footer: {
            Text("Reference an IPSet in a rule with +name.")
        }
    }

    private var logSection: some View {
        Section {
            if log.isEmpty {
                Text("No firewall log entries")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.suffix(100)) { entry in
                    Text(entry.t)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Firewall Log")
        }
    }

    private var securityGroupsSection: some View {
        Section {
            if securityGroups.isEmpty {
                Text("No security groups")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(securityGroups) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.group)
                        if let comment = group.comment, !comment.isEmpty {
                            Text(comment)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Security Groups")
        } footer: {
            Text("Attach an existing cluster security group by adding a group rule.")
        }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        error = nil
        async let rulesRequest = service.fetchGuestFirewallRules(
            node: guest.node,
            type: guest.type,
            vmid: guest.vmid
        )
        async let optionsRequest = service.fetchGuestFirewallOptions(
            node: guest.node,
            type: guest.type,
            vmid: guest.vmid
        )
        async let ipSetsRequest = service.fetchGuestFirewallIPSets(
            node: guest.node,
            type: guest.type,
            vmid: guest.vmid
        )
        async let groupsRequest = service.fetchFirewallSecurityGroups()
        async let logRequest = service.fetchGuestFirewallLog(
            node: guest.node,
            type: guest.type,
            vmid: guest.vmid
        )

        do { rules = try await rulesRequest } catch { self.error = error.localizedDescription }
        do { options = try await optionsRequest } catch {
            if self.error == nil { self.error = error.localizedDescription }
        }
        do { ipSets = try await ipSetsRequest } catch {
            if self.error == nil { self.error = error.localizedDescription }
        }
        securityGroups = (try? await groupsRequest) ?? []
        log = (try? await logRequest) ?? []
        isLoading = false
    }

    @MainActor
    private func delete(_ rule: GuestFirewallRule) async {
        guard let service = appState.service else { return }
        isWorking = true
        defer {
            isWorking = false
            deletingRule = nil
        }
        do {
            try await service.deleteGuestFirewallRule(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                position: rule.pos
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ ipSet: GuestFirewallIPSet) async {
        guard let service = appState.service else { return }
        isWorking = true
        defer {
            isWorking = false
            deletingIPSet = nil
        }
        do {
            try await service.deleteGuestFirewallIPSet(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                name: ipSet.name
            )
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FirewallRuleRow: View {
    let rule: GuestFirewallRule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: rule.enabled ? "checkmark.shield" : "shield.slash")
                .foregroundStyle(rule.enabled ? color : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rule.type.uppercased())
                        .font(.caption.weight(.semibold))
                    Text(rule.action)
                        .font(.body.weight(.medium))
                }
                let details = [
                    rule.protocolName,
                    rule.source.map {
                        String(localized: "Source: \($0)")
                    },
                    rule.destination.map {
                        String(localized: "Destination: \($0)")
                    },
                    rule.destinationPort.map {
                        String(localized: "Destination port: \($0)")
                    },
                    rule.interface,
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let comment = rule.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        switch rule.action.uppercased() {
        case "ACCEPT": return .green
        case "REJECT", "DROP": return .red
        default: return .blue
        }
    }
}

private struct FirewallOptionsEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let onSaved: () async -> Void

    @State private var enabled: Bool
    @State private var inputPolicy: String
    @State private var outputPolicy: String
    @State private var dhcp: Bool
    @State private var ipFilter: Bool
    @State private var macFilter: Bool
    @State private var ndp: Bool
    @State private var routerAdvertisement: Bool
    @State private var inputLogLevel: String
    @State private var outputLogLevel: String
    @State private var isSaving = false
    @State private var error: String?

    init(
        guest: ProxmoxVM,
        options: GuestFirewallOptions,
        onSaved: @escaping () async -> Void
    ) {
        self.guest = guest
        self.onSaved = onSaved
        _enabled = State(initialValue: options.enabled)
        _inputPolicy = State(initialValue: options.inputPolicy)
        _outputPolicy = State(initialValue: options.outputPolicy)
        _dhcp = State(initialValue: options.dhcp)
        _ipFilter = State(initialValue: options.ipFilter)
        _macFilter = State(initialValue: options.macFilter)
        _ndp = State(initialValue: options.ndp)
        _routerAdvertisement = State(initialValue: options.routerAdvertisement)
        _inputLogLevel = State(initialValue: options.inputLogLevel)
        _outputLogLevel = State(initialValue: options.outputLogLevel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable Firewall", isOn: $enabled)
                    Picker("Input Policy", selection: $inputPolicy) {
                        ForEach(["ACCEPT", "DROP", "REJECT"], id: \.self) {
                            Text($0)
                        }
                    }
                    Picker("Output Policy", selection: $outputPolicy) {
                        ForEach(["ACCEPT", "DROP", "REJECT"], id: \.self) {
                            Text($0)
                        }
                    }
                }
                Section {
                    Toggle("Allow DHCP", isOn: $dhcp)
                    Toggle("IP Filter", isOn: $ipFilter)
                    Toggle("MAC Filter", isOn: $macFilter)
                    Toggle("Neighbor Discovery", isOn: $ndp)
                    Toggle("Router Advertisement", isOn: $routerAdvertisement)
                } header: {
                    Text("Filters")
                }
                Section {
                    Picker("Input Log Level", selection: $inputLogLevel) {
                        ForEach(Self.logLevels, id: \.self) {
                            Text($0)
                        }
                    }
                    Picker("Output Log Level", selection: $outputLogLevel) {
                        ForEach(Self.logLevels, id: \.self) {
                            Text($0)
                        }
                    }
                } header: {
                    Text("Logging")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Firewall Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .overlay { if isSaving { ProgressView() } }
        }
    }

    private static let logLevels = [
        "nolog", "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug",
    ]

    @MainActor
    private func save() async {
        guard let service = appState.service else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.updateGuestFirewallOptions(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: [
                    "enable": enabled ? "1" : "0",
                    "policy_in": inputPolicy,
                    "policy_out": outputPolicy,
                    "dhcp": dhcp ? "1" : "0",
                    "ipfilter": ipFilter ? "1" : "0",
                    "macfilter": macFilter ? "1" : "0",
                    "ndp": ndp ? "1" : "0",
                    "radv": routerAdvertisement ? "1" : "0",
                    "log_level_in": inputLogLevel,
                    "log_level_out": outputLogLevel,
                ]
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FirewallRuleEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let rule: GuestFirewallRule?
    let securityGroups: [FirewallSecurityGroup]
    let onSaved: () async -> Void

    @State private var ruleType: String
    @State private var action: String
    @State private var enabled: Bool
    @State private var protocolName: String
    @State private var source: String
    @State private var destination: String
    @State private var sourcePort: String
    @State private var destinationPort: String
    @State private var interface: String
    @State private var macro: String
    @State private var logLevel: String
    @State private var comment: String
    @State private var isSaving = false
    @State private var error: String?

    init(
        guest: ProxmoxVM,
        rule: GuestFirewallRule?,
        securityGroups: [FirewallSecurityGroup],
        onSaved: @escaping () async -> Void
    ) {
        self.guest = guest
        self.rule = rule
        self.securityGroups = securityGroups
        self.onSaved = onSaved
        _ruleType = State(initialValue: rule?.type ?? "in")
        _action = State(initialValue: rule?.action ?? "ACCEPT")
        _enabled = State(initialValue: rule?.enabled ?? true)
        _protocolName = State(initialValue: rule?.protocolName ?? "")
        _source = State(initialValue: rule?.source ?? "")
        _destination = State(initialValue: rule?.destination ?? "")
        _sourcePort = State(initialValue: rule?.sourcePort ?? "")
        _destinationPort = State(initialValue: rule?.destinationPort ?? "")
        _interface = State(initialValue: rule?.interface ?? "")
        _macro = State(initialValue: rule?.macro ?? "")
        _logLevel = State(initialValue: rule?.logLevel ?? "nolog")
        _comment = State(initialValue: rule?.comment ?? "")
    }

    private var canSave: Bool {
        !action.trimmed.isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Direction", selection: $ruleType) {
                        Text("Inbound").tag("in")
                        Text("Outbound").tag("out")
                        Text("Forward").tag("forward")
                        Text("Security Group").tag("group")
                    }
                    if ruleType == "group", !securityGroups.isEmpty {
                        Picker("Security Group", selection: $action) {
                            ForEach(securityGroups) { group in
                                Text(group.group).tag(group.group)
                            }
                        }
                    } else if ruleType != "group" {
                        Picker("Action", selection: $action) {
                            ForEach(["ACCEPT", "DROP", "REJECT"], id: \.self) {
                                Text($0)
                            }
                        }
                    } else {
                        TextField("Security Group", text: $action)
                    }
                    Toggle("Enabled", isOn: $enabled)
                }

                if ruleType != "group" {
                    Section {
                        TextField("Protocol (optional)", text: $protocolName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Source (optional)", text: $source)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Destination (optional)", text: $destination)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Source Port (optional)", text: $sourcePort)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Destination Port (optional)", text: $destinationPort)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Interface (optional)", text: $interface)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Macro (optional)", text: $macro)
                    } header: {
                        Text("Match")
                    }
                }

                Section {
                    Picker("Log Level", selection: $logLevel) {
                        ForEach(
                            ["nolog", "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"],
                            id: \.self
                        ) {
                            Text($0)
                        }
                    }
                    TextField("Comment (optional)", text: $comment, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(rule == nil ? "Add Firewall Rule" : "Edit Firewall Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .overlay { if isSaving { ProgressView() } }
            .onChange(of: ruleType) { newValue in
                if newValue == "group" {
                    action = securityGroups.first?.group ?? ""
                } else if !["ACCEPT", "DROP", "REJECT"].contains(action) {
                    action = "ACCEPT"
                }
            }
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, canSave else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        var form = [
            "type": ruleType,
            "action": action.trimmed,
            "enable": enabled ? "1" : "0",
            "log": logLevel,
        ]
        let values = ruleType == "group"
            ? [
                "proto": "",
                "source": "",
                "dest": "",
                "sport": "",
                "dport": "",
                "iface": "",
                "macro": "",
                "comment": comment,
            ]
            : [
                "proto": protocolName,
                "source": source,
                "dest": destination,
                "sport": sourcePort,
                "dport": destinationPort,
                "iface": interface,
                "macro": macro,
                "comment": comment,
            ]
        for (key, value) in values where !value.trimmed.isEmpty {
            form[key] = value.trimmed
        }
        if let rule {
            let removed = values.compactMap { key, value -> String? in
                guard value.trimmed.isEmpty else { return nil }
                switch key {
                case "proto": return rule.protocolName == nil ? nil : key
                case "source": return rule.source == nil ? nil : key
                case "dest": return rule.destination == nil ? nil : key
                case "sport": return rule.sourcePort == nil ? nil : key
                case "dport": return rule.destinationPort == nil ? nil : key
                case "iface": return rule.interface == nil ? nil : key
                case "macro": return rule.macro == nil ? nil : key
                case "comment": return rule.comment == nil ? nil : key
                default: return nil
                }
            }
            if !removed.isEmpty { form["delete"] = removed.joined(separator: ",") }
        }

        do {
            if let rule {
                try await service.updateGuestFirewallRule(
                    node: guest.node,
                    type: guest.type,
                    vmid: guest.vmid,
                    position: rule.pos,
                    form: form
                )
            } else {
                try await service.createGuestFirewallRule(
                    node: guest.node,
                    type: guest.type,
                    vmid: guest.vmid,
                    form: form
                )
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CreateFirewallIPSetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var comment = ""
    @State private var isSaving = false
    @State private var error: String?

    private var canSave: Bool {
        name.range(
            of: #"^[A-Za-z][A-Za-z0-9_-]{1,63}$"#,
            options: .regularExpression
        ) != nil && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("IPSet Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Comment (optional)", text: $comment)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add IPSet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.createGuestFirewallIPSet(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                name: name,
                comment: comment.trimmed.isEmpty ? nil : comment.trimmed
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FirewallIPSetDetailView: View {
    @EnvironmentObject private var appState: AppState

    let guest: ProxmoxVM
    let ipSet: GuestFirewallIPSet

    @State private var entries: [GuestFirewallIPSetEntry] = []
    @State private var showingAdd = false
    @State private var deletingEntry: GuestFirewallIPSetEntry?
    @State private var isLoading = true
    @State private var error: String?

    private var canEdit: Bool {
        appState.hasPrivilege("VM.Config.Network", for: guest.vmid)
    }

    var body: some View {
        List {
            if entries.isEmpty, !isLoading {
                Text("No IPSet entries")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.cidr)
                            .font(.body.monospaced())
                        if entry.nomatch {
                            Text("No Match")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let comment = entry.comment, !comment.isEmpty {
                        Text(comment)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if canEdit {
                        Button(role: .destructive) {
                            deletingEntry = entry
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(ipSet.name)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showingAdd) {
            AddFirewallIPSetEntryView(guest: guest, ipSet: ipSet) {
                await load()
            }
            .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete IPSet Entry?",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let entry = deletingEntry else { return }
                Task { await delete(entry) }
            }
        }
        .overlay { if isLoading { ProgressView() } }
    }

    @MainActor
    private func load() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await service.fetchGuestFirewallIPSetEntries(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                name: ipSet.name
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ entry: GuestFirewallIPSetEntry) async {
        guard let service = appState.service else { return }
        do {
            try await service.deleteGuestFirewallIPSetEntry(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                name: ipSet.name,
                cidr: entry.cidr
            )
            deletingEntry = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AddFirewallIPSetEntryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let ipSet: GuestFirewallIPSet
    let onSaved: () async -> Void

    @State private var cidr = ""
    @State private var comment = ""
    @State private var noMatch = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("IP Address / CIDR", text: $cidr)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("No Match", isOn: $noMatch)
                TextField("Comment (optional)", text: $comment)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add IPSet Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(cidr.trimmed.isEmpty || isSaving)
                }
            }
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, !cidr.trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.addGuestFirewallIPSetEntry(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                name: ipSet.name,
                cidr: cidr.trimmed,
                comment: comment.trimmed.isEmpty ? nil : comment.trimmed,
                nomatch: noMatch
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
