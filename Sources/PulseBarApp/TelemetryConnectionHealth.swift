import Foundation

struct TelemetryConnectionHealth {
    enum State: String {
        case signedOut = "Signed out"
        case signingIn = "Signing in…"
        case connecting = "Connecting…"
        case waiting = "Waiting for telemetry…"
        case live = "Connected"
        case stale = "Telemetry is stale"
        case reconnecting = "Reconnecting…"
        case paused = "Reconnection paused"
        case expired = "Session expired"
    }
    private(set) var state: State = .signedOut
    private(set) var lastSampleAt: Date?
    var unrecognizedEventName: String?
    private var connectedAt: Date?
    mutating func beginConnection(signingIn: Bool = false) {
        state = signingIn ? .signingIn : .connecting
        unrecognizedEventName = nil
        lastSampleAt = nil
        connectedAt = nil
    }
    mutating func connected(at date: Date) {
        state = .waiting
        connectedAt = date
    }
    mutating func sampleReceived(at date: Date) {
        state = .live
        unrecognizedEventName = nil
        lastSampleAt = date
    }
    mutating func reconnecting() { state = .reconnecting }
    mutating func pause() { state = .paused }
    mutating func expire() {
        state = .expired
        unrecognizedEventName = nil
        lastSampleAt = nil
        connectedAt = nil
    }
    mutating func markStale(at date: Date, after interval: TimeInterval = 30) -> Bool {
        guard state == .live || state == .waiting,
            let reference = [connectedAt, lastSampleAt].compactMap({ $0 }).max(), date.timeIntervalSince(reference) >= interval
        else { return false }
        state = .stale
        return true
    }
    static func retryDelay(failures: Int) -> Duration {
        .seconds(min(30, 2 * pow(2, Double(min(max(failures - 1, 0), 4)))))
    }
}
