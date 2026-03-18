import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class MobileDirectDaemonManagerTests: XCTestCase {
    func testEnsureConnectionBuildsTLSServeArgumentsAndPublishesPin() async throws {
        let recorder = SpawnRecorder()
        let manager = MobileDirectDaemonManager(
            resolveBinaryPath: { "/tmp/cmuxd-remote" },
            getApplicationSupportDirectory: {
                FileManager.default.temporaryDirectory.appendingPathComponent("MobileDirectDaemonManagerTests-\(UUID().uuidString)")
            },
            allocatePort: { 9443 },
            spawn: recorder.spawn(binary:arguments:)
        )

        let info = try await manager.ensureConnection(
            hosts: MobileDirectDaemonHosts(
                machineID: "machine-123",
                hostname: "Lawrences-MacBook-Pro",
                tailscaleHostname: "macbook.tail-scale.ts.net",
                tailscaleIPs: ["100.64.0.7"]
            )
        )

        XCTAssertEqual(recorder.binaryPath, "/tmp/cmuxd-remote")
        XCTAssertEqual(
            recorder.arguments,
            [
                "serve",
                "--tls",
                "--listen",
                "0.0.0.0:9443",
                "--server-id",
                "machine-123",
                "--ticket-secret",
                "test-ticket-secret",
                "--cert-file",
                recorder.certPath ?? "",
                "--key-file",
                recorder.keyPath ?? "",
            ]
        )
        XCTAssertEqual(info.directPort, 9443)
        XCTAssertEqual(info.directTLSPins, ["sha256:test-pin"])
        XCTAssertEqual(info.ticketSecret, "test-ticket-secret")
    }
}

private final class SpawnRecorder {
    private(set) var binaryPath: String?
    private(set) var arguments: [String] = []
    private(set) var certPath: String?
    private(set) var keyPath: String?

    func spawn(binary: String, arguments: [String]) throws -> MobileDirectDaemonProcessHandle {
        binaryPath = binary
        self.arguments = arguments
        certPath = arguments[safe: 9]
        keyPath = arguments[safe: 11]
        return MobileDirectDaemonProcessHandle(
            processIdentifier: 42,
            waitUntilReady: { },
            terminate: { }
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
