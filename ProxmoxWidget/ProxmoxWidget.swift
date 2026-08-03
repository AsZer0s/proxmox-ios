import SwiftUI
import WidgetKit

private struct WidgetGuest: Codable, Identifiable {
    var id: String { "\(vmid)@\(node)" }
    let name:String;let vmid:Int;let status:String;let node:String
}

private struct ProxmoxEntry: TimelineEntry {
    let date:Date;let guests:[WidgetGuest];let updated:Date?
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ProxmoxEntry { ProxmoxEntry(date:Date(),guests:[WidgetGuest(name:"Home Assistant",vmid:100,status:"running",node:"pve1")],updated:Date()) }
    func getSnapshot(in context: Context, completion: @escaping (ProxmoxEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProxmoxEntry>) -> Void) { completion(Timeline(entries:[entry()],policy:.after(Date().addingTimeInterval(900)))) }
    private func entry()->ProxmoxEntry{let defaults=UserDefaults(suiteName:"group.com.aszer0s.proxmoxmanager");let guests=defaults?.data(forKey:"widget.guests").flatMap{try? JSONDecoder().decode([WidgetGuest].self,from:$0)} ?? [];return ProxmoxEntry(date:Date(),guests:guests,updated:defaults?.object(forKey:"widget.updated") as? Date)}
}

private struct ProxmoxWidgetView:View{
    let entry:ProxmoxEntry
    var body:some View{VStack(alignment:.leading,spacing:6){HStack{Label("Proxmox",systemImage:"server.rack").font(.headline);Spacer();if let updated=entry.updated{Text(updated,style:.relative).font(.caption2).foregroundStyle(.secondary)}};if entry.guests.isEmpty{Text("Add favorite guests in the app.").font(.caption).foregroundStyle(.secondary)}else{ForEach(entry.guests.prefix(4)){guest in HStack{Circle().fill(guest.status.lowercased()=="running" ? .green:.gray).frame(width:7,height:7);Text(guest.name).lineLimit(1);Spacer();Text("\(guest.vmid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)}}};Spacer(minLength:0)}.padding().widgetURL(URL(string:"proxmoxmanager://dashboard"))}
}

@main
struct ProxmoxWidgets:WidgetBundle{
    var body:some Widget{ProxmoxFavoritesWidget()}
}

private struct ProxmoxFavoritesWidget:Widget{
    let kind="ProxmoxFavorites"
    var body:some WidgetConfiguration{StaticConfiguration(kind:kind,provider:Provider()){ProxmoxWidgetView(entry:$0)}.configurationDisplayName("Favorite Guests").description("See the latest cached state of favorite VMs and containers.").supportedFamilies([.systemSmall,.systemMedium])}
}
