import CryptoKit
import Foundation
import Security

enum ProxmoxEndpoint {
    static let backupJobs = "/cluster/backup"
    static let nextVMID = "/cluster/nextid"

    static func guests(node: String, type: GuestType) -> String {
        "/nodes/\(node)/\(type.apiPath)"
    }

    static func guest(node: String, type: GuestType, vmid: Int) -> String {
        "\(guests(node: node, type: type))/\(vmid)"
    }

    static func guestConfig(node: String, type: GuestType, vmid: Int) -> String {
        "\(guest(node: node, type: type, vmid: vmid))/config"
    }

    static func guestClone(node: String, type: GuestType, vmid: Int) -> String {
        "\(guest(node: node, type: type, vmid: vmid))/clone"
    }

    static func guestResize(node: String, type: GuestType, vmid: Int) -> String {
        "\(guest(node: node, type: type, vmid: vmid))/resize"
    }

    static func guestMigrate(node: String, type: GuestType, vmid: Int) -> String {
        "\(guest(node: node, type: type, vmid: vmid))/migrate"
    }

    static func guestFirewall(node: String, type: GuestType, vmid: Int) -> String {
        "\(guest(node: node, type: type, vmid: vmid))/firewall"
    }

    static func guestUnlink(node: String, vmid: Int) -> String {
        "\(guest(node: node, type: .qemu, vmid: vmid))/unlink"
    }

    static func guestMoveDisk(node: String, vmid: Int) -> String {
        "\(guest(node: node, type: .qemu, vmid: vmid))/move_disk"
    }

    static func backupJob(id: String) -> String {
        "\(backupJobs)/\(id.pathEscaped)"
    }

    static func storageContent(node: String, storage: String, content: String? = nil) -> String {
        var path = "/nodes/\(node)/storage/\(storage.pathEscaped)/content"
        if let content, !content.isEmpty {
            path += "?content=\(content.formURLEncoded)"
        }
        return path
    }

    static func appliances(node: String) -> String {
        "/nodes/\(node)/aplinfo"
    }

    static func storageDownload(node: String, storage: String) -> String {
        "/nodes/\(node)/storage/\(storage.pathEscaped)/download-url"
    }

    static func storageVolume(node: String, storage: String, volume: String) -> String {
        "/nodes/\(node)/storage/\(storage.pathEscaped)/content/\(volume.pathEscaped)"
    }

    static func backupArchives(node: String, storage: String) -> String {
        "/nodes/\(node)/storage/\(storage.pathEscaped)/content?content=backup"
    }

    static func vzdump(node: String) -> String {
        "/nodes/\(node)/vzdump"
    }

    static func nodeTasks(node: String) -> String {
        "/nodes/\(node)/tasks"
    }

    static func nodeServices(node: String) -> String {
        "/nodes/\(node)/services"
    }

    static func nodeService(node: String, service: String, command: String) -> String {
        "\(nodeServices(node: node))/\(service.pathEscaped)/\(command)"
    }

    static func nodeAPTUpdate(node: String) -> String {
        "/nodes/\(node)/apt/update"
    }
}

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

    /// Proxmox reports an absent or uninitialized Ceph installation as HTTP
    /// 500. Keep that expected state separate from an unhealthy Ceph cluster.
    var indicatesCephUnavailable: Bool {
        guard case .requestFailed(let status, let body) = self, status == 500 else {
            return false
        }
        let value = body.lowercased()
        return [
            "binary not installed",
            "pveceph configuration not initialized",
            "pveceph configuration not enabled",
            "ceph not fully configured",
            "no ceph configuration",
        ].contains { value.contains($0) }
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
    private var tfaChallengeTicket: String?
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

        let body = [
            "username=\(server.fullUsername.formURLEncoded)",
            "password=\(password.formURLEncoded)",
            "new-format=1",
        ].joined(separator: "&")

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

        if decoded.data.requiresTFA {
            self.tfaChallengeTicket = decoded.data.ticket
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
        guard let challengeTicket = tfaChallengeTicket else {
            throw ProxmoxError.authenticationFailed("No pending TFA challenge.")
        }
        let trimmedCode = code.trimmed
        guard !trimmedCode.isEmpty else {
            throw ProxmoxError.authenticationFailed("Enter a TOTP code.")
        }

        let body = Self.totpFormBody(
            username: server.fullUsername,
            code: trimmedCode,
            challengeTicket: challengeTicket
        )

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
            guard !decoded.data.ticket.isEmpty, !decoded.data.requiresTFA else {
                throw ProxmoxError.authenticationFailed("TOTP verification failed.")
            }
            self.ticket = decoded.data.ticket
            self.csrfToken = decoded.data.csrfToken
            self.tfaChallengeTicket = nil
        } catch let error as ProxmoxError {
            throw error
        } catch {
            throw ProxmoxError.decodingFailed(error.localizedDescription)
        }
    }

    static func totpFormBody(
        username: String,
        code: String,
        challengeTicket: String
    ) -> String {
        [
            "username=\(username.formURLEncoded)",
            "password=\("totp:\(code)".formURLEncoded)",
            "tfa-challenge=\(challengeTicket.formURLEncoded)",
            "new-format=1",
        ].joined(separator: "&")
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
        tfaChallengeTicket = nil
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
        try await get(ProxmoxEndpoint.guestConfig(node: node, type: type, vmid: vmid), as: GuestConfig.self)
    }

    func fetchNextVMID() async throws -> Int {
        try await get(ProxmoxEndpoint.nextVMID, as: ProxmoxInteger.self).value
    }

    @discardableResult
    func createGuest(_ request: GuestCreateRequest) async throws -> String {
        try await post(
            ProxmoxEndpoint.guests(node: request.node, type: request.type),
            form: request.form
        )
    }

    @discardableResult
    func updateGuest(
        node: String,
        type: GuestType,
        vmid: Int,
        form: [String: String]
    ) async throws -> String {
        guard !form.isEmpty else { return "" }
        return try await put(
            ProxmoxEndpoint.guestConfig(node: node, type: type, vmid: vmid),
            form: form
        )
    }

    @discardableResult
    func deleteGuest(
        node: String,
        type: GuestType,
        vmid: Int,
        purge: Bool = true
    ) async throws -> String {
        return try await delete(
            ProxmoxEndpoint.guest(node: node, type: type, vmid: vmid),
            form: ["purge": purge ? "1" : "0"]
        )
    }

    @discardableResult
    func cloneGuest(_ request: GuestCloneRequest) async throws -> String {
        try await post(
            ProxmoxEndpoint.guestClone(
                node: request.node,
                type: request.type,
                vmid: request.vmid
            ),
            form: request.form
        )
    }

    @discardableResult
    func resizeGuestDisk(
        node: String,
        type: GuestType,
        vmid: Int,
        disk: String,
        growGiB: Int
    ) async throws -> String {
        try await put(
            ProxmoxEndpoint.guestResize(node: node, type: type, vmid: vmid),
            form: [
                "disk": disk,
                "size": "+\(growGiB)G",
            ]
        )
    }

    func fetchMigrationPreconditions(
        node: String,
        type: GuestType,
        vmid: Int,
        target: String? = nil
    ) async throws -> GuestMigrationPreconditions {
        var path = ProxmoxEndpoint.guestMigrate(node: node, type: type, vmid: vmid)
        if let target, !target.isEmpty {
            path += "?target=\(target.formURLEncoded)"
        }
        return try await get(path, as: GuestMigrationPreconditions.self)
    }

    @discardableResult
    func migrateGuest(
        node: String,
        type: GuestType,
        vmid: Int,
        target: String,
        online: Bool,
        targetStorage: String?,
        withLocalDisks: Bool
    ) async throws -> String {
        var form = [
            "target": target,
            "online": online ? "1" : "0",
        ]
        if let targetStorage, !targetStorage.isEmpty {
            form[type == .qemu ? "targetstorage" : "target-storage"] = targetStorage
        }
        if type == .qemu, withLocalDisks {
            form["with-local-disks"] = "1"
        }
        return try await post(
            ProxmoxEndpoint.guestMigrate(node: node, type: type, vmid: vmid),
            form: form
        )
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

    func fetchNodeTasks(
        node: String,
        source: String = "all",
        limit: Int = 100,
        start: Int = 0,
        errorsOnly: Bool = false
    ) async throws -> [ProxmoxNodeTask] {
        let query = [
            "source=\(source.formURLEncoded)",
            "limit=\(max(0, limit))",
            "start=\(max(0, start))",
            "errors=\(errorsOnly ? 1 : 0)",
        ].joined(separator: "&")
        return try await get(
            "\(ProxmoxEndpoint.nodeTasks(node: node))?\(query)",
            as: [ProxmoxNodeTask].self
        )
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

    // MARK: HA / Replication

    func fetchHAStatus() async throws -> [ProxmoxHAStatus] {
        try await get("/cluster/ha/status/current", as: [ProxmoxHAStatus].self)
    }

    func fetchHAResources() async throws -> [ProxmoxHAResource] {
        let summaries = try await get("/cluster/ha/resources", as: [ProxmoxHAResource].self)
        var resources: [ProxmoxHAResource] = []
        for summary in summaries {
            let detail = try? await get(
                "/cluster/ha/resources/\(summary.sid.pathEscaped)",
                as: ProxmoxHAResource.self
            )
            resources.append(detail ?? summary)
        }
        return resources.sorted { $0.sid.localizedStandardCompare($1.sid) == .orderedAscending }
    }

    func createHAResource(form: [String: String]) async throws {
        _ = try await post("/cluster/ha/resources", form: form)
    }

    func updateHAResource(sid: String, form: [String: String]) async throws {
        _ = try await put("/cluster/ha/resources/\(sid.pathEscaped)", form: form)
    }

    func deleteHAResource(sid: String, purge: Bool = false) async throws {
        _ = try await delete(
            "/cluster/ha/resources/\(sid.pathEscaped)",
            form: ["purge": purge ? "1" : "0"]
        )
    }

    func fetchHAGroups() async throws -> [ProxmoxHAGroup] {
        let summaries = try await get("/cluster/ha/groups", as: [ProxmoxHAGroup].self)
        var groups: [ProxmoxHAGroup] = []
        for summary in summaries {
            let detail = try? await get(
                "/cluster/ha/groups/\(summary.group.pathEscaped)",
                as: ProxmoxHAGroup.self
            )
            groups.append(detail ?? summary)
        }
        return groups.sorted { $0.group.localizedStandardCompare($1.group) == .orderedAscending }
    }

    func createHAGroup(form: [String: String]) async throws {
        _ = try await post("/cluster/ha/groups", form: form)
    }

    func updateHAGroup(id: String, form: [String: String]) async throws {
        _ = try await put("/cluster/ha/groups/\(id.pathEscaped)", form: form)
    }

    func deleteHAGroup(id: String) async throws {
        _ = try await delete("/cluster/ha/groups/\(id.pathEscaped)")
    }

    func fetchReplicationJobs() async throws -> [ProxmoxReplicationJob] {
        try await get("/cluster/replication", as: [ProxmoxReplicationJob].self)
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func createReplicationJob(form: [String: String]) async throws {
        _ = try await post("/cluster/replication", form: form)
    }

    func updateReplicationJob(id: String, form: [String: String]) async throws {
        _ = try await put("/cluster/replication/\(id.pathEscaped)", form: form)
    }

    func deleteReplicationJob(id: String, force: Bool = false, keep: Bool = false) async throws {
        _ = try await delete(
            "/cluster/replication/\(id.pathEscaped)",
            form: ["force": force ? "1" : "0", "keep": keep ? "1" : "0"]
        )
    }

    // MARK: Access Control

    func fetchAccessUsers() async throws -> [ProxmoxAccessUser] {
        try await get("/access/users?full=1", as: [ProxmoxAccessUser].self)
            .sorted { $0.userid.localizedCaseInsensitiveCompare($1.userid) == .orderedAscending }
    }

    func createAccessUser(form: [String: String]) async throws {
        _ = try await post("/access/users", form: form)
    }

    func updateAccessUser(userid: String, form: [String: String]) async throws {
        _ = try await put("/access/users/\(userid.pathEscaped)", form: form)
    }

    func deleteAccessUser(userid: String) async throws {
        _ = try await delete("/access/users/\(userid.pathEscaped)")
    }

    func fetchAPITokens(userid: String) async throws -> [ProxmoxAPIToken] {
        try await get(
            "/access/users/\(userid.pathEscaped)/token",
            as: [ProxmoxAPIToken].self
        )
        .sorted { $0.tokenid.localizedCaseInsensitiveCompare($1.tokenid) == .orderedAscending }
    }

    func createAPIToken(
        userid: String,
        tokenid: String,
        form: [String: String]
    ) async throws -> ProxmoxAPITokenSecret {
        try await postDecoded(
            "/access/users/\(userid.pathEscaped)/token/\(tokenid.pathEscaped)",
            form: form,
            as: ProxmoxAPITokenSecret.self
        )
    }

    func updateAPIToken(userid: String, tokenid: String, form: [String: String]) async throws {
        _ = try await put(
            "/access/users/\(userid.pathEscaped)/token/\(tokenid.pathEscaped)",
            form: form
        )
    }

    func deleteAPIToken(userid: String, tokenid: String) async throws {
        _ = try await delete(
            "/access/users/\(userid.pathEscaped)/token/\(tokenid.pathEscaped)"
        )
    }

    func fetchRoles() async throws -> [ProxmoxRole] {
        try await get("/access/roles", as: [ProxmoxRole].self)
            .sorted { $0.roleid.localizedCaseInsensitiveCompare($1.roleid) == .orderedAscending }
    }

    func createRole(form: [String: String]) async throws {
        _ = try await post("/access/roles", form: form)
    }

    func updateRole(id: String, form: [String: String]) async throws {
        _ = try await put("/access/roles/\(id.pathEscaped)", form: form)
    }

    func deleteRole(id: String) async throws {
        _ = try await delete("/access/roles/\(id.pathEscaped)")
    }

    func fetchACLs() async throws -> [ProxmoxACLEntry] {
        try await get("/access/acl", as: [ProxmoxACLEntry].self)
            .sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                return $0.ugid < $1.ugid
            }
    }

    func updateACL(form: [String: String]) async throws {
        _ = try await put("/access/acl", form: form)
    }

    // MARK: Cluster Infrastructure

    func fetchNodeNetworkInterfaces(node: String) async throws -> [ProxmoxNetworkInterface] {
        try await get("/nodes/\(node)/network", as: [ProxmoxNetworkInterface].self)
            .sorted { $0.iface.localizedStandardCompare($1.iface) == .orderedAscending }
    }

    func createNodeNetworkInterface(node: String, form: [String: String]) async throws {
        _ = try await post("/nodes/\(node)/network", form: form)
    }

    func updateNodeNetworkInterface(
        node: String,
        iface: String,
        form: [String: String]
    ) async throws {
        _ = try await put("/nodes/\(node)/network/\(iface.pathEscaped)", form: form)
    }

    func deleteNodeNetworkInterface(node: String, iface: String) async throws {
        _ = try await delete("/nodes/\(node)/network/\(iface.pathEscaped)")
    }

    func applyNodeNetworkConfiguration(node: String) async throws {
        _ = try await put("/nodes/\(node)/network", form: [:])
    }

    func revertNodeNetworkConfiguration(node: String) async throws {
        _ = try await delete("/nodes/\(node)/network")
    }

    func fetchStorageConfigs() async throws -> [ProxmoxStorageConfig] {
        try await get("/storage", as: [ProxmoxStorageConfig].self)
            .sorted { $0.storage.localizedCaseInsensitiveCompare($1.storage) == .orderedAscending }
    }

    func createStorageConfig(form: [String: String]) async throws {
        _ = try await post("/storage", form: form)
    }

    func updateStorageConfig(id: String, form: [String: String]) async throws {
        _ = try await put("/storage/\(id.pathEscaped)", form: form)
    }

    func deleteStorageConfig(id: String) async throws {
        _ = try await delete("/storage/\(id.pathEscaped)")
    }

    func fetchCephStatus(node: String) async throws -> ProxmoxCephStatus {
        try await get("/nodes/\(node)/ceph/status", as: ProxmoxCephStatus.self)
    }

    func fetchCephPools(node: String) async throws -> [ProxmoxCephPool] {
        try await get("/nodes/\(node)/ceph/pool", as: [ProxmoxCephPool].self)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createCephPool(node: String, form: [String: String]) async throws {
        _ = try await post("/nodes/\(node)/ceph/pool", form: form)
    }

    func updateCephPool(node: String, name: String, form: [String: String]) async throws {
        _ = try await put("/nodes/\(node)/ceph/pool/\(name.pathEscaped)", form: form)
    }

    func deleteCephPool(node: String, name: String) async throws {
        _ = try await delete("/nodes/\(node)/ceph/pool/\(name.pathEscaped)")
    }

    func fetchSDNZones() async throws -> [ProxmoxSDNZone] {
        try await get("/cluster/sdn/zones", as: [ProxmoxSDNZone].self)
            .sorted { $0.zone.localizedCaseInsensitiveCompare($1.zone) == .orderedAscending }
    }

    func createSDNZone(form: [String: String]) async throws {
        _ = try await post("/cluster/sdn/zones", form: form)
    }

    func updateSDNZone(id: String, form: [String: String]) async throws {
        _ = try await put("/cluster/sdn/zones/\(id.pathEscaped)", form: form)
    }

    func deleteSDNZone(id: String) async throws {
        _ = try await delete("/cluster/sdn/zones/\(id.pathEscaped)")
    }

    func fetchSDNVNets() async throws -> [ProxmoxSDNVNet] {
        try await get("/cluster/sdn/vnets", as: [ProxmoxSDNVNet].self)
            .sorted { $0.vnet.localizedCaseInsensitiveCompare($1.vnet) == .orderedAscending }
    }

    func createSDNVNet(form: [String: String]) async throws {
        _ = try await post("/cluster/sdn/vnets", form: form)
    }

    func updateSDNVNet(id: String, form: [String: String]) async throws {
        _ = try await put("/cluster/sdn/vnets/\(id.pathEscaped)", form: form)
    }

    func deleteSDNVNet(id: String) async throws {
        _ = try await delete("/cluster/sdn/vnets/\(id.pathEscaped)")
    }

    func fetchSDNSubnets(vnet: String) async throws -> [ProxmoxSDNSubnet] {
        try await get(
            "/cluster/sdn/vnets/\(vnet.pathEscaped)/subnets",
            as: [ProxmoxSDNSubnet].self
        )
        .sorted { $0.subnet.localizedCaseInsensitiveCompare($1.subnet) == .orderedAscending }
    }

    func createSDNSubnet(vnet: String, form: [String: String]) async throws {
        _ = try await post("/cluster/sdn/vnets/\(vnet.pathEscaped)/subnets", form: form)
    }

    func updateSDNSubnet(vnet: String, id: String, form: [String: String]) async throws {
        _ = try await put(
            "/cluster/sdn/vnets/\(vnet.pathEscaped)/subnets/\(id.pathEscaped)",
            form: form
        )
    }

    func deleteSDNSubnet(vnet: String, id: String) async throws {
        _ = try await delete(
            "/cluster/sdn/vnets/\(vnet.pathEscaped)/subnets/\(id.pathEscaped)"
        )
    }

    func applySDNConfiguration() async throws {
        _ = try await put("/cluster/sdn", form: [:])
    }

    // MARK: Storage

    func fetchStorages(node: String) async throws -> [ProxmoxStorage] {
        try await get("/nodes/\(node)/storage", as: [ProxmoxStorage].self)
    }

    func fetchStorageStatus(node: String, storage: String) async throws -> ProxmoxStorageStatus {
        try await get("/nodes/\(node)/storage/\(storage.pathEscaped)/status", as: ProxmoxStorageStatus.self)
    }

    func fetchStorageContent(
        node: String,
        storage: String,
        content: String? = nil
    ) async throws -> [ProxmoxStorageContent] {
        let path = ProxmoxEndpoint.storageContent(
            node: node,
            storage: storage,
            content: content
        )
        var items = try await get(path, as: [ProxmoxStorageContent].self)
        if let content {
            for index in items.indices where items[index].content == nil {
                items[index].content = content
            }
        }
        return items
    }

    func fetchApplianceTemplates(node: String) async throws -> [ApplianceTemplate] {
        try await get(ProxmoxEndpoint.appliances(node: node), as: [ApplianceTemplate].self)
            .sorted {
                if ($0.section ?? "") != ($1.section ?? "") {
                    return ($0.section ?? "") < ($1.section ?? "")
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    @discardableResult
    func downloadApplianceTemplate(
        node: String,
        storage: String,
        template: String
    ) async throws -> String {
        try await post(
            ProxmoxEndpoint.appliances(node: node),
            form: [
                "storage": storage,
                "template": template,
            ]
        )
    }

    @discardableResult
    func downloadStorageContent(
        node: String,
        storage: String,
        content: String,
        url: String,
        filename: String,
        checksum: String? = nil,
        checksumAlgorithm: String? = nil,
        verifyCertificates: Bool = true
    ) async throws -> String {
        var form = [
            "content": content,
            "url": url,
            "filename": filename,
            "verify-certificates": verifyCertificates ? "1" : "0",
        ]
        if let checksum, !checksum.isEmpty,
           let checksumAlgorithm, !checksumAlgorithm.isEmpty {
            form["checksum"] = checksum
            form["checksum-algorithm"] = checksumAlgorithm
        }
        return try await post(
            ProxmoxEndpoint.storageDownload(node: node, storage: storage),
            form: form
        )
    }

    @discardableResult
    func deleteStorageContent(
        node: String,
        storage: String,
        volume: String
    ) async throws -> String {
        try await delete(
            ProxmoxEndpoint.storageVolume(node: node, storage: storage, volume: volume)
        )
    }

    func updateStorageContent(
        node: String,
        storage: String,
        volume: String,
        protected: Bool? = nil,
        notes: String? = nil
    ) async throws {
        var form: [String: String] = [:]
        if let protected {
            form["protected"] = protected ? "1" : "0"
        }
        if let notes {
            form["notes"] = notes
        }
        _ = try await put(
            ProxmoxEndpoint.storageVolume(node: node, storage: storage, volume: volume),
            form: form
        )
    }

    // MARK: Backups

    func fetchBackupJobs(node: String) async throws -> [ProxmoxBackupJob] {
        try await get(ProxmoxEndpoint.backupJobs, as: [ProxmoxBackupJob].self)
            .filter { $0.node == nil || $0.node == node }
    }

    func createBackupJob(form: [String: String]) async throws {
        _ = try await post(ProxmoxEndpoint.backupJobs, form: form)
    }

    func updateBackupJob(id: String, form: [String: String]) async throws {
        _ = try await put(ProxmoxEndpoint.backupJob(id: id), form: form)
    }

    func deleteBackupJob(id: String) async throws {
        _ = try await delete(ProxmoxEndpoint.backupJob(id: id))
    }

    func fetchBackupFiles(node: String) async throws -> [ProxmoxBackupFile] {
        let storages = try await fetchStorages(node: node)
            .filter { $0.isAvailable && $0.storageTypes.contains("backup") }

        var files: [ProxmoxBackupFile] = []
        var firstError: Error?
        var failedStorageCount = 0

        for storage in storages {
            do {
                let content: [ProxmoxStorageContent] = try await get(
                    ProxmoxEndpoint.backupArchives(node: node, storage: storage.storage),
                    as: [ProxmoxStorageContent].self
                )
                files.append(contentsOf: content.compactMap { item in
                    guard item.content == "backup" else { return nil }
                    return ProxmoxBackupFile(
                        volid: item.volid,
                        storage: storage.storage,
                        vmid: item.vmid,
                        size: item.size,
                        createdAt: item.ctime,
                        notes: item.notes,
                        format: item.format,
                        isProtected: item.protectedFlag == 1
                    )
                })
            } catch {
                failedStorageCount += 1
                if firstError == nil { firstError = error }
            }
        }

        if !storages.isEmpty, failedStorageCount == storages.count, let firstError {
            throw firstError
        }
        return files.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
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
        return try await post(ProxmoxEndpoint.vzdump(node: node), form: form)
    }

    @discardableResult
    func restoreBackup(
        node: String,
        type: GuestType,
        vmid: Int,
        archive: String,
        storage: String?,
        unique: Bool = true
    ) async throws -> String {
        var form = [
            "vmid": "\(vmid)",
            "unique": unique ? "1" : "0",
        ]
        if let storage, !storage.isEmpty {
            form["storage"] = storage
        }
        form[type == .qemu ? "archive" : "ostemplate"] = archive
        return try await post(ProxmoxEndpoint.guests(node: node, type: type), form: form)
    }

    // MARK: Guest Hardware

    @discardableResult
    func unlinkGuestDisk(
        node: String,
        vmid: Int,
        disk: String,
        permanentlyDelete: Bool
    ) async throws -> String {
        try await put(
            ProxmoxEndpoint.guestUnlink(node: node, vmid: vmid),
            form: [
                "idlist": disk,
                "force": permanentlyDelete ? "1" : "0",
            ]
        )
    }

    @discardableResult
    func moveGuestDisk(
        node: String,
        vmid: Int,
        disk: String,
        storage: String,
        deleteSource: Bool = true
    ) async throws -> String {
        try await post(
            ProxmoxEndpoint.guestMoveDisk(node: node, vmid: vmid),
            form: [
                "disk": disk,
                "storage": storage,
                "delete": deleteSource ? "1" : "0",
            ]
        )
    }

    @discardableResult
    func moveLXCVolume(
        node: String,
        vmid: Int,
        volume: String,
        storage: String,
        deleteSource: Bool = true
    ) async throws -> String {
        try await post(
            "/nodes/\(node)/lxc/\(vmid)/move_volume",
            form: [
                "volume": volume,
                "storage": storage,
                "delete": deleteSource ? "1" : "0",
            ]
        )
    }

    @discardableResult
    func deleteLXCVolume(node: String, vmid: Int, volume: String) async throws -> String {
        try await put(
            ProxmoxEndpoint.guestConfig(node: node, type: .lxc, vmid: vmid),
            form: ["delete": volume]
        )
    }

    func fetchNodePCIDevices(node: String) async throws -> [ProxmoxPCIDevice] {
        try await get(
            "/nodes/\(node)/hardware/pci?verbose=1",
            as: [ProxmoxPCIDevice].self
        )
    }

    func fetchNodeUSBDevices(node: String) async throws -> [ProxmoxUSBDevice] {
        try await get("/nodes/\(node)/hardware/usb", as: [ProxmoxUSBDevice].self)
    }

    // MARK: Node Maintenance

    @discardableResult
    func performNodePowerAction(node: String, command: String) async throws -> String {
        try await post("/nodes/\(node)/status", form: ["command": command])
    }

    func fetchNodeServices(node: String) async throws -> [ProxmoxNodeService] {
        try await get(ProxmoxEndpoint.nodeServices(node: node), as: [ProxmoxNodeService].self)
            .sorted { $0.service.localizedCaseInsensitiveCompare($1.service) == .orderedAscending }
    }

    @discardableResult
    func performNodeServiceAction(
        node: String,
        service: String,
        command: String
    ) async throws -> String {
        try await post(
            ProxmoxEndpoint.nodeService(node: node, service: service, command: command)
        )
    }

    func fetchNodeUpdates(node: String) async throws -> [ProxmoxPackageUpdate] {
        try await get(ProxmoxEndpoint.nodeAPTUpdate(node: node), as: [ProxmoxPackageUpdate].self)
            .sorted { $0.package.localizedCaseInsensitiveCompare($1.package) == .orderedAscending }
    }

    @discardableResult
    func refreshNodePackageIndex(node: String) async throws -> String {
        try await post(ProxmoxEndpoint.nodeAPTUpdate(node: node), form: ["notify": "0"])
    }

    // MARK: Native Consoles

    func createGuestConsoleProxy(
        node: String,
        type: GuestType,
        vmid: Int,
        terminal: Bool
    ) async throws -> ProxmoxConsoleProxy {
        let endpoint = "\(ProxmoxEndpoint.guest(node: node, type: type, vmid: vmid))/\(terminal ? "termproxy" : "vncproxy")"
        return try await postDecoded(
            endpoint,
            form: terminal ? [:] : ["websocket": "1"],
            as: ProxmoxConsoleProxy.self
        )
    }

    func createNodeConsoleProxy(
        node: String,
        command: String = "login"
    ) async throws -> ProxmoxConsoleProxy {
        try await postDecoded(
            "/nodes/\(node)/termproxy",
            form: ["cmd": command],
            as: ProxmoxConsoleProxy.self
        )
    }

    func makeConsoleWebSocketTask(
        node: String,
        type: GuestType?,
        vmid: Int?,
        proxy: ProxmoxConsoleProxy
    ) throws -> URLSessionWebSocketTask {
        var path = "/nodes/\(node)"
        if let type, let vmid {
            path += "/\(type.apiPath)/\(vmid)"
        }
        path += "/vncwebsocket?port=\(proxy.port)&vncticket=\(proxy.ticket.formURLEncoded)"
        guard var components = URLComponents(string: server.baseURL + path) else {
            throw ProxmoxError.invalidURL
        }
        components.scheme = "wss"
        guard let url = components.url else { throw ProxmoxError.invalidURL }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return session.webSocketTask(with: request)
    }

    // MARK: Guest Firewall

    func fetchGuestFirewallRules(
        node: String,
        type: GuestType,
        vmid: Int
    ) async throws -> [GuestFirewallRule] {
        try await get(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/rules",
            as: [GuestFirewallRule].self
        )
        .sorted { $0.pos < $1.pos }
    }

    func fetchGuestFirewallOptions(
        node: String,
        type: GuestType,
        vmid: Int
    ) async throws -> GuestFirewallOptions {
        try await get(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/options",
            as: GuestFirewallOptions.self
        )
    }

    func updateGuestFirewallOptions(
        node: String,
        type: GuestType,
        vmid: Int,
        form: [String: String]
    ) async throws {
        _ = try await put(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/options",
            form: form
        )
    }

    func createGuestFirewallRule(
        node: String,
        type: GuestType,
        vmid: Int,
        form: [String: String]
    ) async throws {
        _ = try await post(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/rules",
            form: form
        )
    }

    func updateGuestFirewallRule(
        node: String,
        type: GuestType,
        vmid: Int,
        position: Int,
        form: [String: String]
    ) async throws {
        _ = try await put(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/rules/\(position)",
            form: form
        )
    }

    func deleteGuestFirewallRule(
        node: String,
        type: GuestType,
        vmid: Int,
        position: Int
    ) async throws {
        _ = try await delete(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/rules/\(position)"
        )
    }

    func fetchGuestFirewallIPSets(
        node: String,
        type: GuestType,
        vmid: Int
    ) async throws -> [GuestFirewallIPSet] {
        try await get(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/ipset",
            as: [GuestFirewallIPSet].self
        )
    }

    func createGuestFirewallIPSet(
        node: String,
        type: GuestType,
        vmid: Int,
        name: String,
        comment: String?
    ) async throws {
        var form = ["name": name]
        if let comment, !comment.isEmpty { form["comment"] = comment }
        _ = try await post(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/ipset",
            form: form
        )
    }

    func deleteGuestFirewallIPSet(
        node: String,
        type: GuestType,
        vmid: Int,
        name: String
    ) async throws {
        _ = try await delete(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/ipset/\(name.pathEscaped)",
            form: ["force": "1"]
        )
    }

    func fetchGuestFirewallIPSetEntries(
        node: String,
        type: GuestType,
        vmid: Int,
        name: String
    ) async throws -> [GuestFirewallIPSetEntry] {
        try await get(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/ipset/\(name.pathEscaped)",
            as: [GuestFirewallIPSetEntry].self
        )
    }

    func addGuestFirewallIPSetEntry(
        node: String,
        type: GuestType,
        vmid: Int,
        name: String,
        cidr: String,
        comment: String?,
        nomatch: Bool
    ) async throws {
        var form = [
            "cidr": cidr,
            "nomatch": nomatch ? "1" : "0",
        ]
        if let comment, !comment.isEmpty { form["comment"] = comment }
        _ = try await post(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/ipset/\(name.pathEscaped)",
            form: form
        )
    }

    func deleteGuestFirewallIPSetEntry(
        node: String,
        type: GuestType,
        vmid: Int,
        name: String,
        cidr: String
    ) async throws {
        _ = try await delete(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/ipset/\(name.pathEscaped)/\(cidr.pathEscaped)"
        )
    }

    func fetchFirewallSecurityGroups() async throws -> [FirewallSecurityGroup] {
        try await get("/cluster/firewall/groups", as: [FirewallSecurityGroup].self)
            .sorted { $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending }
    }

    func fetchGuestFirewallLog(
        node: String,
        type: GuestType,
        vmid: Int,
        limit: Int = 500
    ) async throws -> [ProxmoxTaskLogEntry] {
        try await get(
            "\(ProxmoxEndpoint.guestFirewall(node: node, type: type, vmid: vmid))/log?limit=\(limit)",
            as: [ProxmoxTaskLogEntry].self
        )
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
                    do {
                        try await authenticate(password: password)
                    } catch ProxmoxError.tfaRequired {
                        NotificationCenter.default.post(
                            name: .proxmoxAuthenticationExpired,
                            object: server.id
                        )
                        throw ProxmoxError.notAuthenticated
                    }

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
            throw ProxmoxError.requestFailed(
                status: http.statusCode,
                body: Self.errorMessage(from: data)
            )
        }

        return (data, response)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
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
            request.httpBody = Self.formBody(form)
        }

        let (data, _) = try await performAuthenticatedRequest(request)
        return Self.mutationResult(from: data)
    }

    private func postDecoded<T: Decodable>(
        _ path: String,
        form: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        guard server.authMethod == .token || ticket != nil else {
            throw ProxmoxError.notAuthenticated
        }
        guard let url = URL(string: server.baseURL + path) else {
            throw ProxmoxError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)

        let (data, _) = try await performAuthenticatedRequest(request)
        do {
            return try JSONDecoder().decode(ProxmoxResponse<T>.self, from: data).data
        } catch {
            throw ProxmoxError.decodingFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func put(_ path: String, form: [String: String]) async throws -> String {
        guard server.authMethod == .token || ticket != nil else { throw ProxmoxError.notAuthenticated }
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyAuth(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)

        let (data, _) = try await performAuthenticatedRequest(request)
        return Self.mutationResult(from: data)
    }

    @discardableResult
    private func delete(_ path: String, form: [String: String] = [:]) async throws -> String {
        guard server.authMethod == .token || ticket != nil else { throw ProxmoxError.notAuthenticated }
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)
        if !form.isEmpty {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(form)
        }

        let (data, _) = try await performAuthenticatedRequest(request)
        return Self.mutationResult(from: data)
    }

    static func formBody(_ form: [String: String]) -> Data? {
        form.keys.sorted()
            .compactMap { key in
                guard let value = form[key] else { return nil }
                return "\(key.formURLEncoded)=\(value.formURLEncoded)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private static func mutationResult(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ProxmoxResponse<String?>.self, from: data) {
            return decoded.data ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let errors = object["errors"] as? [String: Any], !errors.isEmpty {
                return errors.keys.sorted().compactMap { key in
                    guard let value = errors[key] else { return nil }
                    return "\(key): \(value)"
                }.joined(separator: "\n")
            }
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
