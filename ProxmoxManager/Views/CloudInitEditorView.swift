import SwiftUI

struct CloudInitEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let guest: ProxmoxVM
    let config: GuestConfig
    let onSaved: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var sshKeys: String
    @State private var dnsServers: String
    @State private var searchDomain: String
    @State private var upgradePackages: Bool
    @State private var networks: [CloudInitNetworkSettings]
    @State private var isSaving = false
    @State private var error: String?

    init(guest: ProxmoxVM, config: GuestConfig, onSaved: @escaping () -> Void) {
        self.guest = guest
        self.config = config
        self.onSaved = onSaved

        _username = State(initialValue: config.rawValues["ciuser"] ?? "")
        _sshKeys = State(initialValue: Self.decodedSSHKeys(config.rawValues["sshkeys"] ?? ""))
        _dnsServers = State(initialValue: config.rawValues["nameserver"] ?? "")
        _searchDomain = State(initialValue: config.rawValues["searchdomain"] ?? "")
        _upgradePackages = State(initialValue: config.rawValues["ciupgrade"] != "0")

        var indices = Set(config.networks.compactMap {
            Int($0.key.dropFirst("net".count))
        })
        for key in config.rawValues.keys where
            key.range(of: #"^ipconfig\d+$"#, options: .regularExpression) != nil {
            if let index = Int(key.dropFirst("ipconfig".count)) {
                indices.insert(index)
            }
        }
        _networks = State(initialValue: indices.sorted().map {
            CloudInitNetworkSettings(index: $0, value: config.rawValues["ipconfig\($0)"])
        })
    }

    private var hasCloudInitDrive: Bool {
        config.rawValues.contains { key, value in
            key.range(
                of: #"^(ide|sata|scsi)\d+$"#,
                options: .regularExpression
            ) != nil && value.lowercased().contains("cloudinit")
        }
    }

    private var canSave: Bool {
        networks.allSatisfy(\.isValid)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !hasCloudInitDrive {
                    Section {
                        Label(
                            "This VM has no Cloud-Init drive. Add one in Proxmox before expecting these settings to apply.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("Cloud-Init User", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("New Password (optional)", text: $password)
                        .textContentType(.newPassword)
                    Toggle("Upgrade Packages on First Boot", isOn: $upgradePackages)
                } footer: {
                    Text("Leave the password empty to keep the existing password. SSH keys are recommended.")
                }

                Section {
                    TextEditor(text: $sshKeys)
                        .frame(minHeight: 130)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("SSH Public Keys")
                } footer: {
                    Text("Enter one OpenSSH public key per line.")
                }

                Section {
                    TextField("DNS Servers", text: $dnsServers)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("DNS Search Domain", text: $searchDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Separate multiple DNS server addresses with spaces.")
                }

                if networks.isEmpty {
                    Section {
                        Text("Add a virtual network interface before configuring Cloud-Init networking.")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Network")
                    }
                } else {
                    ForEach($networks) { $network in
                        cloudInitNetworkSection(network: $network)
                    }
                }

                if !canSave {
                    Section {
                        Label(
                            "Check static IP/CIDR and gateway values.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Cloud-Init")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView()
                }
            }
        }
    }

    private func cloudInitNetworkSection(
        network: Binding<CloudInitNetworkSettings>
    ) -> some View {
        Section {
            Picker("IPv4 Configuration", selection: network.ipv4Mode) {
                Text("No Configuration").tag(GuestNetworkSettings.IPMode.unspecified)
                Text("DHCP").tag(GuestNetworkSettings.IPMode.dhcp)
                Text("Static").tag(GuestNetworkSettings.IPMode.static)
            }
            if network.wrappedValue.ipv4Mode == .static {
                TextField("IPv4 Address / CIDR", text: network.ipv4Address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("IPv4 Gateway (optional)", text: network.ipv4Gateway)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Picker("IPv6 Configuration", selection: network.ipv6Mode) {
                Text("No Configuration").tag(GuestNetworkSettings.IPMode.unspecified)
                Text("Automatic").tag(GuestNetworkSettings.IPMode.automatic)
                Text("DHCP").tag(GuestNetworkSettings.IPMode.dhcp)
                Text("Static").tag(GuestNetworkSettings.IPMode.static)
            }
            if network.wrappedValue.ipv6Mode == .static {
                TextField("IPv6 Address / CIDR", text: network.ipv6Address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("IPv6 Gateway (optional)", text: network.ipv6Gateway)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Cloud-Init Network \(network.wrappedValue.index)")
        }
    }

    @MainActor
    private func save() async {
        guard let service = appState.service, canSave else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        var form: [String: String] = [:]
        var deleted: [String] = []
        appendChange(
            key: "ciuser",
            value: username,
            original: config.rawValues["ciuser"] ?? "",
            form: &form,
            deleted: &deleted
        )
        appendChange(
            key: "sshkeys",
            value: sshKeys,
            original: Self.decodedSSHKeys(config.rawValues["sshkeys"] ?? ""),
            form: &form,
            deleted: &deleted
        )
        appendChange(
            key: "nameserver",
            value: dnsServers,
            original: config.rawValues["nameserver"] ?? "",
            form: &form,
            deleted: &deleted
        )
        appendChange(
            key: "searchdomain",
            value: searchDomain,
            original: config.rawValues["searchdomain"] ?? "",
            form: &form,
            deleted: &deleted
        )

        let originalUpgrade = config.rawValues["ciupgrade"] != "0"
        if upgradePackages != originalUpgrade {
            form["ciupgrade"] = upgradePackages ? "1" : "0"
        }
        if !password.isEmpty {
            form["cipassword"] = password
        }

        for network in networks {
            let key = "ipconfig\(network.index)"
            let original = config.rawValues[key]
            let value = network.encodedValue
            if value != original {
                if let value {
                    form[key] = value
                } else if original != nil {
                    deleted.append(key)
                }
            }
        }

        if !deleted.isEmpty {
            form["delete"] = deleted.joined(separator: ",")
        }

        do {
            _ = try await service.updateGuest(
                node: guest.node,
                type: guest.type,
                vmid: guest.vmid,
                form: form
            )
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func appendChange(
        key: String,
        value: String,
        original: String,
        form: inout [String: String],
        deleted: inout [String]
    ) {
        let value = value.trimmed
        let original = original.trimmed
        guard value != original else { return }
        if value.isEmpty {
            if !original.isEmpty {
                deleted.append(key)
            }
        } else {
            form[key] = value
        }
    }

    private static func decodedSSHKeys(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
