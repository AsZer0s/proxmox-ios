import CryptoKit
import Foundation
import Security

enum PBSAuthMethod: String, Codable, CaseIterable, Identifiable {
    case ticket, token
    var id: String { rawValue }
    var label: String { self == .ticket ? String(localized: "Username + Password") : String(localized: "API Token") }
}

struct PBSServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port = 8007
    var username = "root@pam"
    var authMethod = PBSAuthMethod.token
    var tokenID = ""
    var allowInsecureSSL = false
    var certificateFingerprint = ""

    var baseURL: String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.trimmed
        components.port = port
        components.path = "/api2/json"
        return components.url?.absoluteString ?? "https://\(host):\(port)/api2/json"
    }
}

enum PBSStore {
    private static let key = "pbs.servers"
    static func load() -> [PBSServer] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PBSServer].self, from: data)) ?? []
    }
    static func save(_ values: [PBSServer]) {
        if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct PBSDatastore: Decodable, Identifiable, Hashable {
    let store: String
    let comment: String?
    let path: String?
    let maintenanceMode: String?
    var id: String { store }
    enum CodingKeys: String, CodingKey { case store, comment, path; case maintenanceMode = "maintenance-mode" }
}

struct PBSDatastoreStatus: Decodable, Hashable {
    let total: UInt64?
    let used: UInt64?
    let available: UInt64?
    let gcStatus: PBSGCStatus?
    enum CodingKeys: String, CodingKey { case total, used, available; case gcStatus = "gc-status" }
}

struct PBSGCStatus: Decodable, Hashable {
    let upid: String?
    let status: String?
    let lastRunEndtime: Int64?
    let removedBytes: UInt64?
    enum CodingKeys: String, CodingKey { case upid, status; case lastRunEndtime = "last-run-endtime"; case removedBytes = "removed-bytes" }
}

struct PBSBackupGroup: Decodable, Identifiable, Hashable {
    let backupType: String
    let backupID: String
    let lastBackup: Int64?
    let backupCount: Int?
    let owner: String?
    var id: String { "\(backupType)/\(backupID)" }
    enum CodingKeys: String, CodingKey { case owner; case backupType = "backup-type"; case backupID = "backup-id"; case lastBackup = "last-backup"; case backupCount = "backup-count" }
}

struct PBSBackupSnapshot: Decodable, Identifiable, Hashable {
    let backupType: String
    let backupID: String
    let backupTime: Int64
    let size: UInt64?
    let owner: String?
    let protected: Bool?
    let comment: String?
    let verification: PBSVerification?
    var id: String { "\(backupType)/\(backupID)/\(backupTime)" }
    enum CodingKeys: String, CodingKey {
        case owner, protected, comment, size, verification
        case backupType = "backup-type"; case backupID = "backup-id"; case backupTime = "backup-time"
    }
}

struct PBSVerification: Decodable, Hashable {
    let state: String?
    let upid: String?
    let lastTime: Int64?
    enum CodingKeys: String, CodingKey { case state, upid; case lastTime = "last-time" }
}

struct PBSJob: Decodable, Identifiable, Hashable {
    let id: String
    let store: String?
    let schedule: String?
    let comment: String?
    let disable: Bool?
    let lastRunState: String?
    let lastRunEndtime: Int64?
    enum CodingKeys: String, CodingKey { case id, store, schedule, comment, disable; case lastRunState = "last-run-state"; case lastRunEndtime = "last-run-endtime" }
}

struct PBSTask: Decodable, Identifiable, Hashable {
    let upid: String
    let workerType: String?
    let status: String?
    let user: String?
    let startTime: Int64?
    let endTime: Int64?

    var id: String { upid }

    private enum CodingKeys: String, CodingKey {
        case upid, status, user
        case workerType = "worker_type"
        case startTime = "starttime"
        case endTime = "endtime"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upid = try container.decode(String.self, forKey: .upid)
        workerType = try container.decodeIfPresent(String.self, forKey: .workerType)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        startTime = container.decodeFlexibleInt64(forKey: .startTime)
        endTime = container.decodeFlexibleInt64(forKey: .endTime)
    }
}

struct PBSTaskLogEntry: Decodable, Identifiable, Hashable {
    let n: Int
    let t: String
    var id: Int { n }
}

actor PBSAPIService {
    private let server: PBSServer
    private let secret: String
    private let session: URLSession
    private var ticket: String?
    private var csrf: String?

    init(server: PBSServer, secret: String) {
        self.server = server
        self.secret = secret
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        if server.allowInsecureSSL {
            session = URLSession(configuration: configuration, delegate: PBSTrustDelegate(expectedFingerprint: server.certificateFingerprint), delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
    }

    func authenticate() async throws {
        guard server.authMethod == .ticket else { return }
        let payload = ["username": server.username, "password": secret]
        let result: PBSTicket = try await request("/access/ticket", method: "POST", form: payload, authenticated: false)
        ticket = result.ticket
        csrf = result.csrf
    }

    func datastores() async throws -> [PBSDatastore] { try await request("/admin/datastore") }
    func status(store: String) async throws -> PBSDatastoreStatus { try await request("/admin/datastore/\(store.pathEscaped)/status") }
    func groups(store: String) async throws -> [PBSBackupGroup] { try await request("/admin/datastore/\(store.pathEscaped)/groups") }
    func snapshots(store: String, group: PBSBackupGroup? = nil) async throws -> [PBSBackupSnapshot] {
        var path = "/admin/datastore/\(store.pathEscaped)/snapshots"
        if let group { path += "?backup-type=\(group.backupType.formURLEncoded)&backup-id=\(group.backupID.formURLEncoded)" }
        return try await request(path)
    }
    func garbageCollect(store: String) async throws -> String { try await request("/admin/datastore/\(store.pathEscaped)/gc", method: "POST", form: [:]) }
    func verify(store: String, snapshot: PBSBackupSnapshot) async throws -> String {
        try await request("/admin/datastore/\(store.pathEscaped)/verify", method: "POST", form: [
            "backup-type": snapshot.backupType, "backup-id": snapshot.backupID, "backup-time": String(snapshot.backupTime)
        ])
    }
    func deleteSnapshot(store: String, snapshot: PBSBackupSnapshot) async throws {
        try await mutate("/admin/datastore/\(store.pathEscaped)/snapshots", method: "DELETE", form: [
            "backup-type": snapshot.backupType,
            "backup-id": snapshot.backupID,
            "backup-time": String(snapshot.backupTime),
        ])
    }
    func pruneJobs() async throws -> [PBSJob] { try await request("/config/prune") }
    func verifyJobs() async throws -> [PBSJob] { try await request("/config/verify") }
    func syncJobs() async throws -> [PBSJob] { try await request("/config/sync") }
    func runPruneJob(id: String) async throws -> String { try await request("/admin/prune/\(id.pathEscaped)", method: "POST", form: [:]) }
    func runVerifyJob(id: String) async throws -> String { try await request("/admin/verify/\(id.pathEscaped)", method: "POST", form: [:]) }
    func runSyncJob(id: String) async throws -> String { try await request("/admin/sync-job/\(id.pathEscaped)", method: "POST", form: [:]) }
    func tasks(limit: Int = 100) async throws -> [PBSTask] {
        try await request("/nodes/localhost/tasks?limit=\(max(1, min(limit, 500)))")
    }
    func taskLog(upid: String) async throws -> [PBSTaskLogEntry] {
        try await request("/nodes/localhost/tasks/\(upid.pathEscaped)/log")
    }

    func createJob(kind: String, form: [String: String]) async throws { try await mutate("/config/\(kind)", method: "POST", form: form) }
    func updateJob(kind: String, id: String, form: [String: String]) async throws { try await mutate("/config/\(kind)/\(id.pathEscaped)", method: "PUT", form: form) }
    func deleteJob(kind: String, id: String) async throws { try await mutate("/config/\(kind)/\(id.pathEscaped)", method: "DELETE", form: [:]) }

    private func mutate(_ path: String, method: String, form: [String: String]) async throws {
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key.formURLEncoded)=\($0.value.formURLEncoded)" }.joined(separator: "&").data(using: .utf8)
        if server.authMethod == .token {
            request.setValue("PBSAPIToken=\(server.tokenID):\(secret)", forHTTPHeaderField: "Authorization")
        } else if let ticket {
            request.setValue("PBSAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
            request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProxmoxError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        form: [String: String]? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        guard let url = URL(string: server.baseURL + path) else { throw ProxmoxError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.map { "\($0.key.formURLEncoded)=\($0.value.formURLEncoded)" }.joined(separator: "&").data(using: .utf8)
        }
        if authenticated {
            if server.authMethod == .token {
                request.setValue("PBSAPIToken=\(server.tokenID):\(secret)", forHTTPHeaderField: "Authorization")
            } else if let ticket {
                request.setValue("PBSAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
                if method != "GET" { request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken") }
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProxmoxError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(PBSEnvelope<T>.self, from: data).data }
        catch { throw ProxmoxError.decodingFailed(error.localizedDescription) }
    }
}

private struct PBSEnvelope<T: Decodable>: Decodable { let data: T }
private struct PBSTicket: Decodable {
    let ticket: String
    let csrf: String
    enum CodingKeys: String, CodingKey { case ticket; case csrf = "CSRFPreventionToken" }
}

private final class PBSTrustDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprint: String
    init(expectedFingerprint: String) { self.expectedFingerprint = expectedFingerprint.filter(\.isHexDigit).uppercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
        guard !expectedFingerprint.isEmpty, digest == expectedFingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
