import SwiftUI

/// Root tab container shown once a server is connected. Hosts Nodes, VMs,
/// Tasks, and Settings tabs and reflects the connected server in the nav.
struct MainDashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedDashboardTab) {
            CustomDashboardView(dashboard: appState.dashboard)
                .tabItem {
                    Label("Overview", systemImage: "rectangle.3.group")
                }
                .tag(DashboardTab.overview)

            VMListView()
                .tabItem {
                    Label("VMs & CTs", systemImage: "square.stack.3d.up")
                }
                .tag(DashboardTab.guests)

            TaskCenterView()
                .environmentObject(appState.taskCenter)
                .environmentObject(appState)
                .tabItem {
                    Label("Tasks", systemImage: "checkmark.circle")
                }
                .tag(DashboardTab.tasks)

            OperationsView()
                .environmentObject(appState.alertCenter)
                .tabItem {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
                .tag(DashboardTab.manage)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(DashboardTab.settings)
        }
    }
}

#Preview {
    MainDashboardView()
        .environmentObject(AppState())
}
