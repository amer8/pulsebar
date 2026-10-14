import SwiftUI

public enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case both = "RAM and GPU"
    case memory = "RAM"
    case gpu = "GPU"
    case icon = "Icon only"
    public static let preferenceKey = "PulseBar.MenuBarDisplay"
    public var id: String { rawValue }
}

public struct MenuBarPreferencesContent: View {
    @Binding private var display: MenuBarDisplay
    public init(display: Binding<MenuBarDisplay>) { _display = display }

    public var body: some View {
        DashboardPreferencesCard {
            Label("Menu Bar", systemImage: "menubar.rectangle").fontWeight(.semibold)
            HStack {
                Text("Show")
                Spacer()
                Picker("Show in menu bar", selection: $display) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 190)
            }
            Text("Choose what appears in the macOS menu bar.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
