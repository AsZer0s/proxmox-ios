import SwiftUI

struct ScopedFirewallView: View {
    @EnvironmentObject private var appState: AppState
    let scope: FirewallScope

    @State private var options: GuestFirewallOptions?
    @State private var rules: [GuestFirewallRule] = []
    @State private var editingRule: GuestFirewallRule?
    @State private var addingRule = false
    @State private var editingOptions = false
    @State private var deletingRule: GuestFirewallRule?
    @State private var loading = true
    @State private var error: String?

    private var canEdit: Bool {
        appState.hasPrivilege("Sys.Modify", on: scope.privilegePath)
    }

    var body: some View {
        List {
            Section("Options") {
                if let options {
                    LabeledContent("Firewall", value: options.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    LabeledContent("Input Policy", value: options.inputPolicy)
                    LabeledContent("Output Policy", value: options.outputPolicy)
                    if canEdit { Button("Edit Firewall Options") { editingOptions = true } }
                } else if !loading {
                    Text("Firewall options are unavailable.").foregroundStyle(.secondary)
                }
            }

            Section("Rules") {
                if rules.isEmpty && !loading { Text("No firewall rules").foregroundStyle(.secondary) }
                ForEach(rules) { rule in
                    Button { editingRule = rule } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(rule.type.uppercased()) · \(rule.action.uppercased())").foregroundStyle(.primary)
                                Spacer()
                                if !rule.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(ruleSummary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .disabled(!canEdit)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canEdit {
                            Button(role: .destructive) { deletingRule = rule } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }

            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        }
        .navigationTitle(scope.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingRule = true } label: { Image(systemName: "plus") }.disabled(!canEdit)
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $addingRule) {
            ScopedFirewallRuleEditor(scope: scope, rule: nil) { await load() }.environmentObject(appState)
        }
        .sheet(item: $editingRule) { rule in
            ScopedFirewallRuleEditor(scope: scope, rule: rule) { await load() }.environmentObject(appState)
        }
        .sheet(isPresented: $editingOptions) {
            if let options {
                ScopedFirewallOptionsEditor(scope: scope, options: options) { await load() }.environmentObject(appState)
            }
        }
        .confirmationDialog("Delete Firewall Rule?", isPresented: Binding(get: { deletingRule != nil }, set: { if !$0 { deletingRule = nil } })) {
            Button("Delete", role: .destructive) {
                guard let deletingRule else { return }
                Task { await delete(deletingRule) }
            }
        } message: { Text("This removes the selected firewall rule.") }
    }

    private func ruleSummary(_ rule: GuestFirewallRule) -> String {
        [rule.protocolName, rule.source.map { "from \($0)" }, rule.destination.map { "to \($0)" }, rule.destinationPort.map { "port \($0)" }, rule.comment]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @MainActor private func load() async {
        guard let service = appState.service else { return }
        loading = true; error = nil; defer { loading = false }
        do {
            async let fetchedOptions = service.fetchFirewallOptions(scope: scope)
            async let fetchedRules = service.fetchFirewallRules(scope: scope)
            (options, rules) = try await (fetchedOptions, fetchedRules)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func delete(_ rule: GuestFirewallRule) async {
        guard let service = appState.service else { return }
        do { try await service.deleteFirewallRule(scope: scope, position: rule.pos); await load() }
        catch { self.error = error.localizedDescription }
    }
}

private struct ScopedFirewallOptionsEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let scope: FirewallScope
    let options: GuestFirewallOptions
    let onSaved: () async -> Void
    @State private var enabled: Bool
    @State private var inputPolicy: String
    @State private var outputPolicy: String
    @State private var inputLog: String
    @State private var outputLog: String
    @State private var error: String?

    init(scope: FirewallScope, options: GuestFirewallOptions, onSaved: @escaping () async -> Void) {
        self.scope = scope; self.options = options; self.onSaved = onSaved
        _enabled = State(initialValue: options.enabled)
        _inputPolicy = State(initialValue: options.inputPolicy)
        _outputPolicy = State(initialValue: options.outputPolicy)
        _inputLog = State(initialValue: options.inputLogLevel)
        _outputLog = State(initialValue: options.outputLogLevel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Enabled", isOn: $enabled)
                Picker("Input Policy", selection: $inputPolicy) { Text("ACCEPT").tag("ACCEPT"); Text("DROP").tag("DROP"); Text("REJECT").tag("REJECT") }
                Picker("Output Policy", selection: $outputPolicy) { Text("ACCEPT").tag("ACCEPT"); Text("DROP").tag("DROP"); Text("REJECT").tag("REJECT") }
                TextField("Input Log Level", text: $inputLog)
                TextField("Output Log Level", text: $outputLog)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Firewall Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
            }
        }
    }

    @MainActor private func save() async {
        guard let service = appState.service else { return }
        do {
            try await service.updateFirewallOptions(scope: scope, form: ["enable": enabled ? "1" : "0", "policy_in": inputPolicy, "policy_out": outputPolicy, "log_level_in": inputLog.trimmed, "log_level_out": outputLog.trimmed])
            await onSaved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ScopedFirewallRuleEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let scope: FirewallScope
    let rule: GuestFirewallRule?
    let onSaved: () async -> Void
    @State private var type: String
    @State private var action: String
    @State private var enabled: Bool
    @State private var protocolName: String
    @State private var source: String
    @State private var destination: String
    @State private var destinationPort: String
    @State private var comment: String
    @State private var error: String?

    init(scope: FirewallScope, rule: GuestFirewallRule?, onSaved: @escaping () async -> Void) {
        self.scope = scope; self.rule = rule; self.onSaved = onSaved
        _type = State(initialValue: rule?.type ?? "in")
        _action = State(initialValue: rule?.action ?? "ACCEPT")
        _enabled = State(initialValue: rule?.enabled ?? true)
        _protocolName = State(initialValue: rule?.protocolName ?? "")
        _source = State(initialValue: rule?.source ?? "")
        _destination = State(initialValue: rule?.destination ?? "")
        _destinationPort = State(initialValue: rule?.destinationPort ?? "")
        _comment = State(initialValue: rule?.comment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Direction", selection: $type) { Text("Input").tag("in"); Text("Output").tag("out"); Text("Forward").tag("forward") }
                Picker("Action", selection: $action) { Text("Accept").tag("ACCEPT"); Text("Drop").tag("DROP"); Text("Reject").tag("REJECT") }
                Toggle("Enabled", isOn: $enabled)
                TextField("Protocol (optional)", text: $protocolName).textInputAutocapitalization(.never)
                TextField("Source (optional)", text: $source).textInputAutocapitalization(.never)
                TextField("Destination (optional)", text: $destination).textInputAutocapitalization(.never)
                TextField("Destination Port (optional)", text: $destinationPort).keyboardType(.numbersAndPunctuation)
                TextField("Comment", text: $comment)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(rule == nil ? "Add Firewall Rule" : "Edit Firewall Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
            }
        }
    }

    private var form: [String: String] {
        var result = ["type": type, "action": action, "enable": enabled ? "1" : "0"]
        for (key, value) in [("proto", protocolName), ("source", source), ("dest", destination), ("dport", destinationPort), ("comment", comment)] where !value.trimmed.isEmpty {
            result[key] = value.trimmed
        }
        return result
    }

    @MainActor private func save() async {
        guard let service = appState.service else { return }
        do {
            if let rule { try await service.updateFirewallRule(scope: scope, position: rule.pos, form: form) }
            else { try await service.createFirewallRule(scope: scope, form: form) }
            await onSaved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
