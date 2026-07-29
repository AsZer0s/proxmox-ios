import Foundation
import SwiftUI

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

@MainActor
final class AppState: ObservableObject {
    @Published var servers: [ProxmoxServer]
    @Published private(set) var connectedServer: ProxmoxServer?
    @Published private(set) var service: ProxmoxAPIService?
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published var lastError: String?
    @Published var pendingCertificateConfirmation: CertificateConfirmation?
    let taskCenter = ProxmoxTaskCenter()
    private var authenticationObserver: NSObjectProtocol?

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    var isConnected: Bool { connectionState == .connected }

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
    }

    deinit {
        if let authenticationObserver {
            NotificationCenter.default.removeObserver(authenticationObserver)
        }
    }

    // MARK: - Server management

    func addServer(_ server: ProxmoxServer, password: String) {
        servers.append(server)
        if !KeychainHelper.savePassword(password, for: server.id) {
            lastError = "Could not securely save the server password."
        }
        ServerStore.save(servers)
    }

    func updateServer(_ server: ProxmoxServer, password: String?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        if let password = password, !KeychainHelper.savePassword(password, for: server.id) {
            lastError = "Could not securely save the server password."
        }
        ServerStore.save(servers)
    }

    func removeServer(_ server: ProxmoxServer) {
        servers.removeAll { $0.id == server.id }
        KeychainHelper.deletePassword(for: server.id)
        ServerStore.save(servers)
        if connectedServer?.id == server.id {
            disconnect()
        }
    }

    // MARK: - Connection lifecycle

    /// Connects to a server using its stored Keychain password.
    func connect(to server: ProxmoxServer) async {
        guard let password = KeychainHelper.password(for: server.id) else {
            lastError = "No saved password for \(server.name). Edit the server to re-enter it."
            return
        }
        await connect(to: server, password: password)
    }

    /// Connects with an explicit password (used right after adding a server).
    func connect(to server: ProxmoxServer, password: String) async {
        connectionState = .connecting
        lastError = nil

        let service = ProxmoxAPIService(server: server)
        do {
            try await service.authenticate(password: password)
            self.service = service
            self.connectedServer = server
            self.connectionState = .connected
        } catch let error as ProxmoxError {
            self.connectionState = .disconnected
            if case let .certificateConfirmationRequired(_, fingerprint) = error {
                self.pendingCertificateConfirmation = CertificateConfirmation(
                    server: server,
                    fingerprint: fingerprint
                )
                self.lastError = nil
            } else {
                self.lastError = error.localizedDescription
            }
        } catch {
            self.connectionState = .disconnected
            self.lastError = error.localizedDescription
        }
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
    }
}
