import AppKit
import SwiftUI

public struct DeviceOption: Identifiable {
    public let alias: String
    public let status: String
    public let tone: PreferencesStatusTone
    public let username: String?
    public var id: String { alias }

    public init(alias: String, status: String = "Not connected", tone: PreferencesStatusTone = .neutral, username: String? = nil) {
        self.alias = alias
        self.status = status
        self.tone = tone
        self.username = username
    }

    fileprivate var accessibilityDescription: String {
        [alias, username.map { "Signed in as \($0)" }, status].compactMap { $0 }.joined(separator: ", ")
    }

    // Native macOS menus draw template symbols in the menu text color.
    fileprivate var menuDot: NSImage {
        let color = NSColor(tone.color)
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 6, height: 6)).fill()
            return true
        }
    }
}

struct DevicePicker: View {
    let devices: [DeviceOption]
    @Binding var selection: String
    let label: String
    var header: DeviceOption?
    let addDevice: () -> Void

    var body: some View {
        let selected = header ?? devices.first { $0.alias == selection }
        Menu {
            Button(action: addDevice) { Label("Add new", systemImage: "plus") }
            if !devices.isEmpty { Divider() }
            ForEach(devices) { device in
                Toggle(isOn: Binding(get: { device.alias == selection }, set: { _ in selection = device.alias })) {
                    Label {
                        Text(verbatim: "\(device.alias) · \(device.username ?? device.status)")
                    } icon: {
                        Image(nsImage: device.menuDot)
                    }
                }
                .accessibilityLabel(device.accessibilityDescription)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                Text(verbatim: selected?.alias ?? (selection.isEmpty ? "Choose a connection" : selection))
                    .lineLimit(1).truncationMode(.middle)
                if let selected {
                    Circle().fill(selected.tone.color).frame(width: 6, height: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label)
        .accessibilityValue(selected?.accessibilityDescription ?? selection)
        .help(selected.map { "\($0.alias) · \($0.status)" } ?? label)
    }
}
