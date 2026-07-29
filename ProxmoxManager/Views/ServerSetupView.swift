import SwiftUI

/// Add or edit a Proxmox server. On save it persists the server and,
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
    @State private var authMethod: AuthMethod = .ticket
    @State private var tokenID: String = ""
    @State private var tokenSecret: String = ""
    @State private var isTesting = false
    @State private var testResult: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSave: Bool {
        guard !name.trimmed.isEmpty,
              !host.trimmed.isEmpty,
              !username.trimmed.isEmpty,
              (1...65535).contains(Int(port) ?? 0) else { return false }
        if authMethod == .ticket {
            return isEditing || !password.isEmpty
        } else {
            return !tokenID.trimmed.isEmpty && !tokenSecret.isEmpty
        }
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

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }

                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Realm", text: $realm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if authMethod == .ticket {
                        SecureField(isEditing ? "New password (optional)" : "Password", text: $password)
                    } else {
                        TextField("Token ID (e.g. root@pam!mytoken)", text: $tokenID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Token Secret", text: $tokenSecret)
                    }
                }

                Section {
                    Toggle("Allow self-signed certificate", isOn: $allowInsecureSSL)
                } footer: {
                    if allowInsecureSSL {
                        Text("The app will verify the certificate fingerprint on first connection and reject changes afterwards.")
                    } else {
                        Text("Requires a CA-signed certificate on your Proxmox server.")
                    }
                }

                if !isEditing {
                    Section {
                        Button(action: testConnection) {
                            HStack {
                                if isTesting {
                                    ProgressView()
                                }
                                Text(isTesting ? "Testing…" : "Test Connection")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isTesting || !canSave)

                        if let result = testResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                        }
                    }
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
        authMethod = server.authMethod
        tokenID = server.tokenID
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let server = buildServer()
        Task {
            do {
                let service = ProxmoxAPIService(server: server, tokenValue: tokenSecret)
                if authMethod == .ticket {
                    try await service.authenticate(password: password)
                }
                let _ = try await service.fetchNodes()
                await MainActor.run {
                    testResult = "✓ Connected successfully"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    private func buildServer() -> ProxmoxServer {
        switch mode {
        case .add:
            return ProxmoxServer(
                name: name.trimmed,
                host: host.trimmed,
                port: Int(port) ?? 8006,
                username: username.trimmed,
                realm: realm.trimmed.isEmpty ? "pam" : realm.trimmed,
                allowInsecureSSL: allowInsecureSSL,
                authMethod: authMethod,
                tokenID: tokenID.trimmed
            )
        case let .edit(existing):
            var server = existing
            server.name = name.trimmed
            server.host = host.trimmed
            server.port = Int(port) ?? 8006
            server.username = username.trimmed
            server.realm = realm.trimmed.isEmpty ? "pam" : realm.trimmed
            server.allowInsecureSSL = allowInsecureSSL
            server.authMethod = authMethod
            server.tokenID = tokenID.trimmed
            return server
        }
    }

    private func save() {
        let server = buildServer()

        switch mode {
        case .add:
            let secret = authMethod == .token ? tokenSecret : password
            appState.addServer(server, secret: secret)
            let connectTarget = server
            dismiss()
            Task { await appState.connect(to: connectTarget, secret: secret) }

        case .edit:
            let secret: String?
            if authMethod == .token {
                secret = tokenSecret.isEmpty ? nil : tokenSecret
            } else {
                secret = password.isEmpty ? nil : password
            }
            appState.updateServer(server, secret: secret)
            dismiss()
        }
    }
}

#Preview {
    ServerSetupView(mode: .add)
        .environmentObject(AppState())
}
