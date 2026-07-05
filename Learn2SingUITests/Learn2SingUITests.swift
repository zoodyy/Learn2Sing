import XCTest

/// Interaction-level tests for the exercise list. The simulator keeps the app's
/// real UserDefaults between runs, so tests that reorder exercises PERSIST their
/// changes — every assertion is written order-independently (compare sets, or
/// derive expectations from the order read at launch).
final class Learn2SingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch the app and open the Exercises tab.
    @discardableResult
    private func openExercises() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let tab = app.buttons["Exercises"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Exercises tab not found")
        tab.tap()
        XCTAssertTrue(app.navigationBars["Exercises"].waitForExistence(timeout: 5))
        return app
    }

    /// Saves a full-screen PNG to $SCREENSHOT_DIR (pass as TEST_RUNNER_SCREENSHOT_DIR
    /// to xcodebuild) for visual comparison; falls back to a result-bundle attachment.
    private func saveScreenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        } else {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Captures the exercise list in its main visual states so a code change can
    /// be checked for unintended visual differences.
    func testCaptureExerciseListScreenshots() throws {
        let app = openExercises()
        sleep(2)
        saveScreenshot("list-top")

        // Collapse the first category to capture the collapsed-header look.
        let firstHeader = app.staticTexts["Tone"].firstMatch
        if firstHeader.exists {
            firstHeader.tap()
            sleep(1)
            saveScreenshot("list-collapsed")
            // Restore.
            app.staticTexts["Tone"].firstMatch.tap()
            sleep(1)
        }

        app.swipeUp()
        sleep(1)
        saveScreenshot("list-bottom")
    }

    // MARK: - List introspection

    /// What the exercise list currently shows: category headers (top to bottom)
    /// and the exercise names visible under each. Derived from the live UI so
    /// tests don't depend on the (persistent, test-mutated) data order.
    private struct ListSnapshot {
        var headers: [String]
        var items: [String: [String]]
    }

    private func snapshotList(_ app: XCUIApplication) -> ListSnapshot {
        let contentTop = app.navigationBars.firstMatch.frame.maxY
        let tabBar = app.tabBars.firstMatch
        let contentBottom = tabBar.exists ? tabBar.frame.minY : app.frame.maxY - 90

        var cellRows: [(label: String, y: CGFloat)] = []
        for cell in app.cells.allElementsBoundByIndex {
            let frame = cell.frame
            guard frame.height > 0, frame.midY > contentTop, frame.midY < contentBottom else { continue }
            let text = cell.staticTexts.firstMatch
            guard text.exists else { continue }
            cellRows.append((text.label, frame.midY))
        }
        let cellLabels = Set(cellRows.map(\.label))

        var headerRows: [(label: String, y: CGFloat)] = []
        for text in app.staticTexts.allElementsBoundByIndex {
            let frame = text.frame
            guard frame.height > 0, frame.midY > contentTop, frame.midY < contentBottom else { continue }
            let label = text.label
            guard !label.isEmpty, !label.hasPrefix("("), !cellLabels.contains(label) else { continue }
            headerRows.append((label, frame.midY))
        }
        headerRows.sort { $0.y < $1.y }

        var items: [String: [String]] = [:]
        for (index, header) in headerRows.enumerated() {
            let nextY = index + 1 < headerRows.count ? headerRows[index + 1].y : .infinity
            items[header.label] = cellRows
                .filter { $0.y > header.y && $0.y < nextY }
                .sorted { $0.y < $1.y }
                .map(\.label)
        }
        return ListSnapshot(headers: headerRows.map(\.label), items: items)
    }

    private func cell(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }

    private func header(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.staticTexts[name].firstMatch
    }

    /// Return to a fresh Exercises list. Relaunching is the only reliable way
    /// back: on iOS 26 the floating back button isn't reachable through the
    /// navigation-bar element and synthetic edge swipes don't pop.
    private func relaunchToExercises(_ app: XCUIApplication) -> XCUIApplication {
        app.terminate()
        return openExercises()
    }

    /// Long-press `source` and drop it just above the top edge of `target`, slowly,
    /// the way a user drags a row. Retries because synthetic drags sometimes fail
    /// to lift the row at all.
    private func drag(_ app: XCUIApplication, source: XCUIElement, target: XCUIElement,
                      attempts: Int = 3, verify: () -> Bool) -> Bool {
        for _ in 0..<attempts {
            let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            from.press(forDuration: 1.0, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
            sleep(2)
            if verify() { return true }
        }
        return verify()
    }

    // MARK: - Drag & drop

    /// Dragging an exercise within its category commits a new order.
    func testDragReordersWithinCategory() throws {
        let app = openExercises()
        sleep(2)
        let before = snapshotList(app)
        guard let category = before.headers.first(where: { (before.items[$0]?.count ?? 0) >= 2 }),
              let itemsBefore = before.items[category] else {
            XCTFail("no category with 2+ visible exercises"); return
        }

        let moved = drag(app,
                         source: cell(app, named: itemsBefore.last!),
                         target: cell(app, named: itemsBefore.first!)) {
            let now = self.snapshotList(app).items[category] ?? []
            return Set(now) == Set(itemsBefore) && now != itemsBefore
        }
        XCTAssertTrue(moved, "order in \(category) never changed: \(itemsBefore)")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during drag")

        // The new order must survive a relaunch (i.e. it was persisted).
        let reordered = snapshotList(app).items[category] ?? []
        app.terminate()
        let relaunched = openExercises()
        sleep(2)
        XCTAssertEqual(snapshotList(relaunched).items[category], reordered,
                       "reorder was not persisted across relaunch")
    }

    /// Dragging an exercise onto a row of another category moves it there.
    func testDragMovesAcrossCategories() throws {
        let app = openExercises()
        sleep(2)
        let before = snapshotList(app)
        guard before.headers.count >= 2,
              let sourceCategory = before.headers.first(where: { !(before.items[$0] ?? []).isEmpty }),
              let targetCategory = before.headers.first(where: {
                  $0 != sourceCategory && !(before.items[$0] ?? []).isEmpty
              }),
              let exercise = before.items[sourceCategory]?.first,
              let targetItem = before.items[targetCategory]?.first else {
            XCTFail("need two categories with visible exercises"); return
        }

        let moved = drag(app,
                         source: cell(app, named: exercise),
                         target: cell(app, named: targetItem)) {
            let now = self.snapshotList(app)
            return (now.items[targetCategory] ?? []).contains(exercise)
                && !(now.items[sourceCategory] ?? []).contains(exercise)
        }
        XCTAssertTrue(moved, "\(exercise) never moved from \(sourceCategory) to \(targetCategory)")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during drag")
    }

    /// The historic SwiftUI crash was dragging the LAST row of a section; also
    /// covers a category emptying out (its header must disappear).
    func testDragLastExerciseOfCategoryDoesNotCrash() throws {
        let app = openExercises()
        sleep(2)
        let before = snapshotList(app)
        guard let sourceCategory = before.headers.last(where: { !(before.items[$0] ?? []).isEmpty }),
              let targetCategory = before.headers.first(where: {
                  $0 != sourceCategory && !(before.items[$0] ?? []).isEmpty
              }),
              let lastItem = before.items[sourceCategory]?.last,
              let targetItem = before.items[targetCategory]?.first else {
            XCTFail("need two categories with visible exercises"); return
        }
        let emptiesCategory = before.items[sourceCategory]?.count == 1

        let moved = drag(app,
                         source: cell(app, named: lastItem),
                         target: cell(app, named: targetItem)) {
            (self.snapshotList(app).items[targetCategory] ?? []).contains(lastItem)
        }
        XCTAssertNotEqual(app.state, .notRunning, "app crashed dragging the last row of a section")
        XCTAssertTrue(moved, "\(lastItem) never left \(sourceCategory)")
        if emptiesCategory {
            XCTAssertFalse(snapshotList(app).headers.contains(sourceCategory),
                           "emptied category \(sourceCategory) should no longer be listed")
        }
    }

    /// Dropping an exercise onto a collapsed category's header files it in there.
    func testDropOnCollapsedCategoryHeader() throws {
        let app = openExercises()
        sleep(2)
        var before = snapshotList(app)
        guard let targetCategory = before.headers.first(where: { !(before.items[$0] ?? []).isEmpty }),
              let sourceCategory = before.headers.first(where: {
                  $0 != targetCategory && !(before.items[$0] ?? []).isEmpty
              }),
              let exercise = before.items[sourceCategory]?.first else {
            XCTFail("need two categories with visible exercises"); return
        }

        // Collapse the target category.
        header(app, named: targetCategory).tap()
        sleep(1)
        before = snapshotList(app)
        XCTAssertEqual(before.items[targetCategory], [], "\(targetCategory) should be collapsed")

        let moved = drag(app,
                         source: cell(app, named: exercise),
                         target: header(app, named: targetCategory)) {
            !(self.snapshotList(app).items[sourceCategory] ?? []).contains(exercise)
        }
        XCTAssertTrue(moved, "\(exercise) never left \(sourceCategory)")

        // Expand and confirm it landed inside.
        header(app, named: targetCategory).tap()
        sleep(1)
        XCTAssertTrue((snapshotList(app).items[targetCategory] ?? []).contains(exercise),
                      "\(exercise) not found in \(targetCategory) after expanding")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during drag")
    }

    /// Tapping a row still opens the exercise, and the leading swipe still
    /// reveals the Settings action.
    func testRowTapAndLeadingSwipeStillWork() throws {
        let app = openExercises()
        sleep(2)
        let snap = snapshotList(app)
        guard let category = snap.headers.first(where: { !(snap.items[$0] ?? []).isEmpty }),
              let name = snap.items[category]?.first else {
            XCTFail("no visible exercise"); return
        }

        cell(app, named: name).tap()
        XCTAssertTrue(app.navigationBars["Exercises"].waitForNonExistence(timeout: 3),
                      "tapping \(name) should push the exercise screen")

        let relaunched = relaunchToExercises(app)
        sleep(2)
        cell(relaunched, named: name).swipeRight()
        let settings = relaunched.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3),
                      "leading swipe should reveal the Settings action")
        settings.tap()
        XCTAssertTrue(relaunched.navigationBars["Exercises"].waitForNonExistence(timeout: 3),
                      "the Settings action should push the settings screen")
    }

    /// The visible exercise names, top to bottom.
    private func visibleCellOrder(_ app: XCUIApplication) -> [String] {
        let contentTop = app.navigationBars.firstMatch.frame.maxY
        let tabBar = app.tabBars.firstMatch
        let contentBottom = tabBar.exists ? tabBar.frame.minY : app.frame.maxY - 90
        var rows: [(String, CGFloat)] = []
        for cell in app.cells.allElementsBoundByIndex {
            let frame = cell.frame
            guard frame.height > 0, frame.midY > contentTop, frame.midY < contentBottom else { continue }
            let text = cell.staticTexts.firstMatch
            guard text.exists else { continue }
            rows.append((text.label, frame.midY))
        }
        return rows.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// A new (uncategorized) exercise can be dragged out of the header-less
    /// uncategorized section at the bottom of the list.
    func testDragOutOfUncategorizedSection() throws {
        var app = openExercises()
        sleep(2)

        // The + button (labelled "Add") creates and persists an uncategorized
        // exercise, then opens its settings; relaunch to get back to the list.
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), "+ button not found")
        add.tap()
        sleep(1)
        app = relaunchToExercises(app)
        sleep(2)

        // The uncategorized section is at the very bottom; scroll all the way.
        for _ in 0..<8 {
            app.swipeUp()
            usleep(500_000)
        }
        sleep(1)

        let before = visibleCellOrder(app)
        guard before.count >= 4, before.last == "New Exercise" else {
            XCTFail("expected New Exercise at the bottom of the list, saw \(before)"); return
        }
        // Bottommost cell = the uncategorized exercise; drag it up onto the
        // second-from-top visible cell (fully on screen, above the boundary).
        let sourceCandidates = app.cells.containing(.staticText, identifier: "New Exercise")
            .allElementsBoundByIndex
        guard let source = sourceCandidates.max(by: { $0.frame.midY < $1.frame.midY }) else {
            XCTFail("no New Exercise cell"); return
        }
        let target = cell(app, named: before[1])

        let moved = drag(app, source: source, target: target) {
            self.visibleCellOrder(app) != before
        }
        XCTAssertTrue(moved, "dragging the uncategorized exercise never changed the list order")
        XCTAssertNotEqual(app.state, .notRunning, "app crashed during drag")
    }

    // MARK: - Profile

    /// The Settings tab's Profile screen shows an editable username, the device
    /// ID, and a Download button; an edited username survives a relaunch.
    func testProfileScreen() throws {
        func openProfile() -> XCUIApplication {
            let app = XCUIApplication()
            app.launch()
            let tab = app.buttons["Settings"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Settings tab not found")
            tab.tap()
            let profile = app.buttons["Profile"].firstMatch
            XCTAssertTrue(profile.waitForExistence(timeout: 5), "Profile row not found")
            profile.tap()
            XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5),
                          "Profile row should push the profile screen")
            return app
        }

        var app = openProfile()
        let username = app.textFields["Username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 3), "username field not found")
        XCTAssertTrue(app.staticTexts["Device ID"].exists, "device ID row not found")
        XCTAssertTrue(app.buttons["Download Profile"].exists, "download button not found")
        saveScreenshot("profile")

        // Type into the username field and confirm it persists across a relaunch.
        username.tap()
        username.typeText("abc")
        let typed = username.value as? String
        XCTAssertNotNil(typed)
        app.terminate()

        app = openProfile()
        let reopened = app.textFields["Username"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 3))
        XCTAssertEqual(reopened.value as? String, typed, "username was not persisted")
    }

    /// Tap-to-collapse and long-press-to-reorder-mode on headers still work.
    func testHeaderTapAndLongPressStillWork() throws {
        let app = openExercises()
        sleep(2)
        let before = snapshotList(app)
        guard let category = before.headers.first(where: { !(before.items[$0] ?? []).isEmpty }) else {
            XCTFail("no expanded category"); return
        }

        header(app, named: category).tap()
        sleep(1)
        XCTAssertEqual(snapshotList(app).items[category], [], "tap should collapse \(category)")
        header(app, named: category).tap()
        sleep(1)
        XCTAssertFalse((snapshotList(app).items[category] ?? []).isEmpty, "tap should expand \(category)")

        header(app, named: category).press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["Reorder"].waitForExistence(timeout: 3),
                      "long-press on header should enter reorder mode")
        app.buttons["xmark"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Exercises"].waitForExistence(timeout: 3),
                      "✗ should exit reorder mode")
    }
}
