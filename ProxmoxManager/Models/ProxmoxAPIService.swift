import CryptoKit
import Foundation
import Security

// MARK: - Errors

enum ProxmoxError: LocalizedError {
    case invalidURL
    case notAuthenticated
    case authenticationFailed(String)
    case requestFailed(status: Int, body: String)
    case decodingFailed(String)
    case certificateConfirmationRequired(host: String, fingerprint: String)
    case certificateMismatch(host: String, expected: String, actual: String)
    case taskFailed(String)
    case taskTimeout
    case network(String)
    case tfaRequired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL is invalid."
        case .notAuthenticated:
            return "Not logged in. Please connect to the server first."
        case .authenticationFailed(let msg):
            return "Authentication failed: \(msg)"
        case .requestFailed(let status, _):
            return "Request failed (HTTP \(status))."
        case .decodingFailed(let msg):
            return "Could not read the server response: \(msg)"
        case .certificateConfirmationRequired(let host, let fingerprint):
            return "Confirm the SHA-256 certificate fingerprint for \(host):\n\(fingerprint)"
        case .certificateMismatch(let host, let expected, let actual):
            return "Certificate mismatch for \(host). Expected \(expected), received \(actual)."
        case .taskFailed(let msg):
            return "Proxmox task failed: \(msg)"
        case .taskTimeout:
            return "The Proxmox task timed out. Check the task log on the server."
        case .network(let msg):
            return "Network error: \(msg)"
        case .tfaRequired:
            return "Two-factor authentication is required. Enter your TOTP code."
        }
    }
}

// MARK: - Service

/// Talks to a single Proxmox VE server. Handles ticket auth, adds the required
/// cookie + CSRF header, and exposes typed calls for the screens.
///
/// A fresh instance is created per server connection. It is an `actor` so the
/// stored ticket/CSRF token can't be mutated from two tasks at once.
actor ProxmoxAPIService {
    private let server: ProxmoxServer
    private let session: URLSession
    private let certificateTrustState: CertificateTrustState

    private var ticket: String?
    private var csrfToken: String?
    private var tokenValue: String?
    private var tfaChallenge: ProxmoxTFAChallenge?
    /// Stored password for transparent 401 retries.
    private var storedPassword: String?

    init(server: ProxmoxServer, tokenValue: String? = nil) {
        self.server = server
        self.tokenValue = tokenValue

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false

        let trustState = CertificateTrustState(
            host: server.host,
            expectedFingerprint: server.allowInsecureSSL
                ? KeychainHelper.certificateFingerprint(for: server.id)
                : nil
        )
        self.certificateTrustState = trustState

        if server.allowInsecureSSL {
            self.session = URLSession(
                configuration: config,
                delegate: InsecureSSLDelegate(trustState: trustState),
                delegateQueue: nil
            )
        } else {
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Authentication

    /// Logs in with a password and stores the ticket + CSRF token for
    /// subsequent requests. Throws `.tfaRequired` if a TOTP second factor
    /// challenge is received; call `authenticateTOTP(code:)` to complete it.
    func authenticate(password: String) async throws {
        storedPassword = password

        let body = "username=\(server.fullUsername.formURLEncoded)&password=\(password.formURLEncoded)"

        let (data, response) = try await postLogin(body: body)
        guard let http = response as? HTTPURLResponse else {
            throw ProxmoxError.network("No HTTP response")
        }

        guard http.statusCode == 200 else {
            throw ProxmoxError.authenticationFailed(
                http.statusCode == 401 ? "Invalid credentials" : "The server rejected the authentication request (HTTP \(http.statusCode))."
            )
        }

        let decoded = try JSONDecoder().decode(ProxmoxResponse<ProxmoxTicketPayload>.self, from: data)

        // If ticket is empty, PVE is requesting TOTP second factor.
        if decoded.data.ticket.isEmpty, let tfaChallenge = decoded.data.tfa {
            self.tfaChallenge = ProxmoxTFAChallenge(
                tfa: tfaChallenge,
                tfaChallenge: decoded.data.tfaChallenge ?? tfaChallenge,
                username: decoded.data.username
            )
            throw ProxmoxError.tfaRequired
        }

        guard !decoded.data.ticket.isEmpty else {
            throw ProxmoxError.authenticationFailed("Empty ticket received.")
        }

        self.ticket = decoded.data.ticket
        self.csrfToken = decoded.data.csrfToken
    }

    /// Complete a TOTP challenge. Call this after receiving `.tfaRequired`.
    func authenticateTOTP(code: String) async throws {
        guard let challenge = tfaChallenge else {
            throw ProxmoxError.authenticationFailed("No pending TFA challenge.")
        }

        let body = "username=\(server.fullUsername.formURLEncoded)" +
            "&password=\(challenge.tfa.formURLEncoded)" +
            "&tfa-challenge=\(challenge.tfaChallenge.formURLEncoded)" +
            "&tfa-code=\(code.formURLEncoded)"

        let (data, response) = try await postLogin(body: body)
        guard let http = response as? HTTPURLResponse else {
            throw ProxmoxError.network("No HTTP response")
        }

        guard http.statusCode == 200 else {
            throw ProxmoxError.authenticationFailed(
                http.statusCode == 401 ? "Invalid TOTP code" : "TFA authentication failed (HTTP \(http.statusCode))."
            )
        }

        do {
            let decoded = try JSONDecoder().decode(ProxmoxResponse<ProxmoxTicketPayload>.self, from: data)
            guard !decoded.data.ticket.isEmpty else {
                throw ProxmoxError.authenticationFailed("TOTP verification failed.")
            }
            self.ticket = decoded.data.ticket
            self.csrfToken = decoded.data.csrfToken
            self.tfaChallenge = nil
        } catch let error as ProxmoxError {
            throw error
        } catch {
            throw ProxmoxError.decodingFailed(error.localizedDescription)
        }
    }

    private func postLogin(body: String) async throws -> (Data, URLResponse) {
        guard let url = URL(string: "\(server.baseURL)/access/ticket") else {
            throw ProxmoxError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        return try await performRequest(request)
    }

    /// Authenticate using an API Token. No login request needed — the token
    /// is sent as a header on every request.
    func authenticateWithToken() {
        guard let tokenValue = tokenValue, !tokenValue.isEmpty else { return }
        // Token is already set from init; mark as authenticated.
    }

    var isAuthenticated: Bool {
        server.authMethod == .token ? (tokenValue?.isEmpty == false) : (ticket != nil)
    }

    func logout() {
        ticket = nil
        csrfToken = nil
    }

    // MARK: Reads

    func fetchNodes() async throws -> [ProxmoxNode] {
        try await get("/nodes", as: [ProxmoxNode].self)
            .sorted { $0.node < $1.node }
    }

    func fetchNodeStatus(node: String) async throws -> NodeStatus {
        try await get("/nodes/\(node)/status", as: NodeStatus.self)
    }

    func fetchClusterResources() async throws -> [ClusterResource] {
        try await get("/cluster/resources", as: [ClusterResource].self)
    }

    /// Fetches both QEMU VMs and LXC containers for a node and tags each guest
    /// with its node + type so the UI can drive control actions.
    /// Each type is fetched independently so a permission error on one type
    /// (common with restricted API Token accounts) doesn't block the other.
    func fetchGuests(node: String) async throws -> [ProxmoxVM] {
        var guests: [ProxmoxVM] = []
        // Try QEMU
        if let qemu = try? await get("/nodes/\(node)/qemu", as: [ProxmoxVM].self) {
            for var vm in qemu {
                vm.node = node
                vm.type = .qemu
                guests.append(vm)
            }
        }
        // Try LXC
        if let lxc = try? await get("/nodes/\(node)/lxc", as: [ProxmoxVM].self) {
            for var ct in lxc {
                ct.node = node
                ct.type = .lxc
                guests.append(ct)
            }
        }
        return guests.sorted { $0.vmid < $1.vmid }
    }

    func fetchGuestStatus(node: String, type: GuestType, vmid: Int) async throws -> VMStatus {
        try await get("/nodes/\(node)/\(type.apiPath)/\(vmid)/status/current", as: VMStatus.self)
    }

    func fetchGuestConfig(node: String, type: GuestType, vmid: Int) async throws -> GuestConfig {
        try await get("/nodes/\(node)/\(type.apiPath)/\(vmid)/config", as: GuestConfig.self)
    }

    func fetchSnapshots(node: String, type: GuestType, vmid: Int) async throws -> [GuestSnapshot] {
        try await get("/nodes/\(node)/\(type.apiPath)/\(vmid)/snapshot", as: [GuestSnapshot].self)
            .filter { !$0.isCurrent }
            .sorted { ($0.snaptime ?? 0) > ($1.snaptime ?? 0) }
    }

    @discardableResult
    func createSnapshot(
        node: String,
        type: GuestType,
        vmid: Int,
        name: String,
        description: String?,
        includeVMState: Bool = true
    ) async throws -> String {
        var form = ["snapname": name]
        if let description, !description.isEmpty {
            form["description"] = description
        }
        if type == .qemu {
            form["vmstate"] = includeVMState ? "1" : "0"
        }
        return try await post(
            "/nodes/\(node)/\(type.apiPath)/\(vmid)/snapshot",
            form: form
        )
    }

    @discardableResult
    func rollbackSnapshot(
        node: String,
        type: GuestType,
        vmid: Int,
        snapshot: String
    ) async throws -> String {
        try await post(
            "/nodes/\(node)/\(type.apiPath)/\(vmid)/snapshot/\(snapshot.pathEscaped)/rollback",
            form: [:]
        )
    }

    @discardableResult
    func deleteSnapshot(
        node: String,
        type: GuestType,
        vmid: Int,
        snapshot: String
    ) async throws -> String {
        try await delete("/nodes/\(node)/\(type.apiPath)/\(vmid)/snapshot/\(snapshot.pathEscaped)")
    }

    func fetchTaskStatus(node: String, upid: String) async throws -> ProxmoxTaskStatus {
        let encodedUPID = upid.pathEscaped
        return try await get("/nodes/\(node)/tasks/\(encodedUPID)/status", as: ProxmoxTaskStatus.self)
    }

    func fetchTaskLog(node: String, upid: String) async throws -> [ProxmoxTaskLogEntry] {
        let encodedUPID = upid.pathEscaped
        return try await get("/nodes/\(node)/tasks/\(encodedUPID)/log", as: [ProxmoxTaskLogEntry].self)
            .sorted { $0.n < $1.n }
    }

    /// Cancels a running task (cluster tasks only, not guest-level tasks).
    @discardableResult
    func cancelTask(node: String, upid: String) async throws -> String {
        let encodedUPID = upid.pathEscaped
        return try await delete("/nodes/\(node)/tasks/\(encodedUPID)")
    }

    func waitForTask(
        node: String,
        upid: String,
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        maxPolls: Int = 120
    ) async throws -> ProxmoxTaskStatus {
        for poll in 0...maxPolls {
            try Task.checkCancellation()
            let status = try await fetchTaskStatus(node: node, upid: upid)
            if status.isFinished {
                guard status.isSuccessful else {
                    throw ProxmoxError.taskFailed(status.exitstatus ?? "Unknown error")
                }
                return status
            }
            if poll < maxPolls {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
        throw ProxmoxError.taskTimeout
    }

    // MARK: Control

    /// Sends a start/stop/shutdown/reboot to a guest. Returns the UPID task id.
    @discardableResult
    func performAction(_ action: GuestAction, node: String, type: GuestType, vmid: Int) async throws -> String {
        let path = "/nodes/\(node)/\(type.apiPath)/\(vmid)/status/\(action.rawValue)"
        return try await post(path)
    }

    // MARK: Permissions

    func fetchPermissions() async throws -> ProxmoxPermissions {
        try await get("/access/permissions", as: ProxmoxPermissions.self)
    }

    // MARK: Storage

    func fetchStorages(node: String) async throws -> [ProxmoxStorage] {
        try await get("/nodes/\(node)/storage", as: [ProxmoxStorage].self)
    }

    func fetchStorageStatus(node: String, storage: String) async throws -> ProxmoxStorageStatus {
        try await get("/nodes/\(node)/storage/\(storage.pathEscaped)/status", as: ProxmoxStorageStatus.self)
    }

    func fetchStorageContent(node: String, storage: String) async throws -> [ProxmoxStorageContent] {
        try await get("/nodes/\(node)/storage/\(storage.pathEscaped)/content", as: [ProxmoxStorageContent].self)
    }

    // MARK: Backups

    func fetchBackups(node: String) async throws -> [ProxmoxBackup] {
        try await get("/nodes/\(node)/backup", as: [ProxmoxBackup].self)
    }

    func fetchBackupLog(node: String, id: String) async throws -> [ProxmoxTaskLogEntry] {
        try await get("/nodes/\(node)/backup/\(id.pathEscaped)/log", as: [ProxmoxTaskLogEntry].self)
    }

    @discardableResult
    func runBackup(
        node: String,
        vmid: Int,
        storage: String,
        mode: String = "snapshot"
    ) async throws -> String {
        let form: [String: String] = [
            "vmid": "\(vmid)",
            "storage": storage,
            "mode": mode,
        ]
        return try await post("/nodes/\(node)/backup", form: form)
    }

    // MARK: RRD / Historical data

    func fetchRRDData(
        node: String,
        timeframe: String = "hour",
        cf: String = "AVERAGE"
    ) async throws -> [RRDDataPoint] {
        try await get(
            "/nodes/\(node)/rrddata?timeframe=\(timeframe)&cf=\(cf)",
            as: [RRDDataPoint].self
        )
    }

    func fetchGuestRRDData(
        node: String,
        type: GuestType,
        vmid: Int,
        timeframe: String = "hour",
        cf: String = "AVERAGE"
    ) async throws -> [RRDDataPoint] {
        try await get(
            "/nodes/\(node)/\(type.apiPath)/\(vmid)/rrddata?timeframe=\(timeframe)&cf=\(cf)",
            as: [RRDDataPoint].self
        )
    }

    // MARK: - Request plumbing

    /// Performs an authenticated request with transparent ticket renewal on 401.
    /// For token-based auth, 401 is fatal (no auto-renewal possible).
    private func performAuthenticatedRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await performRequest(request)

        guard let http = response as? HTTPURLResponse else {
            throw ProxmoxError.network("No HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                // Clear current auth state
                ticket = nil
                csrfToken = nil

                // For ticket auth with stored password, attempt transparent renewal
                if server.authMethod == .ticket, let password = storedPassword {
                    // Re-authenticate
                    try await authenticate(password: password)

                    // Retry the original request with new credentials
                    var retryRequest = request
                    applyAuth(to: &retryRequest)
                    let (retryData, retryResponse) = try await performRequest(retryRequest)
                    guard let retryHTTP = retryResponse as? HTTPURLResponse,
                          (200..<300).contains(retryHTTP.statusCode) else {
                        ticket = nil
                        csrfToken = nil
                        NotificationCenter.default.post(
                            name: .proxmoxAuthenticationExpired,
                            object: server.id
                        )
                        throw ProxmoxError.notAuthenticated
                    }
                    return (retryData, retryResponse)
                }

                // No auto-renewal possible
                NotificationCenter.default.post(
                    name: .proxmoxAuthenticationExpired,
                    object: server.id
                )
                throw ProxmoxError.notAuthenticated
            }
            throw ProxmoxError.requestFailed(status: http.statusCode, body: "")
        }

        return (data, response)
    }

    private func get<T: Codable>(_ path: String, as type: T.Type) async throws -> T {
        guard server.authMethod == .token || ticket != nil else { throw ProxmoxError.notAuthenticated }
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, _) = try await performAuthenticatedRequest(request)
        do {
            return try JSONDecoder().decode(ProxmoxResponse<T>.self, from: data).data
        } catch {
            throw ProxmoxError.decodingFailed("\(path): \(error.localizedDescription)")
        }
    }

    /// POST that returns the raw `data` string (Proxmox returns a UPID for
    /// control actions).
    @discardableResult
    private func post(_ path: String, form: [String: String] = [:]) async throws -> String {
        guard server.authMethod == .token || ticket != nil else { throw ProxmoxError.notAuthenticated }
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        if !form.isEmpty {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.keys.sorted()
                .compactMap { key in
                    guard let value = form[key] else { return nil }
                    return "\(key.formURLEncoded)=\(value.formURLEncoded)"
                }
                .joined(separator: "&")
                .data(using: .utf8)
        }

        let (data, _) = try await performAuthenticatedRequest(request)

        // The UPID payload is a bare string; tolerate an empty body too.
        if let decoded = try? JSONDecoder().decode(ProxmoxResponse<String>.self, from: data) {
            return decoded.data
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    private func delete(_ path: String) async throws -> String {
        guard server.authMethod == .token || ticket != nil else { throw ProxmoxError.notAuthenticated }
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)

        let (data, _) = try await performAuthenticatedRequest(request)
        if let decoded = try? JSONDecoder().decode(ProxmoxResponse<String>.self, from: data) {
            return decoded.data
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func applyAuth(to request: inout URLRequest) {
        if server.authMethod == .token, let tokenValue = tokenValue, !tokenValue.isEmpty {
            request.setValue("PVEAPIToken=\(server.tokenID)=\(tokenValue)", forHTTPHeaderField: "Authorization")
        } else if let ticket = ticket {
            request.setValue("PVEAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
        }
        if let csrf = csrfToken, request.httpMethod != "GET" {
            request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken")
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if let event = certificateTrustState.takeEvent() {
                switch event {
                case .confirmationRequired(let fingerprint):
                    throw ProxmoxError.certificateConfirmationRequired(
                        host: server.host,
                        fingerprint: fingerprint
                    )
                case .mismatch(let expected, let actual):
                    throw ProxmoxError.certificateMismatch(
                        host: server.host,
                        expected: expected,
                        actual: actual
                    )
                }
            }
            throw ProxmoxError.network(error.localizedDescription)
        }
    }
}

// MARK: - Certificate Trust

private final class CertificateTrustState: @unchecked Sendable {
    enum Event {
        case confirmationRequired(String)
        case mismatch(expected: String, actual: String)
    }

    let host: String
    let expectedFingerprint: String?
    private let lock = NSLock()
    private var event: Event?

    init(host: String, expectedFingerprint: String?) {
        self.host = host
        self.expectedFingerprint = expectedFingerprint
    }

    func record(_ event: Event) {
        lock.lock()
        self.event = event
        lock.unlock()
    }

    func takeEvent() -> Event? {
        lock.lock()
        defer { lock.unlock() }
        let event = self.event
        self.event = nil
        return event
    }
}

private final class InsecureSSLDelegate: NSObject, URLSessionDelegate {
    private let trustState: CertificateTrustState

    init(trustState: CertificateTrustState) {
        self.trustState = trustState
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              hostMatches(challenge.protectionSpace.host),
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let firstCert = certificate.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let actual = Self.fingerprint(for: firstCert)
        guard let expected = trustState.expectedFingerprint else {
            trustState.record(.confirmationRequired(actual))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
            trustState.record(.mismatch(expected: expected, actual: actual))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func hostMatches(_ challengeHost: String) -> Bool {
        let configuredHost = trustState.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return challengeHost.caseInsensitiveCompare(configuredHost) == .orderedSame
    }

    private static func fingerprint(for certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
