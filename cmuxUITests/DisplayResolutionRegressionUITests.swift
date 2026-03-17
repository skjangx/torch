import XCTest
import Foundation

final class DisplayResolutionRegressionUITests: XCTestCase {
    private let displayHarnessManifestPath = "/tmp/cmux-ui-test-display-harness.json"
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var displayReadyPath = ""
    private var displayIDPath = ""
    private var displayStartPath = ""
    private var displayDonePath = ""
    private var helperBinaryPath = ""
    private var helperLogPath = ""
    private var helperProcess: Process?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let token = UUID().uuidString
        socketPath = "/tmp/cmux-ui-test-display-churn-\(token).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-display-churn-\(token).json"
        displayReadyPath = "/tmp/cmux-ui-test-display-ready-\(token)"
        displayIDPath = "/tmp/cmux-ui-test-display-id-\(token)"
        displayStartPath = "/tmp/cmux-ui-test-display-start-\(token)"
        displayDonePath = "/tmp/cmux-ui-test-display-done-\(token)"
        helperBinaryPath = "/tmp/cmux-ui-test-display-helper-\(token)"
        helperLogPath = "/tmp/cmux-ui-test-display-helper-\(token).log"

        removeTestArtifacts()
    }

    override func tearDown() {
        helperProcess?.terminate()
        helperProcess?.waitUntilExit()
        helperProcess = nil
        removeTestArtifacts()
        super.tearDown()
    }

    func testRapidDisplayResolutionChangesKeepTerminalResponsive() throws {
        try prepareDisplayHarnessIfNeeded()

        XCTAssertTrue(waitForFile(atPath: displayReadyPath, timeout: 12.0), "Expected display harness ready file at \(displayReadyPath)")
        guard let targetDisplayID = readTrimmedFile(atPath: displayIDPath), !targetDisplayID.isEmpty else {
            XCTFail("Missing target display ID at \(displayIDPath)")
            return
        }

        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_TARGET_DISPLAY_ID"] = targetDisplayID
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 12.0), "Expected cmux window to appear")
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket to respond at \(socketPath)")
        XCTAssertTrue(
            waitForTargetDisplayMove(targetDisplayID: targetDisplayID, timeout: 12.0),
            "Expected app window to move to display \(targetDisplayID). diagnostics=\(loadDiagnostics() ?? [:])"
        )

        guard let baselineStats = waitForRenderStats(timeout: 8.0) else {
            XCTFail("Missing initial render_stats response")
            return
        }
        let baselinePresentCount = baselineStats.presentCount

        XCTAssertTrue(
            FileManager.default.createFile(atPath: displayStartPath, contents: Data("start\n".utf8)),
            "Expected start signal file to be created"
        )

        let deadline = Date().addingTimeInterval(30.0)
        var maxPresentCount = baselinePresentCount
        var lastStats = baselineStats
        var socketFailures = 0

        while Date() < deadline {
            if let stats = renderStats(responseTimeout: 2.0) {
                lastStats = stats
                maxPresentCount = max(maxPresentCount, stats.presentCount)
            } else {
                socketFailures += 1
            }

            let doneMarker = readTrimmedFile(atPath: displayDonePath)
            if doneMarker == "done" && maxPresentCount >= baselinePresentCount + 8 {
                break
            }
            if let doneMarker, doneMarker.hasPrefix("error:") {
                XCTFail("Display churn helper failed: \(doneMarker). log=\(readTrimmedFile(atPath: helperLogPath) ?? "<missing>")")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTAssertEqual(readTrimmedFile(atPath: displayDonePath), "done", "Expected display churn to finish. helperLog=\(readTrimmedFile(atPath: helperLogPath) ?? "<missing>")")
        guard let finalStats = waitForRenderStats(timeout: 6.0) else {
            XCTFail("Expected render_stats after display churn. socketFailures=\(socketFailures)")
            return
        }

        maxPresentCount = max(maxPresentCount, finalStats.presentCount)
        XCTAssertGreaterThanOrEqual(
            maxPresentCount - baselinePresentCount,
            8,
            "Expected terminal presents to keep advancing during display churn. baseline=\(baselineStats) last=\(lastStats) final=\(finalStats)"
        )
        XCTAssertLessThanOrEqual(socketFailures, 8, "Too many socket timeouts while display modes changed")
    }

    private func prepareDisplayHarnessIfNeeded() throws {
        let env = ProcessInfo.processInfo.environment
        if let externalHarness = loadExternalHarnessFromEnvironment(env) ?? loadExternalHarnessFromManifest() {
            displayReadyPath = externalHarness.readyPath
            displayIDPath = externalHarness.displayIDPath
            displayStartPath = externalHarness.startPath
            displayDonePath = externalHarness.donePath
            if let logPath = externalHarness.logPath, !logPath.isEmpty {
                helperLogPath = logPath
            }
            return
        }

        try buildDisplayHelper()
        try launchDisplayHelper()
    }

    private func loadExternalHarnessFromEnvironment(_ env: [String: String]) -> ExternalDisplayHarness? {
        guard let readyPath = env["CMUX_UI_TEST_DISPLAY_READY_PATH"], !readyPath.isEmpty,
              let displayIDPath = env["CMUX_UI_TEST_DISPLAY_ID_PATH"], !displayIDPath.isEmpty,
              let startPath = env["CMUX_UI_TEST_DISPLAY_START_PATH"], !startPath.isEmpty,
              let donePath = env["CMUX_UI_TEST_DISPLAY_DONE_PATH"], !donePath.isEmpty else {
            return nil
        }

        return ExternalDisplayHarness(
            readyPath: readyPath,
            displayIDPath: displayIDPath,
            startPath: startPath,
            donePath: donePath,
            logPath: env["CMUX_UI_TEST_DISPLAY_LOG_PATH"]
        )
    }

    private func loadExternalHarnessFromManifest() -> ExternalDisplayHarness? {
        let manifestURL = URL(fileURLWithPath: displayHarnessManifestPath)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ExternalDisplayHarness.self, from: data)
    }

    private func buildDisplayHelper() throws {
        let sourceURL = repoRootURL.appendingPathComponent("scripts/create-virtual-display.m")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        proc.arguments = [
            "-framework", "Foundation",
            "-framework", "CoreGraphics",
            "-o", helperBinaryPath,
            sourceURL.path,
        ]

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to build display helper: \(stderr)"
            ])
        }
    }

    private func launchDisplayHelper() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperBinaryPath)
        proc.arguments = [
            "--modes", "1920x1080,1728x1117,1600x900,1440x810",
            "--ready-path", displayReadyPath,
            "--display-id-path", displayIDPath,
            "--start-path", displayStartPath,
            "--done-path", displayDonePath,
            "--iterations", "40",
            "--interval-ms", "40",
        ]

        let logHandle = FileHandle(forWritingAtPath: helperLogPath) ?? {
            FileManager.default.createFile(atPath: helperLogPath, contents: nil)
            return FileHandle(forWritingAtPath: helperLogPath)
        }()
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        helperProcess = proc
    }

    private func waitForTargetDisplayMove(targetDisplayID: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let diagnostics = self.loadDiagnostics() else { return false }
            return diagnostics["targetDisplayMoveSucceeded"] == "1" &&
                diagnostics["windowScreenDisplayIDs"]?.contains(targetDisplayID) == true
        }
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping", responseTimeout: 2.0) == "PONG"
        }
    }

    private func waitForRenderStats(timeout: TimeInterval) -> RenderStats? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let stats = renderStats(responseTimeout: 2.0) {
                return stats
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func renderStats(responseTimeout: TimeInterval) -> RenderStats? {
        guard let response = socketCommand("render_stats", responseTimeout: responseTimeout),
              response.hasPrefix("OK ") else {
            return nil
        }

        let json = String(response.dropFirst(3))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RenderStats.self, from: data)
    }

    private func socketCommand(_ command: String, responseTimeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let script = "printf '%s\\n' \(shellSingleQuote(command)) | /usr/bin/nc -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        proc.arguments = ["-lc", script]

        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()

        let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let firstLine = output.split(separator: "\n", maxSplits: 1).first {
            let trimmed = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func waitForCondition(timeout: TimeInterval, pollInterval: TimeInterval = 0.15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func waitForFile(atPath path: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            FileManager.default.fileExists(atPath: path)
        }
    }

    private func readTrimmedFile(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func removeTestArtifacts() {
        for path in [
            socketPath,
            diagnosticsPath,
            displayReadyPath,
            displayIDPath,
            displayStartPath,
            displayDonePath,
            helperBinaryPath,
            helperLogPath,
        ] {
            guard !path.isEmpty else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private struct RenderStats: Decodable, CustomStringConvertible {
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool

        var description: String {
            "draw=\(drawCount) present=\(presentCount) lastPresent=\(String(format: "%.3f", lastPresentTime)) inWindow=\(inWindow) key=\(windowIsKey) visible=\(windowOcclusionVisible)"
        }
    }

    private struct ExternalDisplayHarness: Decodable {
        let readyPath: String
        let displayIDPath: String
        let startPath: String
        let donePath: String
        let logPath: String?
    }
}
