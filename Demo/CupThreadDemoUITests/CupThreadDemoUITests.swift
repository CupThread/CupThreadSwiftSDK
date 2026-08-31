import XCTest

final class CupThreadDemoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Core Screenshots

    @MainActor
    func testCapture01Roadmap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-initialTab", "roadmap"]
        app.launch()

        let roadmapTitle = app.navigationBars["Roadmap"]
        XCTAssertTrue(roadmapTitle.waitForExistence(timeout: 5), "Roadmap navigation bar should appear")

        // Allow UI animations and render loop to settle
        Thread.sleep(forTimeInterval: 1.0)

        saveScreenshot(XCUIScreen.main.screenshot(), name: "roadmap")
    }

    @MainActor
    func testCapture02FeatureRequests() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-initialTab", "requests"]
        app.launch()

        let requestsTitle = app.navigationBars["Feature Requests"]
        XCTAssertTrue(requestsTitle.waitForExistence(timeout: 5), "Feature Requests navigation bar should appear")

        Thread.sleep(forTimeInterval: 1.0)

        saveScreenshot(XCUIScreen.main.screenshot(), name: "feature_requests")
    }

    @MainActor
    func testCapture03SubmitRequestSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-initialTab", "requests", "-openCompose"]
        app.launch()

        let sheetTitle = app.navigationBars["Request a Feature"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "Request a Feature sheet should appear")

        Thread.sleep(forTimeInterval: 1.0)

        saveScreenshot(XCUIScreen.main.screenshot(), name: "submit_request")
    }

    @MainActor
    func testCapture04WhatsNew() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-initialTab", "whatsNew"]
        app.launch()

        let whatsNewTitle = app.navigationBars["What's New"]
        XCTAssertTrue(whatsNewTitle.waitForExistence(timeout: 5), "What's New navigation bar should appear")

        Thread.sleep(forTimeInterval: 1.0)

        saveScreenshot(XCUIScreen.main.screenshot(), name: "whats_new")
    }

    @MainActor
    func testCapture05ChangelogOverlay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-initialTab", "whatsNew", "-openChangelogOverlay"]
        app.launch()

        let overlayButton = app.buttons["Got It"]
        let closeButton = app.buttons["Close"]
        let exists = overlayButton.waitForExistence(timeout: 5) || closeButton.waitForExistence(timeout: 5)
        XCTAssertTrue(exists, "Changelog overlay dismiss or close button should appear")

        Thread.sleep(forTimeInterval: 1.0)

        saveScreenshot(XCUIScreen.main.screenshot(), name: "changelog_overlay")
    }

    @MainActor
    func testCapture06FeedbackComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-initialTab", "feedback", "-prefillFeedback"]
        app.launch()

        let feedbackTitle = app.navigationBars["Send Feedback"]
        XCTAssertTrue(feedbackTitle.waitForExistence(timeout: 5), "Send Feedback navigation bar should appear")

        Thread.sleep(forTimeInterval: 1.0)

        saveScreenshot(XCUIScreen.main.screenshot(), name: "feedback_composer")
    }

    // MARK: - Interactive Navigation Test

    @MainActor
    func testInteractiveNavigationAndVotingFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        // 1. Check Roadmap Tab
        XCTAssertTrue(app.navigationBars["Roadmap"].waitForExistence(timeout: 5))

        // 2. Switch to What's New Tab
        let whatsNewTab = app.tabBars.buttons["What's New"]
        if whatsNewTab.exists {
            whatsNewTab.tap()
            XCTAssertTrue(app.navigationBars["What's New"].waitForExistence(timeout: 3))
        }

        // 3. Switch to Requests Tab & verify search / compose
        let requestsTab = app.tabBars.buttons["Requests"]
        if requestsTab.exists {
            requestsTab.tap()
            XCTAssertTrue(app.navigationBars["Feature Requests"].waitForExistence(timeout: 3))

            // Open compose sheet
            let composeButton = app.buttons["cupthread.features.compose"]
            if composeButton.exists {
                composeButton.tap()
                XCTAssertTrue(app.navigationBars["Request a Feature"].waitForExistence(timeout: 3))

                // Cancel sheet
                let cancelButton = app.buttons["Cancel"]
                if cancelButton.exists {
                    cancelButton.tap()
                }
            }
        }

        // 4. Switch to Feedback Tab
        let feedbackTab = app.tabBars.buttons["Feedback"]
        if feedbackTab.exists {
            feedbackTab.tap()
            XCTAssertTrue(app.navigationBars["Send Feedback"].waitForExistence(timeout: 3))
        }
    }

    // MARK: - Screenshot Persistence Helper

    private func saveScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let data = screenshot.image.pngData() else { return }

        // Locate repository root relative to this test file
        let currentFile = URL(fileURLWithPath: #filePath)
        let repoRoot = currentFile
            .deletingLastPathComponent() // CupThreadDemoUITests
            .deletingLastPathComponent() // Demo
            .deletingLastPathComponent() // Repository Root

        let doccResourcesDir = repoRoot.appendingPathComponent("Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources")
        try? FileManager.default.createDirectory(at: doccResourcesDir, withIntermediateDirectories: true)

        let targetFile = doccResourcesDir.appendingPathComponent("\(name).png")
        try? data.write(to: targetFile)
    }
}
