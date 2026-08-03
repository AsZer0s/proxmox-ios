import SwiftUI

struct CustomDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var dashboard: DashboardCenter
    @State private var resources: [ClusterResource] = []
    @State private var customizing = false
    @State private var error: String?

    init(dashboard: DashboardCenter) { self.dashboard = dashboard }

    var body: some View {
        NavigationStack {
            List {
                ForEach(dashboard.sections.filter { !dashboard.hiddenSections.contains($0) }) { section in
                    content(section)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(appState.connectedServer?.name ?? String(localized: "Dashboard"))
            .toolbar {
                Button { customizing = true } label: { Image(systemName: "rectangle.3.group") }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $customizing) { DashboardCustomizationView(center: dashboard) }
        }
    }

    @ViewBuilder private func content(_ section: DashboardSection) -> some View {
        switch section {
        case .summary:
            Section("Cluster Summary") {
                HStack {
                    summaryItem("Nodes", resources.filter { $0.type == .node }.count, "server.rack")
                    summaryItem("Running", guests.filter(\.isRunning).count, "play.circle.fill")
                    summaryItem("Stopped", guests.filter { !$0.isRunning }.count, "stop.circle")
                }
                if let cpu = resources.filter({ $0.type == .node }).compactMap(\.cpu).average {
                    LabeledContent("Average CPU", value: cpu.formatted(.percent.precision(.fractionLength(2))))
                }
            }
        case .favorites:
            Section("Favorites") {
                let values = dashboard.favorites.filter { $0.serverID == appState.connectedServer?.id }
                if values.isEmpty { Text("Long-press a VM or CT to add it here.").foregroundStyle(.secondary) }
                ForEach(values) { favorite in
                    HStack {
                        Image(systemName: favorite.type == .qemu ? "desktopcomputer" : "shippingbox")
                        VStack(alignment: .leading) { Text(favorite.name); Text("\(favorite.vmid) · \(favorite.node)").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); StatusBadge(status: favorite.status)
                    }
                }
            }
        case .alerts:
            Section("Active Alerts") {
                let alerts = appState.alertCenter.alerts.filter { !$0.acknowledged }.prefix(5)
                if alerts.isEmpty { Label("No active alerts", systemImage: "checkmark.shield").foregroundStyle(.green) }
                ForEach(Array(alerts)) { alert in VStack(alignment:.leading){Text(alert.title);Text(alert.message).font(.caption).foregroundStyle(.secondary)} }
            }
        case .tasks:
            Section("Recent Tasks") {
                ForEach(Array(appState.taskCenter.tasks.prefix(5))) { task in
                    HStack { VStack(alignment:.leading){Text(task.title);Text(task.object).font(.caption).foregroundStyle(.secondary)};Spacer();Text(task.state.label).font(.caption) }
                }
            }
        case .quickActions:
            Section("Quick Actions") {
                NavigationLink { NodesView() } label: { Label("Browse Nodes", systemImage: "server.rack") }
                NavigationLink { VMListView() } label: { Label("Browse VMs & CTs", systemImage: "square.stack.3d.up") }
                NavigationLink { AlertsView().environmentObject(appState.alertCenter) } label: { Label("Alerts", systemImage: "bell.badge") }
            }
        }
    }

    private var guests: [ClusterResource] { resources.filter { $0.type == .qemu || $0.type == .lxc } }
    private func summaryItem(_ title: LocalizedStringKey, _ value: Int, _ icon: String) -> some View { VStack(spacing:5){Image(systemName:icon).foregroundStyle(.blue);Text("\(value)").font(.title2.bold());Text(title).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity) }
    @MainActor private func load() async { do { resources = try await appState.service?.fetchClusterResources() ?? []; if let id=appState.connectedServer?.id{dashboard.update(resources:resources,serverID:id)} } catch { self.error=error.localizedDescription } }
}

private struct DashboardCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var center: DashboardCenter
    var body: some View {
        NavigationStack {
            List {
                ForEach(center.sections) { section in
                    Toggle(section.label, isOn: Binding(get:{!center.hiddenSections.contains(section)},set:{visible in if visible{center.hiddenSections.remove(section)}else{center.hiddenSections.insert(section)}}))
                }.onMove { center.sections.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationTitle("Customize Dashboard")
            .toolbar { ToolbarItem(placement:.confirmationAction){Button("Done"){dismiss()}};ToolbarItem(placement:.navigationBarLeading){EditButton()} }
        }
    }
}

private extension Array where Element == Double { var average: Double? { isEmpty ? nil : reduce(0,+)/Double(count) } }
