import SwiftUI

@main
@MainActor
enum PulseBarMain {
    static func main() {
        if CommandLine.arguments.contains("--check-runtime") {
            // dyld loads linked frameworks before reaching this entry point.
            print("PulseBar runtime dependencies loaded.")
            return
        }
        PulseBarApp.main()
    }
}
