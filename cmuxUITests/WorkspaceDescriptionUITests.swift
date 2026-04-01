import XCTest

private func workspaceDescriptionPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class WorkspaceDescriptionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdShiftEAllowsImmediateTypingAndSave() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndEnsureForeground(app)

        let description = "Cmd Shift E focus note"
        app.typeKey("e", modifierFlags: [.command, .shift])

        let editor = requireDescriptionEditor(in: app, timeout: 5.0)
        XCTAssertTrue(editor.exists, "Expected workspace description editor to open")

        app.typeText(description)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(editor, timeout: 5.0),
            "Expected Enter to save and dismiss the workspace description editor"
        )
        XCTAssertTrue(
            app.staticTexts[description].waitForExistence(timeout: 5.0),
            "Expected saved workspace description to appear in the sidebar"
        )
    }

    func testClickingDescriptionEditorAllowsTypingAndSave() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndEnsureForeground(app)

        let description = "Clicked description note"
        app.typeKey("e", modifierFlags: [.command, .shift])

        let editor = requireDescriptionEditor(in: app, timeout: 5.0)
        XCTAssertTrue(editor.exists, "Expected workspace description editor to open")

        editor.click()
        app.typeText(description)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(editor, timeout: 5.0),
            "Expected Enter to save and dismiss the workspace description editor after clicking it"
        )
        XCTAssertTrue(
            app.staticTexts[description].waitForExistence(timeout: 5.0),
            "Expected clicked workspace description to appear in the sidebar"
        )
    }

    private func requireDescriptionEditor(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement {
        let candidates = descriptionEditorCandidates(in: app)
        var match: XCUIElement?
        let found = workspaceDescriptionPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        if let match, found {
            return match
        }
        XCTFail("Expected workspace description editor to appear")
        return candidates[0]
    }

    private func descriptionEditorCandidates(in app: XCUIApplication) -> [XCUIElement] {
        [
            app.textViews["CommandPaletteWorkspaceDescriptionEditor"],
            app.scrollViews["CommandPaletteWorkspaceDescriptionEditor"],
            app.otherElements["CommandPaletteWorkspaceDescriptionEditor"],
            app.textViews["Edit Workspace Description…"],
            app.textViews["Workspace description"],
            app.staticTexts["Workspace description"],
            app.descendants(matching: .any).matching(identifier: "CommandPaletteWorkspaceDescriptionEditor").firstMatch,
        ]
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground {
            return
        }

        if app.state == .runningBackground {
            return
        }

        let activated = workspaceDescriptionPollUntil(timeout: timeout) {
            app.activate()
            return app.state == .runningForeground || app.state == .runningBackground
        }
        XCTAssertTrue(activated, "App failed to start. state=\(app.state.rawValue)")
    }
}
