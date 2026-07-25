import SwiftUI

/// Root tab container shown once a server is connected. Hosts Nodes, VMs, and
/// Settings tabs and reflects the connected server in the nav.
struct MainDashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            NodesView()
                .tabItem {
                    Label("Nodes", systemImage: "server.rack")
                }

            VMListView()
                .tabItem {
                    Label("VMs & CTs", systemImage: "square.stack.3d.up")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    MainDashboardView()
        .environmentObject(AppState())
}
