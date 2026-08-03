import SwiftUI

struct ClusterOverviewSnapshot: Identifiable {
    let id: UUID; let name:String; let host:String; let state:String; let nodes:Int; let guests:Int; let running:Int; let cpu:Double?; let memory:Double?; let error:String?
}

struct MultiClusterOverviewView: View {
    @EnvironmentObject private var appState: AppState
    @State private var snapshots:[ClusterOverviewSnapshot]=[]
    @State private var loading=true
    var body: some View {
        List {
            ForEach(snapshots) { item in
                Section {
                    HStack { Label(item.state,systemImage:item.error==nil ? "checkmark.circle.fill":"exclamationmark.triangle.fill").foregroundStyle(item.error==nil ? .green:.orange);Spacer();Text(item.host).font(.caption).foregroundStyle(.secondary) }
                    if item.error == nil {
                        LabeledContent("Nodes",value:"\(item.nodes)");LabeledContent("Guests",value:"\(item.running) / \(item.guests) running")
                        if let cpu=item.cpu{LabeledContent("CPU",value:cpu.formatted(.percent.precision(.fractionLength(2))))}
                        if let memory=item.memory{LabeledContent("Memory",value:memory.formatted(.percent.precision(.fractionLength(2))))}
                    } else { Text(item.error ?? "").font(.caption).foregroundStyle(.secondary) }
                } header: { Text(item.name) }
            }
        }
        .navigationTitle("All Clusters")
        .overlay { if loading { ProgressView() } }
        .task { await load() }.refreshable{await load()}
    }
    @MainActor private func load() async {
        loading=true;defer{loading=false}
        let servers=appState.servers
        snapshots = await withTaskGroup(of: ClusterOverviewSnapshot.self, returning: [ClusterOverviewSnapshot].self) { group in
            for server in servers { group.addTask { await snapshot(server) } }
            var result:[ClusterOverviewSnapshot]=[];for await value in group{result.append(value)};return result.sorted{$0.name<$1.name}
        }
    }
    private func snapshot(_ server:ProxmoxServer) async -> ClusterOverviewSnapshot {
        guard let secret=KeychainHelper.secret(authMethod:server.authMethod,for:server.id)else{return ClusterOverviewSnapshot(id:server.id,name:server.name,host:server.host,state:String(localized:"Credentials Required"),nodes:0,guests:0,running:0,cpu:nil,memory:nil,error:String(localized:"Edit the server and save its credentials."))}
        do{let service=ProxmoxAPIService(server:server,tokenValue:server.authMethod == .token ? secret:nil);if server.authMethod == .ticket{try await service.authenticate(password:secret)};async let n=service.fetchNodes();async let r=service.fetchClusterResources();let(nodes,resources)=try await(n,r);let guests=resources.filter{$0.type == .qemu || $0.type == .lxc};let cpuValues=nodes.compactMap(\.cpu);let cpu=cpuValues.isEmpty ? nil:cpuValues.reduce(0,+)/Double(cpuValues.count);let totals=nodes.compactMap{node->(Double,Double)? in guard let used=node.mem,let total=node.maxmem,total>0 else{return nil};return(Double(used),Double(total))};let mem=totals.isEmpty ? nil:totals.map{$0.0}.reduce(0,+)/totals.map{$0.1}.reduce(0,+);return ClusterOverviewSnapshot(id:server.id,name:server.name,host:server.host,state:String(localized:"Online"),nodes:nodes.count,guests:guests.count,running:guests.filter(\.isRunning).count,cpu:cpu,memory:mem,error:nil)}catch{return ClusterOverviewSnapshot(id:server.id,name:server.name,host:server.host,state:String(localized:"Needs Attention"),nodes:0,guests:0,running:0,cpu:nil,memory:nil,error:error.localizedDescription)}
    }
}
