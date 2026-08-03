import Foundation

struct FavoriteGuest: Identifiable, Codable, Hashable {
    var id: String { "\(serverID.uuidString):\(type.rawValue):\(vmid)" }
    let serverID: UUID
    let vmid: Int
    let type: GuestType
    var name: String
    var node: String
    var status: String
}

enum DashboardSection: String, Codable, CaseIterable, Identifiable {
    case summary, favorites, alerts, tasks, quickActions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .summary: return String(localized: "Cluster Summary")
        case .favorites: return String(localized: "Favorites")
        case .alerts: return String(localized: "Active Alerts")
        case .tasks: return String(localized: "Recent Tasks")
        case .quickActions: return String(localized: "Quick Actions")
        }
    }
}

@MainActor
final class DashboardCenter: ObservableObject {
    @Published var favorites: [FavoriteGuest] { didSet { persist() } }
    @Published var sections: [DashboardSection] { didSet { persistSections() } }
    @Published var hiddenSections: Set<DashboardSection> { didSet { persistSections() } }

    init() {
        favorites = Self.decode("dashboard.favorites", fallback: [])
        sections = Self.decode("dashboard.sections", fallback: DashboardSection.allCases)
        hiddenSections = Set(Self.decode("dashboard.hidden", fallback: [] as [DashboardSection]))
    }

    func isFavorite(serverID: UUID, guest: ProxmoxVM) -> Bool {
        favorites.contains { $0.serverID == serverID && $0.vmid == guest.vmid && $0.type == guest.type }
    }

    func toggle(serverID: UUID, guest: ProxmoxVM) {
        if let index = favorites.firstIndex(where: { $0.serverID == serverID && $0.vmid == guest.vmid && $0.type == guest.type }) {
            favorites.remove(at: index)
        } else {
            favorites.append(FavoriteGuest(serverID: serverID, vmid: guest.vmid, type: guest.type, name: guest.displayName, node: guest.node, status: guest.status))
        }
    }

    func update(resources: [ClusterResource], serverID: UUID) {
        for index in favorites.indices where favorites[index].serverID == serverID {
            if let item = resources.first(where: { $0.vmid == favorites[index].vmid && $0.type.rawValue == favorites[index].type.rawValue }) {
                favorites[index].name = item.displayName
                favorites[index].node = item.node ?? favorites[index].node
                favorites[index].status = item.status ?? favorites[index].status
            }
        }
    }

    private func persist() {
        Self.encode(favorites, key: "dashboard.favorites")
        let cache = favorites.prefix(6).map { WidgetGuest(name: $0.name, vmid: $0.vmid, status: $0.status, node: $0.node) }
        if let defaults = UserDefaults(suiteName: "group.com.aszer0s.proxmoxmanager") {
            defaults.set(try? JSONEncoder().encode(cache), forKey: "widget.guests")
            defaults.set(Date(), forKey: "widget.updated")
        }
    }
    private func persistSections() { Self.encode(sections, key:"dashboard.sections");Self.encode(Array(hiddenSections),key:"dashboard.hidden") }
    private static func encode<T:Encodable>(_ value:T,key:String){if let data=try? JSONEncoder().encode(value){UserDefaults.standard.set(data,forKey:key)}}
    private static func decode<T:Decodable>(_ key:String,fallback:T)->T{guard let data=UserDefaults.standard.data(forKey:key),let value=try? JSONDecoder().decode(T.self,from:data)else{return fallback};return value}
    private struct WidgetGuest:Codable{let name:String;let vmid:Int;let status:String;let node:String}
}
