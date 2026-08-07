import Foundation
import LocalAuthentication
import UserNotifications

extension Notification.Name {
    static let proxmoxMutationCompleted = Notification.Name("proxmoxMutationCompleted")
}

struct OperationAuditEntry: Identifiable, Codable, Hashable {
    enum Result: String, Codable { case succeeded, failed, scheduled }
    let id: UUID
    let serverID: UUID
    let timestamp: Date
    let method: String
    let path: String
    let changes: [String: String]
    let result: Result
    let detail: String?
}

struct ScheduledOperation: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case start, shutdown, reboot, stop
        var id: String { rawValue }
        var label: String { String(localized: String.LocalizationValue(rawValue.capitalized)) }
    }
    var id = UUID()
    var serverID: UUID
    var executeAt: Date
    var kind: Kind
    var node: String
    var guestType: GuestType
    var vmid: Int
    var retryCount: Int
    var maximumRetries: Int
    var completed: Bool
    var lastError: String? = nil
}

@MainActor
final class OperationSafetyCenter: ObservableObject {
    @Published private(set) var audits: [OperationAuditEntry] = []
    @Published var scheduled: [ScheduledOperation] = [] { didSet { persistScheduled() } }
    @Published var maintenanceWindowEnabled = false
    @Published var maintenanceStartHour = 1
    @Published var maintenanceEndHour = 5

    private var service: ProxmoxAPIService?
    private var serverID: UUID?
    private var timer: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init() {
        audits = Self.load("operations.audit", fallback: [])
        scheduled = Self.load("operations.scheduled", fallback: [])
        maintenanceWindowEnabled = UserDefaults.standard.bool(forKey: "operations.window.enabled")
        maintenanceStartHour = UserDefaults.standard.object(forKey: "operations.window.start") as? Int ?? 1
        maintenanceEndHour = UserDefaults.standard.object(forKey: "operations.window.end") as? Int ?? 5
        observer = NotificationCenter.default.addObserver(forName: .proxmoxMutationCompleted, object: nil, queue: .main) { [weak self] notification in
            guard let payload = notification.userInfo,
                  let id = payload["serverID"] as? UUID,
                  let method = payload["method"] as? String,
                  let path = payload["path"] as? String else { return }
            Task { @MainActor in self?.record(serverID: id, method: method, path: path, changes: payload["changes"] as? [String:String] ?? [:], result: .succeeded) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func activate(serverID: UUID, service: ProxmoxAPIService) {
        self.serverID = serverID; self.service = service
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.runDueOperations()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func deactivate() { timer?.cancel(); timer=nil; service=nil; serverID=nil }

    func schedule(_ operation: ScheduledOperation) {
        scheduled.append(operation)
        record(serverID: operation.serverID, method: "SCHEDULE", path: "/nodes/\(operation.node)/\(operation.guestType.apiPath)/\(operation.vmid)/status/\(operation.kind.rawValue)", changes: ["executeAt": operation.executeAt.ISO8601Format()], result: .scheduled)
        scheduleReminder(for: operation)
    }

    func removeScheduled(at offsets: IndexSet) {
        let identifiers = offsets.map { reminderIdentifier(for: scheduled[$0]) }
        scheduled.remove(atOffsets: offsets)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func retry(_ entry: OperationAuditEntry) async throws {
        guard let service, entry.serverID == serverID else { throw ProxmoxError.notAuthenticated }
        let parts = entry.path.split(separator: "/").map(String.init)
        guard parts.count >= 6, parts[0] == "nodes", let vmid = Int(parts[3]), let type = GuestType(rawValue: parts[2]), let action = GuestAction(rawValue: parts[5]) else {
            throw ProxmoxError.taskFailed(String(localized: "This operation cannot be retried automatically."))
        }
        _ = try await service.performAction(action, node: parts[1], type: type, vmid: vmid)
    }

    func saveMaintenanceWindow() {
        UserDefaults.standard.set(maintenanceWindowEnabled, forKey: "operations.window.enabled")
        UserDefaults.standard.set(maintenanceStartHour, forKey: "operations.window.start")
        UserDefaults.standard.set(maintenanceEndHour, forKey: "operations.window.end")
    }

    func clearAudit() { audits=[]; persistAudits() }

    func authorizeCriticalAction(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    private func runDueOperations() async {
        guard let service, let serverID else { return }
        let now = Date()
        guard isInsideMaintenanceWindow(now) else { return }
        for index in scheduled.indices where !scheduled[index].completed && scheduled[index].serverID == serverID && scheduled[index].executeAt <= now {
            let operation = scheduled[index]
            do {
                let action = GuestAction(rawValue: operation.kind.rawValue) ?? .shutdown
                _ = try await service.performAction(action, node: operation.node, type: operation.guestType, vmid: operation.vmid)
                scheduled[index].completed = true
                scheduled[index].lastError = nil
                removeReminder(for: operation)
            } catch {
                scheduled[index].retryCount += 1
                scheduled[index].lastError = error.localizedDescription
                if scheduled[index].retryCount > scheduled[index].maximumRetries {
                    scheduled[index].completed = true
                    removeReminder(for: operation)
                }
            }
        }
    }

    private func isInsideMaintenanceWindow(_ date: Date) -> Bool {
        guard maintenanceWindowEnabled else { return true }
        let hour = Calendar.current.component(.hour, from: date)
        if maintenanceStartHour <= maintenanceEndHour { return hour >= maintenanceStartHour && hour < maintenanceEndHour }
        return hour >= maintenanceStartHour || hour < maintenanceEndHour
    }

    private func record(serverID: UUID, method: String, path: String, changes: [String:String], result: OperationAuditEntry.Result, detail: String? = nil) {
        audits.insert(OperationAuditEntry(id: UUID(), serverID: serverID, timestamp: Date(), method: method, path: path, changes: changes, result: result, detail: detail), at: 0)
        audits = Array(audits.prefix(1000)); persistAudits()
    }

    private func persistAudits() { Self.save(audits, "operations.audit") }
    private func persistScheduled() { Self.save(scheduled, "operations.scheduled") }
    private func reminderIdentifier(for operation: ScheduledOperation) -> String {
        "scheduled-operation.\(operation.id.uuidString)"
    }

    private func removeReminder(for operation: ScheduledOperation) {
        let identifier = reminderIdentifier(for: operation)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func scheduleReminder(for operation: ScheduledOperation) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true
            }
            guard authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Scheduled Proxmox Operation")
            content.body = String(localized: "Open Proxmox Manager to run \(operation.kind.label) for \(operation.guestType.rawValue.uppercased()) \(operation.vmid) on \(operation.node).")
            content.sound = .default
            let components = Calendar.current.dateComponents(
                [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
                from: operation.executeAt
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: reminderIdentifier(for: operation), content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
    private static func save<T: Encodable>(_ value: T, _ key: String) { if let data=try? JSONEncoder().encode(value){UserDefaults.standard.set(data,forKey:key)} }
    private static func load<T: Decodable>(_ key: String, fallback: T) -> T { guard let data=UserDefaults.standard.data(forKey:key),let value=try? JSONDecoder().decode(T.self,from:data) else { return fallback }; return value }
}
