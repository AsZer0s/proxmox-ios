import SwiftUI

/// Add or edit a Proxmox server. On save it persists the server + password and,
/// when adding, immediately attempts to connect.
struct ServerSetupView: View {
    enum Mode {
        case add
        case edit(ProxmoxServer)
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "8006"
    @State private var username: String = "root"
    @State private var realm: String = "pam"
    @State private var password: String = ""
    @State private var allowInsecureSSL: Bool = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSave: Bool {
        !name.trimmed.isEmpty &&
        !host.trimmed.isEmpty &&
        !username.trimmed.isEmpty &&
        (1...65535).contains(Int(port) ?? 0) &&
        (isEditing || !password.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Host or IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Realm", text: $realm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(isEditing ? "New password (optional)" : "Password", text: $password)
                }

                Section {
                    Toggle("Allow self-signed certificate", isOn: $allowInsecureSSL)
                } footer: {
                    Text("Proxmox ships a self-signed certificate by default. Leave on for typical home setups.")
                }
            }
            .navigationTitle(isEditing ? "Edit Server" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadForEditing)
        }
    }

    private func loadForEditing() {
        guard case let .edit(server) = mode else { return }
        name = server.name
        host = server.host
        port = String(server.port)
        username = server.username
        realm = server.realm
        allowInsecureSSL = server.allowInsecureSSL
    }

    private func save() {
        var server: ProxmoxServer
        switch mode {
        case .add:
            server = ProxmoxServer(
                name: name.trimmed,
                host: host.trimmed,
                port: Int(port) ?? 8006,
                username: username.trimmed,
                realm: realm.trimmed.isEmpty ? "pam" : realm.trimmed,
                allowInsecureSSL: allowInsecureSSL
            )
            appState.addServer(server, password: password)
            let connectTarget = server
            dismiss()
            Task { await appState.connect(to: connectTarget, password: password) }

        case let .edit(existing):
            server = existing
            server.name = name.trimmed
            server.host = host.trimmed
            server.port = Int(port) ?? 8006
            server.username = username.trimmed
            server.realm = realm.trimmed.isEmpty ? "pam" : realm.trimmed
            server.allowInsecureSSL = allowInsecureSSL
            appState.updateServer(server, password: password.isEmpty ? nil : password)
            dismiss()
        }
    }
}

#Preview {
    ServerSetupView(mode: .add)
        .environmentObject(AppState())
}
