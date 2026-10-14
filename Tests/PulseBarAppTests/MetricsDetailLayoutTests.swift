import AppKit
import SwiftUI
import XCTest

@testable import PulseBarApp

final class MetricsDetailLayoutTests: XCTestCase {
    @MainActor
    func testSignedOutPanelHasUsableInitialSize() {
        _ = NSApplication.shared
        let model = MetricsViewModel(sessionStore: PanelSessionStore())
        defer { model.signOut() }
        assertUsablePanel(model)
    }

    @MainActor
    func testLivePanelHasUsableSizeOnRepeatedOpen() async throws {
        _ = NSApplication.shared
        let model = MetricsViewModel(sessionStore: PanelSessionStore(), demo: true)
        defer { model.signOut() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.history.samples.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.history.samples.isEmpty)
        for _ in 0..<3 { assertUsablePanel(model) }
    }

    @MainActor
    private func assertUsablePanel(_ model: MetricsViewModel, file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingController(rootView: MetricsDetailView(viewModel: model))
        // Window sizing probes both the ideal size and a compressed opening proposal.
        for proposal in [NSSize.zero, NSSize(width: 400, height: 1), NSSize(width: 400, height: 1000)] {
            let size = host.sizeThatFits(in: proposal)
            XCTAssertEqual(size.width, 400, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThan(size.height, 350, "The history panel must not collapse to its scroll bar.", file: file, line: line)
            XCTAssertLessThanOrEqual(size.height, 650, file: file, line: line)
        }
        if let path = ProcessInfo.processInfo.environment["PULSEBAR_LAYOUT_PREVIEW_DIR"] {
            let size = host.sizeThatFits(in: .zero)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            let view = NSHostingView(
                rootView: MetricsDetailView(viewModel: model)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            do {
                let bitmap = try XCTUnwrap(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), file: file, line: line)
                bitmap.size = size
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = model.history.samples.isEmpty ? "history-signed-out.png" : "history-live.png"
                let url = URL(fileURLWithPath: path).appendingPathComponent(name)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
                try png.write(to: url)
            } catch {
                XCTFail("Could not capture the history panel: \(error)", file: file, line: line)
            }
        }
    }
}

@MainActor
private final class PanelSessionStore: DashboardSessionStoring {
    func loadUsername() -> String { "" }
    func loadToken() -> String? { nil }
    func saveUsername(_ username: String) {}
    func saveToken(_ token: String) {}
    func clearUsername() {}
    func clearToken() {}
}
