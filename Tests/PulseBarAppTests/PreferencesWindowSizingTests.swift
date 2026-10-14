import AppKit
import PulseBarUI
import XCTest

final class PreferencesWindowSizingTests: XCTestCase {
    func testContentFitsWithoutScrollingWhenScreenHasRoom() {
        let content = NSSize(width: 520, height: 735)
        let chrome = NSSize(width: 0, height: 28)
        let screen = NSRect(x: 0, y: 24, width: 1440, height: 840)
        let frame = PreferencesWindowGeometry.frame(
            fitting: content, currentFrame: NSRect(x: 0, y: 0, width: 520, height: 688), chromeSize: chrome,
            visibleFrame: screen, centered: true)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertGreaterThanOrEqual(frame.height - chrome.height, content.height)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.midY, screen.midY)
    }

    func testSmallScreenIncludesTitleBarInHeightLimit() {
        let screen = NSRect(x: 0, y: 50, width: 800, height: 520)
        let chrome = NSSize(width: 0, height: 28)
        let frame = PreferencesWindowGeometry.frame(
            fitting: NSSize(width: 520, height: 1000), currentFrame: NSRect(x: 100, y: 100, width: 520, height: 688),
            chromeSize: chrome, visibleFrame: screen, centered: false)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.height, screen.height)
        XCTAssertEqual(frame.height - chrome.height, 492)
    }

    func testWelcomeDismissalKeepsWindowTopAndUserWidth() {
        let current = NSRect(x: 100, y: 100, width: 620, height: 750)
        let frame = PreferencesWindowGeometry.frame(
            fitting: NSSize(width: 620, height: 480), currentFrame: current, chromeSize: NSSize(width: 0, height: 28),
            visibleFrame: NSRect(x: 0, y: 24, width: 1440, height: 900), centered: false)
        XCTAssertLessThan(frame.height, current.height)
        XCTAssertEqual(frame.maxY, current.maxY)
        XCTAssertEqual(frame.width, current.width)
    }

    func testMovingToSmallerDisplayWithNegativeOriginKeepsWholeWindowVisible() {
        let screen = NSRect(x: -480, y: -100, width: 480, height: 600)
        let frame = PreferencesWindowGeometry.frame(
            fitting: NSSize(width: 620, height: 1000), currentFrame: NSRect(x: 100, y: 100, width: 620, height: 750),
            chromeSize: NSSize(width: 0, height: 28), visibleFrame: screen, centered: false)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.size, screen.size)
    }

    @MainActor
    func testWindowRefitsAfterContentAndDisplayChanges() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 660), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let display = TestDisplay()
        let sizing = PreferencesWindowSizing(window: window, visibleFrameProvider: { display.frame })
        sizing.contentSizeDidChange(NSSize(width: 520, height: 735))
        XCTAssertGreaterThanOrEqual(window.contentRect(forFrameRect: window.frame).height, 735)
        let top = window.frame.maxY
        sizing.contentSizeDidChange(NSSize(width: 520, height: 480))
        XCTAssertEqual(window.frame.maxY, top)
        XCTAssertLessThan(window.contentRect(forFrameRect: window.frame).height, 500)

        display.frame = NSRect(x: -480, y: 30, width: 480, height: 450)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(display.frame.contains(window.frame))
        XCTAssertLessThanOrEqual(window.minSize.width, display.frame.width)
        XCTAssertLessThanOrEqual(window.minSize.height, display.frame.height)
    }
}

@MainActor
private final class TestDisplay {
    var frame = NSRect(x: 0, y: 24, width: 1440, height: 900)
}
