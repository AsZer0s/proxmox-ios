import Foundation

// MARK: - Server Configuration

/// Authentication method for a Proxmox server.
enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case ticket
    case token

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ticket: return String(localized: "Username + Password")
        case .token: return String(localized: "API Token")
        }
    }
}

/// A single Proxmox VE server the user has configured.
struct ProxmoxServer: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var realm: String
    var allowInsecureSSL: Bool
    var authMethod: AuthMethod
    var tokenID: String

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 8006,
        username: String,
        realm: String = "pam",
        allowInsecureSSL: Bool = false,
        authMethod: AuthMethod = .ticket,
        tokenID: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.realm = realm
        self.allowInsecureSSL = allowInsecureSSL
        self.authMethod = authMethod
        self.tokenID = tokenID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, realm, allowInsecureSSL, authMethod, tokenID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8006
        username = try container.decode(String.self, forKey: .username)
        realm = try container.decodeIfPresent(String.self, forKey: .realm) ?? "pam"
        allowInsecureSSL = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureSSL) ?? false
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .ticket
        tokenID = try container.decodeIfPresent(String.self, forKey: .tokenID) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(realm, forKey: .realm)
        try container.encode(allowInsecureSSL, forKey: .allowInsecureSSL)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(tokenID, forKey: .tokenID)
    }

    var baseURL: String {
        var components = URLComponents()
        components.scheme = "https"
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.host = trimmedHost.contains(":") && !trimmedHost.hasPrefix("[")
            ? "[\(trimmedHost)]"
            : trimmedHost
        components.port = port
        components.path = "/api2/json"
        return components.url?.absoluteString ?? "https://\(host):\(port)/api2/json"
    }

    var fullUsername: String {
        "\(username)@\(realm)"
    }
}

// MARK: - Authentication

/// Ticket payload returned by `/access/ticket`.
///
/// For modern PVE TFA logins, the first response contains a half-authenticated
/// ticket whose payload starts with `!tfa!`. That ticket must be sent back as
/// `tfa-challenge` when submitting the second factor.
struct ProxmoxTicketPayload: Codable {
    let ticket: String
    let csrfToken: String
    let username: String

    enum CodingKeys: String, CodingKey {
        case ticket
        case csrfToken = "CSRFPreventionToken"
        case username
    }

    init(ticket: String, csrfToken: String, username: String) {
        self.ticket = ticket
        self.csrfToken = csrfToken
        self.username = username
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try container.decodeIfPresent(String.self, forKey: .ticket) ?? ""
        csrfToken = try container.decodeIfPresent(String.self, forKey: .csrfToken) ?? ""
        username = try container.decode(String.self, forKey: .username)
    }

    var requiresTFA: Bool {
        ticket.contains(":!tfa!")
    }
}

/// Generic Proxmox response envelope. Every endpoint wraps its payload in `data`.
struct ProxmoxResponse<T: Codable>: Codable {
    let data: T
}

// MARK: - Cluster Resources

/// The kind of resource returned by `/cluster/resources`.
enum ResourceType: String, Codable {
    case node
    case qemu
    case lxc
    case storage
    case pool
    case sdn
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResourceType(rawValue: raw) ?? .unknown
    }
}

/// A row from `/cluster/resources`. Fields are optional because the shape
/// differs per resource type (a node has no `vmid`, a VM has no `maxdisk` on
/// some setups, and so on).
struct ClusterResource: Codable, Identifiable, Hashable {
    let id: String
    let type: ResourceType
    let node: String?
    let status: String?
    let name: String?
    let vmid: Int?
    let cpu: Double?
    let maxcpu: Double?
    let mem: Int64?
    let maxmem: Int64?
    let disk: Int64?
    let maxdisk: Int64?
    let uptime: Int64?

    /// Display label: VM/CT name, else node name, else the raw id.
    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let node = node, type == .node { return node }
        return id
    }

    var isRunning: Bool {
        status?.lowercased() == "running" || status?.lowercased() == "online"
    }
}

// MARK: - Node

/// A row from `/nodes`.
struct ProxmoxNode: Codable, Identifiable, Hashable {
    var id: String { node }
    let node: String
    let status: String
    let cpu: Double?
    let maxcpu: Int?
    let mem: Int64?
    let maxmem: Int64?
    let disk: Int64?
    let maxdisk: Int64?
    let uptime: Int64?
    let level: String?

    var isOnline: Bool { status.lowercased() == "online" }
    var cpuFraction: Double? { cpu.map { min(max($0, 0), 1) } }
}

/// Detailed node status from `/nodes/{node}/status`.
struct NodeStatus: Codable, Hashable {
    let uptime: Int64?
    let cpu: Double?
    let loadavg: [String]?
    let memory: MemoryInfo?
    let rootfs: DiskInfo?

    struct MemoryInfo: Codable, Hashable {
        let total: Int64?
        let used: Int64?
        let free: Int64?
    }

    struct DiskInfo: Codable, Hashable {
        let total: Int64?
        let used: Int64?
        let free: Int64?
    }
}

struct ProxmoxTaskLogEntry: Codable, Hashable, Identifiable {
    let n: Int
    let t: String

    var id: Int { n }
}

struct ProxmoxTaskStatus: Codable, Hashable {
    let status: String?
    let exitstatus: String?
    let type: String?
    let node: String?
    let pid: Int?
    let starttime: Int64?
    let endtime: Int64?

    var isFinished: Bool {
        status?.lowercased() != "running" || endtime != nil
    }

    var isSuccessful: Bool {
        exitstatus?.uppercased() == "OK"
    }
}

// MARK: - Virtual Machines / Containers

/// A guest (QEMU VM or LXC container). Used for `/nodes/{node}/qemu` and
/// `/nodes/{node}/lxc` lists.
struct ProxmoxVM: Codable, Identifiable, Hashable {
    var id: Int { vmid }
    let vmid: Int
    let name: String?
    let status: String
    let cpu: Double?
    let cpus: Double?
    let mem: Int64?
    let maxmem: Int64?
    let disk: Int64?
    let maxdisk: Int64?
    let uptime: Int64?

    /// Not part of the API payload — assigned by the service so the UI knows
    /// which node/type this guest belongs to for control actions.
    var node: String = ""
    var type: GuestType = .qemu

    enum CodingKeys: String, CodingKey {
        case vmid, name, status, cpu, cpus, mem, maxmem, disk, maxdisk, uptime
    }

    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        return "\(type.label) \(vmid)"
    }

    var isRunning: Bool { status.lowercased() == "running" }
}

enum GuestType: String, Codable, CaseIterable {
    case qemu
    case lxc

    var label: String { self == .qemu ? "VM" : "CT" }
    var apiPath: String { rawValue }
}

/// Detailed guest status from `/status/current`.
struct VMStatus: Codable, Hashable {
    let status: String
    let cpu: Double?
    let cpus: Double?
    let mem: Int64?
    let maxmem: Int64?
    let disk: Int64?
    let maxdisk: Int64?
    let uptime: Int64?
    let name: String?

    var isRunning: Bool { status.lowercased() == "running" }
}

struct GuestConfig: Codable, Hashable {
    let name: String?
    let hostname: String?
    let description: String?
    let tags: String?
    let cores: Int?
    let sockets: Int?
    let vcpus: Int?
    let memory: Int64?
    let swap: Int64?
    let onboot: Int?
    let boot: String?
    let ostype: String?
    let agent: String?
    let unprivileged: Int?
    let rootfs: String?
    let scsi0: String?
    let virtio0: String?
    let sata0: String?
    let ide0: String?
    let net0: String?
    let net1: String?
    let mp0: String?
    let mp1: String?

    enum CodingKeys: String, CodingKey {
        case name, hostname, description, tags, cores, sockets, vcpus, memory, swap
        case onboot, boot, ostype, agent, unprivileged, rootfs
        case scsi0, virtio0, sata0, ide0, net0, net1, mp0, mp1
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        tags = try container.decodeIfPresent(String.self, forKey: .tags)
        cores = try Self.decodeInt(container, key: .cores)
        sockets = try Self.decodeInt(container, key: .sockets)
        vcpus = try Self.decodeInt(container, key: .vcpus)
        memory = try Self.decodeInt64(container, key: .memory)
        swap = try Self.decodeInt64(container, key: .swap)
        onboot = try Self.decodeInt(container, key: .onboot)
        boot = try container.decodeIfPresent(String.self, forKey: .boot)
        ostype = try container.decodeIfPresent(String.self, forKey: .ostype)
        agent = try Self.decodeString(container, key: .agent)
        unprivileged = try Self.decodeInt(container, key: .unprivileged)
        rootfs = try container.decodeIfPresent(String.self, forKey: .rootfs)
        scsi0 = try container.decodeIfPresent(String.self, forKey: .scsi0)
        virtio0 = try container.decodeIfPresent(String.self, forKey: .virtio0)
        sata0 = try container.decodeIfPresent(String.self, forKey: .sata0)
        ide0 = try container.decodeIfPresent(String.self, forKey: .ide0)
        net0 = try container.decodeIfPresent(String.self, forKey: .net0)
        net1 = try container.decodeIfPresent(String.self, forKey: .net1)
        mp0 = try container.decodeIfPresent(String.self, forKey: .mp0)
        mp1 = try container.decodeIfPresent(String.self, forKey: .mp1)
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func decodeInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}

struct GuestSnapshot: Codable, Hashable, Identifiable {
    let name: String
    let description: String?
    let snaptime: Int64?
    let parent: String?
    let vmstate: Int?

    var id: String { name }

    var isCurrent: Bool { name == "current" }
}

// MARK: - Permissions

struct ProxmoxPermissions: Codable, Hashable {
    /// PVE returns `path -> privilege -> propagate`, without an enclosing key.
    let paths: [String: [String: Bool]]

    private struct PermissionFlag: Codable {
        let value: Bool

        init(_ value: Bool) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let int = try? container.decode(Int.self) {
                value = int != 0
            } else if let string = try? container.decode(String.self) {
                value = string == "1" || string.lowercased() == "true"
            } else {
                throw DecodingError.typeMismatch(
                    Bool.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected a boolean-compatible permission flag."
                    )
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    init(paths: [String: [String: Bool]]) {
        self.paths = paths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([String: [String: PermissionFlag]].self)
        paths = decoded.mapValues { privileges in
            privileges.mapValues(\.value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(paths.mapValues { privileges in
            privileges.mapValues(PermissionFlag.init)
        })
    }

    /// Check an effective privilege on an exact path or a propagating parent.
    func hasPrivilege(_ privilege: String, on path: String) -> Bool {
        let normalized = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")

        if paths[normalized]?[privilege] != nil {
            return true
        }

        var parent = normalized
        while parent != "/" {
            guard let slash = parent.lastIndex(of: "/") else { break }
            parent = slash == parent.startIndex ? "/" : String(parent[..<slash])
            if paths[parent]?[privilege] == true {
                return true
            }
        }
        return false
    }
}

// MARK: - Storage

struct ProxmoxStorage: Codable, Identifiable, Hashable {
    let storage: String
    let type: String
    let active: Int?
    let used: Int64?
    let avail: Int64?
    let total: Int64?
    let usedFraction: Double?
    let content: String?

    var id: String { storage }

    var isAvailable: Bool { active == 1 }

    var storageTypes: [String] {
        content?.split(separator: ",").map(String.init) ?? []
    }
}

struct ProxmoxStorageStatus: Codable, Hashable {
    let used: Int64?
    let avail: Int64?
    let total: Int64?
    let active: Int?
}

struct ProxmoxStorageContent: Codable, Identifiable, Hashable {
    let volid: String
    let format: String?
    let size: Int64?
    let used: Int64?
    let content: String?
    let notes: String?
    let vmid: Int?
    let ctime: Int64?
    let protectedFlag: Int?

    var id: String { volid }

    enum CodingKeys: String, CodingKey {
        case volid, format, size, used, content, notes, vmid, ctime
        case protectedFlag = "protected"
    }

    init(
        volid: String,
        format: String?,
        size: Int64?,
        used: Int64?,
        content: String?,
        notes: String?,
        vmid: Int?,
        ctime: Int64? = nil,
        protectedFlag: Int? = nil
    ) {
        self.volid = volid
        self.format = format
        self.size = size
        self.used = used
        self.content = content
        self.notes = notes
        self.vmid = vmid
        self.ctime = ctime
        self.protectedFlag = protectedFlag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volid = try container.decode(String.self, forKey: .volid)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        used = try container.decodeIfPresent(Int64.self, forKey: .used)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        vmid = try container.decodeIfPresent(Int.self, forKey: .vmid)
        ctime = try container.decodeIfPresent(Int64.self, forKey: .ctime)
        if let value = try? container.decode(Int.self, forKey: .protectedFlag) {
            protectedFlag = value
        } else if let value = try? container.decode(Bool.self, forKey: .protectedFlag) {
            protectedFlag = value ? 1 : 0
        } else {
            protectedFlag = nil
        }
    }

    /// Friendly name extracted from volid (storage:filename).
    var displayName: String {
        if let slash = volid.firstIndex(of: "/") {
            return String(volid[volid.index(after: slash)...])
        }
        return volid
    }
}

// MARK: - Backups

struct ProxmoxBackupJob: Codable, Identifiable, Hashable {
    let id: String
    let node: String?
    let storage: String?
    let schedule: String?
    let vmid: String?
    let comment: String?
    let mode: String?
    let enabled: Bool?
    let all: Bool?

    var isEnabled: Bool { enabled != false }

    enum CodingKeys: String, CodingKey {
        case id, node, storage, schedule, vmid, comment, mode, enabled, all
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        node = try container.decodeIfPresent(String.self, forKey: .node)
        storage = try container.decodeIfPresent(String.self, forKey: .storage)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        if let value = try? container.decode(String.self, forKey: .vmid) {
            vmid = value
        } else if let value = try? container.decode(Int.self, forKey: .vmid) {
            vmid = String(value)
        } else {
            vmid = nil
        }
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        enabled = Self.decodeBool(container, key: .enabled)
        all = Self.decodeBool(container, key: .all)
    }

    private static func decodeBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return nil
    }
}

struct ProxmoxBackupFile: Identifiable, Hashable {
    let volid: String
    let storage: String
    let vmid: Int?
    let size: Int64?
    let createdAt: Int64?
    let notes: String?
    let format: String?
    let isProtected: Bool

    var id: String { volid }
}

// MARK: - Historical / RRD

struct RRDDataPoint: Codable, Hashable {
    let time: Int64
    let value: Double?
    let cpu: Double?
    let mem: Double?
    let maxmem: Double?
    let netin: Double?
    let netout: Double?
    let diskread: Double?
    let diskwrite: Double?
    let rootfs: Double?
    let maxrootfs: Double?
}

// MARK: - Guest Control Actions

enum GuestAction: String, CaseIterable, Sendable {
    case start
    case stop
    case shutdown
    case reboot

    var label: String {
        switch self {
        case .start: return String(localized: "Start")
        case .stop: return String(localized: "Stop")
        case .shutdown: return String(localized: "Shutdown")
        case .reboot: return String(localized: "Reboot")
        }
    }

    var systemImage: String {
        switch self {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .shutdown: return "power"
        case .reboot: return "arrow.clockwise"
        }
    }

    var isDestructive: Bool {
        self == .stop || self == .shutdown || self == .reboot
    }
}
