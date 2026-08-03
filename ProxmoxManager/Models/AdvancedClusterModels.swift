import Foundation

struct ProxmoxHARule: Decodable, Identifiable, Hashable {
    let rule: String
    let type: String
    let resources: String?
    let nodes: String?
    let affinity: String?
    let strict: Bool?
    let disable: Bool?
    let comment: String?
    var id: String { rule }
    enum CodingKeys: String, CodingKey { case rule, type, resources, nodes, affinity, strict, disable, comment }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rule = try c.decode(String.self, forKey: .rule)
        type = (try? c.decode(String.self, forKey: .type)) ?? "node-affinity"
        resources = try? c.decodeIfPresent(String.self, forKey: .resources)
        nodes = try? c.decodeIfPresent(String.self, forKey: .nodes)
        affinity = try? c.decodeIfPresent(String.self, forKey: .affinity)
        strict = Self.bool(c, .strict)
        disable = Self.bool(c, .disable)
        comment = try? c.decodeIfPresent(String.self, forKey: .comment)
    }
    private static func bool(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        (try? c.decodeIfPresent(Bool.self, forKey: key))
            ?? (try? c.decodeIfPresent(Int.self, forKey: key)).map { $0 != 0 }
            ?? (try? c.decodeIfPresent(String.self, forKey: key)).map { $0 == "1" || $0.lowercased() == "true" }
    }
}

struct ProxmoxClusterStatusEntry: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let ip: String?
    let nodeid: Int?
    let nodes: Int?
    let online: Bool?
    let local: Bool?
    let quorate: Bool?
    let version: Int?
    enum CodingKeys:String,CodingKey{case id,name,type,ip,nodeid,nodes,online,local,quorate,version}
    init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name);type=try c.decode(String.self,forKey:.type);ip=try? c.decodeIfPresent(String.self,forKey:.ip);nodeid=Self.int(c,.nodeid);nodes=Self.int(c,.nodes);online=Self.bool(c,.online);local=Self.bool(c,.local);quorate=Self.bool(c,.quorate);version=Self.int(c,.version)}
    private static func int(_ c:KeyedDecodingContainer<CodingKeys>,_ k:CodingKeys)->Int?{(try? c.decodeIfPresent(Int.self,forKey:k)) ?? Int((try? c.decodeIfPresent(String.self,forKey:k)) ?? "")}
    private static func bool(_ c:KeyedDecodingContainer<CodingKeys>,_ k:CodingKeys)->Bool?{(try? c.decodeIfPresent(Bool.self,forKey:k)) ?? int(c,k).map{$0 != 0}}
}

struct ProxmoxCephDaemon: Decodable, Identifiable, Hashable {
    let name: String
    let host: String?
    let state: String?
    let service: Bool?
    let quorum: Bool?
    let rank: Int?
    let addr: String?
    let cephVersionShort: String?
    var id: String { name }
    enum CodingKeys: String, CodingKey { case name, host, state, service, quorum, rank, addr; case cephVersionShort = "ceph_version_short" }
    init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);name=try c.decode(String.self,forKey:.name);host=try? c.decodeIfPresent(String.self,forKey:.host);state=try? c.decodeIfPresent(String.self,forKey:.state);service=Self.bool(c,.service);quorum=Self.bool(c,.quorum);rank=(try? c.decodeIfPresent(Int.self,forKey:.rank)) ?? Int((try? c.decodeIfPresent(String.self,forKey:.rank)) ?? "");addr=try? c.decodeIfPresent(String.self,forKey:.addr);cephVersionShort=try? c.decodeIfPresent(String.self,forKey:.cephVersionShort)}
    private static func bool(_ c:KeyedDecodingContainer<CodingKeys>,_ k:CodingKeys)->Bool?{(try? c.decodeIfPresent(Bool.self,forKey:k)) ?? (try? c.decodeIfPresent(Int.self,forKey:k)).map{$0 != 0} ?? (try? c.decodeIfPresent(String.self,forKey:k)).map{$0=="1" || $0.lowercased()=="true"}}
}

struct ProxmoxCephOSDResponse: Decodable, Hashable {
    let root: ProxmoxCephOSDNode
    let flags: String?
}

struct ProxmoxCephOSDNode: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let type: String?
    let status: String?
    let `in`: Int?
    let host: String?
    let deviceClass: String?
    let children: [ProxmoxCephOSDNode]
    enum CodingKeys: String, CodingKey { case id, name, type, status, `in`, host, children; case deviceClass = "device-class" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? Int((try? c.decode(String.self, forKey: .id)) ?? "") ?? 0
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        `in` = (try? c.decodeIfPresent(Int.self, forKey: .in)) ?? Int((try? c.decodeIfPresent(String.self, forKey: .in)) ?? "")
        host = try? c.decodeIfPresent(String.self, forKey: .host)
        deviceClass = try? c.decodeIfPresent(String.self, forKey: .deviceClass)
        children = (try? c.decode([ProxmoxCephOSDNode].self, forKey: .children)) ?? []
    }
    var osds: [ProxmoxCephOSDNode] { (type == "osd" ? [self] : []) + children.flatMap(\.osds) }
}

struct ProxmoxSDNPlugin: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let endpoint: String?
    let nodes: String?
    let state: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        id = (try? c.decode(String.self, forKey: DynamicKey("controller")))
            ?? (try? c.decode(String.self, forKey: DynamicKey("ipam")))
            ?? (try? c.decode(String.self, forKey: DynamicKey("dns"))) ?? "unknown"
        type = (try? c.decode(String.self, forKey: DynamicKey("type"))) ?? "unknown"
        endpoint = (try? c.decode(String.self, forKey: DynamicKey("url")))
            ?? (try? c.decode(String.self, forKey: DynamicKey("peers")))
        nodes = try? c.decode(String.self, forKey: DynamicKey("nodes"))
        state = try? c.decode(String.self, forKey: DynamicKey("state"))
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
