import AppKit
import SwiftUI

@MainActor
struct PulseBarApp: App {
    private let viewModel = MetricsViewModel()

    var body: some Scene {
        MenuBarExtra {
            MetricsMenuView(viewModel: viewModel)
        } label: {
            MenuBarStatusItemLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            PulseBarCommands(viewModel: viewModel)
        }
    }
}

@MainActor
private struct MenuBarStatusItemLabel: View {
    @ObservedObject var viewModel: MetricsViewModel

    var body: some View {
        if let menuBarImage = menuBarLabelImage {
            Image(nsImage: menuBarImage)
                .accessibilityLabel(viewModel.snapshot.menuBarTitle)
        } else {
            Text(viewModel.snapshot.menuBarTitle)
                .monospacedDigit()
                .accessibilityLabel(viewModel.snapshot.menuBarTitle)
        }
    }

    private var menuBarLabelImage: NSImage? {
        let renderer = ImageRenderer(
            content: MenuBarLabelView(snapshot: viewModel.snapshot)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let image = renderer.nsImage else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

private struct MenuBarLabelView: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "memorychip")
            Text(snapshot.memory.percentText)
            Image(systemName: "cpu.fill")
            Text(snapshot.gpu.menuBarText)
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
