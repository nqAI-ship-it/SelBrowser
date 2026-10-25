import XCTest

/// These tests tap and type into real controls; a JavaScript focus() call cannot test iOS keyboard policy.
final class BrowserKeyboardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testWebsiteSearchKeepsPageOutsideChromeAndRemovesFormToolbar() {
        launchPreview("page-dark")
        let field = app.webViews.textFields.matching(identifier: "Поиск на странице").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The real WebKit fixture input must load")
        assertHeaderGeometry()
        field.tap()
        dismissFirstKeyboardIntroduction()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("subway surfers")
        XCTAssertTrue((field.value as? String)?.contains("subway surfers") == true)
        assertFooterHiddenAndViewportAboveKeyboard()

        // Our custom chrome is not a UIToolbar. The unwanted WebKit form accessory has a Done button.
        let doneLabels = NSPredicate(format: "label == %@ OR label == %@", "Done", "Готово")
        XCTAssertFalse(app.toolbars.buttons.matching(doneLabels).firstMatch.exists,
                       "The additional website form toolbar must not appear above the keyboard")
        attachScreenshot("website-search-keyboard")
    }

    func testLongAddressDoesNotCoverTheSettingsButton() {
        launchPreview("address-long")
        let address = app.textFields["mobileAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.textFields.matching(identifier: "Поиск на странице").firstMatch.waitForExistence(timeout: 30),
                      "Wait for fixture loading and its initial address-focus callback before typing")
        address.tap()
        dismissFirstKeyboardIntroduction()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        // Enter a long value through the actual keyboard without submitting or leaving the local fixture.
        address.tap()
        let longAddress = "https://example.com/search?query=" + String(repeating: "long-address-", count: 12)
        address.typeText(longAddress)
        XCTAssertTrue((address.value as? String)?.contains(longAddress) == true)
        assertHeaderGeometry()
        assertFooterHiddenAndViewportAboveKeyboard()
        attachScreenshot("long-address-keyboard")
    }

    private func launchPreview(_ name: String) {
        app.launchArguments = ["--sel-ui-preview", name]
        app.launch()
        XCTAssertTrue(app.textFields["mobileAddress"].waitForExistence(timeout: 30))
    }

    private func assertHeaderGeometry() {
        let address = app.textFields["mobileAddress"]
        let settings = app.buttons["mobileSettings"]
        XCTAssertTrue(address.exists && settings.exists)
        XCTAssertGreaterThanOrEqual(address.frame.height, 40)
        XCTAssertLessThanOrEqual(address.frame.maxX + 2, settings.frame.minX,
                                 "The text field and settings button must have separate columns")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(address.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(settings.frame.maxX, window.maxX)
        let viewport = viewportFrame()
        XCTAssertGreaterThanOrEqual(viewport.minY, max(address.frame.maxY, settings.frame.maxY),
                                    "Website content must begin below the complete browser header")
    }

    private func assertFooterHiddenAndViewportAboveKeyboard() {
        let footer = app.descendants(matching: .any).matching(identifier: "mobileBottomBar").firstMatch
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !footer.exists || !footer.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                       "Browser navigation must hide while the docked keyboard is open")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        XCTAssertLessThanOrEqual(viewportFrame().maxY, keyboard.frame.minY + 3,
                                 "The website viewport must end above the keyboard")
    }

    private func viewportFrame() -> CGRect {
        let container = app.descendants(matching: .any).matching(identifier: "mobileWebContent").firstMatch
        return container.exists ? container.frame : app.webViews.firstMatch.frame
    }

    private func dismissFirstKeyboardIntroduction() {
        // Fresh CI simulators show Apple's QuickPath explanation instead of the keys on first use.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app!, springboard] {
            for title in ["Continue", "Продолжить"] {
                let button = owner.buttons.matching(identifier: title).firstMatch
                if button.waitForExistence(timeout: 0.5), button.isHittable { button.tap() }
            }
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot(), quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
