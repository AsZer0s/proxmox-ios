import SwiftUI
import UIKit

struct AccessControlView: View {
    @EnvironmentObject private var appState: AppState
    @State private var users: [ProxmoxAccessUser] = []
    @State private var roles: [ProxmoxRole] = []
    @State private var acls: [ProxmoxACLEntry] = []
    @State private var section = 0
    @State private var loading = true
    @State private var error: String?
    @State private var editingUser: ProxmoxAccessUser?
    @State private var editingRole: ProxmoxRole?
    @State private var editingACL: ProxmoxACLEntry?
    @State private var creating = false

    var body: some View {
        List {
            Picker("Section", selection: $section) {
                Text("Users").tag(0); Text("Roles").tag(1); Text("ACL").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if section == 0 { usersSection }
            else if section == 1 { rolesSection }
            else { aclSection }

            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Users & Permissions")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.disabled(!canModify) } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $creating) {
            if section == 0 { UserEditor(user: nil) { await load() } }
            else if section == 1 { RoleEditor(role: nil) { await load() } }
            else { ACLEditor(entry: nil, users: users, roles: roles) { await load() } }
        }
        .sheet(item: $editingUser) { UserEditor(user: $0) { await load() } }
        .sheet(item: $editingRole) { RoleEditor(role: $0) { await load() } }
        .sheet(item: $editingACL) { ACLEditor(entry: $0, users: users, roles: roles) { await load() } }
    }

    @ViewBuilder private var usersSection: some View {
        Section("Users") {
            if users.isEmpty && !loading { Text("No users are visible.").foregroundStyle(.secondary) }
            ForEach(users) { user in
                Button { editingUser = user } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.displayName).foregroundStyle(.primary)
                            Text("\(user.userid)\(user.groups.isEmpty ? "" : " · " + user.groups.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: user.enabled ? "checkmark.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(user.enabled ? .green : .secondary)
                    }
                }.disabled(!canModify)
            }
        }
    }

    @ViewBuilder private var rolesSection: some View {
        Section("Roles") {
            ForEach(roles) { role in
                Button { editingRole = role } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(role.roleid).foregroundStyle(.primary)
                        Text(role.privileges.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.disabled(!canModify || role.special)
            }
        }
    }

    @ViewBuilder private var aclSection: some View {
        Section("Access Control List") {
            ForEach(acls) { entry in
                Button { editingACL = entry } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(entry.ugid) · \(entry.roleid)").foregroundStyle(.primary)
                        Text("\(entry.path) · \(entry.propagate ? String(localized: "Propagates") : String(localized: "This path only"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!canModify)
            }
        }
    }

    private var canModify: Bool { appState.hasPrivilege("Permissions.Modify", on: "/") }

    @MainActor private func load() async {
        guard let service = appState.service else { return }
        loading = true; error = nil; defer { loading = false }
        async let a = service.fetchAccessUsers(); async let b = service.fetchRoles(); async let c = service.fetchACLs()
        do { (users, roles, acls) = try await (a, b, c) } catch { self.error = error.localizedDescription }
    }
}

private struct UserEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let user: ProxmoxAccessUser?; let onSaved: () async -> Void
    @State private var userid: String; @State private var password = ""; @State private var firstName: String; @State private var lastName: String; @State private var email: String; @State private var groups: String; @State private var comment: String; @State private var enabled: Bool
    @State private var tokens: [ProxmoxAPIToken] = []; @State private var showingToken = false; @State private var editingToken: ProxmoxAPIToken?
    @State private var working = false; @State private var error: String?

    init(user: ProxmoxAccessUser?, onSaved: @escaping () async -> Void) { self.user = user; self.onSaved = onSaved; _userid = State(initialValue: user?.userid ?? ""); _firstName = State(initialValue: user?.firstname ?? ""); _lastName = State(initialValue: user?.lastname ?? ""); _email = State(initialValue: user?.email ?? ""); _groups = State(initialValue: user?.groups.joined(separator: ",") ?? ""); _comment = State(initialValue: user?.comment ?? ""); _enabled = State(initialValue: user?.enabled ?? true) }

    var body: some View { NavigationStack { Form {
        Section("Account") {
            TextField("User ID (name@realm)", text: $userid).textInputAutocapitalization(.never).disabled(user != nil)
            SecureField(user == nil ? "Password" : "New Password (optional)", text: $password)
            Toggle("Enabled", isOn: $enabled)
        }
        Section("Profile") { TextField("First Name", text: $firstName); TextField("Last Name", text: $lastName); TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never); TextField("Groups (comma separated)", text: $groups); TextField("Comment", text: $comment) }
        if user != nil { Section("API Tokens") {
            ForEach(tokens) { token in Button { editingToken = token } label: { HStack { VStack(alignment: .leading) { Text(token.tokenid).foregroundStyle(.primary); if let comment = token.comment { Text(comment).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Image(systemName: token.privilegeSeparation ? "person.crop.circle.badge.checkmark" : "equal.circle") } } }
            Button { showingToken = true } label: { Label("Add API Token", systemImage: "plus.circle") }
        } }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if user != nil { Section { Button("Delete User", role: .destructive) { Task { await remove() } } } }
    }
    .navigationTitle(user == nil ? "Add User" : "Edit User")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(userid.trimmed.isEmpty || (user == nil && password.isEmpty)) } }
    .overlay { if working { ProgressView() } }
    .task { await loadTokens() }
    .sheet(isPresented: $showingToken) { TokenEditor(userid: user?.userid ?? userid, token: nil) { await loadTokens() } }
    .sheet(item: $editingToken) { TokenEditor(userid: user?.userid ?? userid, token: $0) { await loadTokens() } }
    } }

    @MainActor private func loadTokens() async { guard let service = appState.service, let user else { return }; tokens = (try? await service.fetchAPITokens(userid: user.userid)) ?? [] }
    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; var form = ["enable":enabled ? "1":"0"]; if !password.isEmpty { form["password"] = password }; for (key,value) in [("firstname",firstName),("lastname",lastName),("email",email),("groups",groups),("comment",comment)] where !value.trimmed.isEmpty { form[key] = value.trimmed }; do { if let user { try await service.updateAccessUser(userid: user.userid, form: form) } else { form["userid"] = userid.trimmed; try await service.createAccessUser(form: form) }; await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let user else { return }; working = true; defer { working = false }; do { try await service.deleteAccessUser(userid: user.userid); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct TokenEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let userid: String; let token: ProxmoxAPIToken?; let onSaved: () async -> Void
    @State private var tokenid: String; @State private var comment: String; @State private var privsep: Bool; @State private var secret: ProxmoxAPITokenSecret?; @State private var working = false; @State private var error: String?
    init(userid: String, token: ProxmoxAPIToken?, onSaved: @escaping () async -> Void) { self.userid = userid; self.token = token; self.onSaved = onSaved; _tokenid = State(initialValue: token?.tokenid ?? ""); _comment = State(initialValue: token?.comment ?? ""); _privsep = State(initialValue: token?.privilegeSeparation ?? true) }
    var body: some View { NavigationStack { Form {
        if let secret { Section { Text(secret.fullTokenID).font(.caption.monospaced()).textSelection(.enabled); Text(secret.value).font(.caption.monospaced()).textSelection(.enabled); Button("Copy Token Secret") { UIPasteboard.general.string = secret.value } } header: { Text("Save This Secret Now") } footer: { Text("Proxmox shows this secret only once.") } }
        else { Section("Token") { TextField("Token ID", text: $tokenid).textInputAutocapitalization(.never).disabled(token != nil); Toggle("Privilege Separation", isOn: $privsep); TextField("Comment", text: $comment) } }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if token != nil && secret == nil { Section { Button("Delete API Token", role: .destructive) { Task { await remove() } } } }
    }.navigationTitle(token == nil ? "Add API Token" : "Edit API Token").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(secret == nil ? "Cancel" : "Done") { dismiss() } }
        if secret == nil { ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(tokenid.trimmed.isEmpty) } }
    }.overlay { if working { ProgressView() } } } }
    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; var form = ["privsep":privsep ? "1":"0"]; if !comment.trimmed.isEmpty { form["comment"] = comment.trimmed }; do { if let token { try await service.updateAPIToken(userid: userid, tokenid: token.tokenid, form: form); await onSaved(); dismiss() } else { secret = try await service.createAPIToken(userid: userid, tokenid: tokenid.trimmed, form: form); await onSaved() } } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let token else { return }; working = true; defer { working = false }; do { try await service.deleteAPIToken(userid: userid, tokenid: token.tokenid); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct RoleEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let role: ProxmoxRole?; let onSaved: () async -> Void
    @State private var roleid: String; @State private var selected: Set<String>; @State private var working = false; @State private var error: String?
    private let privileges = ["Datastore.Allocate","Datastore.AllocateSpace","Datastore.AllocateTemplate","Datastore.Audit","Group.Allocate","Mapping.Audit","Mapping.Modify","Permissions.Modify","Pool.Allocate","Pool.Audit","Realm.AllocateUser","Realm.Allocate","SDN.Allocate","SDN.Audit","Sys.Audit","Sys.Console","Sys.Incoming","Sys.Modify","Sys.PowerMgmt","Sys.Syslog","User.Modify","VM.Allocate","VM.Audit","VM.Backup","VM.Clone","VM.Config.CDROM","VM.Config.Cloudinit","VM.Config.CPU","VM.Config.Disk","VM.Config.HWType","VM.Config.Memory","VM.Config.Network","VM.Config.Options","VM.Console","VM.Migrate","VM.Monitor","VM.PowerMgmt","VM.Replicate","VM.Snapshot","VM.Snapshot.Rollback"]
    init(role: ProxmoxRole?, onSaved: @escaping () async -> Void) { self.role = role; self.onSaved = onSaved; _roleid = State(initialValue: role?.roleid ?? ""); _selected = State(initialValue: Set(role?.privileges ?? [])) }
    var body: some View { NavigationStack { List {
        Section { TextField("Role ID", text: $roleid).textInputAutocapitalization(.never).disabled(role != nil) }
        Section("Privileges") { ForEach(privileges, id: \.self) { privilege in Button { if selected.contains(privilege) { selected.remove(privilege) } else { selected.insert(privilege) } } label: { HStack { Text(privilege).foregroundStyle(.primary); Spacer(); if selected.contains(privilege) { Image(systemName: "checkmark").foregroundStyle(.blue) } } } } }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if role != nil { Section { Button("Delete Role", role: .destructive) { Task { await remove() } } } }
    }.navigationTitle(role == nil ? "Add Role" : "Edit Role").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(roleid.trimmed.isEmpty || selected.isEmpty) } }.overlay { if working { ProgressView() } } } }
    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; var form = ["privs":selected.sorted().joined(separator: ",")]; do { if let role { try await service.updateRole(id: role.roleid, form: form) } else { form["roleid"] = roleid.trimmed; try await service.createRole(form: form) }; await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let role else { return }; working = true; defer { working = false }; do { try await service.deleteRole(id: role.roleid); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}

private struct ACLEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let entry: ProxmoxACLEntry?; let users: [ProxmoxAccessUser]; let roles: [ProxmoxRole]; let onSaved: () async -> Void
    @State private var path: String; @State private var type: String; @State private var subject: String; @State private var role: String; @State private var propagate: Bool; @State private var working = false; @State private var error: String?
    init(entry: ProxmoxACLEntry?, users: [ProxmoxAccessUser], roles: [ProxmoxRole], onSaved: @escaping () async -> Void) { self.entry = entry; self.users = users; self.roles = roles; self.onSaved = onSaved; _path = State(initialValue: entry?.path ?? "/"); _type = State(initialValue: entry?.type ?? "user"); _subject = State(initialValue: entry?.ugid ?? users.first?.userid ?? ""); _role = State(initialValue: entry?.roleid ?? roles.first?.roleid ?? ""); _propagate = State(initialValue: entry?.propagate ?? true) }
    var body: some View { NavigationStack { Form {
        Section("ACL Entry") { TextField("Path", text: $path).textInputAutocapitalization(.never).disabled(entry != nil); Picker("Subject Type", selection: $type) { Text("User").tag("user"); Text("Group").tag("group"); Text("API Token").tag("token") }.disabled(entry != nil); if type == "user" { Picker("User", selection: $subject) { ForEach(users) { Text($0.userid).tag($0.userid) } } } else { TextField(type == "group" ? "Group ID" : "Full Token ID", text: $subject) }; Picker("Role", selection: $role) { ForEach(roles) { Text($0.roleid).tag($0.roleid) } }; Toggle("Propagate to Children", isOn: $propagate) }
        if let error { Section { Text(error).foregroundStyle(.red) } }
        if entry != nil { Section { Button("Delete ACL Entry", role: .destructive) { Task { await remove() } } } }
    }.navigationTitle(entry == nil ? "Add ACL" : "Edit ACL").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(path.trimmed.isEmpty || subject.trimmed.isEmpty || role.isEmpty) } }.overlay { if working { ProgressView() } } } }
    private var subjectKey: String { type == "group" ? "groups" : type == "token" ? "tokens" : "users" }
    private var form: [String:String] { ["path":path.trimmed,"roles":role,subjectKey:subject.trimmed,"propagate":propagate ? "1":"0"] }
    @MainActor private func save() async { guard let service = appState.service else { return }; working = true; defer { working = false }; do { if let entry { let oldKey = entry.type == "group" ? "groups" : entry.type == "token" ? "tokens" : "users"; let old = ["path": entry.path, "roles": entry.roleid, oldKey: entry.ugid, "propagate": entry.propagate ? "1" : "0", "delete": "1"]; try await service.updateACL(form: old) }; try await service.updateACL(form: form); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
    @MainActor private func remove() async { guard let service = appState.service, let entry else { return }; working = true; defer { working = false }; let oldKey = entry.type == "group" ? "groups" : entry.type == "token" ? "tokens" : "users"; let value = ["path": entry.path, "roles": entry.roleid, oldKey: entry.ugid, "propagate": entry.propagate ? "1" : "0", "delete": "1"]; do { try await service.updateACL(form: value); await onSaved(); dismiss() } catch { self.error = error.localizedDescription } }
}
