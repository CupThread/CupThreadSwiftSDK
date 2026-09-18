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

    /// Walks the four tabs against the mock server and exercises two
    /// interactive flows end-to-end: opening/dismissing the compose sheet via
    /// the SDK's stable `cupthread.features.compose` identifier, and casting a
    /// vote through the `cupthread.features.vote_pill` toggle. Every step
    /// asserts unconditionally so a broken flow fails the test instead of
    /// silently skipping it.
    @MainActor
    func testInteractiveNavigationAndVotingFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        // 1. Roadmap is the initial tab.
        let roadmapTitle = app.navigationBars["Roadmap"]
        XCTAssertTrue(roadmapTitle.waitForExistence(timeout: 10), "Roadmap navigation bar should appear on launch")

        // 2. Switch to What's New.
        let whatsNewTab = app.tabBars.buttons["What's New"]
        XCTAssertTrue(whatsNewTab.waitForExistence(timeout: 5), "What's New tab should exist in the tab bar")
        whatsNewTab.tap()
        XCTAssertTrue(
            app.navigationBars["What's New"].waitForExistence(timeout: 5),
            "What's New navigation bar should appear after switching tabs"
        )

        // 3. Switch to Requests.
        let requestsTab = app.tabBars.buttons["Requests"]
        XCTAssertTrue(requestsTab.waitForExistence(timeout: 5), "Requests tab should exist in the tab bar")
        requestsTab.tap()
        XCTAssertTrue(
            app.navigationBars["Feature Requests"].waitForExistence(timeout: 10),
            "Feature Requests navigation bar should appear after switching tabs"
        )

        // 4. Open the compose sheet through the SDK's stable identifier.
        let composeButton = app.buttons["cupthread.features.compose"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 5), "Compose button should expose the cupthread.features.compose identifier")
        composeButton.tap()
        let composeSheetTitle = app.navigationBars["Request a Feature"]
        XCTAssertTrue(composeSheetTitle.waitForExistence(timeout: 5), "Request a Feature sheet should appear after tapping compose")

        // 5. Dismiss it again (the compose sheet's cancellation action comes
        // from the shared dismiss guard, whose localized label is "Cancel").
        let cancelButton = app.navigationBars["Request a Feature"].buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Compose sheet should expose a Cancel button")
        cancelButton.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: composeSheetTitle)
        waitForExpectations(timeout: 5, handler: nil)

        // 6. Cast one vote against the mock server. The mock reconciles every
        // vote to "143 / hasVoted", so the pill's label must change from its
        // initial value (142 for the first mock request).
        let votePill = app.buttons["cupthread.features.vote_pill"].firstMatch
        XCTAssertTrue(votePill.waitForExistence(timeout: 10), "Vote pill should expose the cupthread.features.vote_pill identifier")
        let labelBeforeVote = votePill.label
        votePill.tap()
        expectation(
            for: NSPredicate(format: "label != %@", labelBeforeVote),
            evaluatedWith: votePill
        )
        waitForExpectations(timeout: 10, handler: nil)

        // 7. Switch to Feedback.
        let feedbackTab = app.tabBars.buttons["Feedback"]
        XCTAssertTrue(feedbackTab.waitForExistence(timeout: 5), "Feedback tab should exist in the tab bar")
        feedbackTab.tap()
        XCTAssertTrue(
            app.navigationBars["Send Feedback"].waitForExistence(timeout: 10),
            "Send Feedback navigation bar should appear after switching tabs"
        )
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

        if let jpegData = screenshot.image.jpegData(compressionQuality: 0.90) {
            let jpgTarget = doccResourcesDir.appendingPathComponent("\(name).jpg")
            try? jpegData.write(to: jpgTarget)
        }
    }
}
