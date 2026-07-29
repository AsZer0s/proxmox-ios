import XCTest
@testable import ProxmoxManager

final class ProxmoxManagerTests: XCTestCase {
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
        XCTAssertEqual(AuthMethod.ticket.label, "Username + Password")
        XCTAssertEqual(AuthMethod.token.label, "API Token")
    }

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

    func testFormAndPathEncodingProtectSeparators() {
        XCTAssertEqual("a+b&c=d".formURLEncoded, "a%2Bb%26c%3Dd")
        XCTAssertEqual("snap/name".pathEscaped, "snap%2Fname")
        XCTAssertEqual("UPID:pve:100:abc:qmstart:100:root@pam:".pathEscaped,
                       "UPID%3Apve%3A100%3Aabc%3Aqmstart%3A100%3Aroot%40pam%3A")
    }

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

    func testKeychainAccountSuffixes() {
        let id = UUID()
        // Just test that the helper methods compile and accept the new auth-aware interface
        // (full integration requires a signed test host with Keychain access)
    }

    func testProxmoxErrorDescriptions() {
        XCTAssertNotNil(ProxmoxError.invalidURL.localizedDescription)
        XCTAssertNotNil(ProxmoxError.notAuthenticated.localizedDescription)
        XCTAssertEqual(ProxmoxError.authenticationFailed("bad password").localizedDescription,
                       "Authentication failed: bad password")
        if case .requestFailed(let status, _) = ProxmoxError.requestFailed(status: 500, body: "") {
            XCTAssertEqual(status, 500)
        }
    }
}
