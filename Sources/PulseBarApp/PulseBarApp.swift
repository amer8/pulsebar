import AppKit
import PulseBarUI
import SwiftUI

@MainActor
struct PulseBarApp: App {
    private let viewModel = MetricsViewModel(demo: CommandLine.arguments.contains("--demo"))

    init() {
        if !UserDefaults.standard.bool(forKey: "PulseBar.HasSeenWelcome") {
            let model = viewModel
            DispatchQueue.main.async { PulseBarNavigation.openPreferences(viewModel: model) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MetricsDetailView(viewModel: viewModel)
        } label: {
            MenuBarStatusItemLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
        .commands {
            PulseBarCommands(viewModel: viewModel)
        }
    }
}

@MainActor
private struct MenuBarStatusItemLabel: View {
    @ObservedObject var viewModel: MetricsViewModel
    @AppStorage(MenuBarDisplay.preferenceKey) private var display = MenuBarDisplay.both.rawValue

    var body: some View {
        let presentation = MenuBarPresentation(
            state: viewModel.connectionHealth.state, snapshot: viewModel.snapshot,
            display: MenuBarDisplay(rawValue: display) ?? .both,
            updateStatus: viewModel.isSignedIn ? viewModel.updateStatus : .hidden)
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
        let renderer = ImageRenderer(
            content: MenuBarLabelView(
                snapshot: viewModel.snapshot, state: viewModel.connectionHealth.state,
                updateStatus: viewModel.isSignedIn ? viewModel.updateStatus : .hidden
            ).id(display)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let image = renderer.nsImage else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

struct MenuBarUpdateIndicator: Equatable {
    let isStale: Bool

    init?(status: SystemUpdateStatus) {
        switch status {
        case .available: isStale = false
        case .staleAvailable: isStale = true
        default: return nil
        }
    }

    var accessibilityDescription: String {
        isStale ? "DGX system update previously available, status stale" : "DGX system update available"
    }
}

struct MenuBarLabelView: View {
    let snapshot: MetricsSnapshot
    let state: TelemetryConnectionHealth.State
    let updateStatus: SystemUpdateStatus
    @AppStorage(MenuBarDisplay.preferenceKey) private var display = MenuBarDisplay.both.rawValue

    var body: some View {
        HStack(spacing: 6) {
            if MenuBarPresentation(state: state, snapshot: snapshot).showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            if display == MenuBarDisplay.icon.rawValue {
                Image(systemName: "waveform.path.ecg")
            } else {
                if display != MenuBarDisplay.gpu.rawValue {
                    Image(systemName: "memorychip")
                    Text(snapshot.memory.percentText)
                }
                if display != MenuBarDisplay.memory.rawValue {
                    Image(systemName: "cpu.fill")
                    Text(snapshot.gpu.menuBarText)
                }
            }
            if let indicator = MenuBarUpdateIndicator(status: updateStatus) {
                HStack(spacing: 1) {
                    Image(systemName: indicator.isStale ? "arrow.down.circle" : "arrow.down.circle.fill")
                    if indicator.isStale { Text("?").font(.system(size: 9, weight: .bold)) }
                }
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
    let viewModel: MetricsViewModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                PulseBarNavigation.openPreferences(viewModel: viewModel)
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
                viewModel.quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
