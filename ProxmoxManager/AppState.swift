import Foundation
import SwiftUI
import LocalAuthentication

/// App-wide state: the list of configured servers, the currently connected
/// server + its authenticated service, and the connection lifecycle.
///
/// Views observe this object and drive it through `connect`, `disconnect`,
/// `addServer`, and `removeServer`. Network reads live on the per-screen view
/// models; this object owns identity, persistence, and the shared service
/// handle.
struct CertificateConfirmation: Identifiable {
    let id = UUID()
    let server: ProxmoxServer
    let fingerprint: String
}

struct TFAChallengeState: Identifiable {
    let id = UUID()
    let serverID: UUID
    let challenge: ProxmoxTFAChallenge
}

@MainActor
final class AppState: ObservableObject {
    @Published var servers: [ProxmoxServer]
    @Published private(set) var connectedServer: ProxmoxServer?
    @Published private(set) var service: ProxmoxAPIService?
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published var lastError: String?
    @Published var pendingCertificateConfirmation: CertificateConfirmation?
    @Published var pendingTFAChallenge: TFAChallengeState?
    @Published var permissions: ProxmoxPermissions?
    @Published var appLocked = true
    let taskCenter = ProxmoxTaskCenter()
    private var authenticationObserver: NSObjectProtocol?

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    var isConnected: Bool { connectionState == .connected }

    /// App lock / Face ID preference stored in UserDefaults.
    var faceIDEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "faceIDEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "faceIDEnabled") }
    }

    /// Whether Face ID is available on this device.
    var canUseFaceID: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    init() {
        self.servers = ServerStore.load()
        authenticationObserver = NotificationCenter.default.addObserver(
            forName: .proxmoxAuthenticationExpired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let serverID = notification.object as? UUID,
                  self?.connectedServer?.id == serverID else { return }
            self?.disconnect()
            self?.lastError = ProxmoxError.notAuthenticated.localizedDescription
        }
        // Auto-lock if Face ID is enabled
        if UserDefaults.standard.bool(forKey: "faceIDEnabled") {
            appLocked = true
        } else {
            appLocked = false
        }
    }

    deinit {
        if let authenticationObserver {
            NotificationCenter.default.removeObserver(authenticationObserver)
        }
    }

    /// Authenticate via Face ID / Touch ID to unlock the app.
    func authenticateWithBiometrics() async -> Bool {
        let context = LAContext()
        do {
            let reason = NSLocalizedString("Unlock Proxmox Manager to access your servers", comment: "Face ID prompt")
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            appLocked = false
            return true
        } catch {
            return false
        }
    }

    /// Check if the current user has a specific PVE privilege on a path.
    func hasPrivilege(_ privilege: String, for vmid: Int? = nil) -> Bool {
        guard let permissions else { return false }
        let vmPath = vmid.map { "/vms/\($0)" } ?? ""
        if !vmPath.isEmpty, permissions.hasPrivilege(privilege, on: vmPath) { return true }
        return permissions.hasPrivilege(privilege, on: "")
    }

    // MARK: - Server management

    func addServer(_ server: ProxmoxServer, secret: String) {
        servers.append(server)
        if !KeychainHelper.saveSecret(secret, authMethod: server.authMethod, for: server.id) {
            lastError = "Could not securely save the server credentials."
        }
        ServerStore.save(servers)
    }

    func updateServer(_ server: ProxmoxServer, secret: String?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        if let secret = secret, !KeychainHelper.saveSecret(secret, authMethod: server.authMethod, for: server.id) {
            lastError = "Could not securely save the server credentials."
        }
        ServerStore.save(servers)
    }

    func removeServer(_ server: ProxmoxServer) {
        servers.removeAll { $0.id == server.id }
        KeychainHelper.deleteCredentials(for: server.id)
        ServerStore.save(servers)
        if connectedServer?.id == server.id {
            disconnect()
        }
    }

    // MARK: - Connection lifecycle

    /// Connects to a server using its stored credentials (password or token secret).
    func connect(to server: ProxmoxServer) async {
        let secret = KeychainHelper.secret(authMethod: server.authMethod, for: server.id)
        guard let secret else {
            lastError = "No saved credentials for \(server.name). Edit the server to re-enter them."
            return
        }
        await connect(to: server, secret: secret)
    }

    /// Connects with explicit credentials.
    func connect(to server: ProxmoxServer, secret: String) async {
        connectionState = .connecting
        lastError = nil
        pendingTFAChallenge = nil

        let service = ProxmoxAPIService(server: server, tokenValue: server.authMethod == .token ? secret : nil)
        do {
            if server.authMethod == .ticket {
                try await service.authenticate(password: secret)
            }
            self.service = service
            self.connectedServer = server
            self.connectionState = .connected
            // Load permissions after successful connection
            if let permissions = try? await service.fetchPermissions() {
                self.permissions = permissions
            }
        } catch let error as ProxmoxError {
            self.connectionState = .disconnected
            switch error {
            case .certificateConfirmationRequired(_, let fingerprint):
                self.pendingCertificateConfirmation = CertificateConfirmation(
                    server: server,
                    fingerprint: fingerprint
                )
                self.lastError = nil
            case .tfaRequired:
                // Re-init service and authenticate with TOTP
                let newService = ProxmoxAPIService(server: server)
                try? await newService.authenticate(password: secret)
                // The challenge is captured in the service actor
                self.service = newService
                self.connectedServer = server
                self.pendingTFAChallenge = TFAChallengeState(
                    serverID: server.id,
                    challenge: ProxmoxTFAChallenge(tfa: "", tfaChallenge: "", username: server.fullUsername)
                )
            default:
                self.lastError = error.localizedDescription
            }
        } catch {
            self.connectionState = .disconnected
            self.lastError = error.localizedDescription
        }
    }

    /// Complete a TOTP challenge during login.
    func submitTOTP(code: String) async {
        guard let service = service, let challenge = pendingTFAChallenge else { return }
        pendingTFAChallenge = nil
        do {
            try await service.authenticateTOTP(code: code)
            self.connectionState = .connected
        } catch {
            self.lastError = error.localizedDescription
            self.connectionState = .disconnected
            self.service = nil
            self.connectedServer = nil
        }
    }

    /// Refresh permissions for the current server.
    func refreshPermissions() async {
        guard let service else { return }
        permissions = try? await service.fetchPermissions()
    }

    func trustPendingCertificate() async {
        guard let confirmation = pendingCertificateConfirmation else { return }
        guard KeychainHelper.saveCertificateFingerprint(
            confirmation.fingerprint,
            for: confirmation.server.id
        ) else {
            pendingCertificateConfirmation = nil
            lastError = "Could not securely save the certificate fingerprint."
            return
        }
        pendingCertificateConfirmation = nil
        await connect(to: confirmation.server)
    }

    func disconnect() {
        Task { await service?.logout() }
        service = nil
        connectedServer = nil
        connectionState = .disconnected
        permissions = nil
    }
}
