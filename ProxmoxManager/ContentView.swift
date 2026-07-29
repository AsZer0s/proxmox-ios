import SwiftUI

/// Root view. Routes between the server list (when nothing is connected) and
/// the main dashboard (once a server connection is established).
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isConnected {
                MainDashboardView()
            } else {
                ServerListView()
            }
        }
        .animation(.default, value: appState.isConnected)
    }
}

/// Lists configured servers and lets the user connect, add, edit, or remove
/// them. Shown whenever no server is connected.
struct ServerListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingAddServer = false
    @State private var editingServer: ProxmoxServer?

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
                                appState.removeServer(server)
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
            ProgressView("Connecting…")
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
