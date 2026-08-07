import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let didRegisterForRemoteNotifications = Notification.Name("didRegisterForRemoteNotifications")
    static let didFailToRegisterForRemoteNotifications = Notification.Name("didFailToRegisterForRemoteNotifications")
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationCenter.default.post(name: .didRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCenter.default.post(name: .didFailToRegisterForRemoteNotifications, object: error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        UserDefaults.standard.set(Date(), forKey: "push.lastReceivedAt")
        completionHandler(.newData)
    }
}

struct AlertRule: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case nodeOffline, cpu, memory, storage, backupFailure
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nodeOffline: return String(localized: "Node Offline")
            case .cpu: return String(localized: "High CPU Usage")
            case .memory: return String(localized: "High Memory Usage")
            case .storage: return String(localized: "Storage Nearly Full")
            case .backupFailure: return String(localized: "Backup Failed")
            }
        }
    }

    var id: UUID
    var kind: Kind
    var enabled: Bool
    var threshold: Double?
    var serverIDs: [UUID]
    var resourcePattern: String
    var cooldownMinutes: Int

    static let defaults: [AlertRule] = [
        AlertRule(id: UUID(), kind: .nodeOffline, enabled: true, threshold: nil, serverIDs: [], resourcePattern: "*", cooldownMinutes: 10),
        AlertRule(id: UUID(), kind: .cpu, enabled: true, threshold: 0.90, serverIDs: [], resourcePattern: "*", cooldownMinutes: 15),
        AlertRule(id: UUID(), kind: .memory, enabled: true, threshold: 0.90, serverIDs: [], resourcePattern: "*", cooldownMinutes: 15),
        AlertRule(id: UUID(), kind: .storage, enabled: true, threshold: 0.85, serverIDs: [], resourcePattern: "*", cooldownMinutes: 30),
        AlertRule(id: UUID(), kind: .backupFailure, enabled: true, threshold: nil, serverIDs: [], resourcePattern: "*", cooldownMinutes: 5),
    ]
}

@MainActor
final class RemoteNotificationManager: ObservableObject {
    @Published private(set) var deviceToken = ""
    @Published private(set) var registrationState = String(localized: "Not Registered")
    @Published private(set) var lastError: String?
    @Published var rules: [AlertRule] { didSet { persistRules() } }

    static func deviceEndpointPath(for deviceToken: String) -> String {
        "/v1/devices/\(deviceToken)"
    }

    static func authorizationHeader(for enrollmentToken: String) -> String {
        "Bearer \(enrollmentToken)"
    }

    var relayURL: String {
        get { UserDefaults.standard.string(forKey: "push.relayURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmed, forKey: "push.relayURL") }
    }

    var enrollmentToken: String {
        get { KeychainHelper.genericSecret(account: "push-relay-enrollment") ?? "" }
        set { _ = KeychainHelper.saveGenericSecret(newValue, account: "push-relay-enrollment") }
    }

    private var observers: [NSObjectProtocol] = []

    init() {
        deviceToken = UserDefaults.standard.string(forKey: "push.deviceToken") ?? ""
        if let data = UserDefaults.standard.data(forKey: "alerts.rules"),
           let saved = try? JSONDecoder().decode([AlertRule].self, from: data) {
            rules = saved
        } else {
            rules = AlertRule.defaults
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .didRegisterForRemoteNotifications,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.object as? Data else { return }
            Task { @MainActor in await self?.receivedDeviceToken(data) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .didFailToRegisterForRemoteNotifications,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.lastError = (notification.object as? Error)?.localizedDescription
                self?.registrationState = String(localized: "Registration Failed")
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func requestRegistration(servers: [ProxmoxServer]) async {
        lastError = nil
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else {
                registrationState = String(localized: "Notifications Disabled")
                return
            }
            registrationState = String(localized: "Waiting for Device Token")
            UIApplication.shared.registerForRemoteNotifications()
            if !deviceToken.isEmpty { try await enroll(servers: servers) }
        } catch {
            lastError = error.localizedDescription
            registrationState = String(localized: "Registration Failed")
        }
    }

    func unregister() async {
        guard !deviceToken.isEmpty,
              let url = endpoint(Self.deviceEndpointPath(for: deviceToken)) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        authorize(&request)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = ""
        UserDefaults.standard.removeObject(forKey: "push.deviceToken")
        registrationState = String(localized: "Not Registered")
    }

    private func receivedDeviceToken(_ data: Data) async {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(deviceToken, forKey: "push.deviceToken")
        registrationState = String(localized: "Device Registered")
        do { try await enroll(servers: ServerStore.load()) }
        catch { lastError = error.localizedDescription; registrationState = String(localized: "Relay Sync Failed") }
    }

    func sync(servers: [ProxmoxServer]) async {
        guard !deviceToken.isEmpty else {
            await requestRegistration(servers: servers)
            return
        }
        do { try await enroll(servers: servers) }
        catch {
            lastError = error.localizedDescription
            registrationState = String(localized: "Relay Sync Failed")
        }
    }

    private func enroll(servers: [ProxmoxServer]) async throws {
        guard let url = endpoint("/v1/devices") else { throw URLError(.badURL) }
        let payload = EnrollmentPayload(
            deviceToken: deviceToken,
            environment: _isDebugAssertConfiguration() ? "sandbox" : "production",
            clusterIDs: servers.map { $0.id.uuidString },
            rules: rules
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? String(localized: "Relay rejected registration")
            throw NSError(domain: "AlertRelay", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        registrationState = String(localized: "Background Alerts Active")
    }

    private func endpoint(_ path: String) -> URL? {
        guard var components = URLComponents(string: relayURL),
              components.scheme?.lowercased() == "https",
              components.host != nil else { return nil }
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [base, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue(Self.authorizationHeader(for: enrollmentToken), forHTTPHeaderField: "Authorization")
    }

    private func persistRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "alerts.rules")
        }
    }

    private struct EnrollmentPayload: Encodable {
        let deviceToken: String
        let environment: String
        let clusterIDs: [String]
        let rules: [AlertRule]
    }
}
