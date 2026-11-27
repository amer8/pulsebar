import AppKit
import PulseBarUI
import SwiftUI

@MainActor
struct PulseBarApp: App {
    @StateObject private var sessions = makeSessions()
    @AppStorage(MenuBarDisplay.preferenceKey) private var display = MenuBarDisplay.both.rawValue

    private static func makeSessions() -> DeviceSessions {
        let demo = CommandLine.arguments.contains("--demo")
        let sessions = DeviceSessions(defaults: demo ? nil : .standard) { endpoint in
            MetricsViewModel(demo: demo && endpoint.sshHost == nil, endpoint: endpoint)
        }
        if !demo, sessions.displayed.endpoint.sshHost == nil,
            !UserDefaults.standard.bool(forKey: "PulseBar.HasPresentedSSHSetup")
        {
            DispatchQueue.main.async {
                PulseBarNavigation.openPreferences(sessions: sessions, addingDevice: true)
                UserDefaults.standard.set(true, forKey: "PulseBar.HasPresentedSSHSetup")
            }
        }
        return sessions
    }

    var body: some Scene {
        let presentation = sessions.displayed.menuBarPresentation(display: MenuBarDisplay(rawValue: display) ?? .both)
        MenuBarExtra {
            MetricsDetailView(sessions: sessions)
        } label: {
            MenuBarStatusItemLabel(presentation: presentation)
        }
        .menuBarExtraStyle(.window)
        .commands {
            PulseBarCommands(sessions: sessions)
        }
    }
}

@MainActor
private struct MenuBarStatusItemLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        if let menuBarImage = menuBarLabelImage {
            Image(nsImage: menuBarImage)
                .accessibilityLabel(presentation.accessibilityLabel)
                .help(presentation.accessibilityLabel)
        } else {
            Text(presentation.fallbackTitle)
                .monospacedDigit()
                .accessibilityLabel(presentation.accessibilityLabel)
                .help(presentation.accessibilityLabel)
        }
    }

    private var menuBarLabelImage: NSImage? {
        let renderer = ImageRenderer(content: MenuBarLabelView(presentation: presentation))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let image = renderer.nsImage else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

struct MenuBarLabelView: View {
    let presentation: MenuBarPresentation

    var body: some View {
        HStack(spacing: 6) {
            if let symbol = presentation.connectionSymbol {
                Image(systemName: symbol)
                if presentation.display != .icon { Text(presentation.state.rawValue) }
            } else if presentation.display == .icon {
                Image(systemName: MenuBarDisplay.iconSymbol)
            } else {
                if presentation.display != .gpu {
                    Image(systemName: "memorychip")
                    Text(presentation.snapshot.memory.percentText)
                }
                if presentation.display != .memory {
                    Image(systemName: "cpu.fill")
                    Text(presentation.snapshot.gpu.menuBarText)
                }
            }
            if presentation.showsAvailableUpdate {
                Image(systemName: "arrow.down.circle.fill")
            }
        }
        .font(.system(size: NSFont.menuBarFont(ofSize: 0).pointSize))
        .monospacedDigit()
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.black)
        .fixedSize()
    }
}

@MainActor
struct PulseBarCommands: Commands {
    let sessions: DeviceSessions

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                PulseBarNavigation.openPreferences(sessions: sessions)
            } label: {
                Label("Preferences…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                SparkleController.shared.checkForUpdates()
            }
            .disabled(!SparkleController.shared.canCheckForUpdates)
        }

        CommandGroup(replacing: .appTermination) {
            Button {
                sessions.displayed.quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
