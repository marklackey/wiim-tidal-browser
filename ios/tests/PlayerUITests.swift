import XCTest

final class PlayerUITests: XCTestCase {
    private func app(_ mode: String = "player", tab: String = "player") -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "org.wiimtidal.browser.ios")
        app.launchEnvironment["WIIM_UI_TEST"] = mode
        app.launchArguments = ["-selectedTab", tab]
        app.launch()
        return app
    }
    private func wait(_ predicate: String, _ element: XCUIElement, timeout: Double = 8) {
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: timeout) == .completed)
    }
    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPauseResumeSkipAndMiniPlayerStayInSync() {
        let app = app()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        wait("enabled == true AND label == 'Pause'", playPause)
        screenshot("Now Playing", app)
        playPause.tap()
        wait("enabled == true AND label == 'Play'", playPause)
        app.tabBars.buttons["Browse"].tap()
        let mini = app.buttons["miniPlayer.playPause"]
        wait("enabled == true AND label == 'Play'", mini)
        mini.tap()
        wait("enabled == true AND label == 'Pause'", mini)
        app.tabBars.buttons["Player"].tap()
        app.buttons["Next track"].tap()
        wait("label == 'Second track'", app.staticTexts["player.title"])
        wait("enabled == true", app.buttons["Previous track"])
        app.buttons["Previous track"].tap()
        wait("label == 'Evening Lines'", app.staticTexts["player.title"])
        wait("enabled == true", playPause)
        app.sliders["player.progress"].adjust(toNormalizedSliderPosition: 0.5)
        wait("enabled == true", playPause)
        app.swipeUp()
        app.sliders["player.volume"].adjust(toNormalizedSliderPosition: 0.35)
        wait("enabled == true", playPause)
    }

    func testSearchFiltersAlbumCancelPlaybackAndHistory() {
        let app = app(tab: "catalog")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Mira\n")
        XCTAssertTrue(app.buttons["Filters"].waitForExistence(timeout: 8))
        screenshot("Search results", app)
        app.buttons["Filters"].tap()
        app.switches["Hi-Res only"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait("value == '1'", app.switches["Hi-Res only"])
        screenshot("Hi-Res filter", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["3 of 4 matches"].waitForExistence(timeout: 5))
        app.buttons["Clear filters"].tap()
        let album = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Evening Lines' AND label CONTAINS '2024'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
        screenshot("Album", app)
        app.buttons["Play album"].tap()
        XCTAssertTrue(app.staticTexts["Starting playback"].waitForExistence(timeout: 2))
        app.buttons["Cancel"].tap()
        app.buttons["Play album"].tap()
        XCTAssertTrue(app.staticTexts["Starting playback"].waitForExistence(timeout: 2))
        wait("exists == false", app.staticTexts["Starting playback"], timeout: 8)
        app.tabBars.buttons["Player"].tap()
        app.swipeUp()
        app.buttons["Queue"].tap()
        XCTAssertTrue(app.navigationBars["Sent to WiiM"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Second track"].exists)
        app.buttons["Done"].tap()
        app.buttons["Album tracks"].tap()
        XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))
        screenshot("Current album", app)
    }

    func testReconnectAndForegroundRefresh() {
        let app = app("reconnect")
        XCTAssertTrue(app.staticTexts["Reconnecting to WiiM…"].waitForExistence(timeout: 4))
        wait("enabled == true", app.buttons["player.playPause"], timeout: 10)
        XCUIDevice.shared.press(.home)
        app.activate()
        wait("enabled == true", app.buttons["player.playPause"])
    }

    func testLastAlbumTrackClearsMiniPlayer() {
        for mode in ["longAlbum", "longAlbumLarge"] {
            let app = app(mode, tab: "catalog")
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            search.typeText("Mira\n")
            let album = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Evening Lines' AND label CONTAINS '2024'")).firstMatch
            XCTAssertTrue(app.buttons["Filters"].waitForExistence(timeout: 8))
            for _ in 0..<5 {
                if album.exists { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(album.waitForExistence(timeout: 8))
            album.tap()
            XCTAssertTrue(app.buttons["Play album"].waitForExistence(timeout: 5))

            let lastPlay = app.buttons["Play The Final Song (After the Lights Go Out) on WiiM"]
            let list = app.collectionViews.firstMatch
            for _ in 0..<16 {
                if lastPlay.exists && lastPlay.isHittable { break }
                list.swipeUp()
            }
            list.swipeUp()
            XCTAssertTrue(lastPlay.exists)
            let lastRow = app.cells.containing(.button, identifier: "Play The Final Song (After the Lights Go Out) on WiiM").firstMatch
            XCTAssertTrue(lastRow.exists)
            screenshot("Last album track — \(mode)", app)
            XCTAssertLessThanOrEqual(lastRow.frame.maxY, app.buttons["miniPlayer.playPause"].frame.minY - 10,
                                     "The entire final track, including resolution, must clear the mini-player.")
            lastPlay.tap()
            XCTAssertTrue(app.staticTexts["Starting playback"].waitForExistence(timeout: 2))
            app.buttons["Cancel"].tap()
            app.terminate()
        }
    }

    func testDarkAppearanceAndLargeText() {
        let app = app("appearance")
        let control = app.buttons["player.playPause"]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        screenshot("Large text dark player", app)
        app.swipeUp()
        wait("enabled == true", control)
        control.tap()
        wait("enabled == true AND label == 'Play'", control)
        screenshot("Large text transport", app)
        app.tabBars.buttons["Settings"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["Discover WiiM"].waitForExistence(timeout: 5))
        screenshot("Large text settings", app)
    }

    func testDeviceLoginCompletesWithoutPastingURL() {
        let app = app("login", tab: "catalog")
        XCTAssertTrue(app.buttons["Connect TIDAL"].waitForExistence(timeout: 8))
        app.buttons["Connect TIDAL"].tap()
        XCTAssertTrue(app.staticTexts["Waiting for TIDAL approval…"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.textFields["TIDAL redirect URL"].exists)
        XCTAssertTrue(app.buttons["TIDAL account"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Albums"].exists)
    }

    func testLockScreenControlsRunInBackground() {
        let app = app("lockScreen")
        wait("enabled == true AND label == 'Pause'", app.buttons["player.playPause"], timeout: 10)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.75)))
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }
        let pause = springboard.buttons["Pause WiiM"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        screenshot("Lock Screen player", springboard)
        pause.tap()
        let play = springboard.buttons["Play WiiM"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        springboard.buttons["Next track"].tap()
        XCTAssertTrue(springboard.staticTexts["Second track"].waitForExistence(timeout: 8))
        springboard.buttons["Refresh WiiM"].tap()
        screenshot("Lock Screen after skip", springboard)
        app.activate()
        wait("label == 'Second track'", app.staticTexts["player.title"])
    }
}
