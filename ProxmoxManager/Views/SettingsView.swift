import SwiftUI

/// Shows the connected server, lets the user switch/manage saved servers,
/// and disconnect. Server add/edit is delegated to `ServerSetupView`.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var editingServer: ProxmoxServer?
    @State private var showAddServer = false
    @State private var faceIDOn: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if let connected = appState.connectedServer {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connected.name).font(.headline)
                            Text("\(connected.fullUsername)@\(connected.host):\(connected.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Auth", value: connected.authMethod.label)

                        Button("Disconnect", role: .destructive) {
                            appState.disconnect()
                        }
                    } header: {
                        Text("Connected")
                    }
                }

                Section {
                    Toggle(isOn: $faceIDOn) {
                        HStack {
                            Image(systemName: "faceid")
                                .foregroundStyle(.blue)
                            Text("Face ID Lock")
                        }
                    }
                    .disabled(!appState.canUseFaceID)
                    .onChange(of: faceIDOn) { newValue in
                        appState.faceIDEnabled = newValue
                        if newValue {
                            appState.appLocked = true
                        }
                    }
                    .onAppear {
                        faceIDOn = appState.faceIDEnabled
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if !appState.canUseFaceID {
                        Text("Face ID is not available on this device.")
                    }
                }

                Section {
                    ForEach(appState.servers) { server in
                        Button {
                            editingServer = server
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text("\(server.host):\(server.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if server.authMethod == .token {
                                        Text("Token: \(server.tokenID)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if appState.connectedServer?.id == server.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteServers)

                    Button {
                        showAddServer = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                } header: {
                    Text("Saved Servers")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } footer: {
                    Text("Proxmox Manager · Manage Proxmox VE from iOS.")
                }

                Section {
                    Link(destination: URL(string: "https://github.com/AsZer0s/proxmox-ios")!) {
                        Label("Website & Support", systemImage: "globe")
                    }
                } footer: {
                    Text("Visit the GitHub repository for documentation, issues, and privacy information.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { EditButton() }
            .sheet(isPresented: $showAddServer) {
                ServerSetupView(mode: .add)
            }
            .sheet(item: $editingServer) { server in
                ServerSetupView(mode: .edit(server))
            }
            .alert("Delete Server", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let server = serverToDelete {
                        appState.removeServer(server)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the server configuration and all stored credentials. This action cannot be undone.")
            }
        }
    }

    @State private var showingDeleteConfirmation = false
    @State private var serverToDelete: ProxmoxServer?

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func deleteServers(at offsets: IndexSet) {
        for index in offsets {
            let server = appState.servers[index]
            serverToDelete = server
            showingDeleteConfirmation = true
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
