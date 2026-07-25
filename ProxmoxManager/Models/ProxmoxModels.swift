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
