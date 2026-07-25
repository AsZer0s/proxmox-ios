import SwiftUI

/// Shows the connected server, lets the user switch/manage saved servers, and
/// disconnect. Server add/edit is delegated to `ServerSetupView`.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var editingServer: ProxmoxServer?
    @State private var showAddServer = false

    var body: some View {
        NavigationStack {
            List {
                if let connected = appState.connectedServer {
                    Section("Connected") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connected.name).font(.headline)
                            Text("\(connected.fullUsername)@\(connected.host):\(connected.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Disconnect", role: .destructive) {
                            appState.disconnect()
                        }
                    }
                }

                Section("Saved Servers") {
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
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } footer: {
                    Text("Proxmox Manager · Manage Proxmox VE from iOS.")
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
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func deleteServers(at offsets: IndexSet) {
        for index in offsets {
            appState.removeServer(appState.servers[index])
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
