import SwiftUI

struct AdvancedClusterView: View {
    @EnvironmentObject private var appState: AppState
    @State private var nodes: [String] = []
    @State private var node = ""
    var body: some View {
        List {
            if !nodes.isEmpty { Picker("Target Node", selection: $node) { ForEach(nodes, id: \.self) { Text($0).tag($0) } } }
            Section("Cluster") {
                NavigationLink("Quorum & Membership") { ClusterMembershipView() }
                NavigationLink("Modern HA Rules") { HARulesView() }
            }
            Section("Ceph") {
                NavigationLink("OSD, MON & MGR") { CephDaemonManagementView(node: node) }.disabled(node.isEmpty)
            }
            Section("SDN Services") {
                NavigationLink("Controllers, IPAM & DNS") { SDNPluginManagementView() }
            }
        }
        .navigationTitle("Advanced Cluster")
        .task { nodes = (try? await appState.service?.fetchNodes())?.map(\.node) ?? []; node = node.isEmpty ? nodes.first ?? "" : node }
    }
}

private struct ClusterMembershipView: View {
    @EnvironmentObject private var appState: AppState
    @State private var status: [ProxmoxClusterStatusEntry] = []
    @State private var joining = false
    @State private var creating = false
    @State private var deleting: ProxmoxClusterStatusEntry?
    @State private var error: String?
    var body: some View {
        List {
            if let cluster = status.first(where: { $0.type == "cluster" }) {
                Section("Quorum") {
                    LabeledContent("Cluster", value: cluster.name)
                    LabeledContent("Nodes", value: "\(cluster.nodes ?? 0)")
                    LabeledContent("Quorate", value: cluster.quorate == true ? String(localized: "Yes") : String(localized: "No"))
                }
            }
            Section("Members") {
                ForEach(status.filter { $0.type == "node" }) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item.name); Text(item.ip ?? "—").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if item.local == true { Text("Local").font(.caption).foregroundStyle(.blue) }
                        Circle().fill(item.online == true ? .green : .red).frame(width: 8, height: 8)
                    }
                    .swipeActions { if item.local != true { Button("Remove", role: .destructive) { deleting = item } } }
                }
            }
            Section { Button("Create Cluster") { creating = true }; Button("Join Existing Cluster") { joining = true } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Cluster Membership")
        .task { await load() }.refreshable { await load() }
        .sheet(isPresented: $creating) { CreateClusterSheet { await load() } }
        .sheet(isPresented: $joining) { JoinClusterSheet { await load() } }
        .alert("Remove Cluster Node?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) { if let deleting { Task { await remove(deleting) } } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("The node must be powered off and must not contain cluster workloads. This changes corosync membership.") }
    }
    @MainActor private func load() async { do { status = try await appState.service?.fetchClusterStatus() ?? [] } catch { self.error = error.localizedDescription } }
    @MainActor private func remove(_ item: ProxmoxClusterStatusEntry) async { guard await appState.operationSafety.authorizeCriticalAction(reason:String(localized:"Authorize cluster membership change")) else{return};do { try await appState.service?.removeClusterNode(name: item.name); deleting=nil; await load() } catch { self.error=error.localizedDescription } }
}

private struct CreateClusterSheet: View {
    @EnvironmentObject private var appState: AppState; @Environment(\.dismiss) private var dismiss
    let onSaved: () async -> Void
    @State private var name=""; @State private var address=""; @State private var error:String?
    var body: some View { NavigationStack { Form { TextField("Cluster Name",text:$name); TextField("Corosync Address",text:$address); if let error { Text(error).foregroundStyle(.red) } }.navigationTitle("Create Cluster").toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}; ToolbarItem(placement:.confirmationAction){Button("Create"){Task{await save()}}.disabled(name.trimmed.isEmpty || address.trimmed.isEmpty)} } } }
    @MainActor private func save() async { guard await appState.operationSafety.authorizeCriticalAction(reason:String(localized:"Authorize cluster creation")) else{return};do { try await appState.service?.createCluster(name:name.trimmed,link0:address.trimmed); await onSaved(); dismiss() } catch { self.error=error.localizedDescription } }
}

private struct JoinClusterSheet: View {
    @EnvironmentObject private var appState: AppState; @Environment(\.dismiss) private var dismiss
    let onSaved: () async -> Void
    @State private var host=""; @State private var fingerprint=""; @State private var password=""; @State private var link=""; @State private var error:String?
    var body: some View { NavigationStack { Form { TextField("Existing Member",text:$host); TextField("SHA-256 Fingerprint",text:$fingerprint); SecureField("root Password",text:$password); TextField("Local Corosync Address",text:$link); Text("Joining rewrites the local cluster configuration. Verify the fingerprint out of band.").font(.footnote).foregroundStyle(.orange); if let error{Text(error).foregroundStyle(.red)} }.navigationTitle("Join Cluster").toolbar { ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}}; ToolbarItem(placement:.confirmationAction){Button("Join"){Task{await save()}}.disabled(host.trimmed.isEmpty || fingerprint.trimmed.isEmpty || password.isEmpty)} } } }
    @MainActor private func save() async { guard await appState.operationSafety.authorizeCriticalAction(reason:String(localized:"Authorize joining this cluster")) else{return};do { _ = try await appState.service?.joinCluster(hostname:host.trimmed,fingerprint:fingerprint.trimmed,password:password,link0:link); await onSaved(); dismiss() } catch { self.error=error.localizedDescription } }
}

private struct HARulesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var rules:[ProxmoxHARule]=[]; @State private var editing:ProxmoxHARule?; @State private var creating=false; @State private var error:String?
    var body: some View { List { ForEach(rules){rule in Button{editing=rule}label:{VStack(alignment:.leading){Text(rule.rule).foregroundStyle(.primary);Text([rule.type,rule.resources,rule.nodes,rule.affinity].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}}}; if let error{Text(error).foregroundStyle(.red)} }.navigationTitle("HA Rules").toolbar{Button{creating=true}label:{Image(systemName:"plus")}}.task{await load()}.refreshable{await load()}.sheet(isPresented:$creating){HARuleEditor(rule:nil){await load()}}.sheet(item:$editing){HARuleEditor(rule:$0){await load()}} }
    @MainActor private func load()async{do{rules=try await appState.service?.fetchHARules() ?? []}catch{self.error=error.localizedDescription}}
}

private struct HARuleEditor: View {
    @EnvironmentObject private var appState:AppState;@Environment(\.dismiss)private var dismiss;let rule:ProxmoxHARule?;let onSaved:()async->Void
    @State private var id="";@State private var type="node-affinity";@State private var resources="";@State private var nodes="";@State private var affinity="positive";@State private var strict=false;@State private var disabled=false;@State private var comment="";@State private var error:String?
    var body:some View{NavigationStack{Form{TextField("Rule ID",text:$id).disabled(rule != nil);Picker("Type",selection:$type){Text("Node Affinity").tag("node-affinity");Text("Resource Affinity").tag("resource-affinity")};TextField("Resources (vm:100,ct:101)",text:$resources);if type=="node-affinity"{TextField("Nodes (node:priority)",text:$nodes);Toggle("Strict",isOn:$strict)}else{Picker("Affinity",selection:$affinity){Text("Together").tag("positive");Text("Separate").tag("negative")}};TextField("Comment",text:$comment);Toggle("Disabled",isOn:$disabled);if let error{Text(error).foregroundStyle(.red)};if rule != nil{Button("Delete Rule",role:.destructive){Task{await remove()}}}}.navigationTitle(rule==nil ? "Add HA Rule":"Edit HA Rule").toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(id.trimmed.isEmpty || resources.trimmed.isEmpty)}}.onAppear{if let rule{id=rule.rule;type=rule.type;resources=rule.resources ?? "";nodes=rule.nodes ?? "";affinity=rule.affinity ?? "positive";strict=rule.strict ?? false;disabled=rule.disable ?? false;comment=rule.comment ?? ""}}}}
    private var form:[String:String]{var f=["type":type,"resources":resources.trimmed,"disable":disabled ? "1":"0","comment":comment];if type=="node-affinity"{f["nodes"]=nodes.trimmed;f["strict"]=strict ? "1":"0"}else{f["affinity"]=affinity};return f}
    @MainActor private func save()async{do{if let rule{try await appState.service?.updateHARule(id:rule.rule,form:form)}else{var f=form;f["rule"]=id.trimmed;try await appState.service?.createHARule(form:f)};await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
    @MainActor private func remove()async{guard let rule else{return};do{try await appState.service?.deleteHARule(id:rule.rule);await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
}

private struct CephDaemonManagementView: View {
    @EnvironmentObject private var appState:AppState;let node:String
    @State private var osds:[ProxmoxCephOSDNode]=[];@State private var mons:[ProxmoxCephDaemon]=[];@State private var mgrs:[ProxmoxCephDaemon]=[];@State private var section=0;@State private var adding=false;@State private var error:String?
    var body:some View{List{Picker("Service",selection:$section){Text("OSD").tag(0);Text("MON").tag(1);Text("MGR").tag(2)}.pickerStyle(.segmented).listRowBackground(Color.clear);if section==0{ForEach(osds){osd in VStack(alignment:.leading){Text(osd.name ?? "osd.\(osd.id)");Text([osd.status,osd.deviceClass,osd.in==1 ? "in":"out"].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}.swipeActions{Button("Scrub"){Task{await osdAction(osd,"scrub")}};Button(osd.in==1 ? "Out":"In"){Task{await osdAction(osd,osd.in==1 ? "out":"in")}}.tint(.orange)}}}else{ForEach(section==1 ? mons:mgrs){daemon in VStack(alignment:.leading){Text(daemon.name);Text([daemon.host,daemon.state,daemon.cephVersionShort].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}}};if let error{Text(error).foregroundStyle(.red)}}.navigationTitle("Ceph Services · \(node)").toolbar{Button{adding=true}label:{Image(systemName:"plus")}}.task{await load()}.refreshable{await load()}.sheet(isPresented:$adding){CephDaemonCreator(node:node,kind:section){await load()}}}
    @MainActor private func load()async{do{async let a=appState.service?.fetchCephOSDs(node:node);async let b=appState.service?.fetchCephMONs(node:node);async let c=appState.service?.fetchCephMGRs(node:node);let(x,y,z)=try await(a,b,c);osds=x?.root.osds ?? [];mons=y ?? [];mgrs=z ?? []}catch let e as ProxmoxError where e.indicatesCephUnavailable{error=String(localized:"Ceph is not installed or configured on this node.")}catch{self.error=error.localizedDescription}}
    @MainActor private func osdAction(_ osd:ProxmoxCephOSDNode,_ action:String)async{do{if action=="scrub"{_ = try await appState.service?.scrubCephOSD(node:node,osd:osd.id)}else{_ = try await appState.service?.setCephOSDState(node:node,osd:osd.id,state:action)};await load()}catch{self.error=error.localizedDescription}}
}

private struct CephDaemonCreator:View{
    @EnvironmentObject private var appState:AppState;@Environment(\.dismiss)private var dismiss;let node:String;let kind:Int;let onSaved:()async->Void
    @State private var value="";@State private var encrypted=false;@State private var error:String?
    var body:some View{NavigationStack{Form{TextField(kind==0 ? "Block Device (/dev/...)":"Daemon ID",text:$value);if kind==0{Toggle("Encrypt OSD",isOn:$encrypted)};if let error{Text(error).foregroundStyle(.red)}}.navigationTitle(kind==0 ? "Create OSD":kind==1 ? "Create MON":"Create MGR").toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Create"){Task{await save()}}.disabled(value.trimmed.isEmpty)}}}}
    @MainActor private func save()async{do{if kind==0{_ = try await appState.service?.createCephOSD(node:node,form:["dev":value.trimmed,"encrypted":encrypted ? "1":"0"])}else{_ = try await appState.service?.createCephDaemon(node:node,kind:kind==1 ? "mon":"mgr",id:value.trimmed)};await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
}

private struct SDNPluginManagementView:View{
    @EnvironmentObject private var appState:AppState;@State private var kind="controllers";@State private var items:[ProxmoxSDNPlugin]=[];@State private var creating=false;@State private var editing:ProxmoxSDNPlugin?;@State private var error:String?
    var body:some View{List{Picker("Service",selection:$kind){Text("Controllers").tag("controllers");Text("IPAM").tag("ipams");Text("DNS").tag("dns")}.pickerStyle(.segmented).listRowBackground(Color.clear);ForEach(items){item in Button{editing=item}label:{VStack(alignment:.leading){Text(item.id).foregroundStyle(.primary);Text([item.type,item.endpoint,item.nodes,item.state].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}}};if let error{Text(error).foregroundStyle(.red)}}.navigationTitle("SDN Services").toolbar{Button{creating=true}label:{Image(systemName:"plus")}}.task(id:kind){await load()}.sheet(isPresented:$creating){SDNPluginEditor(kind:kind,item:nil){await load()}}.sheet(item:$editing){SDNPluginEditor(kind:kind,item:$0){await load()}}}
    @MainActor private func load()async{do{items=try await appState.service?.fetchSDNPlugins(kind:kind) ?? []}catch{self.error=error.localizedDescription}}
}

private struct SDNPluginEditor:View{
    @EnvironmentObject private var appState:AppState;@Environment(\.dismiss)private var dismiss;let kind:String;let item:ProxmoxSDNPlugin?;let onSaved:()async->Void
    @State private var id="";@State private var type="";@State private var url="";@State private var token="";@State private var nodes="";@State private var asn="";@State private var peers="";@State private var error:String?
    var body:some View{NavigationStack{Form{TextField("ID",text:$id).disabled(item != nil);TextField("Type",text:$type);TextField("URL / Endpoint",text:$url);SecureField(kind=="dns" ? "API Key":"Token",text:$token);if kind=="controllers"{TextField("Nodes",text:$nodes);TextField("ASN",text:$asn).keyboardType(.numberPad);TextField("Peers",text:$peers)};if let error{Text(error).foregroundStyle(.red)};if item != nil{Button("Delete",role:.destructive){Task{await remove()}}}}.navigationTitle(item==nil ? "Add SDN Service":"Edit SDN Service").toolbar{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save"){Task{await save()}}.disabled(id.trimmed.isEmpty || type.trimmed.isEmpty)}}.onAppear{if let item{id=item.id;type=item.type;url=item.endpoint ?? "";nodes=item.nodes ?? ""}}}}
    private var form:[String:String]{var f=["type":type.trimmed];let idKey=kind=="controllers" ? "controller":kind=="ipams" ? "ipam":"dns";f[idKey]=id.trimmed;if !url.trimmed.isEmpty{f["url"]=url.trimmed};if !token.isEmpty{f[kind=="dns" ? "key":"token"]=token};if !nodes.trimmed.isEmpty{f["nodes"]=nodes.trimmed};if !asn.trimmed.isEmpty{f["asn"]=asn.trimmed};if !peers.trimmed.isEmpty{f["peers"]=peers.trimmed};return f}
    @MainActor private func save()async{guard await appState.operationSafety.authorizeCriticalAction(reason:String(localized:"Authorize SDN configuration change"))else{return};do{if let item{var f=form;f.removeValue(forKey:kind=="controllers" ? "controller":kind=="ipams" ? "ipam":"dns");try await appState.service?.updateSDNPlugin(kind:kind,id:item.id,form:f)}else{try await appState.service?.createSDNPlugin(kind:kind,form:form)};try await appState.service?.applySDNConfiguration();await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
    @MainActor private func remove()async{guard let item else{return};do{try await appState.service?.deleteSDNPlugin(kind:kind,id:item.id);try await appState.service?.applySDNConfiguration();await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
}
