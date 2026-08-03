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
struct ProxmoxResponse<T: Decodable>: Decodable {
    let data: T
}

/// PVE documents integer responses, but older releases and some proxies may
/// serialize them as JSON strings.
struct ProxmoxInteger: Codable, Equatable {
    let value: Int

    init(_ value: Int) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = value
        } else if let string = try? container.decode(String.self),
                  let value = Int(string) {
            self.value = value
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an integer or integer string."
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
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

struct ProxmoxNodeTask: Decodable, Identifiable, Hashable {
    let upid: String
    let idValue: String
    let node: String
    let pid: Int?
    let startTime: Int64
    let endTime: Int64?
    let status: String?
    let taskType: String
    let user: String

    var id: String { upid }
    var isRunning: Bool {
        endTime == nil && (status == nil || status?.isEmpty == true || status?.uppercased() == "RUNNING")
    }
    var succeeded: Bool { status?.uppercased() == "OK" }

    private enum CodingKeys: String, CodingKey {
        case upid, node, pid, status, user
        case idValue = "id"
        case startTime = "starttime"
        case endTime = "endtime"
        case taskType = "type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upid = try container.decode(String.self, forKey: .upid)
        idValue = try container.decodeIfPresent(String.self, forKey: .idValue) ?? ""
        node = try container.decode(String.self, forKey: .node)
        pid = container.decodeFlexibleInt(forKey: .pid)
        startTime = container.decodeFlexibleInt64(forKey: .startTime) ?? 0
        endTime = container.decodeFlexibleInt64(forKey: .endTime)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        taskType = try container.decode(String.self, forKey: .taskType)
        user = try container.decode(String.self, forKey: .user)
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

struct GuestCreateRequest: Equatable {
    let node: String
    let type: GuestType
    let vmid: Int
    let name: String
    let cores: Int
    let sockets: Int
    let memoryMiB: Int
    let onBoot: Bool
    let startAfterCreation: Bool
    let storage: String
    let diskSizeGiB: Int
    let network: GuestNetworkSettings
    let osType: String
    let installationVolume: String?
    let rootPassword: String?
    let swapMiB: Int
    let unprivileged: Bool

    var form: [String: String] {
        var values: [String: String] = [
            "vmid": "\(vmid)",
            "cores": "\(cores)",
            "memory": "\(memoryMiB)",
            "onboot": onBoot ? "1" : "0",
            "start": startAfterCreation ? "1" : "0",
        ]

        switch type {
        case .qemu:
            let isWindows = osType.hasPrefix("win")
            let disk = isWindows ? "sata0" : "scsi0"
            values["name"] = name
            values["sockets"] = "\(sockets)"
            values["ostype"] = osType
            values[disk] = "\(storage):\(diskSizeGiB)"
            values["net0"] = network.encodedValue
            if !isWindows {
                values["scsihw"] = "virtio-scsi-pci"
                values["agent"] = "enabled=1"
            }
            if let installationVolume, !installationVolume.isEmpty {
                values["ide2"] = "\(installationVolume),media=cdrom"
                values["boot"] = "order=\(disk);ide2"
            } else {
                values["boot"] = "order=\(disk)"
            }

        case .lxc:
            values["hostname"] = name
            values["ostemplate"] = installationVolume
            values["rootfs"] = "\(storage):\(diskSizeGiB)"
            values["swap"] = "\(swapMiB)"
            values["unprivileged"] = unprivileged ? "1" : "0"
            values["net0"] = network.encodedValue
            if let rootPassword, !rootPassword.isEmpty {
                values["password"] = rootPassword
            }
        }

        return values
    }
}

struct GuestCloneRequest: Equatable {
    let node: String
    let type: GuestType
    let vmid: Int
    let newVMID: Int
    let name: String
    let description: String
    let storage: String?
    let full: Bool

    var form: [String: String] {
        var values = [
            "newid": "\(newVMID)",
            "full": full ? "1" : "0",
        ]
        values[type == .qemu ? "name" : "hostname"] = name
        if !description.trimmed.isEmpty {
            values["description"] = description.trimmed
        }
        if let storage, !storage.isEmpty {
            values["storage"] = storage
        }
        return values
    }
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

struct GuestMigrationPreconditions: Decodable, Equatable {
    struct LocalDisk: Decodable, Equatable {
        let volid: String
        let size: Int64?
        let cdrom: Bool?
        let isUnused: Bool?

        enum CodingKeys: String, CodingKey {
            case volid, size, cdrom
            case isUnused = "is_unused"
        }
    }

    let allowedNodes: [String]
    let localDisks: [LocalDisk]
    let localResources: [String]
    let running: Bool?

    private enum CodingKeys: String, CodingKey {
        case allowedNodesUnderscore = "allowed_nodes"
        case allowedNodesHyphen = "allowed-nodes"
        case localDisksUnderscore = "local_disks"
        case localDisksHyphen = "local-disks"
        case localResourcesUnderscore = "local_resources"
        case localResourcesHyphen = "local-resources"
        case running
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let underscoreAllowedNodes = try container.decodeIfPresent(
            [String].self,
            forKey: .allowedNodesUnderscore
        )
        let hyphenAllowedNodes = try container.decodeIfPresent(
            [String].self,
            forKey: .allowedNodesHyphen
        )
        allowedNodes = underscoreAllowedNodes ?? hyphenAllowedNodes ?? []
        let underscoreLocalDisks = try container.decodeIfPresent(
            [LocalDisk].self,
            forKey: .localDisksUnderscore
        )
        let hyphenLocalDisks = try container.decodeIfPresent(
            [LocalDisk].self,
            forKey: .localDisksHyphen
        )
        localDisks = underscoreLocalDisks ?? hyphenLocalDisks ?? []
        let underscoreLocalResources = try container.decodeIfPresent(
            [String].self,
            forKey: .localResourcesUnderscore
        )
        let hyphenLocalResources = try container.decodeIfPresent(
            [String].self,
            forKey: .localResourcesHyphen
        )
        localResources = underscoreLocalResources ?? hyphenLocalResources ?? []
        if let value = try? container.decode(Bool.self, forKey: .running) {
            running = value
        } else if let value = try? container.decode(Int.self, forKey: .running) {
            running = value != 0
        } else {
            running = nil
        }
    }
}

struct GuestConfig: Decodable, Hashable {
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
    let rawValues: [String: String]

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

        let rawContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: String] = [:]
        for key in rawContainer.allKeys {
            if let value = try? rawContainer.decode(String.self, forKey: key) {
                values[key.stringValue] = value
            } else if let value = try? rawContainer.decode(Int64.self, forKey: key) {
                values[key.stringValue] = String(value)
            } else if let value = try? rawContainer.decode(Double.self, forKey: key) {
                values[key.stringValue] = String(value)
            } else if let value = try? rawContainer.decode(Bool.self, forKey: key) {
                values[key.stringValue] = value ? "1" : "0"
            }
        }
        rawValues = values
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

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct GuestHardwareDisk: Identifiable, Hashable {
    let key: String
    let value: String

    var id: String { key }

    var size: String? {
        guard let component = value.split(separator: ",")
            .map(String.init)
            .first(where: { $0.hasPrefix("size=") }) else {
            return nil
        }
        return String(component.dropFirst("size=".count))
    }
}

extension GuestConfig {
    func disks(for type: GuestType) -> [GuestHardwareDisk] {
        rawValues.compactMap { key, value in
            let isDisk: Bool
            if type == .qemu {
                isDisk = key.range(
                    of: #"^(scsi|virtio|sata|ide)\d+$"#,
                    options: .regularExpression
                ) != nil &&
                    !value.contains("media=cdrom") &&
                    !value.lowercased().contains("cloudinit")
            } else {
                isDisk = key == "rootfs" ||
                    key.range(of: #"^mp\d+$"#, options: .regularExpression) != nil
            }
            return isDisk ? GuestHardwareDisk(key: key, value: value) : nil
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    var networks: [GuestHardwareNetwork] {
        rawValues.compactMap { key, value in
            guard key.range(of: #"^net\d+$"#, options: .regularExpression) != nil else {
                return nil
            }
            return GuestHardwareNetwork(key: key, value: value)
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}

struct GuestHardwareNetwork: Identifiable, Hashable {
    let key: String
    let value: String

    var id: String { key }
}

struct GuestNetworkSettings: Equatable {
    enum IPMode: String, CaseIterable, Identifiable {
        case unspecified
        case dhcp
        case automatic
        case manual
        case `static`

        var id: String { rawValue }
    }

    let type: GuestType
    var model = "virtio"
    var interfaceName: String
    var bridge = "vmbr0"
    var vlanTag = ""
    var macAddress = ""
    var firewall = false
    var rateLimit = ""
    var mtu = ""
    var queues = ""
    var linkDown = false
    var trunks = ""
    var ipv4Mode: IPMode = .unspecified
    var ipv4Address = ""
    var ipv4Gateway = ""
    var ipv6Mode: IPMode = .unspecified
    var ipv6Address = ""
    var ipv6Gateway = ""
    private var preservedComponents: [String] = []

    init(type: GuestType, value: String? = nil, interfaceName: String = "eth0") {
        self.type = type
        self.interfaceName = interfaceName

        guard let value, !value.isEmpty else {
            if type == .lxc {
                ipv4Mode = .dhcp
            }
            return
        }

        var components = value.split(separator: ",").map(String.init)
        if type == .qemu, let first = components.first {
            let pair = first.split(separator: "=", maxSplits: 1).map(String.init)
            let knownModels = Set(["e1000", "e1000e", "e1000-82540em", "e1000-82544gc", "e1000-82545em",
                                   "i82551", "i82557b", "i82559er", "ne2k_isa", "ne2k_pci",
                                   "pcnet", "rtl8139", "virtio", "vmxnet3"])
            if knownModels.contains(pair[0]) {
                model = pair[0]
                if pair.count > 1 {
                    macAddress = pair[1]
                }
                components.removeFirst()
            }
        }

        if type == .qemu {
            model = Self.value(for: "model", in: components) ?? model
            if macAddress.isEmpty {
                macAddress = Self.value(for: "macaddr", in: components) ?? ""
            }
        } else {
            self.interfaceName = Self.value(for: "name", in: components) ?? interfaceName
            macAddress = Self.value(for: "hwaddr", in: components) ?? ""
        }

        bridge = Self.value(for: "bridge", in: components) ?? bridge
        vlanTag = Self.value(for: "tag", in: components) ?? ""
        firewall = Self.value(for: "firewall", in: components) == "1"
        rateLimit = Self.value(for: "rate", in: components) ?? ""
        mtu = Self.value(for: "mtu", in: components) ?? ""
        queues = Self.value(for: "queues", in: components) ?? ""
        linkDown = Self.value(for: "link_down", in: components) == "1"
        trunks = Self.value(for: "trunks", in: components) ?? ""

        if type == .lxc {
            (ipv4Mode, ipv4Address) = Self.parseAddress(
                Self.value(for: "ip", in: components),
                supportsAutomatic: false
            )
            ipv4Gateway = Self.value(for: "gw", in: components) ?? ""
            (ipv6Mode, ipv6Address) = Self.parseAddress(
                Self.value(for: "ip6", in: components),
                supportsAutomatic: true
            )
            ipv6Gateway = Self.value(for: "gw6", in: components) ?? ""
        }

        let exposed = type == .qemu
            ? Set(["model", "macaddr", "bridge", "tag", "firewall", "rate", "mtu",
                   "queues", "link_down", "trunks"])
            : Set(["name", "type", "hwaddr", "bridge", "tag", "firewall", "rate", "mtu",
                   "link_down", "trunks", "ip", "gw", "ip6", "gw6"])
        preservedComponents = components.filter {
            guard let key = $0.split(separator: "=", maxSplits: 1).first else { return true }
            return !exposed.contains(String(key))
        }
    }

    var isValid: Bool {
        !bridge.trimmed.isEmpty &&
        (type == .qemu || !interfaceName.trimmed.isEmpty) &&
        Self.isValidMAC(macAddress) &&
        Self.isValidInteger(vlanTag, range: 1...4094) &&
        Self.isValidNonnegativeDecimal(rateLimit) &&
        Self.isValidInteger(mtu, range: type == .qemu ? 1...65520 : 64...65535) &&
        (type == .lxc || Self.isValidInteger(queues, range: 0...64)) &&
        Self.isValidVLANTrunks(trunks) &&
        (type == .qemu || isValidContainerAddresses)
    }

    var encodedValue: String {
        var components: [String]
        if type == .qemu {
            components = [macAddress.trimmed.isEmpty
                ? model
                : "\(model)=\(macAddress.trimmed.uppercased())"]
        } else {
            components = [
                "name=\(interfaceName.trimmed)",
                "type=veth",
            ]
            if !macAddress.trimmed.isEmpty {
                components.append("hwaddr=\(macAddress.trimmed.uppercased())")
            }
        }

        components.append("bridge=\(bridge.trimmed)")
        Self.append("tag", value: vlanTag, to: &components)
        if firewall { components.append("firewall=1") }
        Self.append("rate", value: rateLimit, to: &components)
        Self.append("mtu", value: mtu, to: &components)
        if type == .qemu {
            Self.append("queues", value: queues, to: &components)
        }
        if linkDown { components.append("link_down=1") }
        Self.append("trunks", value: trunks, to: &components)

        if type == .lxc {
            Self.appendAddress("ip", mode: ipv4Mode, address: ipv4Address, to: &components)
            if ipv4Mode == .static {
                Self.append("gw", value: ipv4Gateway, to: &components)
            }
            Self.appendAddress("ip6", mode: ipv6Mode, address: ipv6Address, to: &components)
            if ipv6Mode == .static {
                Self.append("gw6", value: ipv6Gateway, to: &components)
            }
        }

        components.append(contentsOf: preservedComponents)
        return components.joined(separator: ",")
    }

    private var isValidContainerAddresses: Bool {
        let ipv4Valid = ipv4Mode != .automatic &&
            (ipv4Mode != .static || Self.isValidCIDR(ipv4Address, ipv6: false)) &&
            (ipv4Mode != .static || ipv4Gateway.trimmed.isEmpty ||
                Self.isValidIPAddress(ipv4Gateway, ipv6: false))
        let ipv6Valid =
            (ipv6Mode != .static || Self.isValidCIDR(ipv6Address, ipv6: true)) &&
            (ipv6Mode != .static || ipv6Gateway.trimmed.isEmpty ||
                Self.isValidIPAddress(ipv6Gateway, ipv6: true))
        return ipv4Valid && ipv6Valid
    }

    private static func parseAddress(
        _ value: String?,
        supportsAutomatic: Bool
    ) -> (IPMode, String) {
        guard let value, !value.isEmpty else { return (.unspecified, "") }
        switch value {
        case "dhcp": return (.dhcp, "")
        case "auto" where supportsAutomatic: return (.automatic, "")
        case "manual": return (.manual, "")
        default: return (.static, value)
        }
    }

    private static func value(for key: String, in components: [String]) -> String? {
        components.first(where: { $0.hasPrefix("\(key)=") })
            .map { String($0.dropFirst(key.count + 1)) }
    }

    private static func append(_ key: String, value: String, to components: inout [String]) {
        let value = value.trimmed
        if !value.isEmpty {
            components.append("\(key)=\(value)")
        }
    }

    private static func appendAddress(
        _ key: String,
        mode: IPMode,
        address: String,
        to components: inout [String]
    ) {
        switch mode {
        case .unspecified:
            break
        case .dhcp:
            components.append("\(key)=dhcp")
        case .automatic:
            components.append("\(key)=auto")
        case .manual:
            components.append("\(key)=manual")
        case .static:
            append(key, value: address, to: &components)
        }
    }

    private static func isValidMAC(_ value: String) -> Bool {
        value.trimmed.isEmpty ||
        value.trimmed.range(
            of: #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isValidNonnegativeDecimal(_ value: String) -> Bool {
        value.trimmed.isEmpty || (Double(value.trimmed).map { $0 >= 0 } == true)
    }

    private static func isValidInteger(_ value: String, range: ClosedRange<Int>) -> Bool {
        value.trimmed.isEmpty || (Int(value.trimmed).map(range.contains) == true)
    }

    private static func isValidVLANTrunks(_ value: String) -> Bool {
        value.trimmed.isEmpty || value.split(separator: ";").allSatisfy {
            Int($0).map { (1...4094).contains($0) } == true
        }
    }

    private static func isValidCIDR(_ value: String, ipv6: Bool) -> Bool {
        let pieces = value.trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              isValidIPAddress(pieces[0], ipv6: ipv6),
              let prefix = Int(pieces[1]) else {
            return false
        }
        return (ipv6 ? 0...128 : 0...32).contains(prefix)
    }

    private static func isValidIPAddress(_ value: String, ipv6: Bool) -> Bool {
        let value = value.trimmed
        if ipv6 {
            return value.contains(":") &&
                value.range(of: #"^[0-9A-Fa-f:.]+$"#, options: .regularExpression) != nil
        }
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            guard let number = Int($0) else { return false }
            return (0...255).contains(number)
        }
    }
}

struct CloudInitNetworkSettings: Identifiable, Equatable {
    let index: Int
    var ipv4Mode: GuestNetworkSettings.IPMode = .unspecified
    var ipv4Address = ""
    var ipv4Gateway = ""
    var ipv6Mode: GuestNetworkSettings.IPMode = .unspecified
    var ipv6Address = ""
    var ipv6Gateway = ""
    private var preservedComponents: [String] = []

    var id: Int { index }

    init(index: Int, value: String?) {
        self.index = index
        guard let value, !value.isEmpty else { return }
        let components = value.split(separator: ",").map(String.init)
        (ipv4Mode, ipv4Address) = Self.parseAddress(Self.value(for: "ip", in: components), ipv6: false)
        ipv4Gateway = Self.value(for: "gw", in: components) ?? ""
        (ipv6Mode, ipv6Address) = Self.parseAddress(Self.value(for: "ip6", in: components), ipv6: true)
        ipv6Gateway = Self.value(for: "gw6", in: components) ?? ""
        let exposed = Set(["ip", "gw", "ip6", "gw6"])
        preservedComponents = components.filter {
            guard let key = $0.split(separator: "=", maxSplits: 1).first else { return true }
            return !exposed.contains(String(key))
        }
    }

    var encodedValue: String? {
        var components: [String] = []
        Self.appendAddress("ip", mode: ipv4Mode, address: ipv4Address, to: &components)
        if ipv4Mode == .static {
            Self.append("gw", value: ipv4Gateway, to: &components)
        }
        Self.appendAddress("ip6", mode: ipv6Mode, address: ipv6Address, to: &components)
        if ipv6Mode == .static {
            Self.append("gw6", value: ipv6Gateway, to: &components)
        }
        components.append(contentsOf: preservedComponents)
        return components.isEmpty ? nil : components.joined(separator: ",")
    }

    var isValid: Bool {
        ipv4Mode != .automatic &&
        (ipv4Mode != .static || Self.isValidCIDR(ipv4Address, ipv6: false)) &&
        (ipv4Mode != .static || ipv4Gateway.trimmed.isEmpty ||
            Self.isValidIPAddress(ipv4Gateway, ipv6: false)) &&
        (ipv6Mode != .static || Self.isValidCIDR(ipv6Address, ipv6: true)) &&
        (ipv6Mode != .static || ipv6Gateway.trimmed.isEmpty ||
            Self.isValidIPAddress(ipv6Gateway, ipv6: true))
    }

    private static func parseAddress(
        _ value: String?,
        ipv6: Bool
    ) -> (GuestNetworkSettings.IPMode, String) {
        guard let value, !value.isEmpty else { return (.unspecified, "") }
        switch value {
        case "dhcp": return (.dhcp, "")
        case "auto" where ipv6: return (.automatic, "")
        default: return (.static, value)
        }
    }

    private static func value(for key: String, in components: [String]) -> String? {
        components.first(where: { $0.hasPrefix("\(key)=") })
            .map { String($0.dropFirst(key.count + 1)) }
    }

    private static func append(_ key: String, value: String, to components: inout [String]) {
        let value = value.trimmed
        if !value.isEmpty {
            components.append("\(key)=\(value)")
        }
    }

    private static func appendAddress(
        _ key: String,
        mode: GuestNetworkSettings.IPMode,
        address: String,
        to components: inout [String]
    ) {
        switch mode {
        case .unspecified, .manual:
            break
        case .dhcp:
            components.append("\(key)=dhcp")
        case .automatic:
            components.append("\(key)=auto")
        case .static:
            append(key, value: address, to: &components)
        }
    }

    private static func isValidCIDR(_ value: String, ipv6: Bool) -> Bool {
        let pieces = value.trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              isValidIPAddress(pieces[0], ipv6: ipv6),
              let prefix = Int(pieces[1]) else {
            return false
        }
        return (ipv6 ? 0...128 : 0...32).contains(prefix)
    }

    private static func isValidIPAddress(_ value: String, ipv6: Bool) -> Bool {
        let value = value.trimmed
        if ipv6 {
            return value.contains(":") &&
                value.range(of: #"^[0-9A-Fa-f:.]+$"#, options: .regularExpression) != nil
        }
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            guard let number = Int($0) else { return false }
            return (0...255).contains(number)
        }
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
    let enabled: Int?
    let used: Int64?
    let avail: Int64?
    let total: Int64?
    let usedFraction: Double?
    let content: String?

    var id: String { storage }

    var isAvailable: Bool {
        (active ?? 1) != 0 && (enabled ?? 1) != 0
    }

    var storageTypes: [String] {
        content?.split(separator: ",").map(String.init) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case storage, type, active, enabled, used, avail, total, content
        case usedFraction = "used_fraction"
    }

    init(
        storage: String,
        type: String,
        active: Int?,
        enabled: Int? = nil,
        used: Int64?,
        avail: Int64?,
        total: Int64?,
        usedFraction: Double?,
        content: String?
    ) {
        self.storage = storage
        self.type = type
        self.active = active
        self.enabled = enabled
        self.used = used
        self.avail = avail
        self.total = total
        self.usedFraction = usedFraction
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storage = try container.decode(String.self, forKey: .storage)
        type = try container.decode(String.self, forKey: .type)
        active = container.decodeFlexibleInt(forKey: .active)
        enabled = container.decodeFlexibleInt(forKey: .enabled)
        used = container.decodeFlexibleInt64(forKey: .used)
        avail = container.decodeFlexibleInt64(forKey: .avail)
        total = container.decodeFlexibleInt64(forKey: .total)
        usedFraction = container.decodeFlexibleDouble(forKey: .usedFraction)
        content = try container.decodeIfPresent(String.self, forKey: .content)
    }
}

struct ProxmoxStorageStatus: Codable, Hashable {
    let used: Int64?
    let avail: Int64?
    let total: Int64?
    let active: Int?

    enum CodingKeys: String, CodingKey {
        case used, avail, total, active
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used = container.decodeFlexibleInt64(forKey: .used)
        avail = container.decodeFlexibleInt64(forKey: .avail)
        total = container.decodeFlexibleInt64(forKey: .total)
        active = container.decodeFlexibleInt(forKey: .active)
    }
}

struct ProxmoxStorageContent: Codable, Identifiable, Hashable {
    let volid: String
    let format: String?
    let size: Int64?
    let used: Int64?
    var content: String?
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
        size = container.decodeFlexibleInt64(forKey: .size)
        used = container.decodeFlexibleInt64(forKey: .used)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        vmid = container.decodeFlexibleInt(forKey: .vmid)
        ctime = container.decodeFlexibleInt64(forKey: .ctime)
        protectedFlag = container.decodeFlexibleInt(forKey: .protectedFlag)
    }

    /// Friendly name extracted from volid (storage:filename).
    var displayName: String {
        if let slash = volid.firstIndex(of: "/") {
            return String(volid[volid.index(after: slash)...])
        }
        return volid
    }
}

struct ApplianceTemplate: Codable, Identifiable, Hashable {
    let template: String
    let type: String?
    let package: String?
    let version: String?
    let headline: String?
    let infopage: String?
    let description: String?
    let os: String?
    let section: String?

    var id: String { template }

    var displayName: String {
        if let package, !package.isEmpty {
            return package
        }
        return template
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value ? 1 : 0
        }
        if let value = try? decode(String.self, forKey: key) {
            if let integer = Int(value) {
                return integer
            }
            if value.lowercased() == "true" {
                return 1
            }
            if value.lowercased() == "false" {
                return 0
            }
        }
        return nil
    }

    func decodeFlexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value)
        }
        return nil
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
    let compress: String?
    let pruneBackups: String?
    let remove: Bool?
    let protectedBackups: Bool?
    let repeatMissed: Bool?
    let nextRun: Int64?
    let notesTemplate: String?

    var isEnabled: Bool { enabled != false }

    enum CodingKeys: String, CodingKey {
        case id, node, storage, schedule, vmid, comment, mode, enabled, all, compress, remove
        case pruneBackups = "prune-backups"
        case protectedBackups = "protected"
        case repeatMissed = "repeat-missed"
        case nextRun = "next-run"
        case notesTemplate = "notes-template"
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
        compress = try container.decodeIfPresent(String.self, forKey: .compress)
        if let value = try? container.decode(String.self, forKey: .pruneBackups) {
            pruneBackups = value
        } else if let object = try? container.nestedContainer(
            keyedBy: DynamicCodingKey.self,
            forKey: .pruneBackups
        ) {
            pruneBackups = object.allKeys.sorted { $0.stringValue < $1.stringValue }
                .compactMap { key in
                    if let value = try? object.decode(Int.self, forKey: key) {
                        return "\(key.stringValue)=\(value)"
                    }
                    if let value = try? object.decode(Bool.self, forKey: key) {
                        return "\(key.stringValue)=\(value ? 1 : 0)"
                    }
                    if let value = try? object.decode(String.self, forKey: key) {
                        return "\(key.stringValue)=\(value)"
                    }
                    return nil
                }
                .joined(separator: ",")
        } else {
            pruneBackups = nil
        }
        remove = Self.decodeBool(container, key: .remove)
        protectedBackups = Self.decodeBool(container, key: .protectedBackups)
        repeatMissed = Self.decodeBool(container, key: .repeatMissed)
        nextRun = container.decodeFlexibleInt64(forKey: .nextRun)
        notesTemplate = try container.decodeIfPresent(String.self, forKey: .notesTemplate)
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

// MARK: - Node Maintenance / Native Console

struct ProxmoxNodeService: Decodable, Identifiable, Hashable {
    let service: String
    let name: String?
    let description: String?
    let state: String?
    let activeState: String?
    let unitState: String?

    var id: String { service }
    var isRunning: Bool {
        activeState == "active" || state == "running"
    }

    private enum CodingKeys: String, CodingKey {
        case service, name, state
        case description = "desc"
        case activeState = "active-state"
        case unitState = "unit-state"
    }
}

struct ProxmoxPackageUpdate: Decodable, Identifiable, Hashable {
    let package: String
    let title: String?
    let description: String?
    let currentVersion: String?
    let version: String?
    let origin: String?
    let priority: String?

    var id: String { package }

    private enum CodingKeys: String, CodingKey {
        case version = "Version"
        case package = "Package"
        case title = "Title"
        case description = "Description"
        case currentVersion = "OldVersion"
        case origin = "Origin"
        case priority = "Priority"
    }
}

struct ProxmoxPCIDevice: Decodable, Identifiable, Hashable {
    let id: String
    let vendorName: String?
    let deviceName: String?
    let iommuGroup: Int?
    let mediatedDeviceCapable: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case vendorName = "vendor_name"
        case deviceName = "device_name"
        case iommuGroup = "iommugroup"
        case mediatedDeviceCapable = "mdev"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        vendorName = try container.decodeIfPresent(String.self, forKey: .vendorName)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        iommuGroup = container.decodeFlexibleInt(forKey: .iommuGroup)
        mediatedDeviceCapable = (container.decodeFlexibleInt(forKey: .mediatedDeviceCapable) ?? 0) != 0
    }
}

struct ProxmoxUSBDevice: Decodable, Identifiable, Hashable {
    let busNumber: Int
    let deviceNumber: Int
    let port: Int
    let vendorID: String
    let productID: String
    let manufacturer: String?
    let product: String?
    let serial: String?

    var id: String { "\(busNumber)-\(deviceNumber)-\(port)" }
    var selector: String { "host=\(vendorID):\(productID)" }

    private enum CodingKeys: String, CodingKey {
        case port, manufacturer, product, serial
        case busNumber = "busnum"
        case deviceNumber = "devnum"
        case vendorID = "vendid"
        case productID = "prodid"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        busNumber = container.decodeFlexibleInt(forKey: .busNumber) ?? 0
        deviceNumber = container.decodeFlexibleInt(forKey: .deviceNumber) ?? 0
        port = container.decodeFlexibleInt(forKey: .port) ?? 0
        vendorID = try container.decode(String.self, forKey: .vendorID)
        productID = try container.decode(String.self, forKey: .productID)
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer)
        product = try container.decodeIfPresent(String.self, forKey: .product)
        serial = try container.decodeIfPresent(String.self, forKey: .serial)
    }
}

struct ProxmoxConsoleProxy: Decodable, Hashable {
    let user: String
    let ticket: String
    let port: Int
    let upid: String
    let password: String?

    private enum CodingKeys: String, CodingKey {
        case user, ticket, port, upid, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(String.self, forKey: .user)
        ticket = try container.decode(String.self, forKey: .ticket)
        port = container.decodeFlexibleInt(forKey: .port) ?? 0
        upid = try container.decode(String.self, forKey: .upid)
        password = try container.decodeIfPresent(String.self, forKey: .password)
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

    var guestType: GuestType {
        let value = volid.lowercased()
        return value.contains("vzdump-lxc") || value.contains("/ct/")
            ? .lxc
            : .qemu
    }
}

// MARK: - Guest Firewall

struct GuestFirewallRule: Decodable, Identifiable, Hashable {
    let pos: Int
    let type: String
    let action: String
    let enabled: Bool
    let source: String?
    let destination: String?
    let protocolName: String?
    let sourcePort: String?
    let destinationPort: String?
    let interface: String?
    let logLevel: String?
    let macro: String?
    let comment: String?

    var id: Int { pos }

    enum CodingKeys: String, CodingKey {
        case pos, type, action, source, iface, log, macro, comment, enable, proto
        case destination = "dest"
        case sourcePort = "sport"
        case destinationPort = "dport"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pos = container.decodeFlexibleInt(forKey: .pos) ?? 0
        type = try container.decode(String.self, forKey: .type)
        action = try container.decode(String.self, forKey: .action)
        enabled = (container.decodeFlexibleInt(forKey: .enable) ?? 1) != 0
        source = try container.decodeIfPresent(String.self, forKey: .source)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        protocolName = try container.decodeIfPresent(String.self, forKey: .proto)
        sourcePort = try container.decodeIfPresent(String.self, forKey: .sourcePort)
        destinationPort = try container.decodeIfPresent(String.self, forKey: .destinationPort)
        interface = try container.decodeIfPresent(String.self, forKey: .iface)
        logLevel = try container.decodeIfPresent(String.self, forKey: .log)
        macro = try container.decodeIfPresent(String.self, forKey: .macro)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
    }
}

struct GuestFirewallOptions: Decodable, Equatable {
    let enabled: Bool
    let inputPolicy: String
    let outputPolicy: String
    let dhcp: Bool
    let ipFilter: Bool
    let macFilter: Bool
    let ndp: Bool
    let routerAdvertisement: Bool
    let inputLogLevel: String
    let outputLogLevel: String

    private enum CodingKeys: String, CodingKey {
        case enable, dhcp, ipfilter, macfilter, ndp, radv
        case inputPolicy = "policy_in"
        case outputPolicy = "policy_out"
        case inputLogLevel = "log_level_in"
        case outputLogLevel = "log_level_out"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (container.decodeFlexibleInt(forKey: .enable) ?? 0) != 0
        inputPolicy = try container.decodeIfPresent(String.self, forKey: .inputPolicy) ?? "DROP"
        outputPolicy = try container.decodeIfPresent(String.self, forKey: .outputPolicy) ?? "ACCEPT"
        dhcp = (container.decodeFlexibleInt(forKey: .dhcp) ?? 0) != 0
        ipFilter = (container.decodeFlexibleInt(forKey: .ipfilter) ?? 0) != 0
        macFilter = (container.decodeFlexibleInt(forKey: .macfilter) ?? 1) != 0
        ndp = (container.decodeFlexibleInt(forKey: .ndp) ?? 1) != 0
        routerAdvertisement = (container.decodeFlexibleInt(forKey: .radv) ?? 0) != 0
        inputLogLevel = try container.decodeIfPresent(String.self, forKey: .inputLogLevel) ?? "nolog"
        outputLogLevel = try container.decodeIfPresent(String.self, forKey: .outputLogLevel) ?? "nolog"
    }
}

struct GuestFirewallIPSet: Decodable, Identifiable, Hashable {
    let name: String
    let comment: String?

    var id: String { name }
}

struct GuestFirewallIPSetEntry: Decodable, Identifiable, Hashable {
    let cidr: String
    let comment: String?
    let nomatch: Bool

    var id: String { cidr }

    private enum CodingKeys: String, CodingKey {
        case cidr, comment, nomatch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cidr = try container.decode(String.self, forKey: .cidr)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        nomatch = (container.decodeFlexibleInt(forKey: .nomatch) ?? 0) != 0
    }
}

struct FirewallSecurityGroup: Decodable, Identifiable, Hashable {
    let group: String
    let comment: String?

    var id: String { group }
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
