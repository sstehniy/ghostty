import XCTest

final class GhosttySidebarDragUITests: GhosttyCustomConfigCase {
    override static var defaultTestSuite: XCTestSuite { XCTestSuite(forTestCaseClass: Self.self) }

    @MainActor
    func testPinUnpinAndOutsideCancellationPreserveTheActiveTerminal() throws {
        try updateConfig("""
        command = /bin/sh
        confirm-close-surface = false
        window-save-state = never
        macos-tab-layout = vertical
        window-width = 120
        window-height = 20
        """)
        let suite = "GHOSTTY_SIDEBAR_DRAG_TEST_\(UUID().uuidString)"
        let app = try ghosttyApplication(defaultsSuite: suite)
        defer {
            app.terminate()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(suite, isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        for title in ["Alpha", "Beta", "Gamma"] {
            if title != "Alpha" { app.typeKey("t", modifierFlags: .command) }
            app.typeText("printf '\\033]0;\(title)\\007'; sleep 600\n")
            XCTAssertTrue(window.wait(for: \.title, toEqual: title, timeout: 5))
        }

        func row(_ title: String, pinned: Bool) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
                .matching(NSPredicate(format: pinned ? "label CONTAINS 'Pinned'" : "NOT (label CONTAINS 'Pinned')"))
                .firstMatch
        }
        func point(_ element: XCUIElement, below: CGFloat = 0) -> XCUICoordinate {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: below))
        }
        func drag(_ source: XCUIElement, to destination: XCUICoordinate) {
            point(source).click(forDuration: 0.05, thenDragTo: destination,
                withVelocity: .slow, thenHoldForDuration: 0.4)
        }

        let alpha = row("Alpha", pinned: false)
        let beta = row("Beta", pinned: false)
        XCTAssertTrue(alpha.waitForExistence(timeout: 3))
        XCTAssertTrue(beta.exists)
        alpha.click()
        XCTAssertEqual(window.title, "Alpha")
        row("Gamma", pinned: false).click()
        XCTAssertEqual(window.title, "Gamma")
        drag(beta, to: point(alpha))
        let pinnedBeta = row("Beta", pinned: true)
        XCTAssertTrue(pinnedBeta.waitForExistence(timeout: 3))
        XCTAssertEqual(window.title, "Gamma")

        drag(alpha, to: point(pinnedBeta, below: 32))
        let pinnedAlpha = row("Alpha", pinned: true)
        XCTAssertTrue(pinnedAlpha.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(pinnedAlpha.frame.minY, pinnedBeta.frame.minY)
        drag(pinnedAlpha, to: point(pinnedBeta, below: -10))
        XCTAssertTrue(pinnedAlpha.waitForExistence(timeout: 3))
        XCTAssertLessThan(pinnedAlpha.frame.minY, pinnedBeta.frame.minY)
        XCTAssertEqual(window.title, "Gamma")

        let gamma = row("Gamma", pinned: false)
        drag(pinnedBeta, to: point(gamma, below: 100))
        XCTAssertTrue(beta.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(beta.frame.minY, gamma.frame.minY)
        XCTAssertEqual(window.title, "Gamma")

        beta.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .click(forDuration: 0.05, thenDragTo: point(pinnedAlpha),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(beta.waitForExistence(timeout: 3))
        XCTAssertFalse(pinnedBeta.exists)
        XCTAssertEqual(window.title, "Gamma")

        let before = pinnedAlpha.frame
        let outside = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        drag(pinnedAlpha, to: outside)
        XCTAssertTrue(pinnedAlpha.waitForExistence(timeout: 3))
        XCTAssertEqual(pinnedAlpha.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(window.title, "Gamma")

        drag(pinnedAlpha, to: point(beta, below: 100))
        XCTAssertTrue(alpha.waitForExistence(timeout: 3))
        XCTAssertFalse(pinnedAlpha.exists)
        XCTAssertEqual(window.title, "Gamma")

        for index in 0..<6 {
            app.typeKey("t", modifierFlags: .command)
            app.typeText("printf '\\033]0;Scroll \(index)\\007'; sleep 600\n")
            XCTAssertTrue(window.wait(for: \.title, toEqual: "Scroll \(index)", timeout: 3))
        }
        let sidebar = app.groups["Tabs"]
        let list = sidebar.scrollViews.firstMatch
        list.scroll(byDeltaX: 0, deltaY: -1000)
        XCTAssertTrue(beta.isHittable, "Beta: \(beta.frame), viewport: \(list.frame)")
        let bottomEdge = list.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -8))
        point(beta).click(forDuration: 0.05, thenDragTo: bottomEdge,
            withVelocity: .slow, thenHoldForDuration: 1.5)
        let rows = sidebar.buttons.matching(NSPredicate(format: "label MATCHES %@",
            "^(Alpha|Beta|Gamma|Scroll [0-5])(,.*)?$"))
        XCTAssertTrue(rows.element(boundBy: 8).wait(for: \.label, toEqual: "Beta", timeout: 3))
        XCTAssertEqual(window.title, "Scroll 5")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
