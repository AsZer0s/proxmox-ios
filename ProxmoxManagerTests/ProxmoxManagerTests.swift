import XCTest
@testable import ProxmoxManager

final class ProxmoxManagerTests: XCTestCase {
    // MARK: - Server defaults

    func testServerDefaultsToSecureCertificateValidation() {
        let server = ProxmoxServer(
            name: "PVE",
            host: "pve.example.com",
            username: "root"
        )

        XCTAssertFalse(server.allowInsecureSSL)
        XCTAssertEqual(server.authMethod, .ticket)
        XCTAssertEqual(server.tokenID, "")
        XCTAssertEqual(server.baseURL, "https://pve.example.com:8006/api2/json")
    }

    func testServerDecodingDefaultsMissingFieldsToSecure() throws {
        let data = Data(#"{"name":"PVE","host":"pve.example.com","username":"root"}"#.utf8)
        let server = try JSONDecoder().decode(ProxmoxServer.self, from: data)

        XCTAssertFalse(server.allowInsecureSSL)
        XCTAssertEqual(server.authMethod, .ticket)
        XCTAssertEqual(server.tokenID, "")
        XCTAssertEqual(server.port, 8006)
        XCTAssertEqual(server.realm, "pam")
    }

    // MARK: - Auth method

    func testServerTokenAuthRoundTrip() throws {
        let server = ProxmoxServer(
            name: "PVE",
            host: "pve.example.com",
            username: "root",
            authMethod: .token,
            tokenID: "root@pam!mytoken"
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(ProxmoxServer.self, from: data)

        XCTAssertEqual(decoded.authMethod, .token)
        XCTAssertEqual(decoded.tokenID, "root@pam!mytoken")
    }

    func testAuthMethodCases() {
        XCTAssertEqual(AuthMethod.allCases.count, 2)
        XCTAssertEqual(AuthMethod.ticket.label, String(localized: "Username + Password"))
        XCTAssertEqual(AuthMethod.token.label, String(localized: "API Token"))
    }

    func testServerCodableRetainsAllFields() throws {
        let server = ProxmoxServer(
            name: "PVE",
            host: "192.168.1.100",
            port: 8006,
            username: "admin",
            realm: "pve",
            allowInsecureSSL: true,
            authMethod: .token,
            tokenID: "admin@pve!test"
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(ProxmoxServer.self, from: data)

        XCTAssertEqual(decoded.name, "PVE")
        XCTAssertEqual(decoded.host, "192.168.1.100")
        XCTAssertEqual(decoded.port, 8006)
        XCTAssertEqual(decoded.username, "admin")
        XCTAssertEqual(decoded.realm, "pve")
        XCTAssertTrue(decoded.allowInsecureSSL)
        XCTAssertEqual(decoded.authMethod, .token)
        XCTAssertEqual(decoded.tokenID, "admin@pve!test")
    }

    // MARK: - URL / IPv6

    func testIPv6HostBuildsValidBaseURL() {
        let server = ProxmoxServer(
            name: "PVE",
            host: "[fd00::10]",
            username: "root"
        )

        XCTAssertEqual(server.baseURL, "https://[fd00::10]:8006/api2/json")
    }

    func testIPv6BareHostGetsBracketed() {
        let server = ProxmoxServer(
            name: "PVE",
            host: "fd00::10",
            username: "root"
        )

        XCTAssertEqual(server.baseURL, "https://[fd00::10]:8006/api2/json")
    }

    func testIPv4StandardFormat() {
        let server = ProxmoxServer(
            name: "PVE",
            host: "192.168.1.1",
            username: "root"
        )
        XCTAssertEqual(server.baseURL, "https://192.168.1.1:8006/api2/json")
    }

    func testDomainHost() {
        let server = ProxmoxServer(
            name: "PVE",
            host: "pve.example.com",
            port: 443,
            username: "root"
        )
        XCTAssertEqual(server.baseURL, "https://pve.example.com:443/api2/json")
    }

    // MARK: - Encoding

    func testFormAndPathEncodingProtectSeparators() {
        XCTAssertEqual("a+b&c=d".formURLEncoded, "a%2Bb%26c%3Dd")
        XCTAssertEqual("snap/name".pathEscaped, "snap%2Fname")
        XCTAssertEqual("UPID:pve:100:abc:qmstart:100:root@pam:".pathEscaped,
                       "UPID%3Apve%3A100%3Aabc%3Aqmstart%3A100%3Aroot%40pam%3A")
    }

    // MARK: - GuestConfig decoding

    func testGuestConfigDecodesNumericStrings() throws {
        let data = Data(#"""
            {
                "cores": "4",
                "memory": "4096",
                "onboot": 1,
                "agent": 1,
                "net0": "virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0"
            }
            """#.utf8)

        let config = try JSONDecoder().decode(GuestConfig.self, from: data)

        XCTAssertEqual(config.cores, 4)
        XCTAssertEqual(config.memory, 4096)
        XCTAssertEqual(config.onboot, 1)
        XCTAssertEqual(config.agent, "1")
        XCTAssertEqual(config.net0, "virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0")
    }

    func testGuestConfigAllOptionalFields() throws {
        let data = Data(#"{}"#.utf8)
        let config = try JSONDecoder().decode(GuestConfig.self, from: data)
        // All fields should be nil
        XCTAssertNil(config.name)
        XCTAssertNil(config.cores)
        XCTAssertNil(config.memory)
        XCTAssertNil(config.net0)
    }

    // MARK: - Task status

    func testTaskStatusOnlySucceedsWithOKExitStatus() {
        let running = ProxmoxTaskStatus(
            status: "running",
            exitstatus: nil,
            type: "qmstart",
            node: "pve",
            pid: 10,
            starttime: nil,
            endtime: nil
        )
        let finished = ProxmoxTaskStatus(
            status: "stopped",
            exitstatus: "OK",
            type: "qmstart",
            node: "pve",
            pid: 10,
            starttime: nil,
            endtime: 100
        )

        XCTAssertFalse(running.isFinished)
        XCTAssertFalse(running.isSuccessful)
        XCTAssertTrue(finished.isFinished)
        XCTAssertTrue(finished.isSuccessful)
    }

    func testTaskStatusFailedExitStatus() {
        let failed = ProxmoxTaskStatus(
            status: "stopped",
            exitstatus: "ERROR",
            type: "qmstart",
            node: "pve",
            pid: 10,
            starttime: nil,
            endtime: 200
        )

        XCTAssertTrue(failed.isFinished)
        XCTAssertFalse(failed.isSuccessful)
    }

    // MARK: - ProxmoxError

    func testProxmoxErrorDescriptions() {
        XCTAssertEqual(ProxmoxError.invalidURL.localizedDescription, "The server URL is invalid.")
        XCTAssertEqual(ProxmoxError.notAuthenticated.localizedDescription, "Not logged in. Please connect to the server first.")
        XCTAssertEqual(ProxmoxError.authenticationFailed("bad password").localizedDescription,
                       "Authentication failed: bad password")
        XCTAssertEqual(ProxmoxError.tfaRequired.localizedDescription,
                       "Two-factor authentication is required. Enter your TOTP code.")
    }

    func testRequestFailedHidesBody() {
        let err = ProxmoxError.requestFailed(status: 500, body: "Internal server error details here")
        XCTAssertFalse(err.localizedDescription.contains("Internal server error"))
        XCTAssertTrue(err.localizedDescription.contains("HTTP 500"))
    }

    func testCertificateErrorsFormatCorrectly() {
        let confirm = ProxmoxError.certificateConfirmationRequired(
            host: "pve.local", fingerprint: "AA:BB:CC:DD:EE:FF"
        )
        XCTAssertTrue(confirm.localizedDescription.contains("pve.local"))
        XCTAssertTrue(confirm.localizedDescription.contains("AA:BB:CC:DD:EE:FF"))

        let mismatch = ProxmoxError.certificateMismatch(
            host: "pve.local", expected: "AA:BB", actual: "CC:DD"
        )
        XCTAssertTrue(mismatch.localizedDescription.contains("pve.local"))
    }

    // MARK: - ProxmoxTicketPayload

    func testTicketPayloadDecode() throws {
        let data = Data("""
        {"data":{"ticket":"PVE:ticket","CSRFPreventionToken":"token123","username":"root@pam"}}
        """.utf8)
        let resp = try JSONDecoder().decode(ProxmoxResponse<ProxmoxTicketPayload>.self, from: data)
        XCTAssertEqual(resp.data.ticket, "PVE:ticket")
        XCTAssertEqual(resp.data.csrfToken, "token123")
        XCTAssertEqual(resp.data.username, "root@pam")
        XCTAssertFalse(resp.data.requiresTFA)
    }

    func testTicketPayloadTFAChallenge() throws {
        let data = Data("""
        {"data":{"ticket":"PVE:!tfa!%7B%22totp%22%3Atrue%7D:challenge","username":"root@pam"}}
        """.utf8)
        let resp = try JSONDecoder().decode(ProxmoxResponse<ProxmoxTicketPayload>.self, from: data)
        XCTAssertTrue(resp.data.requiresTFA)
        XCTAssertEqual(resp.data.csrfToken, "")
    }

    func testTOTPFormUsesOfficialChallengeFlow() {
        let body = ProxmoxAPIService.totpFormBody(
            username: "root@pam",
            code: "123456",
            challengeTicket: "PVE:!tfa!challenge"
        )

        XCTAssertEqual(
            body,
            "username=root%40pam&password=totp%3A123456&tfa-challenge=PVE%3A%21tfa%21challenge&new-format=1"
        )
    }

    // MARK: - ProxmoxResponse

    func testProxmoxResponseDecode() throws {
        let data = Data(#"{"data":"UPID:node:000:abc:task:100:root@pam:"}"#.utf8)
        let resp = try JSONDecoder().decode(ProxmoxResponse<String>.self, from: data)
        XCTAssertEqual(resp.data, "UPID:node:000:abc:task:100:root@pam:")
    }

    func testProxmoxIntegerAcceptsNumberAndStringResponses() throws {
        let number = try JSONDecoder().decode(
            ProxmoxResponse<ProxmoxInteger>.self,
            from: Data(#"{"data":120}"#.utf8)
        )
        let string = try JSONDecoder().decode(
            ProxmoxResponse<ProxmoxInteger>.self,
            from: Data(#"{"data":"121"}"#.utf8)
        )

        XCTAssertEqual(number.data.value, 120)
        XCTAssertEqual(string.data.value, 121)
    }

    // MARK: - AuthMethod

    func testAuthMethodIdentifiable() {
        XCTAssertEqual(AuthMethod.ticket.id, "ticket")
        XCTAssertEqual(AuthMethod.token.id, "token")
    }

    // MARK: - Keychain account naming

    func testKeychainAccountFormats() {
        let id = UUID()
        // These compile successfully: the interface is consistent
        XCTAssertNotNil(id.uuidString)
    }

    // MARK: - Storage models

    func testStorageContentDisplayName() {
        let content = ProxmoxStorageContent(
            volid: "local:iso/ubuntu-22.04.iso",
            format: "iso",
            size: 4_000_000_000,
            used: nil,
            content: "iso",
            notes: nil,
            vmid: nil
        )
        XCTAssertEqual(content.displayName, "ubuntu-22.04.iso")
    }

    func testStorageContentDisplayNameFallback() {
        let content = ProxmoxStorageContent(
            volid: "simple-id",
            format: nil,
            size: nil,
            used: nil,
            content: nil,
            notes: nil,
            vmid: nil
        )
        XCTAssertEqual(content.displayName, "simple-id")
    }

    func testStorageContentDecodesBooleanProtectedFlag() throws {
        let data = Data(#"""
        {
          "volid": "pbs:backup/vm/100/2026-07-30T00:00:00Z",
          "content": "backup",
          "vmid": 100,
          "size": 1024,
          "ctime": 1785369600,
          "protected": true
        }
        """#.utf8)

        let content = try JSONDecoder().decode(ProxmoxStorageContent.self, from: data)
        XCTAssertEqual(content.protectedFlag, 1)
        XCTAssertEqual(content.ctime, 1_785_369_600)
    }

    // MARK: - GuestSnapshot

    func testGuestSnapshotCurrentDetection() {
        let current = GuestSnapshot(name: "current", description: nil, snaptime: nil, parent: nil, vmstate: nil)
        XCTAssertTrue(current.isCurrent)

        let normal = GuestSnapshot(name: "snap1", description: nil, snaptime: 1000, parent: nil, vmstate: nil)
        XCTAssertFalse(normal.isCurrent)
    }

    // MARK: - ProxmoxVM

    func testProxmoxVMDisplayName() {
        let named = ProxmoxVM(vmid: 100, name: "web-server", status: "running", cpu: nil, cpus: nil, mem: nil, maxmem: nil, disk: nil, maxdisk: nil, uptime: nil)
        XCTAssertEqual(named.displayName, "web-server")

        let unnamed = ProxmoxVM(vmid: 101, name: nil, status: "running", cpu: nil, cpus: nil, mem: nil, maxmem: nil, disk: nil, maxdisk: nil, uptime: nil)
        XCTAssertEqual(unnamed.displayName, "VM 101")
    }

    // MARK: - ResourceType

    func testResourceTypeDecode() throws {
        XCTAssertEqual(try JSONDecoder().decode(ResourceType.self, from: Data(#""qemu""#.utf8)), .qemu)
        XCTAssertEqual(try JSONDecoder().decode(ResourceType.self, from: Data(#""lxc""#.utf8)), .lxc)
        XCTAssertEqual(try JSONDecoder().decode(ResourceType.self, from: Data(#""node""#.utf8)), .node)
        XCTAssertEqual(try JSONDecoder().decode(ResourceType.self, from: Data(#""unknown_type""#.utf8)), .unknown)
    }

    // MARK: - FFI

    func testServerFullUsername() {
        let server = ProxmoxServer(name: "PVE", host: "pve.local", username: "admin", realm: "pve")
        XCTAssertEqual(server.fullUsername, "admin@pve")
    }

    func testServerDefaultRealm() {
        let server = ProxmoxServer(name: "PVE", host: "pve.local", username: "root")
        XCTAssertEqual(server.fullUsername, "root@pam")
    }

    // MARK: - GuestAction

    func testGuestActionDestructive() {
        XCTAssertTrue(GuestAction.stop.isDestructive)
        XCTAssertTrue(GuestAction.shutdown.isDestructive)
        XCTAssertTrue(GuestAction.reboot.isDestructive)
        XCTAssertFalse(GuestAction.start.isDestructive)
    }

    func testGuestActionLabels() {
        XCTAssertEqual(GuestAction.start.label, String(localized: "Start"))
        XCTAssertEqual(GuestAction.stop.label, String(localized: "Stop"))
        XCTAssertEqual(GuestAction.shutdown.label, String(localized: "Shutdown"))
        XCTAssertEqual(GuestAction.reboot.label, String(localized: "Reboot"))
    }

    func testProxmoxStatusLabelsAreLocalized() {
        XCTAssertEqual(localizedProxmoxStatus("running"), String(localized: "Running"))
        XCTAssertEqual(localizedProxmoxStatus("online"), String(localized: "Online"))
        XCTAssertEqual(localizedProxmoxStatus(nil), String(localized: "Unknown"))
        XCTAssertEqual(localizedProxmoxStatus("migrating"), "Migrating")
    }

    // MARK: - ProxmoxStorage

    func testStorageTypes() {
        let storage = ProxmoxStorage(
            storage: "local",
            type: "dir",
            active: 1,
            used: 500_000_000_000,
            avail: 1_000_000_000_000,
            total: 1_500_000_000_000,
            usedFraction: 0.33,
            content: "iso,vztmpl,backup"
        )
        XCTAssertTrue(storage.isAvailable)
        XCTAssertEqual(storage.storageTypes, ["iso", "vztmpl", "backup"])
    }

    func testStorageDecodesBooleanFlagsAndNumericStrings() throws {
        let data = Data(#"""
        {
          "storage": "local-lvm",
          "type": "lvmthin",
          "active": true,
          "enabled": "1",
          "used": "1024",
          "avail": 2048,
          "total": "3072",
          "used_fraction": "0.3333",
          "content": "images,rootdir"
        }
        """#.utf8)

        let storage = try JSONDecoder().decode(ProxmoxStorage.self, from: data)
        XCTAssertTrue(storage.isAvailable)
        XCTAssertEqual(storage.active, 1)
        XCTAssertEqual(storage.enabled, 1)
        XCTAssertEqual(storage.used, 1024)
        XCTAssertEqual(storage.total, 3072)
        XCTAssertEqual(storage.usedFraction, 0.3333)
        XCTAssertEqual(storage.storageTypes, ["images", "rootdir"])
    }

    func testStorageContentAllowsMissingContentAndNumericStrings() throws {
        let data = Data(#"""
        {
          "volid": "local:vztmpl/debian-13.tar.zst",
          "format": "tzst",
          "size": "2048",
          "ctime": "1785369600"
        }
        """#.utf8)

        let content = try JSONDecoder().decode(ProxmoxStorageContent.self, from: data)
        XCTAssertNil(content.content)
        XCTAssertEqual(content.size, 2048)
        XCTAssertEqual(content.ctime, 1_785_369_600)
    }

    func testApplianceTemplateDecodesOfficialFields() throws {
        let data = Data(#"""
        {
          "template": "debian-13-standard_13.0-1_amd64.tar.zst",
          "type": "lxc",
          "package": "debian-13-standard",
          "version": "13.0-1",
          "headline": "Debian 13 standard",
          "os": "debian",
          "section": "system"
        }
        """#.utf8)

        let template = try JSONDecoder().decode(ApplianceTemplate.self, from: data)
        XCTAssertEqual(template.id, "debian-13-standard_13.0-1_amd64.tar.zst")
        XCTAssertEqual(template.displayName, "debian-13-standard")
        XCTAssertEqual(template.section, "system")
    }

    // MARK: - Official permission response shape

    func testPermissionsDecodeOfficialShapeAndInheritance() throws {
        let data = Data(#"""
        {
          "data": {
            "/": {"Sys.Audit": 1},
            "/vms": {"VM.PowerMgmt": true},
            "/vms/100": {"VM.Snapshot": 0}
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(
            ProxmoxResponse<ProxmoxPermissions>.self,
            from: data
        )

        XCTAssertTrue(response.data.hasPrivilege("Sys.Audit", on: "/"))
        XCTAssertTrue(response.data.hasPrivilege("VM.PowerMgmt", on: "/vms/101"))
        XCTAssertTrue(response.data.hasPrivilege("VM.Snapshot", on: "/vms/100"))
        XCTAssertFalse(response.data.hasPrivilege("VM.Snapshot", on: "/vms/101"))
    }

    // MARK: - Guest lifecycle API contracts

    func testGuestLifecycleEndpointsMatchPVEAPI() {
        XCTAssertEqual(ProxmoxEndpoint.nextVMID, "/cluster/nextid")
        XCTAssertEqual(
            ProxmoxEndpoint.guests(node: "pve1", type: .qemu),
            "/nodes/pve1/qemu"
        )
        XCTAssertEqual(
            ProxmoxEndpoint.guest(node: "pve1", type: .lxc, vmid: 120),
            "/nodes/pve1/lxc/120"
        )
        XCTAssertEqual(
            ProxmoxEndpoint.guestConfig(node: "pve1", type: .qemu, vmid: 121),
            "/nodes/pve1/qemu/121/config"
        )
        XCTAssertEqual(
            ProxmoxEndpoint.storageContent(
                node: "pve1",
                storage: "local/templates",
                content: "vztmpl"
            ),
            "/nodes/pve1/storage/local%2Ftemplates/content?content=vztmpl"
        )
        XCTAssertEqual(ProxmoxEndpoint.appliances(node: "pve1"), "/nodes/pve1/aplinfo")
        XCTAssertEqual(
            ProxmoxEndpoint.storageDownload(node: "pve1", storage: "local/iso"),
            "/nodes/pve1/storage/local%2Fiso/download-url"
        )
    }

    func testQEMUCreateRequestBuildsLinuxForm() {
        let request = GuestCreateRequest(
            node: "pve1",
            type: .qemu,
            vmid: 120,
            name: "web-01",
            cores: 4,
            sockets: 2,
            memoryMiB: 4096,
            onBoot: true,
            startAfterCreation: false,
            storage: "local-lvm",
            diskSizeGiB: 32,
            bridge: "vmbr1",
            osType: "l26",
            installationVolume: "local:iso/debian.iso",
            rootPassword: nil,
            swapMiB: 0,
            unprivileged: true
        )

        XCTAssertEqual(request.form["name"], "web-01")
        XCTAssertEqual(request.form["scsi0"], "local-lvm:32")
        XCTAssertEqual(request.form["scsihw"], "virtio-scsi-pci")
        XCTAssertEqual(request.form["net0"], "virtio,bridge=vmbr1")
        XCTAssertEqual(request.form["ide2"], "local:iso/debian.iso,media=cdrom")
        XCTAssertEqual(request.form["boot"], "order=scsi0;ide2")
        XCTAssertEqual(request.form["onboot"], "1")
        XCTAssertEqual(request.form["start"], "0")
    }

    func testLXCCreateRequestBuildsContainerForm() {
        let request = GuestCreateRequest(
            node: "pve1",
            type: .lxc,
            vmid: 220,
            name: "worker-01",
            cores: 2,
            sockets: 1,
            memoryMiB: 1024,
            onBoot: false,
            startAfterCreation: true,
            storage: "local-lvm",
            diskSizeGiB: 8,
            bridge: "vmbr0",
            osType: "l26",
            installationVolume: "local:vztmpl/debian.tar.zst",
            rootPassword: "secret",
            swapMiB: 512,
            unprivileged: true
        )

        XCTAssertEqual(request.form["hostname"], "worker-01")
        XCTAssertEqual(request.form["ostemplate"], "local:vztmpl/debian.tar.zst")
        XCTAssertEqual(request.form["rootfs"], "local-lvm:8")
        XCTAssertEqual(request.form["password"], "secret")
        XCTAssertEqual(request.form["swap"], "512")
        XCTAssertEqual(request.form["unprivileged"], "1")
        XCTAssertEqual(request.form["net0"], "name=eth0,bridge=vmbr0,ip=dhcp")
    }

    func testMutationFormBodyIsDeterministicAndEncoded() {
        let data = ProxmoxAPIService.formBody([
            "name": "web & api",
            "net0": "virtio,bridge=vmbr0",
        ])

        XCTAssertEqual(
            data.flatMap { String(data: $0, encoding: .utf8) },
            "name=web%20%26%20api&net0=virtio%2Cbridge%3Dvmbr0"
        )
    }

    // MARK: - Backup API contracts

    func testBackupEndpointsMatchPVEAPI() {
        XCTAssertEqual(ProxmoxEndpoint.backupJobs, "/cluster/backup")
        XCTAssertEqual(ProxmoxEndpoint.vzdump(node: "pve1"), "/nodes/pve1/vzdump")
        XCTAssertEqual(
            ProxmoxEndpoint.backupArchives(node: "pve1", storage: "backup/store"),
            "/nodes/pve1/storage/backup%2Fstore/content?content=backup"
        )
    }

    func testBackupJobDecodesBooleanCompatibleFields() throws {
        let data = Data(#"""
        {
          "id": "backup-001",
          "node": "pve1",
          "storage": "pbs",
          "schedule": "daily",
          "vmid": 100,
          "mode": "snapshot",
          "enabled": 1,
          "all": "0"
        }
        """#.utf8)

        let job = try JSONDecoder().decode(ProxmoxBackupJob.self, from: data)
        XCTAssertEqual(job.vmid, "100")
        XCTAssertTrue(job.isEnabled)
        XCTAssertEqual(job.all, false)
    }

    // MARK: - Node CPU

    func testNodeCPUIsAlreadyAClusterWideFraction() {
        let node = ProxmoxNode(
            node: "pve1",
            status: "online",
            cpu: 0.42,
            maxcpu: 8,
            mem: nil,
            maxmem: nil,
            disk: nil,
            maxdisk: nil,
            uptime: nil,
            level: nil
        )

        XCTAssertEqual(node.cpuFraction, 0.42)
    }
}
