import Foundation

// MARK: - Errors

enum ProxmoxError: LocalizedError {
    case invalidURL
    case notAuthenticated
    case authenticationFailed(String)
    case requestFailed(status: Int, body: String)
    case decodingFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL is invalid."
        case .notAuthenticated:
            return "Not logged in. Please connect to the server first."
        case .authenticationFailed(let msg):
            return "Authentication failed: \(msg)"
        case .requestFailed(let status, let body):
            return "Request failed (HTTP \(status)): \(body)"
        case .decodingFailed(let msg):
            return "Could not read the server response: \(msg)"
        case .network(let msg):
            return "Network error: \(msg)"
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

    private var ticket: String?
    private var csrfToken: String?

    init(server: ProxmoxServer) {
        self.server = server

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false

        if server.allowInsecureSSL {
            self.session = URLSession(
                configuration: config,
                delegate: InsecureSSLDelegate(host: server.host),
                delegateQueue: nil
            )
        } else {
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Authentication

    /// Logs in with a password and stores the ticket + CSRF token for
    /// subsequent requests.
    func authenticate(password: String) async throws {
        guard let url = URL(string: "\(server.baseURL)/access/ticket") else {
            throw ProxmoxError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(server.fullUsername.formURLEncoded)&password=\(password.formURLEncoded)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw ProxmoxError.network("No HTTP response")
        }

        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ProxmoxError.authenticationFailed(
                http.statusCode == 401 ? "Invalid credentials" : bodyText
            )
        }

        do {
            let decoded = try JSONDecoder().decode(ProxmoxResponse<ProxmoxTicket>.self, from: data)
            self.ticket = decoded.data.ticket
            self.csrfToken = decoded.data.csrfToken
        } catch {
            throw ProxmoxError.decodingFailed(error.localizedDescription)
        }
    }

    var isAuthenticated: Bool { ticket != nil }

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
    func fetchGuests(node: String) async throws -> [ProxmoxVM] {
        async let qemu = get("/nodes/\(node)/qemu", as: [ProxmoxVM].self)
        async let lxc = get("/nodes/\(node)/lxc", as: [ProxmoxVM].self)

        var guests: [ProxmoxVM] = []
        for var vm in try await qemu {
            vm.node = node
            vm.type = .qemu
            guests.append(vm)
        }
        for var ct in try await lxc {
            ct.node = node
            ct.type = .lxc
            guests.append(ct)
        }
        return guests.sorted { $0.vmid < $1.vmid }
    }

    func fetchGuestStatus(node: String, type: GuestType, vmid: Int) async throws -> VMStatus {
        try await get("/nodes/\(node)/\(type.apiPath)/\(vmid)/status/current", as: VMStatus.self)
    }

    // MARK: Control

    /// Sends a start/stop/shutdown/reboot to a guest. Returns the UPID task id.
    @discardableResult
    func performAction(_ action: GuestAction, node: String, type: GuestType, vmid: Int) async throws -> String {
        let path = "/nodes/\(node)/\(type.apiPath)/\(vmid)/status/\(action.rawValue)"
        return try await post(path)
    }

    // MARK: - Request plumbing

    private func get<T: Codable>(_ path: String, as type: T.Type) async throws -> T {
        guard ticket != nil else { throw ProxmoxError.notAuthenticated }
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await performRequest(request)
        try validate(response: response, data: data)

        do {
            return try JSONDecoder().decode(ProxmoxResponse<T>.self, from: data).data
        } catch {
            throw ProxmoxError.decodingFailed("\(path): \(error.localizedDescription)")
        }
    }

    /// POST that returns the raw `data` string (Proxmox returns a UPID for
    /// control actions).
    @discardableResult
    private func post(_ path: String) async throws -> String {
        guard ticket != nil else { throw ProxmoxError.notAuthenticated }
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)

        let (data, response) = try await performRequest(request)
        try validate(response: response, data: data)

        // The UPID payload is a bare string; tolerate an empty body too.
        if let decoded = try? JSONDecoder().decode(ProxmoxResponse<String>.self, from: data) {
            return decoded.data
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func applyAuth(to request: inout URLRequest) {
        if let ticket = ticket {
            request.setValue("PVEAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
        }
        if let csrf = csrfToken, request.httpMethod != "GET" {
            request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken")
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProxmoxError.network("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ProxmoxError.notAuthenticated }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProxmoxError.requestFailed(status: http.statusCode, body: body)
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ProxmoxError.network(error.localizedDescription)
        }
    }
}

// MARK: - Insecure SSL

/// Accepts self-signed certificates for the configured host only. Proxmox
/// ships a self-signed cert by default, so home setups need this. Scoped to
/// the exact host to avoid trusting arbitrary servers.
private final class InsecureSSLDelegate: NSObject, URLSessionDelegate {
    private let host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
