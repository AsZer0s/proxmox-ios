import AppIntents

struct OpenProxmoxDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Proxmox Dashboard"
    static var description = IntentDescription("Open the cluster dashboard and refresh visible data.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

struct OpenProxmoxAlertsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Proxmox Alerts"
    static var description = IntentDescription("Open Proxmox Manager to review cluster alerts.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

struct ProxmoxAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenProxmoxDashboardIntent(), phrases: ["Open \(.applicationName)", "Show \(.applicationName) dashboard"], shortTitle: "Proxmox Dashboard", systemImageName: "server.rack")
        AppShortcut(intent: OpenProxmoxAlertsIntent(), phrases: ["Show \(.applicationName) alerts"], shortTitle: "Proxmox Alerts", systemImageName: "bell.badge")
    }
}
