import SwiftUI

/// Root view. Routes between the server list (when nothing is connected) and
/// the main dashboard (once a server connection is established).
/// Shows the Face ID lock screen when enabled.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.appLocked {
                AppLockView()
            } else if appState.isConnected {
                MainDashboardView()
            } else {
                ServerListView()
            }
        }
        .animation(.default, value: appState.isConnected)
        .animation(.default, value: appState.appLocked)
    }
}

/// Lists configured servers and lets the user connect, add, edit, or remove
/// them. Shown whenever no server is connected.
struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingAddServer = false
    @State private var editingServer: ProxmoxServer?
    @State private var serverToDelete: ProxmoxServer?
    @State private var showingDeleteConfirmation = false
    @State private var totpCode = ""
    @State private var showingTOTP = false

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
            .alert("TOTP Code Required", isPresented: $showingTOTP) {
                TextField("Code", text: $totpCode)
                    .keyboardType(.numberPad)
                Button("Submit") {
                    let code = totpCode
                    totpCode = ""
                    Task { await appState.submitTOTP(code: code) }
                }
                Button("Cancel", role: .cancel) {
                    totpCode = ""
                    appState.pendingTFAChallenge = nil
                }
            } message: {
                Text("Enter your two-factor authentication code.")
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
            .onChange(of: appState.pendingTFAChallenge?.id) { _, _ in
                if appState.pendingTFAChallenge != nil {
                    showingTOTP = true
                }
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
