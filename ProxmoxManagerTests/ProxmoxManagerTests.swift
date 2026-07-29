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
        XCTAssertEqual(server.baseURL, "https://pve.example.com:8006/api2/json")
    }

    func testServerDecodingDefaultsMissingCertificateSettingToSecure() throws {
        let data = Data(#"{"name":"PVE","host":"pve.example.com","username":"root"}"#.utf8)
        let server = try JSONDecoder().decode(ProxmoxServer.self, from: data)

        XCTAssertFalse(server.allowInsecureSSL)
        XCTAssertEqual(server.port, 8006)
        XCTAssertEqual(server.realm, "pam")
    }

    func testIPv6HostBuildsValidBaseURL() {
        let server = ProxmoxServer(
            name: "PVE",
            host: "[fd00::10]",
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
}
