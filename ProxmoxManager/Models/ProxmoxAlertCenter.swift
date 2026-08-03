import Foundation
import UserNotifications

@MainActor
final class ProxmoxAlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var alerts: [ProxmoxAlert] = []
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: String?

    private var serverID: UUID?
    private var service: ProxmoxAPIService?
    private var monitorTask: Task<Void, Never>?
    private var activeAlertKeys: Set<String> = []
    private var monitorStartedAt = Date()

    var monitoringEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "alerts.monitoringEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alerts.monitoringEnabled") }
    }

    var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "alerts.notificationsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alerts.notificationsEnabled") }
    }

    var cpuThreshold: Double {
        get { threshold(for: "alerts.cpuThreshold", fallback: 0.90) }
        set { UserDefaults.standard.set(newValue, forKey: "alerts.cpuThreshold") }
    }

    var memoryThreshold: Double {
        get { threshold(for: "alerts.memoryThreshold", fallback: 0.90) }
        set { UserDefaults.standard.set(newValue, forKey: "alerts.memoryThreshold") }
    }

    var storageThreshold: Double {
        get { threshold(for: "alerts.storageThreshold", fallback: 0.85) }
        set { UserDefaults.standard.set(newValue, forKey: "alerts.storageThreshold") }
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func activate(serverID: UUID, service: ProxmoxAPIService) async {
        monitorTask?.cancel()
        self.serverID = serverID
        self.service = service
        monitorStartedAt = Date()
        alerts = loadPersistedAlerts(serverID: serverID)
        activeAlertKeys = Set(alerts.filter { !$0.acknowledged }.map(\.source))
        guard monitoringEnabled else { return }
        await checkNow()
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.checkNow()
            }
        }
    }

    func deactivate() {
        monitorTask?.cancel()
        monitorTask = nil
        service = nil
        serverID = nil
        activeAlertKeys.removeAll()
        alerts = []
    }

    func restartMonitoring() async {
        guard let serverID, let service else { return }
        await activate(serverID: serverID, service: service)
    }

    func requestNotificationAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAuthorizationStatus()
    }

    func checkNow() async {
        guard monitoringEnabled, let serverID, let service else { return }
        lastError = nil
        do {
            let nodes = try await service.fetchNodes()
            let resources = (try? await service.fetchClusterResources()) ?? []

            var currentKeys: Set<String> = []
            for node in nodes {
                if !node.isOnline {
                    let key = "node-offline:\(node.node)"
                    currentKeys.insert(key)
                    addAlertIfNeeded(
                        key: key,
                        serverID: serverID,
                        severity: .critical,
                        title: String(localized: "Node Offline"),
                        message: String(localized: "Node \(node.node) is offline.")
                    )
                }
                if let cpu = node.cpu, cpu >= cpuThreshold {
                    let key = "node-cpu:\(node.node)"
                    currentKeys.insert(key)
                    addAlertIfNeeded(
                        key: key,
                        serverID: serverID,
                        severity: .warning,
                        title: String(localized: "High CPU Usage"),
                        message: String(localized: "Node \(node.node) CPU usage is \(cpu.formatted(.percent.precision(.fractionLength(2)))).")
                    )
                }
                if let used = node.mem, let total = node.maxmem, total > 0 {
                    let fraction = Double(used) / Double(total)
                    if fraction >= memoryThreshold {
                        let key = "node-memory:\(node.node)"
                        currentKeys.insert(key)
                        addAlertIfNeeded(
                            key: key,
                            serverID: serverID,
                            severity: .warning,
                            title: String(localized: "High Memory Usage"),
                            message: String(localized: "Node \(node.node) memory usage is \(fraction.formatted(.percent.precision(.fractionLength(2)))).")
                        )
                    }
                }
            }

            for resource in resources where resource.type == .storage {
                guard let used = resource.disk, let total = resource.maxdisk, total > 0 else { continue }
                let fraction = Double(used) / Double(total)
                if fraction >= storageThreshold {
                    let key = "storage:\(resource.id)"
                    currentKeys.insert(key)
                    addAlertIfNeeded(
                        key: key,
                        serverID: serverID,
                        severity: fraction >= 0.95 ? .critical : .warning,
                        title: String(localized: "Storage Nearly Full"),
                        message: String(localized: "Storage \(resource.displayName) usage is \(fraction.formatted(.percent.precision(.fractionLength(2)))).")
                    )
                }
            }

            for node in nodes where node.isOnline {
                let failures = (try? await service.fetchNodeTasks(
                    node: node.node,
                    source: "all",
                    limit: 50,
                    errorsOnly: true
                )) ?? []
                for task in failures where task.taskType.lowercased() == "vzdump" {
                    let eventTime = task.endTime ?? task.startTime
                    guard Date(timeIntervalSince1970: TimeInterval(eventTime)) >= monitorStartedAt.addingTimeInterval(-60) else {
                        continue
                    }
                    let key = "backup:\(task.upid)"
                    currentKeys.insert(key)
                    addAlertIfNeeded(
                        key: key,
                        serverID: serverID,
                        severity: .critical,
                        title: String(localized: "Backup Failed"),
                        message: String(localized: "Backup task for \(task.idValue.isEmpty ? node.node : task.idValue) failed: \(task.status ?? "Unknown error")")
                    )
                }
            }

            activeAlertKeys.formIntersection(currentKeys)
            lastCheckedAt = Date()
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func acknowledge(_ alert: ProxmoxAlert) {
        guard let index = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[index].acknowledged = true
        activeAlertKeys.remove(alert.source)
        persist()
    }

    func acknowledgeAll() {
        for index in alerts.indices { alerts[index].acknowledged = true }
        activeAlertKeys.removeAll()
        persist()
    }

    func clearAcknowledged() {
        alerts.removeAll(where: \.acknowledged)
        persist()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    private func addAlertIfNeeded(
        key: String,
        serverID: UUID,
        severity: ProxmoxAlertSeverity,
        title: String,
        message: String
    ) {
        guard !activeAlertKeys.contains(key) else { return }
        activeAlertKeys.insert(key)
        let alert = ProxmoxAlert(
            id: "\(key):\(Date().timeIntervalSince1970)",
            serverID: serverID,
            severity: severity,
            title: title,
            message: message,
            source: key,
            createdAt: Date(),
            acknowledged: false
        )
        alerts.insert(alert, at: 0)
        alerts = Array(alerts.prefix(200))
        if notificationsEnabled { scheduleNotification(for: alert) }
    }

    private func scheduleNotification(for alert: ProxmoxAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = .default
        content.badge = NSNumber(value: alerts.filter { !$0.acknowledged }.count)
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func threshold(for key: String, fallback: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.double(forKey: key)
    }

    private func persistenceKey(_ serverID: UUID) -> String {
        "ProxmoxAlerts.\(serverID.uuidString)"
    }

    private func loadPersistedAlerts(serverID: UUID) -> [ProxmoxAlert] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey(serverID)),
              let values = try? JSONDecoder().decode([ProxmoxAlert].self, from: data) else {
            return []
        }
        return values
    }

    private func persist() {
        guard let serverID, let data = try? JSONEncoder().encode(alerts) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey(serverID))
    }
}
