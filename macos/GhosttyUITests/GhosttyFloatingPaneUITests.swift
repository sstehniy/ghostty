import XCTest

class GhosttyFloatingPaneUITests: GhosttyCustomConfigCase {
    override class var defaultTestSuite: XCTestSuite {
        XCTestSuite(forTestCaseClass: Self.self)
    }

    override func record(_ issue: XCTIssue) {
        super.record(issue)
        if issue.compactDescription.contains("Publishing changes from within view updates") {
            super.record(XCTIssue(type: .assertionFailure, compactDescription: issue.compactDescription))
        }
    }

    @MainActor
    func testPersistentPillAndPaneManagement() throws {
        try updateConfig("""
        command = /bin/sh
        confirm-close-surface = false
        window-save-state = never
        macos-tab-layout = horizontal
        keybind = super+1=new_float_local
        """)
        let suite = "GHOSTTY_FLOAT_PILL_TEST_\(UUID().uuidString)"
        let app = try ghosttyApplication(defaultsSuite: suite)
        defer {
            app.terminate()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(suite, isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let toggle = app.buttons["float-pill-toggle"]
        let manage = app.buttons["float-pill-manage"]
        XCTAssertFalse(toggle.exists)
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        func expectVisible(_ count: Int, total: Int = 2) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "\(count) of \(total) visible"), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
        }

        func capture() {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        expectVisible(2)
        let originalFrame = toggle.frame
        capture()
        XCTAssertEqual(toggle.label, "Collapse all floating panes")
        toggle.click()
        expectVisible(0)
        XCTAssertEqual(toggle.label, "Show all floating panes")
        XCTAssertEqual(toggle.frame, originalFrame)
        app.typeText("printf '\\033]0;Pill focus check\\007'; sleep 60\n")
        XCTAssertTrue(app.windows.firstMatch.wait(for: \.title, toEqual: "Pill focus check", timeout: 3))
        toggle.click()
        expectVisible(2)

        app.buttons["Maximize"].firstMatch.click()
        let restoreSize = app.buttons["Restore size"]
        XCTAssertTrue(restoreSize.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.frame, originalFrame)
        XCTAssertLessThan(restoreSize.frame.maxX, toggle.frame.minX)
        let maximizedPane = app.groups.matching(identifier: "Floating terminal pane")
            .containing(.button, identifier: "Restore size").firstMatch
        XCTAssertLessThan(maximizedPane.buttons["Close floating pane"].frame.maxX, toggle.frame.minX)
        let movablePane = app.groups[maximizedPane.identifier]
        restoreSize.click()
        XCTAssertTrue(restoreSize.waitForNonExistence(timeout: 3))
        expectVisible(2)

        movablePane.staticTexts.firstMatch.click(forDuration: 0.3, thenDragTo: toggle,
                                                 withVelocity: .slow, thenHoldForDuration: 0.2)
        capture()
        let movedMaximize = movablePane.buttons["Maximize"]
        XCTAssertGreaterThan(movedMaximize.frame.midY, toggle.frame.minY)
        XCTAssertLessThan(movedMaximize.frame.midY, toggle.frame.maxY)
        XCTAssertEqual(toggle.frame, originalFrame)
        XCTAssertLessThan(movedMaximize.frame.maxX, toggle.frame.minX)
        XCTAssertLessThan(movablePane.buttons["Close floating pane"].frame.maxX, toggle.frame.minX)
        movedMaximize.click()
        XCTAssertTrue(restoreSize.waitForExistence(timeout: 3))
        restoreSize.click()
        XCTAssertTrue(restoreSize.waitForNonExistence(timeout: 3))
        expectVisible(2)

        movablePane.buttons["Minimize to corner"].click()
        expectVisible(1)
        XCTAssertEqual(toggle.label, "Collapse all floating panes")
        toggle.click()
        expectVisible(0)

        manage.click()
        let showAll = app.buttons["float-pill-show-all"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 3))
        let panes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'float-pill-pane-'"))
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.firstMatch.value as? String, "Collapsed")
        capture()
        panes.firstMatch.click()
        expectVisible(1)
        XCTAssertTrue(showAll.waitForNonExistence(timeout: 3))
        app.typeText("printf '\\033]0;Float focus check\\007'; sleep 60\n")
        XCTAssertTrue(app.staticTexts["Float focus check"].waitForExistence(timeout: 3))
        manage.click()
        XCTAssertTrue(showAll.waitForExistence(timeout: 3))
        XCTAssertTrue(panes.allElementsBoundByIndex.contains { ($0.value as? String) == "Visible" })
        showAll.click()
        expectVisible(2)
        XCTAssertTrue(showAll.waitForNonExistence(timeout: 3))
        manage.click()
        XCTAssertTrue(showAll.waitForExistence(timeout: 3))
        XCTAssertFalse(showAll.isEnabled)
        panes.element(boundBy: 1).click()
        XCTAssertTrue(showAll.waitForNonExistence(timeout: 3))
        app.typeText("printf '\\033]0;Other float focus\\007'; sleep 60\n")
        XCTAssertTrue(app.staticTexts["Other float focus"].waitForExistence(timeout: 3))
        manage.click()
        XCTAssertTrue(showAll.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(showAll.waitForNonExistence(timeout: 3))

        let foregroundPane = app.groups.matching(identifier: "Floating terminal pane")
            .containing(.staticText, identifier: "Other float focus").firstMatch
        foregroundPane.buttons["Close floating pane"].click()
        expectVisible(1, total: 1)
        let remainingPane = app.groups.matching(identifier: "Floating terminal pane")
            .containing(.staticText, identifier: "Float focus check").firstMatch
        remainingPane.buttons["Close floating pane"].click()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 3))
        XCTAssertFalse(manage.exists)
    }
}
