import SwiftUI

/// Root view. Routes between the server list (when nothing is connected) and
/// the main dashboard (once a server connection is established).
/// Shows the Face ID lock screen when enabled.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var privacyCoverVisible = false

    var body: some View {
        ZStack {
            Group {
                if appState.appLocked {
                    AppLockView()
                } else if appState.isConnected {
                    MainDashboardView()
                } else {
                    ServerListView()
                }
            }

            if privacyCoverVisible {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                    .overlay {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .animation(.default, value: appState.isConnected)
        .animation(.default, value: appState.appLocked)
        .onOpenURL { appState.handleDeepLink($0) }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                privacyCoverVisible = false
            case .inactive:
                privacyCoverVisible = appState.faceIDEnabled
            case .background:
                privacyCoverVisible = appState.faceIDEnabled
                if appState.faceIDEnabled {
                    appState.appLocked = true
                }
            @unknown default:
                privacyCoverVisible = appState.faceIDEnabled
            }
        }
    }
}

/// Lists configured servers and lets the user connect, add, edit, or remove
/// them. Shown whenever no server is connected.
struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingAddServer = false
    @State private var showingAllClusters = false
    @State private var editingServer: ProxmoxServer?
    @State private var serverToDelete: ProxmoxServer?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if appState.servers.isEmpty {
                    emptyState
                } else {
                    ForEach(appState.servers) { server in
                        Button {
                            Task { await appState.connect(to: server) }
                        } label: {
                            ServerRow(server: server)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                serverToDelete = server
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingServer = server
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showingAllClusters = true } label: { Image(systemName: "square.grid.2x2") }
                        .disabled(appState.servers.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if appState.connectionState == .connecting {
                    connectingOverlay
                }
            }
            .sheet(isPresented: $showingAddServer) {
                ServerSetupView(mode: .add)
            }
            .sheet(isPresented: $showingAllClusters) {
                NavigationStack { MultiClusterOverviewView() }
            }
            .sheet(item: $editingServer) { server in
                ServerSetupView(mode: .edit(server))
            }
            .alert("Connection Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.lastError ?? "")
            }
            .alert("Remove Server?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let server = serverToDelete {
                        appState.removeServer(server)
                    }
                    serverToDelete = nil
                }
                Button("Cancel", role: .cancel) { serverToDelete = nil }
            } message: {
                Text("This will remove the server and all stored credentials. This action cannot be undone.")
            }
            .sheet(item: $appState.pendingTFAChallenge) { challenge in
                TFAChallengeView(challenge: challenge)
            }
            .alert(item: $appState.pendingCertificateConfirmation) { confirmation in
                Alert(
                    title: Text("Trust Self-Signed Certificate?"),
                    message: Text("Only trust this certificate if you verified it on the server.\n\nSHA-256:\n\(confirmation.fingerprint)"),
                    primaryButton: .default(Text("Trust")) {
                        Task { await appState.trustPendingCertificate() }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Servers")
                .font(.headline)
            Text("Tap + to add a Proxmox server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView("Connecting…")
                Text("Authenticating and fetching server info…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appState.lastError != nil && appState.connectionState == .disconnected },
            set: { if !$0 { appState.lastError = nil } }
        )
    }
}

private struct TFAChallengeView: View {
    @EnvironmentObject private var appState: AppState
    let challenge: TFAChallengeState
    @State private var method: TFAMethod = .totp
    @State private var response = ""
    @State private var working = false
    @State private var error: String?

    private var methods: [TFAMethod] { challenge.info?.availableMethods ?? [.totp] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Authentication Method", selection: $method) {
                        ForEach(methods) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    if method == .webauthn {
                        Button {
                            Task { await useWebAuthn() }
                        } label: {
                            Label("Use Passkey / WebAuthn", systemImage: "person.badge.key.fill")
                        }
                    } else {
                        SecureField(prompt, text: $response)
                            .keyboardType(method == .totp ? .numberPad : .default)
                        if method == .recovery, let ids = challenge.info?.recovery {
                            Text("Available recovery code IDs: \(ids.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if method == .yubico {
                            Text("Touch the hardware key, then paste or type its one-time password.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Two-Factor Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { appState.cancelPendingTFA() } }
                if method != .webauthn {
                    ToolbarItem(placement: .confirmationAction) { Button("Submit") { Task { await submit() } }.disabled(response.trimmed.isEmpty || working) }
                }
            }
            .overlay { if working { ProgressView() } }
            .onAppear { method = methods.first ?? .totp }
        }
        .interactiveDismissDisabled()
    }

    private var prompt: String {
        switch method {
        case .totp: return String(localized: "TOTP Code")
        case .yubico: return String(localized: "Hardware Key OTP")
        case .recovery: return String(localized: "Recovery Code")
        case .webauthn: return ""
        }
    }

    @MainActor private func submit() async {
        working = true; defer { working = false }
        await appState.submitSecondFactor(method: method, response: response)
    }

    @MainActor private func useWebAuthn() async {
        guard let webauthn = challenge.info?.webauthn else { return }
        working = true; error = nil; defer { working = false }
        do {
            let assertion = try await WebAuthnSession.authenticate(webauthn, fallbackRPID: appState.connectedServer?.host ?? "")
            await appState.submitSecondFactor(method: .webauthn, response: assertion)
        } catch { self.error = error.localizedDescription }
    }
}

private struct ServerRow: View {
    let server: ProxmoxServer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)
                Text("\(server.host):\(server.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(server.authMethod.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(server.realm)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
