import Foundation

// MARK: - Alerts

enum ProxmoxAlertSeverity: String, Codable, CaseIterable {
    case info
    case warning
    case critical
}

struct ProxmoxAlert: Identifiable, Codable, Hashable {
    let id: String
    let serverID: UUID
    let severity: ProxmoxAlertSeverity
    let title: String
    let message: String
    let source: String
    let createdAt: Date
    var acknowledged: Bool
}

// MARK: - HA and replication

struct ProxmoxHAStatus: Decodable, Identifiable, Hashable {
    let rawID: String?
    let sid: String?
    let node: String?
    let type: String?
    let state: String?
    let status: String?
    let requestState: String?
    let crmState: String?
    let quorate: Bool?
    let timestamp: Int64?

    var id: String { sid ?? rawID ?? "\(type ?? "status"):\(node ?? "cluster")" }

    private enum CodingKeys: String, CodingKey {
        case rawID = "id"
        case sid, node, type, state, status, quorate, timestamp
        case requestState = "request_state"
        case crmState = "crm_state"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawID = try container.decodeIfPresent(String.self, forKey: .rawID)
        sid = try container.decodeIfPresent(String.self, forKey: .sid)
        node = try container.decodeIfPresent(String.self, forKey: .node)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        requestState = try container.decodeIfPresent(String.self, forKey: .requestState)
        crmState = try container.decodeIfPresent(String.self, forKey: .crmState)
        quorate = container.decodeFlexibleBool(forKey: .quorate)
        timestamp = container.decodeFlexibleInt64(forKey: .timestamp)
    }
}

struct ProxmoxHAResource: Decodable, Identifiable, Hashable {
    let sid: String
    let type: String?
    let state: String?
    let group: String?
    let comment: String?
    let maxRestart: Int?
    let maxRelocate: Int?
    let failback: Bool?
    let autoRebalance: Bool?

    var id: String { sid }

    private enum CodingKeys: String, CodingKey {
        case sid, type, state, group, comment
        case maxRestart = "max_restart"
        case maxRelocate = "max_relocate"
        case failback
        case autoRebalance = "auto-rebalance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sid = try container.decode(String.self, forKey: .sid)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        maxRestart = container.decodeFlexibleInt(forKey: .maxRestart)
        maxRelocate = container.decodeFlexibleInt(forKey: .maxRelocate)
        failback = container.decodeFlexibleBool(forKey: .failback)
        autoRebalance = container.decodeFlexibleBool(forKey: .autoRebalance)
    }
}

struct ProxmoxHAGroup: Decodable, Identifiable, Hashable {
    let group: String
    let nodes: String?
    let comment: String?
    let restricted: Bool?
    let noFailback: Bool?

    var id: String { group }

    private enum CodingKeys: String, CodingKey {
        case group, nodes, comment, restricted, nofailback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decode(String.self, forKey: .group)
        nodes = try container.decodeIfPresent(String.self, forKey: .nodes)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        restricted = container.decodeFlexibleBool(forKey: .restricted)
        noFailback = container.decodeFlexibleBool(forKey: .nofailback)
    }
}

struct ProxmoxReplicationJob: Decodable, Identifiable, Hashable {
    let id: String
    let guest: Int?
    let source: String?
    let target: String?
    let schedule: String?
    let rate: Double?
    let comment: String?
    let disabled: Bool
    let removeJob: String?

    private enum CodingKeys: String, CodingKey {
        case id, guest, source, target, schedule, rate, comment
        case disabled = "disable"
        case removeJob = "remove_job"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guest = container.decodeFlexibleInt(forKey: .guest)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        rate = container.decodeFlexibleDouble(forKey: .rate)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        disabled = container.decodeFlexibleBool(forKey: .disabled) ?? false
        removeJob = (try? container.decodeIfPresent(String.self, forKey: .removeJob)) ??
            container.decodeFlexibleInt(forKey: .removeJob).map { String($0) }
    }
}

// MARK: - Access control

struct ProxmoxAccessUser: Decodable, Identifiable, Hashable {
    let userid: String
    let email: String?
    let firstname: String?
    let lastname: String?
    let comment: String?
    let groups: [String]
    let enabled: Bool
    let expire: Int64?
    let realmType: String?

    var id: String { userid }
    var displayName: String {
        let name = [firstname, lastname].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? userid : name
    }

    private enum CodingKeys: String, CodingKey {
        case userid, email, firstname, lastname, comment, groups, expire
        case enabled = "enable"
        case realmType = "realm-type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userid = try container.decode(String.self, forKey: .userid)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        firstname = try container.decodeIfPresent(String.self, forKey: .firstname)
        lastname = try container.decodeIfPresent(String.self, forKey: .lastname)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        if let values = try? container.decode([String].self, forKey: .groups) {
            groups = values
        } else {
            groups = (try? container.decode(String.self, forKey: .groups))?
                .split(separator: ",").map(String.init) ?? []
        }
        enabled = container.decodeFlexibleBool(forKey: .enabled) ?? true
        expire = container.decodeFlexibleInt64(forKey: .expire)
        realmType = try container.decodeIfPresent(String.self, forKey: .realmType)
    }
}

struct ProxmoxAPIToken: Decodable, Identifiable, Hashable {
    let tokenid: String
    let comment: String?
    let expire: Int64?
    let privilegeSeparation: Bool

    var id: String { tokenid }

    private enum CodingKeys: String, CodingKey {
        case tokenid, comment, expire
        case privilegeSeparation = "privsep"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokenid = try container.decode(String.self, forKey: .tokenid)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        expire = container.decodeFlexibleInt64(forKey: .expire)
        privilegeSeparation = container.decodeFlexibleBool(forKey: .privilegeSeparation) ?? true
    }
}

struct ProxmoxAPITokenSecret: Decodable, Hashable {
    let fullTokenID: String
    let value: String
    let comment: String?
    let expire: Int64?
    let privilegeSeparation: Bool?

    private enum CodingKeys: String, CodingKey {
        case value, comment, expire
        case fullTokenID = "full-tokenid"
        case privilegeSeparation = "privsep"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fullTokenID = try container.decode(String.self, forKey: .fullTokenID)
        value = try container.decode(String.self, forKey: .value)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        expire = container.decodeFlexibleInt64(forKey: .expire)
        privilegeSeparation = container.decodeFlexibleBool(forKey: .privilegeSeparation)
    }
}

struct ProxmoxRole: Decodable, Identifiable, Hashable {
    let roleid: String
    let privileges: [String]
    let special: Bool

    var id: String { roleid }

    private enum CodingKeys: String, CodingKey {
        case roleid, special
        case privileges = "privs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleid = try container.decode(String.self, forKey: .roleid)
        if let values = try? container.decode([String].self, forKey: .privileges) {
            privileges = values
        } else {
            privileges = (try? container.decode(String.self, forKey: .privileges))?
                .split(separator: ",").map(String.init) ?? []
        }
        special = container.decodeFlexibleBool(forKey: .special) ?? false
    }
}

struct ProxmoxACLEntry: Decodable, Identifiable, Hashable {
    let path: String
    let roleid: String
    let type: String
    let ugid: String
    let propagate: Bool

    var id: String { "\(path)|\(roleid)|\(type)|\(ugid)" }

    private enum CodingKeys: String, CodingKey {
        case path, roleid, type, ugid, propagate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        roleid = try container.decode(String.self, forKey: .roleid)
        type = try container.decode(String.self, forKey: .type)
        ugid = try container.decode(String.self, forKey: .ugid)
        propagate = container.decodeFlexibleBool(forKey: .propagate) ?? true
    }
}

// MARK: - Cluster infrastructure

struct ProxmoxNetworkInterface: Decodable, Identifiable, Hashable {
    let iface: String
    let type: String?
    let active: Bool
    let autostart: Bool
    let cidr: String?
    let cidr6: String?
    let gateway: String?
    let gateway6: String?
    let bridgePorts: String?
    let bridgeVLANAwareness: Bool
    let bondMode: String?
    let slaves: String?
    let vlanID: Int?
    let vlanRawDevice: String?
    let mtu: Int?
    let comments: String?

    var id: String { iface }

    private enum CodingKeys: String, CodingKey {
        case iface, type, active, autostart, cidr, cidr6, gateway, gateway6, slaves, mtu, comments
        case bridgePorts = "bridge_ports"
        case bridgeVLANAwareness = "bridge_vlan_aware"
        case bondMode = "bond_mode"
        case vlanID = "vlan-id"
        case vlanRawDevice = "vlan-raw-device"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iface = try container.decode(String.self, forKey: .iface)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        active = container.decodeFlexibleBool(forKey: .active) ?? false
        autostart = container.decodeFlexibleBool(forKey: .autostart) ?? false
        cidr = try container.decodeIfPresent(String.self, forKey: .cidr)
        cidr6 = try container.decodeIfPresent(String.self, forKey: .cidr6)
        gateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        gateway6 = try container.decodeIfPresent(String.self, forKey: .gateway6)
        bridgePorts = try container.decodeIfPresent(String.self, forKey: .bridgePorts)
        bridgeVLANAwareness = container.decodeFlexibleBool(forKey: .bridgeVLANAwareness) ?? false
        bondMode = try container.decodeIfPresent(String.self, forKey: .bondMode)
        slaves = try container.decodeIfPresent(String.self, forKey: .slaves)
        vlanID = container.decodeFlexibleInt(forKey: .vlanID)
        vlanRawDevice = try container.decodeIfPresent(String.self, forKey: .vlanRawDevice)
        mtu = container.decodeFlexibleInt(forKey: .mtu)
        comments = try container.decodeIfPresent(String.self, forKey: .comments)
    }
}

struct ProxmoxStorageConfig: Decodable, Identifiable, Hashable {
    let storage: String
    let type: String?
    let content: String?
    let nodes: String?
    let path: String?
    let server: String?
    let pool: String?
    let disable: Bool
    let shared: Bool

    var id: String { storage }

    private enum CodingKeys: String, CodingKey {
        case storage, type, content, nodes, path, server, pool, disable, shared
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storage = try container.decode(String.self, forKey: .storage)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        nodes = try container.decodeIfPresent(String.self, forKey: .nodes)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        server = try container.decodeIfPresent(String.self, forKey: .server)
        pool = try container.decodeIfPresent(String.self, forKey: .pool)
        disable = container.decodeFlexibleBool(forKey: .disable) ?? false
        shared = container.decodeFlexibleBool(forKey: .shared) ?? false
    }
}

struct ProxmoxCephStatus: Decodable, Hashable {
    struct Health: Decodable, Hashable {
        let status: String?
    }
    struct PGMap: Decodable, Hashable {
        let bytesUsed: Int64?
        let bytesAvailable: Int64?
        let totalPGs: Int?

        private enum CodingKeys: String, CodingKey {
            case bytesUsed = "bytes_used"
            case bytesAvailable = "bytes_avail"
            case totalPGs = "num_pgs"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bytesUsed = container.decodeFlexibleInt64(forKey: .bytesUsed)
            bytesAvailable = container.decodeFlexibleInt64(forKey: .bytesAvailable)
            totalPGs = container.decodeFlexibleInt(forKey: .totalPGs)
        }
    }

    let health: Health?
    let pgmap: PGMap?
    let fsid: String?
}

struct ProxmoxCephPool: Decodable, Identifiable, Hashable {
    let name: String
    let size: Int?
    let minSize: Int?
    let pgNum: Int?
    let crushRuleName: String?
    let bytesUsed: Int64?
    let percentUsed: Double?
    let autoscaleMode: String?

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name
        case poolName = "pool_name"
        case size
        case minSize = "min_size"
        case pgNum = "pg_num"
        case crushRuleName = "crush_rule_name"
        case bytesUsed = "bytes_used"
        case percentUsed = "percent_used"
        case autoscaleMode = "pg_autoscale_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedName = try? container.decode(String.self, forKey: .name) {
            name = decodedName
        } else {
            name = try container.decode(String.self, forKey: .poolName)
        }
        size = container.decodeFlexibleInt(forKey: .size)
        minSize = container.decodeFlexibleInt(forKey: .minSize)
        pgNum = container.decodeFlexibleInt(forKey: .pgNum)
        crushRuleName = try container.decodeIfPresent(String.self, forKey: .crushRuleName)
        bytesUsed = container.decodeFlexibleInt64(forKey: .bytesUsed)
        percentUsed = container.decodeFlexibleDouble(forKey: .percentUsed)
        autoscaleMode = try container.decodeIfPresent(String.self, forKey: .autoscaleMode)
    }
}

struct ProxmoxSDNZone: Decodable, Identifiable, Hashable {
    let zone: String
    let type: String?
    let state: String?
    let nodes: String?
    let mtu: Int?
    let bridge: String?
    let controller: String?
    let ipam: String?

    var id: String { zone }

    private enum CodingKeys: String, CodingKey {
        case zone, type, state, nodes, mtu, bridge, controller, ipam
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zone = try container.decode(String.self, forKey: .zone)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        nodes = try container.decodeIfPresent(String.self, forKey: .nodes)
        mtu = container.decodeFlexibleInt(forKey: .mtu)
        bridge = try container.decodeIfPresent(String.self, forKey: .bridge)
        controller = try container.decodeIfPresent(String.self, forKey: .controller)
        ipam = try container.decodeIfPresent(String.self, forKey: .ipam)
    }
}

struct ProxmoxSDNVNet: Decodable, Identifiable, Hashable {
    let vnet: String
    let zone: String?
    let alias: String?
    let tag: Int?
    let vlanAware: Bool
    let state: String?

    var id: String { vnet }

    private enum CodingKeys: String, CodingKey {
        case vnet, zone, alias, tag, state, vlanaware
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vnet = try container.decode(String.self, forKey: .vnet)
        zone = try container.decodeIfPresent(String.self, forKey: .zone)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        tag = container.decodeFlexibleInt(forKey: .tag)
        vlanAware = container.decodeFlexibleBool(forKey: .vlanaware) ?? false
        state = try container.decodeIfPresent(String.self, forKey: .state)
    }
}

struct ProxmoxSDNSubnet: Decodable, Identifiable, Hashable {
    let subnet: String
    let vnet: String?
    let gateway: String?
    let snat: Bool
    let type: String?

    var id: String { subnet }

    private enum CodingKeys: String, CodingKey {
        case subnet, vnet, gateway, snat, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subnet = try container.decode(String.self, forKey: .subnet)
        vnet = try container.decodeIfPresent(String.self, forKey: .vnet)
        gateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        snat = container.decodeFlexibleBool(forKey: .snat) ?? false
        type = try container.decodeIfPresent(String.self, forKey: .type)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Bool.self, forKey: key) { return value ? 1 : 0 }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func decodeFlexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func decodeFlexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return nil
    }
}
