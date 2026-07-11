import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Mac App Store screenshot capture — the desktop sibling of
/// AppUITests/ScreenshotTests. Same contract: skips unless SCREENSHOT_MODE=1
/// is in the runner environment (scripts/screenshots.sh sets it via
/// TEST_RUNNER_SCREENSHOT_MODE); shot-* attachments are extracted from the
/// xcresult by the script.
///
/// Mac specifics:
/// - Each shot relaunches with a different `--theme` (test-gated in
///   DispatchMacApp), cycling the palette like the iOS suite.
/// - `--screenshot-window` pins the window to 1440x900 points — 16:10, an
///   ASC-accepted Mac size at 1x (1440x900) and 2x/Retina (2880x1800).
/// - The window capture is flattened onto an opaque black background before
///   attaching: macOS windows have rounded transparent corners and App Store
///   screenshots must carry no alpha channel.
final class MacScreenshotTests: XCTestCase {
    /// Matches Theme.allCases order in DispatchKit.
    private static let themes = ["tomato", "teal", "gray", "pink", "chartreuse"]

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1",
            "screenshot capture runs only via scripts/screenshots.sh"
        )
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp(shotIndex: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--mock-sensors", "--ui-testing", "--demo-data", "--screenshot-window",
            "--theme", Self.themes[(shotIndex - 1) % Self.themes.count],
        ]
        app.launch()
        return app
    }

    /// Window capture, flattened to strip the rounded-corner alpha. Attaches
    /// PNG data under the same `shot-` prefix contract as the iOS suite.
    @MainActor
    private func snap(_ name: String, window: XCUIElement) {
        // Give the resize + theme paint a beat to settle.
        Thread.sleep(forTimeInterval: 1)
        let shot = window.screenshot()
        guard let flattened = Self.flattenPNG(shot.pngRepresentation) else {
            XCTFail("could not flatten window capture for \(name)")
            return
        }
        let attachment = XCTAttachment(
            data: flattened, uniformTypeIdentifier: UTType.png.identifier
        )
        attachment.name = "shot-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Redraws the PNG into an opaque RGB bitmap over black — App Store
    /// screenshots must be flattened with no transparency, and macOS window
    /// captures carry alpha in the rounded corners.
    private static func flattenPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, flat, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    @MainActor
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        return window
    }

    @MainActor
    func testCaptureMacScreenshots() throws {
        // 01 — dashboard (sidebar stats + proportion-band grid).
        var app = launchApp(shotIndex: 1)
        var window = mainWindow(app)
        XCTAssertTrue(app.staticTexts["report-count"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2) // charts animate in
        snap("01-dashboard", window: window)
        app.terminate()

        // 02 — split view: reports sidebar + report detail.
        app = launchApp(shotIndex: 2)
        window = mainWindow(app)
        let firstRow = app.descendants(matching: .any)
            .matching(identifier: "report-row").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        firstRow.click()
        XCTAssertTrue(app.buttons["detail-back-button"].waitForExistence(timeout: 10))
        snap("02-report-detail", window: window)
        app.terminate()

        // 03 — insights pane.
        app = launchApp(shotIndex: 3)
        window = mainWindow(app)
        let panePicker = app.descendants(matching: .any)
            .matching(identifier: "detail-pane-picker").firstMatch
        XCTAssertTrue(panePicker.waitForExistence(timeout: 15))
        panePicker.radioButtons["Insights"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "insight-card")
                .firstMatch.waitForExistence(timeout: 15)
        )
        snap("03-insights", window: window)
        app.terminate()

        // 04 — sidebar search filtering the demo data (⌘F focuses the kit
        // search). NOT the Settings scene: that opens a small separate
        // window, which can't satisfy the 16:10 exact-size requirement.
        app = launchApp(shotIndex: 4)
        window = mainWindow(app)
        XCTAssertTrue(app.staticTexts["report-count"].waitForExistence(timeout: 15))
        app.typeKey("f", modifierFlags: .command)
        app.typeText("coffee")
        Thread.sleep(forTimeInterval: 1.5) // let the filter + stats settle
        snap("04-search", window: window)
        app.terminate()
    }
}
