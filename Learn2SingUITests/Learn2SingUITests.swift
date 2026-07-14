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

    /// The MIDI editor's transport: play starts playback (the button flips to
    /// Stop), stop returns it to Play. Captures idle and playing screenshots.
    func testEditorPlaybackTransport() throws {
        let app = openExercises()
        sleep(2)
        let snap = snapshotList(app)
        guard let category = snap.headers.first(where: { !(snap.items[$0] ?? []).isEmpty }),
              let name = snap.items[category]?.first else {
            XCTFail("no visible exercise"); return
        }

        // Into the exercise's settings, then its MIDI editor. The Settings query is
        // scoped to the swiped row so it can't match the tab bar's Settings tab.
        cell(app, named: name).swipeRight()
        let settings = app.collectionViews.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "leading swipe should reveal Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3),
                      "tapping Settings should push the exercise's settings screen")
        sleep(1)
        // The Edit MIDI link sits near the bottom of the (lazy) settings form.
        var editMIDI = app.buttons["Edit MIDI"].firstMatch
        for _ in 0..<4 where !editMIDI.exists {
            app.swipeUp()
            usleep(500_000)
            editMIDI = app.buttons["Edit MIDI"].firstMatch
        }
        XCTAssertTrue(editMIDI.waitForExistence(timeout: 3), "settings should offer Edit MIDI")
        editMIDI.tap()

        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 3), "editor should show a Play button")
        sleep(1)
        saveScreenshot("editor-idle")

        // An exercise without notes leaves Play disabled; nothing more to verify.
        guard play.isEnabled else { return }

        play.tap()
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "Play should flip to Stop while playing")
        sleep(2)
        saveScreenshot("editor-playing")

        stop.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 3),
                      "Stop should return the transport to Play")
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

    // MARK: - Orientation lock

    /// Selecting "Portrait" in the orientation setting keeps the app in portrait
    /// even after the device is rotated to landscape; the choice also persists.
    func testOrientationLockPortrait() throws {
        let device = XCUIDevice.shared
        // Leave the device upright however this test ends.
        defer { device.orientation = .portrait }

        func openSettings() -> XCUIApplication {
            let app = XCUIApplication()
            app.launch()
            let tab = app.buttons["Settings"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Settings tab not found")
            tab.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            return app
        }

        device.orientation = .portrait
        var app = openSettings()

        // The menu-style Picker exposes a button whose label is "Lock orientation,
        // <current value>", so match on the prefix.
        func orientationPicker(_ app: XCUIApplication) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Lock orientation")).firstMatch
        }
        let picker = orientationPicker(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "orientation picker not found")
        picker.tap()
        let portraitOption = app.buttons["Portrait"].firstMatch
        XCTAssertTrue(portraitOption.waitForExistence(timeout: 3), "Portrait option not found")
        portraitOption.tap()
        sleep(1)

        // Rotate the physical device to landscape; the app must stay portrait,
        // i.e. its window stays taller than it is wide.
        device.orientation = .landscapeLeft
        sleep(2)
        let frame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.height, frame.width,
                             "app rotated to landscape despite the portrait lock (\(frame))")

        // The choice must survive a relaunch and still read "Portrait".
        device.orientation = .portrait
        app.terminate()
        app = openSettings()
        let reopened = orientationPicker(app)
        XCTAssertTrue(reopened.waitForExistence(timeout: 3))
        XCTAssertTrue(reopened.label.contains("Portrait"),
                      "orientation choice not persisted, picker shows \(reopened.label)")
    }

    // MARK: - Community

    /// Setting an exercise's visibility to Public makes it appear on the
    /// Community tab, showing the profile username as uploader; the Community
    /// list offers neither a + button nor a Settings swipe action.
    func testCommunityTabShowsPublicExercises() throws {
        // Give the profile a username so the Community row has an uploader to show.
        var app = XCUIApplication()
        app.launch()
        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "Settings tab not found")
        settingsTab.tap()
        let profileRow = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 5), "Profile row not found")
        profileRow.tap()
        let usernameField = app.textFields["Username"].firstMatch
        XCTAssertTrue(usernameField.waitForExistence(timeout: 3), "username field not found")
        var uploaderName = (usernameField.value as? String) ?? ""
        if uploaderName.isEmpty || uploaderName == "Username" { // placeholder when empty
            usernameField.tap()
            usernameField.typeText("TestSinger")
            uploaderName = (usernameField.value as? String) ?? "TestSinger"
        }
        app.terminate()

        // Publish the first visible exercise via its settings.
        app = openExercises()
        sleep(2)
        let snap = snapshotList(app)
        guard let category = snap.headers.first(where: { !(snap.items[$0] ?? []).isEmpty }),
              let name = snap.items[category]?.first else {
            XCTFail("no visible exercise"); return
        }
        cell(app, named: name).swipeRight()
        let settings = app.collectionViews.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "leading swipe should reveal Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
        sleep(1)
        // The menu-style Picker's button is labelled "Visibility, <current value>".
        let pickerQuery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Visibility"))
        var picker = pickerQuery.firstMatch
        for _ in 0..<6 where !picker.exists {
            app.swipeUp()
            usleep(500_000)
            picker = pickerQuery.firstMatch
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "Visibility picker not found")
        picker.tap()
        let publicOption = app.buttons["Public"].firstMatch
        XCTAssertTrue(publicOption.waitForExistence(timeout: 3), "Public option not found")
        publicOption.tap()
        sleep(1)
        XCTAssertTrue(pickerQuery.firstMatch.label.contains("Public"),
                      "picker should now read Public, reads \(pickerQuery.firstMatch.label)")

        // The Community tab lists it, with the uploader's name after the
        // exercise name as its own tappable element (a button, since tapping it
        // opens the uploader's profile). The hidden Exercises tab keeps its own
        // copy of the row in the element tree, so match on name AND uploader
        // together to hit the Community row.
        app.buttons["Community"].tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 5),
                      "Community tab should open the Community screen")
        sleep(1)
        let row = app.cells
            .containing(.staticText, identifier: name)
            .containing(.button, identifier: uploaderName)
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3),
                      "public exercise with uploader \(uploaderName) not listed on Community tab")
        XCTAssertFalse(app.navigationBars["Community"].buttons["Add"].exists,
                       "Community must not offer a + button")
        saveScreenshot("community")

        // No settings access from the Community list.
        row.swipeRight()
        XCTAssertFalse(app.collectionViews.buttons["Settings"].firstMatch.waitForExistence(timeout: 2),
                       "Community rows must not reveal a Settings swipe action")
    }

    /// POST a one-exercise SHARED_EXERCISE document to the server as the fake
    /// device `deviceID`, waiting until the server accepted it.
    private func postSharedExercise(deviceID: String, exerciseID: String, name: String) {
        let doc = """
        {"deviceID":"\(deviceID)","exercises":[{"id":"\(exerciseID)","name":"\(name)",\
        "details":"","category":"No Category","pitchShift":0,"bpm":120,"repeatCount":1,\
        "transposePerRepeat":0,"switchDirectionAfter":0,"beatsBetweenReps":0,\
        "visibility":"public","uploaderName":"ServerTester"}],\
        "midi":{"\(exerciseID)":[{"id":"\(UUID().uuidString)","pitch":60,"beat":0,"length":1}]}}
        """
        var request = URLRequest(url: URL(string:
            "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing/persist/\(deviceID)/SHARED_EXERCISE?customId1=\(deviceID)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(doc.utf8)
        let posted = expectation(description: "posted shared exercise")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertNil(error, "POST failed: \(String(describing: error))")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            posted.fulfill()
        }.resume()
        wait(for: [posted], timeout: 15)
    }

    /// An exercise another device shared on the server appears on the Community
    /// tab. The test plays the other device: it POSTs a SHARED_EXERCISE document
    /// (fixed fake device id, per-run exercise name) straight to the server, then
    /// launches the app and looks for the exercise. Each run replaces the previous
    /// run's document, so test data never accumulates on the server.
    func testCommunityShowsServerExercises() throws {
        let name = "Server Test \(Int(Date().timeIntervalSince1970))"
        postSharedExercise(deviceID: "eeeeeeee-5555-4666-8777-888888888888",
                           exerciseID: UUID().uuidString, name: name)

        let app = XCUIApplication()
        app.launch()
        let tab = app.buttons["Community"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Community tab not found")
        tab.tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 5))
        let row = app.cells
            .containing(.staticText, identifier: name)
            .containing(.button, identifier: "ServerTester")
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "server-shared exercise \(name) not listed on Community tab")
        saveScreenshot("community-server")
    }

    /// Pulling the Community list down refetches from the server: a document
    /// replaced on the server WHILE the tab is open appears after the pull.
    func testCommunityPullToRefresh() throws {
        let deviceID = "eeeeeeee-5555-4666-8777-888888888888"
        let exerciseID = UUID().uuidString
        let stamp = Int(Date().timeIntervalSince1970)
        let oldName = "Refresh Before \(stamp)"
        let newName = "Refresh After \(stamp)"
        postSharedExercise(deviceID: deviceID, exerciseID: exerciseID, name: oldName)

        let app = XCUIApplication()
        app.launch()
        let tab = app.buttons["Community"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Community tab not found")
        tab.tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 5))
        let oldRow = app.cells.containing(.staticText, identifier: oldName).firstMatch
        XCTAssertTrue(oldRow.waitForExistence(timeout: 15),
                      "\(oldName) should be listed after the tab's own fetch")

        // Replace the document on the server while the tab stays open, then
        // pull the list down. A slow synthetic drag from the top row downward
        // triggers the UIRefreshControl.
        postSharedExercise(deviceID: deviceID, exerciseID: exerciseID, name: newName)
        let newRow = app.cells.containing(.staticText, identifier: newName).firstMatch
        for _ in 0..<3 where !newRow.exists {
            let from = app.cells.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = from.withOffset(CGVector(dx: 0, dy: 400))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            sleep(3)
        }
        XCTAssertTrue(newRow.waitForExistence(timeout: 5),
                      "pull-to-refresh should fetch the replaced document (\(newName))")
        XCTAssertFalse(app.cells.containing(.staticText, identifier: oldName).firstMatch.exists,
                       "the stale \(oldName) row should be gone after the refresh")
        saveScreenshot("community-refreshed")
    }

    /// Making an exercise public is refused with a warning when another of the
    /// user's public exercises already has the same name: the alert appears and
    /// the visibility stays Private. Uses the first two exercises of the top
    /// category (always on screen — the bottom of this list is unreachable for
    /// synthetic gestures): the first is published, the second temporarily
    /// renamed to the first's name. Both are restored afterwards.
    func testDuplicatePublicNameRefused() throws {
        var app = openExercises()
        sleep(2)
        // Expand the top category if a previous run left it collapsed.
        var snap = snapshotList(app)
        guard let category = snap.headers.first else { XCTFail("no categories"); return }
        if (snap.items[category] ?? []).count < 2 {
            header(app, named: category).tap()
            sleep(1)
            snap = snapshotList(app)
        }
        guard let items = snap.items[category], items.count >= 2 else {
            XCTFail("top category \(category) needs two visible exercises"); return
        }
        let first = items[0], second = items[1]

        func openSettings(_ name: String) {
            cell(app, named: name).swipeRight()
            let settings = app.collectionViews.buttons["Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 3), "swipe should reveal Settings")
            settings.tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
            sleep(1)
        }

        /// The visibility picker's menu button ("Visibility, <value>"),
        /// scrolled into view if needed.
        func visibilityPicker() -> XCUIElement {
            let query = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Visibility"))
            var picker = query.firstMatch
            for _ in 0..<6 where !picker.exists {
                app.swipeUp()
                usleep(500_000)
                picker = query.firstMatch
            }
            XCTAssertTrue(picker.waitForExistence(timeout: 3), "Visibility picker not found")
            return picker
        }

        /// Selects Private/Public and returns the label shown BEFORE the change.
        @discardableResult
        func setVisibility(_ value: String) -> String {
            let picker = visibilityPicker()
            let before = picker.label
            picker.tap()
            let option = app.buttons[value].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3), "\(value) option not found")
            option.tap()
            sleep(1)
            return before
        }

        /// Replaces the settings name field's content, verifying it stuck.
        func rename(from oldName: String, to newName: String) {
            // Back to the top of the form, where the name field lives (earlier
            // interactions may have scrolled it away — taps at stale frames
            // land on other rows).
            app.swipeDown()
            app.swipeDown()
            let nameField = app.textFields.element(boundBy: 0)
            XCTAssertTrue(nameField.waitForExistence(timeout: 3), "name field not found")
            nameField.tap()
            // Select all (via the edit menu) and type over it; fall back to
            // cursor-to-the-end plus deletes when the menu doesn't show.
            nameField.press(forDuration: 1.2)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 2) {
                selectAll.tap()
                usleep(300_000)
            } else {
                nameField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                          count: oldName.count * 2))
            }
            nameField.typeText(newName)
            app.buttons["Done"].firstMatch.tap()
            usleep(500_000)
            XCTAssertEqual(nameField.value as? String, newName, "rename did not stick")
        }

        // Start from a known state: the second exercise private, the first
        // public — remembering both so they can be restored at the end.
        openSettings(second)
        let secondWasPublic = setVisibility("Private").contains("Public")
        app = relaunchToExercises(app)
        sleep(2)

        openSettings(first)
        let firstWasPublic = setVisibility("Public").contains("Public")
        XCTAssertFalse(app.alerts["Name Already Public"].exists,
                       "publishing \(first) must not warn (its name is unique)")
        XCTAssertTrue(visibilityPicker().label.contains("Public"),
                      "\(first) should be public now")
        app = relaunchToExercises(app)
        sleep(2)

        // Rename the (private) second exercise to the published name and try
        // to publish it: warned, and it stays private.
        openSettings(second)
        rename(from: second, to: first)
        setVisibility("Public")
        let alert = app.alerts["Name Already Public"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3),
                      "publishing a second \"\(first)\" should warn about the duplicate name")
        saveScreenshot("duplicate-name-warning")
        alert.buttons["OK"].tap()
        sleep(1)
        XCTAssertTrue(visibilityPicker().label.contains("Private"),
                      "the duplicate \"\(first)\" must stay private")

        // Restore the second exercise's name. Relaunch first: the settings
        // form has scrolled by now and taps at stale frames go astray, while a
        // fresh screen starts at the top with the name field in place. Two
        // rows now carry the published name — the renamed one sits directly
        // below the original, and must show Private (the original is Public).
        app = relaunchToExercises(app)
        sleep(2)
        let sameNamed = app.cells.containing(.staticText, identifier: first).allElementsBoundByIndex
            .filter { $0.isHittable }
            .sorted { $0.frame.midY < $1.frame.midY }
        XCTAssertGreaterThanOrEqual(sameNamed.count, 2, "both \"\(first)\" rows should be visible")
        sameNamed[1].swipeRight()
        let renamedSettings = app.collectionViews.buttons["Settings"].firstMatch
        XCTAssertTrue(renamedSettings.waitForExistence(timeout: 3))
        renamedSettings.tap()
        XCTAssertTrue(app.navigationBars[first].waitForExistence(timeout: 3))
        sleep(1)
        XCTAssertTrue(visibilityPicker().label.contains("Private"),
                      "the second row must be the renamed (private) exercise")
        for _ in 0..<4 where !app.textFields.element(boundBy: 0).isHittable {
            app.swipeDown()
            usleep(500_000)
        }
        rename(from: first, to: second)
        if secondWasPublic { setVisibility("Public") }

        // And the first exercise's visibility, if the test changed it.
        app = relaunchToExercises(app)
        sleep(2)
        XCTAssertTrue(cell(app, named: second).waitForExistence(timeout: 3),
                      "\(second) should have its original name back")
        if !firstWasPublic {
            openSettings(first)
            setVisibility("Private")
        }
        // Give the debounced sync time to reach the server before the app dies.
        sleep(6)
    }

    /// Editing a public exercise's MIDI pattern updates the server document
    /// automatically — no private/public toggle needed. Reads this device's id
    /// off the Profile screen, snapshots its SHARED_EXERCISE record, draws one
    /// note in the editor of the record's first exercise, and waits for the
    /// record to change. Skipped when the device has nothing shared yet.
    func testEditingPublicExerciseUpdatesServer() throws {
        // The device id (shown in Settings → Profile) keys the server record.
        var app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        let profileRow = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 5), "Profile row not found")
        profileRow.tap()
        XCTAssertTrue(app.staticTexts["Device ID"].waitForExistence(timeout: 3))
        // The id may share its accessibility label with the "Device ID" title,
        // so search every label for a uuid-shaped substring.
        let uuidPattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        guard let deviceID = app.staticTexts.allElementsBoundByIndex
            .compactMap({ $0.label.firstMatch(of: uuidPattern).map { String($0.output) } })
            .first else {
            XCTFail("no uuid-shaped label on the Profile screen"); return
        }

        /// This device's record document, straight from the public fetch.
        func fetchRecord() -> String? {
            var result: String?
            let done = expectation(description: "fetched shared records")
            let url = URL(string:
                "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing/fetch-public/SHARED_EXERCISE")!
            URLSession.shared.dataTask(with: url) { data, _, _ in
                defer { done.fulfill() }
                guard let data,
                      let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else { return }
                result = records.first {
                    ($0["entityId"] as? String)?.caseInsensitiveCompare(deviceID) == .orderedSame
                }?["jsonData"] as? String
            }.resume()
            wait(for: [done], timeout: 15)
            return result
        }

        guard let before = fetchRecord(),
              let doc = try? JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Any],
              let exercises = doc["exercises"] as? [[String: Any]],
              let name = exercises.first?["name"] as? String else {
            throw XCTSkip("this device has no shared exercises; publish one first")
        }

        // Into the shared exercise's MIDI editor.
        app = relaunchToExercises(app)
        sleep(2)
        let row = cell(app, named: name)
        guard row.exists, row.isHittable else {
            throw XCTSkip("shared exercise \(name) not visible in the list")
        }
        row.swipeRight()
        let settings = app.collectionViews.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "leading swipe should reveal Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
        sleep(1)
        var editMIDI = app.buttons["Edit MIDI"].firstMatch
        for _ in 0..<6 where !editMIDI.exists {
            app.swipeUp()
            usleep(500_000)
            editMIDI = app.buttons["Edit MIDI"].firstMatch
        }
        XCTAssertTrue(editMIDI.waitForExistence(timeout: 3), "settings should offer Edit MIDI")
        editMIDI.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 3),
                      "editor did not open")
        sleep(1)

        // Draw with the pen (the default tool): a tap on an empty grid spot
        // creates a note, which saves and schedules the upload. Poll the server
        // for the changed record; try a second spot in case the first tap
        // landed on an existing note (which is a no-op).
        func recordChanged() -> Bool {
            for _ in 0..<8 {
                sleep(3)
                if let now = fetchRecord(), now != before { return true }
            }
            return false
        }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75)).tap()
        var changed = recordChanged()
        if !changed {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.6)).tap()
            changed = recordChanged()
        }
        XCTAssertTrue(changed,
                      "drawing a note in a public exercise should update the server record")
    }

    /// Tapping the grey uploader name on a Community row opens that uploader's
    /// profile: their username as the title, their public exercises without the
    /// per-row uploader name, and the standard back button top-left.
    func testCommunityUsernameOpensUploaderProfile() throws {
        let app = XCUIApplication()
        app.launch()
        let tab = app.buttons["Community"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Community tab not found")
        tab.tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 5))
        sleep(1)

        // Find a visible row showing an uploader (the name label plus the
        // uploader's name, exposed as a button since it's tappable) and tap the
        // uploader's name.
        var exerciseName: String?
        var uploader: XCUIElement?
        for cell in app.cells.allElementsBoundByIndex where cell.isHittable {
            let button = cell.buttons.firstMatch
            guard button.exists, cell.staticTexts.firstMatch.exists else { continue }
            exerciseName = cell.staticTexts.firstMatch.label
            uploader = button
            break
        }
        guard let uploader, let exerciseName else {
            throw XCTSkip("Community shows no exercise with an uploader name; publish one first.")
        }
        let username = uploader.label
        uploader.tap()

        // The profile pushes (instead of the row opening playback): username as
        // the title, and the exercise listed WITHOUT the uploader name on the row.
        let profileBar = app.navigationBars[username]
        XCTAssertTrue(profileBar.waitForExistence(timeout: 5),
                      "tapping the username should push the uploader's profile")
        sleep(1)
        let profileRow = app.cells
            .containing(.staticText, identifier: exerciseName)
            .allElementsBoundByIndex
            .first { $0.isHittable }
        XCTAssertNotNil(profileRow, "the uploader's exercise should be listed on their profile")
        XCTAssertFalse(profileRow?.buttons[username].exists ?? true,
                       "profile rows must not repeat the username")
        saveScreenshot("uploader-profile")

        // The back button top-left returns to the Community list.
        let backButton = profileBar.buttons.firstMatch
        XCTAssertTrue(backButton.exists, "profile should show a back button top-left")
        backButton.tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 5),
                      "back button should return to the Community list")
    }

    /// Opening an exercise from the Community tab shows a Download button above
    /// Start; tapping it flips to a disabled "Added to Exercises" confirmation
    /// and files a private copy under "No Category" on the Exercises tab. The
    /// copy is deleted again afterwards so reruns don't accumulate duplicates.
    func testCommunityDownloadAddsCopyToExercises() throws {
        // Publish the first visible categorized exercise so Community has a
        // known row (idempotent if it is already public).
        var app = openExercises()
        sleep(2)
        let snap = snapshotList(app)
        guard let category = snap.headers.first(where: {
                  $0 != "No Category" && !(snap.items[$0] ?? []).isEmpty
              }),
              let name = snap.items[category]?.first else {
            XCTFail("no visible exercise outside No Category"); return
        }
        cell(app, named: name).swipeRight()
        let settings = app.collectionViews.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "leading swipe should reveal Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
        sleep(1)
        let pickerQuery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Visibility"))
        var picker = pickerQuery.firstMatch
        for _ in 0..<6 where !picker.exists {
            app.swipeUp()
            usleep(500_000)
            picker = pickerQuery.firstMatch
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "Visibility picker not found")
        picker.tap()
        let publicOption = app.buttons["Public"].firstMatch
        XCTAssertTrue(publicOption.waitForExistence(timeout: 3), "Public option not found")
        publicOption.tap()
        sleep(1)

        // How many copies of the exercise "No Category" holds before the download.
        app = relaunchToExercises(app)
        sleep(2)
        // Synthetic scroll gestures are unreliable on this list (its cells are
        // drag sources), so instead collapse categories from the top until the
        // "No Category" section — always the last — is on screen.
        func noCategoryCopies() -> Int {
            for _ in 0..<10 {
                if header(app, named: "No Category").isHittable { break }
                let snap = snapshotList(app)
                guard let target = snap.headers.first(where: {
                    $0 != "No Category" && !(snap.items[$0] ?? []).isEmpty
                }) else { break }
                header(app, named: target).tap()
                usleep(500_000)
            }
            sleep(1)
            return (snapshotList(app).items["No Category"] ?? []).filter { $0 == name }.count
        }
        let copiesBefore = noCategoryCopies()

        // Open the exercise from the Community tab. The hidden Exercises tab
        // keeps its own copy of the row in the element tree, so take a hittable
        // match, and tap the name label (not the cell center, which could hit
        // the uploader button).
        app.buttons["Community"].tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 5))
        sleep(1)
        let rows = app.cells.containing(.staticText, identifier: name).allElementsBoundByIndex
        guard let row = rows.first(where: { $0.isHittable }) else {
            XCTFail("\(name) not listed on the Community tab"); return
        }
        row.staticTexts[name].firstMatch.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3),
                      "tapping the row should push the intro screen")

        // Download sits above Start; tapping it flips to a disabled confirmation.
        let download = app.buttons["Download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 3),
                      "the intro screen from Community should offer Download")
        let start = app.buttons["Start"].firstMatch
        XCTAssertTrue(start.exists, "Start button not found")
        XCTAssertLessThan(download.frame.maxY, start.frame.minY, "Download should sit above Start")
        saveScreenshot("community-intro-download")
        download.tap()
        let confirmation = app.buttons["Added to Exercises"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3),
                      "Download should flip to Added to Exercises")
        XCTAssertFalse(confirmation.isEnabled, "the confirmation must not download again")
        saveScreenshot("community-intro-downloaded")

        // The "No Category" group gained exactly one copy — checked after a
        // relaunch, which also proves the download was persisted.
        app = relaunchToExercises(app)
        sleep(2)
        XCTAssertEqual(noCategoryCopies(), copiesBefore + 1,
                       "the download should add a copy of \(name) to No Category")

        // Delete the copy again: the bottom-most row with the name is the newly
        // appended one (the original sits in its category further up).
        let candidates = app.cells.containing(.staticText, identifier: name).allElementsBoundByIndex
            .filter { $0.isHittable }
        guard let copy = candidates.max(by: { $0.frame.midY < $1.frame.midY }) else {
            XCTFail("downloaded copy not found in the list"); return
        }
        copy.swipeRight()
        let copySettings = app.collectionViews.buttons["Settings"].firstMatch
        XCTAssertTrue(copySettings.waitForExistence(timeout: 3))
        copySettings.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
        sleep(1)
        var deleteButton = app.buttons["Delete Exercise"].firstMatch
        for _ in 0..<8 where !deleteButton.exists {
            app.swipeUp()
            usleep(500_000)
            deleteButton = app.buttons["Delete Exercise"].firstMatch
        }
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3), "settings should offer Delete Exercise")
        deleteButton.tap()
        let confirm = app.alerts["Delete Exercise?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "deleting should ask for confirmation")
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(app.navigationBars["Exercises"].waitForExistence(timeout: 5),
                      "deleting the copy should pop back to the list")
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
        XCTAssertTrue(app.navigationBars["Edit Categories"].waitForExistence(timeout: 3),
                      "long-press on header should enter reorder mode")
        app.buttons["xmark"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Exercises"].waitForExistence(timeout: 3),
                      "✗ should exit reorder mode")
    }

    /// The Home tab's "Recent" category: at most five rows, a header that
    /// collapses without ever showing an exercise count, and a long-press
    /// reorder mode without the add/delete buttons of the Exercises tab.
    func testHomeRecentCategory() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        sleep(2)

        let recentHeader = header(app, named: "Recent")
        XCTAssertTrue(recentHeader.exists, "Home should show the Recent category header")
        let expanded = snapshotList(app).items["Recent"] ?? []
        XCTAssertLessThanOrEqual(expanded.count, 5, "Recent shows at most 5 exercises")
        saveScreenshot("home-recent")

        // Collapse: rows disappear but, unlike the Exercises tab, no "(N)" count.
        recentHeader.tap()
        sleep(1)
        XCTAssertEqual(snapshotList(app).items["Recent"] ?? [], [],
                       "tap should collapse Recent")
        let counts = app.staticTexts.allElementsBoundByIndex
            .filter { $0.label.hasPrefix("(") && $0.frame.height > 0 }
        XCTAssertTrue(counts.isEmpty, "collapsed Home headers must not show a count")
        saveScreenshot("home-recent-collapsed")
        header(app, named: "Recent").tap()
        sleep(1)
        XCTAssertEqual((snapshotList(app).items["Recent"] ?? []).count, expanded.count,
                       "tap should expand Recent again")

        // Long-press: reorder mode with only the ✗ button — no +, no trash,
        // and no exercise count on the category row.
        header(app, named: "Recent").press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["Edit Categories"].waitForExistence(timeout: 3),
                      "long-press on a Home header should enter reorder mode")
        XCTAssertFalse(app.navigationBars.buttons["plus"].exists,
                       "Home reorder mode has no add button")
        XCTAssertFalse(app.navigationBars.buttons["trash"].exists,
                       "Home reorder mode has no delete button")
        XCTAssertTrue(app.staticTexts["Recent"].exists,
                      "Recent should appear as a reorderable row")
        XCTAssertFalse(app.staticTexts["(\(expanded.count))"].exists,
                       "Home reorder rows must not show a count")
        saveScreenshot("home-reorder")
        app.buttons["xmark"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3),
                      "✗ should exit reorder mode back to Home")
    }

    /// The Home tab's "Routines" category: the + button creates a named routine,
    /// swiping right on it opens the edit screen (Name field at the top, no
    /// counts), whose + button opens a multi-select exercise picker; picked
    /// exercises land in the routine and the trash mode removes them again.
    func testHomeRoutines() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertTrue(header(app, named: "Routines").exists,
                      "Home should show the Routines category header")

        // Create a routine via the + button. UserDefaults persist between runs,
        // so the name is unique per run.
        let routineName = "Routine \(Int(Date().timeIntervalSince1970))"
        let add = app.navigationBars["Home"].buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), "Home should show a + button")
        add.tap()
        let alert = app.alerts["New Routine"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "+ should ask for the routine's name")
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText(routineName)
        alert.buttons["Create"].tap()
        sleep(1)
        XCTAssertTrue(cell(app, named: routineName).waitForExistence(timeout: 3),
                      "the new routine should be listed under Routines")
        saveScreenshot("home-routines")

        // Swipe right reveals Edit, which pushes the edit screen: the Name field
        // at the top holds the routine's name, and there are no "(N)" counts.
        cell(app, named: routineName).swipeRight()
        let edit = app.collectionViews.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3), "swipe right should reveal Edit")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Routine"].waitForExistence(timeout: 3),
                      "Edit should push the routine's edit screen")
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "edit screen should show a Name field")
        XCTAssertEqual(nameField.value as? String, routineName)
        XCTAssertTrue(app.staticTexts.allElementsBoundByIndex
            .filter { $0.label.hasPrefix("(") && $0.frame.height > 0 }.isEmpty,
                      "the edit-routine screen must not show exercise counts")
        saveScreenshot("routine-edit-empty")

        // + opens the picker: the categorized exercise list, but with no + button
        // of its own; tapping rows selects them.
        app.navigationBars["Edit Routine"].buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add Exercises"].waitForExistence(timeout: 3),
                      "+ should push the exercise picker")
        sleep(2)
        XCTAssertFalse(app.navigationBars["Add Exercises"].buttons["Add"].exists,
                       "the picker must not offer a + button")
        let picks = Array(visibleCellOrder(app).prefix(2))
        XCTAssertEqual(picks.count, 2, "need two visible exercises to pick")
        for pick in picks {
            cell(app, named: pick).tap()
            usleep(500_000)
        }
        saveScreenshot("routine-picker-selected")

        // Back on the edit screen the picked exercises are listed.
        let backButton = app.navigationBars["Add Exercises"].buttons.firstMatch
        XCTAssertTrue(backButton.exists, "picker should show a back button")
        backButton.tap()
        XCTAssertTrue(app.navigationBars["Edit Routine"].waitForExistence(timeout: 3),
                      "back should return to the edit screen")
        sleep(1)
        for pick in picks {
            XCTAssertTrue(cell(app, named: pick).exists,
                          "\(pick) should have been added to the routine")
        }
        saveScreenshot("routine-edit-filled")

        // Trash mode removes an exercise from the routine (not from the library).
        app.buttons["trash"].firstMatch.tap()
        sleep(1)
        let removeTarget = cell(app, named: picks[0])
        let remove = removeTarget.buttons.firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3),
                      "trash mode should show per-row delete buttons")
        remove.tap()
        sleep(1)
        XCTAssertFalse(cell(app, named: picks[0]).exists,
                       "\(picks[0]) should have been removed from the routine")
        XCTAssertTrue(cell(app, named: picks[1]).exists,
                      "\(picks[1]) should still be in the routine")

        // The routine and its remaining exercise survive a relaunch.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        sleep(2)
        let routineCell = cell(app, named: routineName)
        XCTAssertTrue(routineCell.waitForExistence(timeout: 3),
                      "the routine should survive a relaunch")
        routineCell.swipeRight()
        let editAgain = app.collectionViews.buttons["Edit"].firstMatch
        XCTAssertTrue(editAgain.waitForExistence(timeout: 3))
        editAgain.tap()
        XCTAssertTrue(app.navigationBars["Edit Routine"].waitForExistence(timeout: 3))
        sleep(1)
        XCTAssertTrue(cell(app, named: picks[1]).exists,
                      "the routine's exercise should survive a relaunch")
    }

    /// Swiping left on a routine reveals a Delete action that asks for
    /// confirmation first: Cancel keeps the routine, Delete removes it — and it
    /// stays gone after a relaunch.
    func testHomeRoutineSwipeDelete() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        sleep(2)

        // Create a routine to delete. UserDefaults persist between runs, so the
        // name is unique per run.
        let routineName = "Doomed \(Int(Date().timeIntervalSince1970))"
        app.navigationBars["Home"].buttons["Add"].firstMatch.tap()
        let nameAlert = app.alerts["New Routine"]
        XCTAssertTrue(nameAlert.waitForExistence(timeout: 3))
        nameAlert.textFields.firstMatch.tap()
        nameAlert.textFields.firstMatch.typeText(routineName)
        nameAlert.buttons["Create"].tap()
        XCTAssertTrue(cell(app, named: routineName).waitForExistence(timeout: 3))

        // Swipe left reveals Delete, which asks for confirmation.
        cell(app, named: routineName).swipeLeft()
        let deleteAction = app.collectionViews.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3),
                      "swiping left on a routine should reveal a Delete action")
        saveScreenshot("routine-swipe-delete")
        deleteAction.tap()
        var confirm = app.alerts["Delete Routine?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3),
                      "Delete should ask for confirmation before deleting")
        saveScreenshot("routine-delete-confirm")

        // Cancel keeps the routine.
        confirm.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertTrue(cell(app, named: routineName).exists,
                      "Cancel must not delete the routine")

        // Delete removes it.
        cell(app, named: routineName).swipeLeft()
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3))
        deleteAction.tap()
        confirm = app.alerts["Delete Routine?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.buttons["Delete"].tap()
        sleep(1)
        XCTAssertFalse(cell(app, named: routineName).exists,
                       "confirming Delete should remove the routine")

        // And it stays gone after a relaunch.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertFalse(cell(app, named: routineName).exists,
                       "the deleted routine must not come back after a relaunch")
    }

    /// Tapping a routine plays its exercises in order: each one's intro screen,
    /// its playback, then the score screen — whose button reads "Next" and moves
    /// on to the following exercise's intro, until the last one's reads "Exit"
    /// and returns home. Requires microphone access to be granted up front
    /// (xcrun simctl privacy … grant microphone) so no permission alert blocks
    /// playback.
    func testRoutinePlaysExercisesInOrder() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        sleep(2)

        // Build a fresh two-exercise routine through the UI.
        let routineName = "Play \(Int(Date().timeIntervalSince1970))"
        app.navigationBars["Home"].buttons["Add"].firstMatch.tap()
        let alert = app.alerts["New Routine"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText(routineName)
        alert.buttons["Create"].tap()
        XCTAssertTrue(cell(app, named: routineName).waitForExistence(timeout: 3))
        cell(app, named: routineName).swipeRight()
        let edit = app.collectionViews.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Routine"].waitForExistence(timeout: 3))
        app.navigationBars["Edit Routine"].buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add Exercises"].waitForExistence(timeout: 3))
        sleep(2)
        let picks = Array(visibleCellOrder(app).prefix(2))
        XCTAssertEqual(picks.count, 2, "need two visible exercises to pick")
        for pick in picks {
            cell(app, named: pick).tap()
            usleep(500_000)
        }
        app.navigationBars["Add Exercises"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Routine"].waitForExistence(timeout: 3))
        app.navigationBars["Edit Routine"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        sleep(1)

        // Tap the routine: the FIRST exercise's intro screen appears.
        cell(app, named: routineName).tap()
        XCTAssertTrue(app.navigationBars[picks[0]].waitForExistence(timeout: 3),
                      "tapping the routine should open \(picks[0])'s intro screen")
        let start = app.buttons["Start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        saveScreenshot("routine-play-intro-1")
        start.tap()

        // Let the exercise play through; the score screen's button reads "Next"
        // because another exercise follows.
        let next = app.buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 300),
                      "\(picks[0]) should finish with a score screen offering Next")
        XCTAssertFalse(app.buttons["Exit"].exists,
                       "mid-routine score screens must not read Exit")
        saveScreenshot("routine-play-score-1")
        next.tap()

        // The SECOND exercise's intro follows; after playing it the score
        // screen's button reads "Exit" and leads back home.
        XCTAssertTrue(app.navigationBars[picks[1]].waitForExistence(timeout: 5),
                      "Next should open \(picks[1])'s intro screen")
        let start2 = app.buttons["Start"].firstMatch
        XCTAssertTrue(start2.waitForExistence(timeout: 3))
        start2.tap()
        let exit = app.buttons["Exit"].firstMatch
        XCTAssertTrue(exit.waitForExistence(timeout: 300),
                      "\(picks[1]) should finish with a score screen offering Exit")
        saveScreenshot("routine-play-score-2")
        exit.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5),
                      "Exit after the last exercise should return to Home")
    }

    // MARK: - Hide tab bar during playback

    /// The Visuals → Playback screen offers the "Hide tab bar" toggle.
    func testHideTabBarToggleExists() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        let visuals = app.buttons["Visuals"].firstMatch
        XCTAssertTrue(visuals.waitForExistence(timeout: 5))
        visuals.tap()
        let playback = app.buttons["Playback"].firstMatch
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        playback.tap()
        // The form renders lazily; scroll until the toggle near the bottom exists.
        let toggle = app.switches["Hide tab bar"].firstMatch
        for _ in 0..<8 where !toggle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "Visuals → Playback should offer the Hide tab bar toggle")
    }

    /// With the setting on, the tab bar disappears while an exercise plays; with
    /// it off, it stays. The setting is forced through the argument domain so the
    /// simulator's persistent defaults are untouched.
    func testHideTabBarDuringPlayback() throws {
        for (value, expectHidden) in [("YES", true), ("NO", false)] {
            let app = XCUIApplication()
            app.launchArguments = ["-\(hideTabBarKey)", value]
            app.launch()
            let tab = app.buttons["Exercises"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tab.tap()
            XCTAssertTrue(app.navigationBars["Exercises"].waitForExistence(timeout: 5))

            // Open the first exercise's intro and start playback.
            let firstCell = app.cells.firstMatch
            XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
            firstCell.tap()
            let start = app.buttons["Start"].firstMatch
            XCTAssertTrue(start.waitForExistence(timeout: 5), "intro Start button not found")
            start.tap()
            XCTAssertTrue(start.waitForNonExistence(timeout: 5), "playback did not start")

            let tabBar = app.tabBars.firstMatch
            if expectHidden {
                XCTAssertTrue(tabBar.waitForNonExistence(timeout: 5),
                              "tab bar should be hidden during playback")
                saveScreenshot("playback-tabbar-hidden")
            } else {
                sleep(2)
                XCTAssertTrue(tabBar.exists && tabBar.isHittable,
                              "tab bar should stay visible during playback")
                saveScreenshot("playback-tabbar-visible")
            }
            app.terminate()
        }
    }

    /// Must match VisualKeys.hideTabBar in the app target.
    private let hideTabBarKey = "vis_hideTabBar"
}
