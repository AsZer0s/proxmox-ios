import SwiftUI

struct InfrastructureView: View {
    @EnvironmentObject private var appState: AppState
    @State private var nodes: [String] = []
    @State private var node = ""

    var body: some View {
        List {
            if !nodes.isEmpty {
                Section("Target Node") {
                    Picker("Node", selection: $node) { ForEach(nodes, id: \.self) { Text($0).tag($0) } }
                }
            }
            Section("Cluster Infrastructure") {
                NavigationLink { AdvancedClusterView() } label: { Label("Advanced Cluster", systemImage: "point.3.filled.connected.trianglepath.dotted") }
                NavigationLink { NodeNetworkConfigurationView(node: node) } label: { Label("Node Network", systemImage: "cable.connector.horizontal") }.disabled(node.isEmpty)
                NavigationLink { StorageConfigurationView() } label: { Label("Storage Configuration", systemImage: "externaldrive.connected.to.line.below") }
                NavigationLink { CephManagementView(node: node) } label: { Label("Ceph", systemImage: "square.3.layers.3d") }.disabled(node.isEmpty)
                NavigationLink { SDNManagementView() } label: { Label("Software-Defined Network", systemImage: "point.3.connected.trianglepath.dotted") }
            }
        }
        .navigationTitle("Infrastructure")
        .task { nodes = (try? await appState.service?.fetchNodes())?.map(\.node) ?? []; if node.isEmpty { node = nodes.first ?? "" } }
    }
}

private struct NodeNetworkConfigurationView: View {
    @EnvironmentObject private var appState: AppState
    let node: String
    @State private var interfaces: [ProxmoxNetworkInterface] = []
    @State private var editing: ProxmoxNetworkInterface?
    @State private var creating = false
    @State private var loading = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            Section { Text("Changes are staged by Proxmox until you apply them. Applying network changes can interrupt this connection.").font(.footnote).foregroundStyle(.secondary) }
            Section("Interfaces") {
                ForEach(interfaces) { item in
                    Button { editing = item } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text(item.iface).foregroundStyle(.primary); Text([item.type, item.cidr ?? item.cidr6, item.bridgePorts ?? item.slaves].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Circle().fill(item.active ? .green : .secondary).frame(width: 8, height: 8)
                        }
                    }.disabled(!canModify)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if canModify { Section("Pending Changes") { Button("Apply Network Configuration") { Task { await apply() } }; Button("Revert Pending Changes", role: .destructive) { Task { await revert() } } } }
        }
        .navigationTitle("Network · \(node)")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.disabled(!canModify) } }
        .overlay { if loading || working { ProgressView() } }
        .task { await load() }.refreshable { await load() }
        .sheet(isPresented: $creating) { NetworkInterfaceEditor(node: node, interface: nil) { await load() } }
        .sheet(item: $editing) { NetworkInterfaceEditor(node: node, interface: $0) { await load() } }
    }
    private var canModify: Bool { appState.hasPrivilege("Sys.Modify", on: "/nodes/\(node)") }
    @MainActor private func load() async { guard let service = appState.service else { return }; loading = true; defer { loading = false }; do { interfaces = try await service.fetchNodeNetworkInterfaces(node: node) } catch { self.error = error.localizedDescription } }
    @MainActor private func apply() async { guard let service = appState.service, await appState.operationSafety.authorizeCriticalAction(reason: String(localized: "Authorize applying node network configuration")) else { return }; working = true; defer { working = false }; do { try await service.applyNodeNetworkConfiguration(node: node); await load() } catch { self.error = error.localizedDescription } }
    @MainActor private func revert() async { guard let service = appState.service else { return }; working = true; defer { working = false }; do { try await service.revertNodeNetworkConfiguration(node: node); await load() } catch { self.error = error.localizedDescription } }
}

private struct NetworkInterfaceEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let node: String; let interface: ProxmoxNetworkInterface?; let onSaved: () async -> Void
    @State private var iface: String; @State private var type: String; @State private var cidr: String; @State private var gateway: String; @State private var ports: String; @State private var slaves: String; @State private var bondMode: String; @State private var vlanID: String; @State private var vlanRaw: String; @State private var mtu: String; @State private var autostart: Bool; @State private var vlanAware: Bool; @State private var comments: String
    @State private var working = false; @State private var error: String?
    init(node: String, interface: ProxmoxNetworkInterface?, onSaved: @escaping () async -> Void) { self.node=node; self.interface=interface; self.onSaved=onSaved; _iface=State(initialValue: interface?.iface ?? ""); _type=State(initialValue: interface?.type ?? "bridge"); _cidr=State(initialValue: interface?.cidr ?? ""); _gateway=State(initialValue: interface?.gateway ?? ""); _ports=State(initialValue: interface?.bridgePorts ?? ""); _slaves=State(initialValue: interface?.slaves ?? ""); _bondMode=State(initialValue: interface?.bondMode ?? "active-backup"); _vlanID=State(initialValue: interface?.vlanID.map { String($0) } ?? ""); _vlanRaw=State(initialValue: interface?.vlanRawDevice ?? ""); _mtu=State(initialValue: interface?.mtu.map { String($0) } ?? ""); _autostart=State(initialValue: interface?.autostart ?? true); _vlanAware=State(initialValue: interface?.bridgeVLANAwareness ?? false); _comments=State(initialValue: interface?.comments ?? "") }
    var body: some View { NavigationStack { Form {
        Section("Interface") { TextField("Name", text: $iface).textInputAutocapitalization(.never).disabled(interface != nil); Picker("Type", selection: $type) { Text("Linux Bridge").tag("bridge"); Text("Linux Bond").tag("bond"); Text("VLAN").tag("vlan"); Text("Ethernet").tag("eth") }.disabled(interface != nil); Toggle("Start Automatically", isOn: $autostart); TextField("IPv4/CIDR", text: $cidr).textInputAutocapitalization(.never); TextField("Gateway", text: $gateway).textInputAutocapitalization(.never); TextField("MTU", text: $mtu).keyboardType(.numberPad); TextField("Comment", text: $comments) }
        if type == "bridge" { Section("Bridge") { TextField("Bridge Ports", text: $ports); Toggle("VLAN Aware", isOn: $vlanAware) } }
        if type == "bond" { Section("Bond") { TextField("Slaves", text: $slaves); Picker("Mode", selection: $bondMode) { Text("Active Backup").tag("active-backup"); Text("802.3ad").tag("802.3ad"); Text("Balance XOR").tag("balance-xor"); Text("Balance ALB").tag("balance-alb") } } }
        if type == "vlan" { Section("VLAN") { TextField("VLAN ID", text: $vlanID).keyboardType(.numberPad); TextField("Raw Device", text: $vlanRaw) } }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if interface != nil { Section { Button("Delete Interface", role: .destructive) { Task { await remove() } } } }
    }.navigationTitle(interface == nil ? "Add Interface" : "Edit Interface").navigationBarTitleDisplayMode(.inline).toolbar { basicToolbar(canSave: !iface.trimmed.isEmpty, dismiss: dismiss, save: save) }.overlay { if working { ProgressView() } } } }
    private var form: [String:String] { var f=["autostart":autostart ? "1":"0"]; for (k,v) in [("cidr",cidr),("gateway",gateway),("mtu",mtu),("comments",comments)] where !v.trimmed.isEmpty { f[k]=v.trimmed }; if type == "bridge" { f["bridge_ports"]=ports.trimmed; f["bridge_vlan_aware"]=vlanAware ? "1":"0" }; if type == "bond" { f["slaves"]=slaves.trimmed; f["bond_mode"]=bondMode }; if type == "vlan" { f["vlan-id"]=vlanID.trimmed; f["vlan-raw-device"]=vlanRaw.trimmed }; return f }
    @MainActor private func save() async { guard let service=appState.service else{return}; working=true; defer{working=false}; do { if let interface { try await service.updateNodeNetworkInterface(node:node,iface:interface.iface,form:form) } else { var f=form; f["iface"]=iface.trimmed; f["type"]=type; try await service.createNodeNetworkInterface(node:node,form:f) }; await onSaved(); dismiss() } catch { self.error=error.localizedDescription } }
    @MainActor private func remove() async { guard let service=appState.service, let interface else{return}; working=true; defer{working=false}; do { try await service.deleteNodeNetworkInterface(node:node,iface:interface.iface); await onSaved(); dismiss() } catch { self.error=error.localizedDescription } }
}

private struct StorageConfigurationView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items:[ProxmoxStorageConfig]=[]; @State private var editing:ProxmoxStorageConfig?; @State private var creating=false; @State private var loading=true; @State private var error:String?
    var body: some View { List { Section("Storage") { ForEach(items) { item in Button { editing=item } label: { HStack { VStack(alignment:.leading,spacing:3){Text(item.storage).foregroundStyle(.primary); Text([item.type,item.content,item.nodes].compactMap{$0}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)}; Spacer(); if item.disable { Text("Disabled").font(.caption).foregroundStyle(.secondary) } } }.disabled(!canModify) } }; if let error { Section { Text(error).foregroundStyle(.red) } } }.navigationTitle("Storage Configuration").toolbar { ToolbarItem(placement:.navigationBarTrailing){Button{creating=true}label:{Image(systemName:"plus")}.disabled(!canModify)} }.overlay{if loading{ProgressView()}}.task{await load()}.refreshable{await load()}.sheet(isPresented:$creating){StorageConfigEditor(item:nil){await load()}}.sheet(item:$editing){StorageConfigEditor(item:$0){await load()}} }
    private var canModify:Bool{appState.hasPrivilege("Datastore.Allocate",on:"/")}
    @MainActor private func load() async { guard let service=appState.service else{return};loading=true;defer{loading=false};do{items=try await service.fetchStorageConfigs()}catch{self.error=error.localizedDescription} }
}

private struct StorageConfigEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let item: ProxmoxStorageConfig?
    let onSaved: () async -> Void
    @State private var id: String
    @State private var type: String
    @State private var content: String
    @State private var nodes: String
    @State private var path: String
    @State private var server: String
    @State private var pool: String
    @State private var remoteName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var fingerprint = ""
    @State private var volumeGroup = ""
    @State private var thinPool = ""
    @State private var monitors = ""
    @State private var disabled: Bool
    @State private var shared: Bool
    @State private var working = false
    @State private var error: String?

    init(item: ProxmoxStorageConfig?, onSaved: @escaping () async -> Void) {
        self.item = item; self.onSaved = onSaved
        _id = State(initialValue: item?.storage ?? ""); _type = State(initialValue: item?.type ?? "dir")
        _content = State(initialValue: item?.content ?? "images,rootdir,backup,iso,vztmpl")
        _nodes = State(initialValue: item?.nodes ?? ""); _path = State(initialValue: item?.path ?? "")
        _server = State(initialValue: item?.server ?? ""); _pool = State(initialValue: item?.pool ?? "")
        _disabled = State(initialValue: item?.disable ?? false); _shared = State(initialValue: item?.shared ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Storage") {
                    TextField("Storage ID", text: $id).disabled(item != nil)
                    Picker("Type", selection: $type) { ForEach(["dir","nfs","cifs","lvm","lvmthin","zfspool","pbs","rbd"], id: \.self) { Text($0).tag($0) } }.disabled(item != nil)
                    TextField("Content Types", text: $content)
                    TextField("Restrict to Nodes", text: $nodes)
                    Toggle("Shared", isOn: $shared); Toggle("Disabled", isOn: $disabled)
                }
                if type == "dir" { Section("Directory") { TextField("Path", text: $path) } }
                if type == "nfs" { Section("NFS") { TextField("Server", text: $server); TextField("Export", text: $remoteName) } }
                if type == "cifs" { Section("SMB/CIFS") { TextField("Server", text: $server); TextField("Share", text: $remoteName); TextField("Username", text: $username); SecureField("Password", text: $password) } }
                if type == "pbs" { Section("Proxmox Backup Server") { TextField("Server", text: $server); TextField("Datastore", text: $remoteName); TextField("Username", text: $username); SecureField("Password", text: $password); TextField("Fingerprint", text: $fingerprint) } }
                if type == "lvm" || type == "lvmthin" { Section("LVM") { TextField("Volume Group", text: $volumeGroup); if type == "lvmthin" { TextField("Thin Pool", text: $thinPool) } } }
                if type == "zfspool" { Section("ZFS") { TextField("ZFS Pool", text: $pool) } }
                if type == "rbd" { Section("Ceph RBD") { TextField("Pool", text: $pool); TextField("Monitor Hosts", text: $monitors); TextField("Username", text: $username) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if item != nil { Section { Button("Delete Storage", role: .destructive) { Task { await remove() } } } }
            }
            .navigationTitle(item == nil ? "Add Storage" : "Edit Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { basicToolbar(canSave: canSave, dismiss: dismiss, save: save) }
            .overlay { if working { ProgressView() } }
        }
    }

    private var canSave: Bool {
        guard !id.trimmed.isEmpty else { return false }
        if item != nil { return true }
        switch type {
        case "dir": return !path.trimmed.isEmpty
        case "nfs", "cifs", "pbs": return !server.trimmed.isEmpty && !remoteName.trimmed.isEmpty
        case "lvm": return !volumeGroup.trimmed.isEmpty
        case "lvmthin": return !volumeGroup.trimmed.isEmpty && !thinPool.trimmed.isEmpty
        case "zfspool", "rbd": return !pool.trimmed.isEmpty
        default: return true
        }
    }

    private var form: [String: String] {
        var value = ["content": content.trimmed, "disable": disabled ? "1" : "0", "shared": shared ? "1" : "0"]
        for (key, field) in [("nodes",nodes),("path",path),("server",server),("pool",pool),("username",username),("password",password),("fingerprint",fingerprint),("vgname",volumeGroup),("thinpool",thinPool),("monhost",monitors)] where !field.trimmed.isEmpty { value[key] = field.trimmed }
        if type == "nfs" { value["export"] = remoteName.trimmed }
        if type == "cifs" { value["share"] = remoteName.trimmed }
        if type == "pbs" { value["datastore"] = remoteName.trimmed }
        return value
    }

    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; do { if let item { try await service.updateStorageConfig(id: item.storage, form: form) } else { var value = form; value["storage"] = id.trimmed; value["type"] = type; try await service.createStorageConfig(form: value) }; await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let item else { return }; working = true; defer { working = false }; do { try await service.deleteStorageConfig(id: item.storage); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct CephManagementView: View {
    @EnvironmentObject private var appState: AppState
    let node: String
    @State private var status: ProxmoxCephStatus?
    @State private var pools: [ProxmoxCephPool] = []
    @State private var editing: ProxmoxCephPool?
    @State private var creating = false
    @State private var cephUnavailable = false
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if cephUnavailable {
                ContentUnavailableCompat(
                    title: "Ceph Is Not Configured",
                    systemImage: "square.3.layers.3d.slash",
                    description: "Ceph is not installed or initialized on this node. This is expected when the cluster does not use Ceph."
                )
            } else {
                List {
                    Section("Health") {
                        LabeledContent("Status", value: status?.health?.status ?? "—")
                        if let pg = status?.pgmap {
                            if let used = pg.bytesUsed {
                                LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: used, countStyle: .binary))
                            }
                            if let available = pg.bytesAvailable {
                                LabeledContent("Available", value: ByteCountFormatter.string(fromByteCount: available, countStyle: .binary))
                            }
                            if let count = pg.totalPGs {
                                LabeledContent("Placement Groups", value: "\(count)")
                            }
                        }
                    }
                    Section("Pools") {
                        ForEach(pools) { pool in
                            Button { editing = pool } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(pool.name).foregroundStyle(.primary)
                                        Text("size \(pool.size ?? 0) · PG \(pool.pgNum ?? 0)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let used = pool.percentUsed {
                                        Text(used.formatted(.percent.precision(.fractionLength(2))))
                                            .font(.caption.monospacedDigit())
                                    }
                                }
                            }
                            .disabled(!canModify)
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
            }
        }
        .navigationTitle("Ceph · \(node)")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .disabled(!canModify || cephUnavailable)
            }
        }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $creating) { CephPoolEditor(node: node, pool: nil) { await load() } }
        .sheet(item: $editing) { CephPoolEditor(node: node, pool: $0) { await load() } }
    }

    private var canModify: Bool {
        appState.hasPrivilege("Sys.Modify", on: "/nodes/\(node)")
    }

    @MainActor private func load() async {
        guard let service = appState.service else { return }
        loading = true
        error = nil
        cephUnavailable = false
        defer { loading = false }
        do {
            status = try await service.fetchCephStatus(node: node)
            pools = try await service.fetchCephPools(node: node)
        } catch let cephError as ProxmoxError where cephError.indicatesCephUnavailable {
            status = nil
            pools = []
            cephUnavailable = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CephPoolEditor:View{
    @EnvironmentObject private var appState:AppState;@Environment(\.dismiss)private var dismiss;let node:String;let pool:ProxmoxCephPool?;let onSaved:()async->Void
    @State private var name:String;@State private var size:Int;@State private var minSize:Int;@State private var pg:Int;@State private var autoscale:String;@State private var working=false;@State private var error:String?
    init(node:String,pool:ProxmoxCephPool?,onSaved:@escaping()async->Void){self.node=node;self.pool=pool;self.onSaved=onSaved;_name=State(initialValue:pool?.name ?? "");_size=State(initialValue:pool?.size ?? 3);_minSize=State(initialValue:pool?.minSize ?? 2);_pg=State(initialValue:pool?.pgNum ?? 128);_autoscale=State(initialValue:pool?.autoscaleMode ?? "on")}
    var body:some View{NavigationStack{Form{Section("Pool"){TextField("Name",text:$name).disabled(pool != nil);Stepper("Replica Size: \(size)",value:$size,in:1...8);Stepper("Minimum Size: \(minSize)",value:$minSize,in:1...8);Stepper("Placement Groups: \(pg)",value:$pg,in:1...32768);Picker("PG Autoscale",selection:$autoscale){Text("On").tag("on");Text("Warn").tag("warn");Text("Off").tag("off")}};if let error{Section{Text(error).foregroundStyle(.red)}};if pool != nil{Section{Button("Delete Pool",role:.destructive){Task{await remove()}}}}}.navigationTitle(pool==nil ? "Add Ceph Pool":"Edit Ceph Pool").navigationBarTitleDisplayMode(.inline).toolbar{basicToolbar(canSave:!name.trimmed.isEmpty,dismiss:dismiss,save:save)}.overlay{if working{ProgressView()}}}}
    @MainActor private func save()async{guard let service=appState.service else{return};working=true;defer{working=false};var f=["size":"\(size)","min_size":"\(minSize)","pg_num":"\(pg)","pg_autoscale_mode":autoscale];do{if let pool{try await service.updateCephPool(node:node,name:pool.name,form:f)}else{f["name"]=name.trimmed;try await service.createCephPool(node:node,form:f)};await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
    @MainActor private func remove()async{guard let service=appState.service,let pool else{return};working=true;defer{working=false};do{try await service.deleteCephPool(node:node,name:pool.name);await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
}

private struct SDNManagementView: View {
    @EnvironmentObject private var appState: AppState
    @State private var zones: [ProxmoxSDNZone] = []
    @State private var vnets: [ProxmoxSDNVNet] = []
    @State private var subnets: [ProxmoxSDNSubnet] = []
    @State private var selectedVNet = ""
    @State private var section = 0
    @State private var editingZone: ProxmoxSDNZone?
    @State private var editingVNet: ProxmoxSDNVNet?
    @State private var editingSubnet: ProxmoxSDNSubnet?
    @State private var creating = false
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Picker("Section", selection: $section) {
                Text("Zones").tag(0); Text("VNets").tag(1); Text("Subnets").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if section == 0 {
                Section("Zones") {
                    ForEach(zones) { item in
                        Button { editingZone = item } label: {
                            VStack(alignment: .leading) {
                                Text(item.zone).foregroundStyle(.primary)
                                Text([item.type, item.nodes, item.state].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(!canModify)
                    }
                }
            } else if section == 1 {
                Section("Virtual Networks") {
                    ForEach(vnets) { item in
                        Button { editingVNet = item } label: {
                            VStack(alignment: .leading) {
                                Text(item.vnet).foregroundStyle(.primary)
                                Text([item.zone, item.alias, item.state].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(!canModify)
                    }
                }
            } else {
                Section("Virtual Network") {
                    Picker("VNet", selection: $selectedVNet) {
                        ForEach(vnets) { Text($0.vnet).tag($0.vnet) }
                    }
                }
                Section("Subnets") {
                    ForEach(subnets) { item in
                        Button { editingSubnet = item } label: {
                            VStack(alignment: .leading) {
                                Text(item.subnet).foregroundStyle(.primary)
                                Text([item.gateway, item.snat ? String(localized: "SNAT") : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(!canModify)
                    }
                }
            }
            if canModify { Section { Button("Apply SDN Configuration") { Task { await apply() } } } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("SDN")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.disabled(!canModify || (section == 2 && selectedVNet.isEmpty)) } }
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .task(id: selectedVNet) { await loadSubnets() }
        .refreshable { await load() }
        .sheet(isPresented: $creating) {
            if section == 0 { SDNZoneEditor(item: nil) { await load() } }
            else if section == 1 { SDNVNetEditor(item: nil, zones: zones) { await load() } }
            else { SDNSubnetEditor(vnet: selectedVNet, item: nil) { await loadSubnets() } }
        }
        .sheet(item: $editingZone) { SDNZoneEditor(item: $0) { await load() } }
        .sheet(item: $editingVNet) { SDNVNetEditor(item: $0, zones: zones) { await load() } }
        .sheet(item: $editingSubnet) { SDNSubnetEditor(vnet: selectedVNet, item: $0) { await loadSubnets() } }
    }

    private var canModify: Bool { appState.hasPrivilege("SDN.Allocate", on: "/") }
    @MainActor private func load() async {
        guard let service = appState.service else { return }; loading = true; defer { loading = false }
        do { async let a = service.fetchSDNZones(); async let b = service.fetchSDNVNets(); (zones, vnets) = try await (a, b); if !vnets.contains(where: { $0.vnet == selectedVNet }) { selectedVNet = vnets.first?.vnet ?? "" }; await loadSubnets() } catch { self.error = error.localizedDescription }
    }
    @MainActor private func loadSubnets() async { guard let service = appState.service, !selectedVNet.isEmpty else { subnets = []; return }; do { subnets = try await service.fetchSDNSubnets(vnet: selectedVNet) } catch { self.error = error.localizedDescription } }
    @MainActor private func apply() async { guard let service = appState.service else { return }; do { try await service.applySDNConfiguration(); await load() } catch { self.error = error.localizedDescription } }
}

private struct SDNZoneEditor:View{
    @EnvironmentObject private var appState:AppState;@Environment(\.dismiss)private var dismiss;let item:ProxmoxSDNZone?;let onSaved:()async->Void
    @State private var id:String;@State private var type:String;@State private var nodes:String;@State private var mtu:String;@State private var bridge:String;@State private var working=false;@State private var error:String?
    init(item:ProxmoxSDNZone?,onSaved:@escaping()async->Void){self.item=item;self.onSaved=onSaved;_id=State(initialValue:item?.zone ?? "");_type=State(initialValue:item?.type ?? "simple");_nodes=State(initialValue:item?.nodes ?? "");_mtu=State(initialValue:item?.mtu.map { String($0) } ?? "");_bridge=State(initialValue:item?.bridge ?? "")}
    var body:some View{NavigationStack{Form{Section("Zone"){TextField("Zone ID",text:$id).disabled(item != nil);Picker("Type",selection:$type){ForEach(["simple","vlan","vxlan","evpn"],id:\.self){Text($0).tag($0)}}.disabled(item != nil);TextField("Nodes",text:$nodes);TextField("MTU",text:$mtu).keyboardType(.numberPad);if type=="vlan"{TextField("Bridge",text:$bridge)}};if let error{Section{Text(error).foregroundStyle(.red)}};if item != nil{Section{Button("Delete Zone",role:.destructive){Task{await remove()}}}}}.navigationTitle(item==nil ? "Add SDN Zone":"Edit SDN Zone").navigationBarTitleDisplayMode(.inline).toolbar{basicToolbar(canSave:!id.trimmed.isEmpty,dismiss:dismiss,save:save)}.overlay{if working{ProgressView()}}}}
    private var form:[String:String]{var f:[String:String]=[:];for(k,v)in[("nodes",nodes),("mtu",mtu),("bridge",bridge)]where !v.trimmed.isEmpty{f[k]=v.trimmed};return f}
    @MainActor private func save()async{guard let service=appState.service else{return};working=true;defer{working=false};do{if let item{try await service.updateSDNZone(id:item.zone,form:form)}else{var f=form;f["zone"]=id.trimmed;f["type"]=type;try await service.createSDNZone(form:f)};await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
    @MainActor private func remove()async{guard let service=appState.service,let item else{return};working=true;defer{working=false};do{try await service.deleteSDNZone(id:item.zone);await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
}

private struct SDNVNetEditor:View{
    @EnvironmentObject private var appState:AppState;@Environment(\.dismiss)private var dismiss;let item:ProxmoxSDNVNet?;let zones:[ProxmoxSDNZone];let onSaved:()async->Void
    @State private var id:String;@State private var zone:String;@State private var alias:String;@State private var tag:String;@State private var vlanAware:Bool;@State private var working=false;@State private var error:String?
    init(item:ProxmoxSDNVNet?,zones:[ProxmoxSDNZone],onSaved:@escaping()async->Void){self.item=item;self.zones=zones;self.onSaved=onSaved;_id=State(initialValue:item?.vnet ?? "");_zone=State(initialValue:item?.zone ?? zones.first?.zone ?? "");_alias=State(initialValue:item?.alias ?? "");_tag=State(initialValue:item?.tag.map { String($0) } ?? "");_vlanAware=State(initialValue:item?.vlanAware ?? false)}
    var body:some View{NavigationStack{Form{Section("Virtual Network"){TextField("VNet ID",text:$id).disabled(item != nil);Picker("Zone",selection:$zone){ForEach(zones){Text($0.zone).tag($0.zone)}};TextField("Alias",text:$alias);TextField("VLAN Tag",text:$tag).keyboardType(.numberPad);Toggle("VLAN Aware",isOn:$vlanAware)};if let error{Section{Text(error).foregroundStyle(.red)}};if item != nil{Section{Button("Delete VNet",role:.destructive){Task{await remove()}}}}}.navigationTitle(item==nil ? "Add VNet":"Edit VNet").navigationBarTitleDisplayMode(.inline).toolbar{basicToolbar(canSave:!id.trimmed.isEmpty && !zone.isEmpty,dismiss:dismiss,save:save)}.overlay{if working{ProgressView()}}}}
    private var form:[String:String]{var f=["zone":zone,"vlanaware":vlanAware ? "1":"0"];if !alias.trimmed.isEmpty{f["alias"]=alias.trimmed};if !tag.trimmed.isEmpty{f["tag"]=tag.trimmed};return f}
    @MainActor private func save()async{guard let service=appState.service else{return};working=true;defer{working=false};do{if let item{try await service.updateSDNVNet(id:item.vnet,form:form)}else{var f=form;f["vnet"]=id.trimmed;try await service.createSDNVNet(form:f)};await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
    @MainActor private func remove()async{guard let service=appState.service,let item else{return};working=true;defer{working=false};do{try await service.deleteSDNVNet(id:item.vnet);await onSaved();dismiss()}catch{self.error=error.localizedDescription}}
}

private struct SDNSubnetEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let vnet: String
    let item: ProxmoxSDNSubnet?
    let onSaved: () async -> Void
    @State private var subnet: String
    @State private var gateway: String
    @State private var snat: Bool
    @State private var working = false
    @State private var error: String?

    init(vnet: String, item: ProxmoxSDNSubnet?, onSaved: @escaping () async -> Void) {
        self.vnet = vnet; self.item = item; self.onSaved = onSaved
        _subnet = State(initialValue: item?.subnet ?? "")
        _gateway = State(initialValue: item?.gateway ?? "")
        _snat = State(initialValue: item?.snat ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Subnet") {
                    LabeledContent("VNet", value: vnet)
                    TextField("CIDR (for example 10.0.0.0/24)", text: $subnet).textInputAutocapitalization(.never).disabled(item != nil)
                    TextField("Gateway", text: $gateway).textInputAutocapitalization(.never)
                    Toggle("Source NAT", isOn: $snat)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if item != nil { Section { Button("Delete Subnet", role: .destructive) { Task { await remove() } } } }
            }
            .navigationTitle(item == nil ? "Add Subnet" : "Edit Subnet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { basicToolbar(canSave: !subnet.trimmed.isEmpty, dismiss: dismiss, save: save) }
            .overlay { if working { ProgressView() } }
        }
    }

    private var form: [String: String] {
        var value = ["snat": snat ? "1" : "0"]
        if !gateway.trimmed.isEmpty { value["gateway"] = gateway.trimmed }
        return value
    }
    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; do { if let item { try await service.updateSDNSubnet(vnet: vnet, id: item.subnet, form: form) } else { var value = form; value["subnet"] = subnet.trimmed; value["type"] = "subnet"; value["vnet"] = vnet; try await service.createSDNSubnet(vnet: vnet, form: value) }; await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let item else { return }; working = true; defer { working = false }; do { try await service.deleteSDNSubnet(vnet: vnet, id: item.subnet); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct InfrastructureToolbar:ToolbarContent{let canSave:Bool;let dismiss:DismissAction;let save:()->Void;var body:some ToolbarContent{ToolbarItem(placement:.cancellationAction){Button("Cancel"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("Save",action:save).disabled(!canSave)}}}
private func basicToolbar(canSave:Bool,dismiss:DismissAction,save:@escaping()async->Void)->InfrastructureToolbar{InfrastructureToolbar(canSave:canSave,dismiss:dismiss,save:{Task{await save()}})}
