import Foundation

// MARK: - Server Configuration

/// A single Proxmox VE server the user has configured.
struct ProxmoxServer: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 8006
    var username: String
    var realm: String = "pam"
    var allowInsecureSSL: Bool = true

    var baseURL: String {
        "https://\(host):\(port)/api2/json"
    }

    var fullUsername: String {
        "\(username)@\(realm)"
    }
}

// MARK: - Authentication

/// Ticket payload returned by `/access/ticket`.
struct ProxmoxTicket: Codable {
    let ticket: String
    let csrfToken: String
    let username: String

    enum CodingKeys: String, CodingKey {
        case ticket
        case csrfToken = "CSRFPreventionToken"
        case username
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

// MARK: - Guest Control Actions

enum GuestAction: String, CaseIterable {
    case start
    case stop
    case shutdown
    case reboot

    var label: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .shutdown: return "Shutdown"
        case .reboot: return "Reboot"
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
