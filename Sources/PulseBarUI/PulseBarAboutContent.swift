import AppKit
import SwiftUI

public struct PulseBarAppInformation {
    public let versionDescription: String
    public let releaseDate: String?

    public init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    public init(infoDictionary: [String: Any]) {
        let version = infoDictionary["CFBundleShortVersionString"] as? String
        let build = infoDictionary["CFBundleVersion"] as? String
        versionDescription = (version.map { "Version \($0)" } ?? "Development build") + (build.map { " (\($0))" } ?? "")

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        if let value = infoDictionary["PulseBarReleaseDate"] as? String, let date = parser.date(from: value) {
            let formatter = DateFormatter()
            formatter.timeZone = parser.timeZone
            formatter.dateStyle = .long
            releaseDate = formatter.string(from: date)
        } else {
            releaseDate = nil
        }
    }
}

public struct PulseBarAboutContent: View {
    private let information: PulseBarAppInformation
    private let appIcon: NSImage

    @MainActor
    public init(information: PulseBarAppInformation = PulseBarAppInformation(), appIcon: NSImage? = nil) {
        self.information = information
        self.appIcon = appIcon ?? NSApplication.shared.applicationIconImage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(nsImage: appIcon).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PulseBar").font(.headline)
                    Text(information.versionDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Text("Live DGX Dashboard telemetry\nin your macOS menu bar.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let releaseDate = information.releaseDate {
                Text("Released \(releaseDate)").font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack(spacing: 14) {
                Link("Release Notes", destination: URL(string: "https://github.com/amer8/pulsebar/releases")!)
                Link("GitHub", destination: URL(string: "https://github.com/amer8/pulsebar")!)
                Spacer(minLength: 0)
                Text("MIT License").foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(18).frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain).accessibilityLabel("About PulseBar")
    }
}
