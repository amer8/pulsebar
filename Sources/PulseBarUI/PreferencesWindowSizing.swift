import AppKit

public enum PreferencesWindowGeometry {
    public static func frame(
        fitting contentSize: NSSize, currentFrame: NSRect, chromeSize: NSSize, visibleFrame: NSRect, centered: Bool
    ) -> NSRect {
        let width = min(max(currentFrame.width, ceil(contentSize.width) + chromeSize.width), visibleFrame.width)
        let height = min(ceil(contentSize.height) + chromeSize.height, visibleFrame.height)
        let x = centered ? visibleFrame.midX - width / 2 : currentFrame.minX
        let y = centered ? visibleFrame.midY - height / 2 : currentFrame.maxY - height
        return NSRect(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - height), width: width, height: height
        )
    }
}

@MainActor
public final class PreferencesWindowSizing: NSObject, NSWindowDelegate {
    public private(set) var measuredContentSize = NSSize.zero
    private weak var window: NSWindow?
    private let visibleFrameProvider: () -> NSRect?
    private var hasFittedContent = false
    private var isFitting = false
    private var lastFittedWidth: CGFloat = 0

    public init(window: NSWindow, visibleFrameProvider: (() -> NSRect?)? = nil) {
        self.window = window
        self.visibleFrameProvider = visibleFrameProvider ?? { [weak window] in window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame }
        super.init()
        window.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        fitContent()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    public func contentSizeDidChange(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        measuredContentSize = size
        fitContent()
    }

    public func fitContent() {
        guard !isFitting, let window, !window.inLiveResize, let available = visibleFrameProvider(), !available.isEmpty else { return }
        isFitting = true
        defer { isFitting = false }
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let chrome = NSSize(width: window.frame.width - contentRect.width, height: window.frame.height - contentRect.height)
        window.contentMinSize = NSSize(
            width: max(0, min(400, available.width - chrome.width)), height: max(0, min(240, available.height - chrome.height)))
        window.maxSize = available.size
        let content = measuredContentSize == .zero ? contentRect.size : measuredContentSize
        let frame = PreferencesWindowGeometry.frame(
            fitting: content, currentFrame: window.frame, chromeSize: chrome, visibleFrame: available, centered: !hasFittedContent)
        if window.frame != frame { window.setFrame(frame, display: window.isVisible) }
        lastFittedWidth = window.frame.width
        if measuredContentSize != .zero { hasFittedContent = true }
    }

    public func windowDidChangeScreen(_ notification: Notification) { fitContent() }

    public func windowDidEndLiveResize(_ notification: Notification) {
        if let window, abs(window.frame.width - lastFittedWidth) > 0.5 { fitContent() }
    }

    @objc private func screenParametersChanged() { fitContent() }
}
