import SwiftUI
import XCTest

@testable import PulseBarApp
@testable import PulseBarUI

@MainActor
final class DeviceSessionsTests: XCTestCase {
    func testSavedSessionRecoveryBelongsOnlyToTheAppliedDevice() {
        var state = DashboardPreferencesState(deviceName: "desk")
        state.edit = .applied
        XCTAssertFalse(state.showsSavedSessionRecovery)
        state.sessionLoadIssue = .permissionRequired
        XCTAssertTrue(state.showsSavedSessionRecovery)
        state.setupStep = .chooseAlias
        XCTAssertFalse(state.showsSavedSessionRecovery)
        state.setupStep = .choose
        state.edit = .pending("desk · 12000")
        XCTAssertFalse(state.showsSavedSessionRecovery)
        state.edit = .applied
        state.sessionLoadIssue = nil
        state.removalFailed = true
        XCTAssertTrue(state.showsSavedSessionRecovery)

        var signedIn = DashboardPreferencesState(deviceName: "desk", accountName: "alice")
        signedIn.edit = .applied
        signedIn.removalFailed = true
        XCTAssertFalse(signedIn.showsSavedSessionRecovery)
    }

    func testRemovalRequiresConfirmationForTheNamedDeviceAndConsumesItOnce() {
        var confirmation = SavedSessionRemovalConfirmation()
        var removed: [String] = []
        func confirm(_ device: String) {
            confirmation.confirm(for: device) { removed.append(device) }
        }
        confirm("desk")
        confirmation.requestedDevice = "desk"
        confirm("lab")
        confirmation.requestedDevice = nil
        confirm("desk")
        XCTAssertTrue(removed.isEmpty)
        confirmation.requestedDevice = "lab"
        confirm("lab")
        confirm("lab")
        XCTAssertEqual(removed, ["lab"])
    }

    func testNativePickerMenusShowEachAccountAndSwitchByDeviceAlias() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Hosting a SwiftUI menu for inspection requires macOS 14.4.") }
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pause = DashboardReconnectPauseStore(defaults: defaults)
        let accounts = ["desk": "alice", "lab": "lab-admin"]
        let sessions = DeviceSessions(defaults: nil) { endpoint in
            let account = endpoint.sshHost.flatMap { accounts[$0] }
            pause.setPaused(true, for: endpoint)
            let store = MemorySessionStore(username: account ?? "", token: account.map { _ in "fixture-token" })
            return MetricsViewModel(sessionStore: store, endpoint: endpoint, reconnectPauseStore: pause)
        }
        sessions.didVerify(try DashboardEndpoint(port: 11000, sshHost: "desk"))
        sessions.didVerify(try DashboardEndpoint(port: 11000, sshHost: "lab"))

        func checkMenu(
            _ picker: DevicePicker, titles: [String], checked: String, select title: String, binding: Binding<String>, expectedAlias: String
        ) async throws {
            let menu = NSHostingMenu(rootView: picker)
            menu.update()
            let entries = try XCTUnwrap(menu.items.first?.submenu)
            entries.update()
            let commands = entries.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(commands.map(\.title), titles)
            XCTAssertEqual(entries.items.filter { $0.state == .on }.map(\.title), [checked])
            XCTAssertTrue(commands.allSatisfy { $0.image != nil })
            let entry = try XCTUnwrap(entries.items.first { $0.title == title })
            XCTAssertTrue(entry.isEnabled)
            let action = try XCTUnwrap(entry.action)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: entry.target, from: entry))
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while binding.wrappedValue != expectedAlias && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            withExtendedLifetime(menu) {}
            XCTAssertEqual(binding.wrappedValue, expectedAlias)
        }

        let panel = Binding(get: { sessions.displayed.endpoint.sshHost ?? "" }, set: { sessions.display($0) })
        let preferences = Binding(get: { sessions.managed.endpoint.sshHost ?? "" }, set: { sessions.manage($0) })
        var actions = TelemetryPanelActions()
        actions.selectDevice = sessions.display
        let telemetry = TelemetryHistoryPanel(
            state: sessions.panelState(at: .now, historyWindow: .minute), now: .now, historySeconds: .constant(60), actions: actions)
        let desk = "desk · alice"
        let lab = "lab · lab-admin"
        try await checkMenu(
            telemetry.devicePicker, titles: ["Add new", desk, lab], checked: desk, select: lab, binding: panel, expectedAlias: "lab")
        try await checkMenu(
            preferencesPicker(sessions), titles: ["Add new", desk, lab], checked: lab, select: desk,
            binding: preferences, expectedAlias: "desk")
        XCTAssertEqual(panel.wrappedValue, "lab")
        let deskAccount = sessions.managed.preferencesState(port: "11000", host: "desk")
        XCTAssertEqual(deskAccount.accountHeading, "DGX Dashboard account on desk")
        XCTAssertEqual(deskAccount.accountName, "alice")
        sessions.managed.signOut()
        sessions.managed.username = "unfinished-login"
        let signedOut = "desk · Signed out"
        try await checkMenu(
            preferencesPicker(sessions), titles: ["Add new", signedOut, lab], checked: signedOut, select: lab,
            binding: preferences, expectedAlias: "lab")
        let labAccount = sessions.managed.preferencesState(port: "11000", host: "lab")
        XCTAssertEqual(labAccount.accountHeading, "DGX Dashboard account on lab")
        XCTAssertEqual(labAccount.accountName, "lab-admin")
    }

    func testAddNewInBothPickersOpensAliasListWithZeroOneOrTwoDevices() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Hosting a SwiftUI menu for inspection requires macOS 14.4.") }
        _ = NSApplication.shared
        let sessions = DeviceSessions(defaults: nil) {
            MetricsViewModel(sessionStore: MemorySessionStore(username: "", token: nil), endpoint: $0)
        }
        let navigation = PreferencesNavigation()
        let setup = DGXConnectionSetup()
        var actions = TelemetryPanelActions()
        actions.addDevice = navigation.requestAddDevice

        for alias in [nil, "desk", "lab"] {
            if let alias { sessions.didVerify(try DashboardEndpoint(port: 11000, sshHost: alias)) }
            let displayed = sessions.displayed
            let managed = sessions.managed
            let panel = TelemetryHistoryPanel(
                state: sessions.panelState(at: .now, historyWindow: .minute), now: .now, historySeconds: .constant(60), actions: actions)
            for picker in [panel.devicePicker, preferencesPicker(sessions, addDevice: navigation.requestAddDevice)] {
                navigation.pane = .general
                let menu = NSHostingMenu(rootView: picker)
                menu.update()
                let entries = try XCTUnwrap(menu.items.first?.submenu)
                entries.update()
                let add = try XCTUnwrap(entries.items.first)
                XCTAssertEqual(add.title, "Add new")
                XCTAssertNotNil(add.image)
                XCTAssertTrue(add.isEnabled)
                XCTAssertEqual(entries.items.filter(\.isSeparatorItem).count, sessions.devices.isEmpty ? 0 : 1)
                XCTAssertEqual(
                    entries.items.filter { !$0.isSeparatorItem }.map(\.title),
                    ["Add new"] + sessions.devices.map { "\($0.alias) · Signed out" }
                )
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(add.action), to: add.target, from: add))
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while !navigation.addDeviceRequested && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                withExtendedLifetime(menu) {}
                XCTAssertTrue(navigation.beginRequestedSetup(in: setup))
                XCTAssertEqual(navigation.pane, .dashboard)
                XCTAssertEqual(setup.step, .chooseAlias)
                await setup.loadAliases { ["desk", "lab", "new-device"] }
                let available = sessions.preferencesState(port: "11000", host: "", setup: setup).availableAliases
                XCTAssertEqual(available, ["desk", "lab", "new-device"].filter { !sessions.devices.map(\.alias).contains($0) })
                XCTAssertTrue(sessions.displayed === displayed)
                XCTAssertTrue(sessions.managed === managed)
                setup.reset()
                XCTAssertFalse(navigation.beginRequestedSetup(in: setup))
                XCTAssertEqual(setup.step, .choose)
            }
        }
    }

    func testChoosingAliasStartsVerificationAndSyncRemainsASecondaryAction() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Hosting a SwiftUI menu for inspection requires macOS 14.4.") }
        _ = NSApplication.shared
        let lab = try DashboardEndpoint(port: 12000, sshHost: "lab")
        var trusted = false
        var probes: [DashboardEndpoint] = []
        let setup = DGXConnectionSetup(
            probe: { target in
                probes.append(target)
                guard trusted else { throw DashboardError.unknownSSHHostKey }
                return true
            },
            fingerprint: { _, expected in
                if let expected { trusted = expected == "SHA256:fixture" }
                return "SHA256:fixture"
            })
        let sessions = DeviceSessions(defaults: nil) {
            MetricsViewModel(sessionStore: MemorySessionStore(username: "", token: nil), endpoint: $0)
        }
        setup.reset(to: .chooseAlias)
        var host = ""
        var launches = 0
        var operation: Task<Void, Never>?
        var actions = DashboardPreferencesActions()
        actions.openSync = { launches += 1 }
        actions.connect = {
            guard let target = try? DashboardEndpoint.parse("12000", sshHost: host) else { return XCTFail("Missing selection") }
            operation = setup.connect(target, onConnected: sessions.didVerify)
        }
        func presentation() -> DashboardPreferencesState {
            sessions.preferencesState(port: "12000", host: host, setup: setup)
        }
        func options() -> NSMenu {
            let content = DashboardPreferencesContent(
                port: .constant("12000"), sshHost: Binding(get: { host }, set: { host = $0 }),
                username: .constant(""), password: .constant(""), pane: .constant(.dashboard), state: presentation(), actions: actions
            ) { EmptyView() }
            let menu = NSHostingMenu(rootView: content.addDeviceOptions)
            menu.update()
            return menu
        }
        func click(_ title: String, in menu: NSMenu) throws {
            let item = try XCTUnwrap(menu.items.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        let sync = "Set up a device in NVIDIA Sync…"
        await setup.loadAliases { [] }
        let empty = options()
        XCTAssertEqual(empty.items.map(\.title), [sync])
        try click(sync, in: empty)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while launches == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(probes.isEmpty)
        XCTAssertFalse(presentation().showsAccount)

        await setup.loadAliases { ["desk", "lab"] }
        let menu = options()
        XCTAssertEqual(menu.items.map(\.title), ["desk", "lab", sync])
        try click("lab", in: menu)
        let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while operation == nil && ContinuousClock.now < selectionDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try await XCTUnwrap(operation).value
        XCTAssertEqual(probes, [lab])
        XCTAssertEqual(setup.step, .verify("SHA256:fixture"))
        XCTAssertNil(setup.connect(lab, expected: "wrong", onConnected: sessions.didVerify))
        XCTAssertFalse(presentation().showsAccount)
        XCTAssertTrue(sessions.devices.isEmpty)
        try await XCTUnwrap(setup.connect(lab, expected: "SHA256:fixture", onConnected: sessions.didVerify)).value
        XCTAssertEqual(probes, [lab, lab])
        XCTAssertEqual(sessions.managed.endpoint, lab)
        XCTAssertTrue(presentation().showsSignInForm)
        XCTAssertEqual(presentation().accountHeading, "Sign in to DGX Dashboard on lab")
        XCTAssertEqual(launches, 1)
    }

    private func preferencesPicker(_ sessions: DeviceSessions, addDevice: @escaping () -> Void = {})
        -> DevicePicker
    {
        let model = sessions.managed
        let host = model.endpoint.sshHost ?? ""
        let port = String(model.endpoint.port)
        let state = sessions.preferencesState(port: port, host: host, setup: DGXConnectionSetup())
        var actions = DashboardPreferencesActions()
        actions.selectDevice = { sessions.manage($0) }
        actions.addDevice = addDevice
        return DashboardPreferencesContent(
            port: .constant(port), sshHost: .constant(host), username: .constant(""), password: .constant(""),
            pane: .constant(.dashboard), state: state, actions: actions
        ) { EmptyView() }.devicePicker
    }

    func testSelectingTrustedDeviceRestoresItsSavedAccountOnlyAfterVerification() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try DashboardEndpoint(port: 11000, sshHost: "desk")
        let second = try DashboardEndpoint(port: 11000, sshHost: "lab")
        defaults.set(first.sshHost, forKey: DashboardEndpoint.hostPreferenceKey)
        defaults.set(first.port, forKey: DashboardEndpoint.preferenceKey)
        let stores = [
            first: MemorySessionStore(username: "alice", token: "desk-token"),
            second: MemorySessionStore(username: "bob", token: "lab-token"),
        ]
        let pause = DashboardReconnectPauseStore(defaults: defaults)
        for device in stores.keys { pause.setPaused(true, for: device) }
        var opened: [DashboardEndpoint] = []
        let sessions = DeviceSessions(defaults: defaults) { endpoint in
            opened.append(endpoint)
            return MetricsViewModel(sessionStore: stores[endpoint]!, endpoint: endpoint, reconnectPauseStore: pause)
        }
        var reachable = false
        let setup = DGXConnectionSetup(
            probe: { _ in reachable },
            fingerprint: { _, _ in
                XCTFail("A previously trusted host should not require enrollment")
                return ""
            })
        setup.reset(to: .chooseAlias)
        await setup.loadAliases { ["desk", "lab"] }
        func state() -> DashboardPreferencesState { sessions.preferencesState(port: "11000", host: "lab", setup: setup) }
        XCTAssertEqual(state().availableAliases, ["lab"])
        try await XCTUnwrap(setup.connect(second, onConnected: sessions.didVerify)).value
        XCTAssertEqual(opened, [first])
        XCTAssertFalse(state().showsAccount)
        reachable = true
        try await XCTUnwrap(setup.connect(second, onConnected: sessions.didVerify)).value
        XCTAssertEqual(opened, [first, second])
        XCTAssertTrue(state().showsAccount)
        XCTAssertFalse(state().showsSignInForm)
        XCTAssertEqual(state().accountName, "bob")
        XCTAssertEqual(sessions.devices.map(\.username), ["alice", "bob"])
        XCTAssertEqual(stores[first]?.token, "desk-token")
        XCTAssertEqual(stores[second]?.token, "lab-token")
    }

    func testRestoreKeepsLegacyProfileAndBothSessionsWithLastDisplayedDevice() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let desk = try DashboardEndpoint(port: 11999, sshHost: "desk")
        let lab = try DashboardEndpoint(port: 11000, sshHost: "lab")
        defaults.set(desk.sshHost, forKey: DashboardEndpoint.hostPreferenceKey)
        defaults.set(desk.port, forKey: DashboardEndpoint.preferenceKey)
        let stores = [
            desk: MemorySessionStore(username: "alice", token: "desk-token"), lab: MemorySessionStore(username: "bob", token: "lab-token"),
        ]
        // Paused profiles load their accounts without opening network connections.
        let pause = DashboardReconnectPauseStore(defaults: defaults)
        for endpoint in stores.keys { pause.setPaused(true, for: endpoint) }
        var created: [DashboardEndpoint] = []
        func restore() -> DeviceSessions {
            DeviceSessions(defaults: defaults) { endpoint in
                created.append(endpoint)
                return MetricsViewModel(sessionStore: stores[endpoint]!, endpoint: endpoint, reconnectPauseStore: pause)
            }
        }

        do {
            let sessions = restore()
            XCTAssertEqual(created, [desk])
            XCTAssertEqual(sessions.displayed.username, "alice")
            sessions.didVerify(lab)
            XCTAssertEqual(sessions.managed.username, "bob")
            XCTAssertEqual(sessions.displayed.endpoint, desk)
            sessions.display("lab")
            sessions.manage("desk")
            sessions.didVerify(desk)
            XCTAssertEqual(created, [desk, lab])
        }
        created.removeAll()
        let restored = restore()
        XCTAssertEqual(created, [desk, lab])
        XCTAssertEqual(restored.displayed.endpoint, lab)
        XCTAssertEqual(restored.displayed.username, "bob")
        XCTAssertTrue(restored.displayed.isSignedIn)
        XCTAssertTrue(restored.manage("desk"))
        XCTAssertTrue(restored.managed.isSignedIn)
        XCTAssertEqual(restored.managed.username, "alice")
        XCTAssertEqual(restored.managed.endpoint.port, 11999)
        let setup = DGXConnectionSetup(probe: { _ in false })
        setup.reset(to: .chooseAlias)
        await setup.loadAliases { ["DESK", "unrelated"] }
        func presentation() -> DashboardPreferencesState {
            restored.preferencesState(port: "11000", host: "unrelated", setup: setup)
        }
        XCTAssertEqual(presentation().availableAliases, ["unrelated"])
        XCTAssertEqual(presentation().devices.map(\.alias), ["desk", "lab"])
        let target = try DashboardEndpoint(port: 11000, sshHost: "unrelated")
        await setup.connect(target, onConnected: restored.didVerify)?.value
        XCTAssertEqual(setup.step, .chooseAlias)
        setup.reset()
        XCTAssertNil(presentation().availableAliases)
        XCTAssertEqual(restored.displayed.endpoint, lab)
        XCTAssertEqual(restored.managed.endpoint, desk)
        XCTAssertEqual(restored.devices.map(\.username), ["alice", "bob"])
        XCTAssertEqual(stores[desk]?.token, "desk-token")
        XCTAssertEqual(stores[lab]?.token, "lab-token")
        XCTAssertEqual(created, [desk, lab])
        XCTAssertEqual(restored.devices.map(\.tone), [.warning, .warning])
    }

    func testChangingOnePortReplacesOnlyThatCollectorAndRetestsReuseIt() throws {
        var created: [DashboardEndpoint] = []
        let sessions = DeviceSessions(defaults: nil) { endpoint in
            created.append(endpoint)
            return MetricsViewModel(sessionStore: MemorySessionStore(username: "", token: nil), endpoint: endpoint)
        }
        let first = try DashboardEndpoint(port: 11000, sshHost: "one")
        let second = try DashboardEndpoint(port: 11000, sshHost: "two")
        let edited = try DashboardEndpoint(port: 12000, sshHost: "two")
        XCTAssertTrue(sessions.devices.isEmpty)
        sessions.didVerify(first)
        let original = sessions.displayed
        sessions.didVerify(second)
        sessions.display("two")
        let oldPort = sessions.displayed
        sessions.didVerify(edited)
        XCTAssertFalse(sessions.displayed === oldPort)
        XCTAssertEqual(sessions.displayed.endpoint, edited)
        XCTAssertEqual(sessions.verifiedEndpoints, [first, edited])
        let replacement = sessions.displayed
        sessions.didVerify(edited)
        XCTAssertTrue(sessions.managed === replacement)
        XCTAssertEqual(created, [.standard, first, second, edited])
        sessions.manage("one")
        XCTAssertTrue(sessions.managed === original)
        XCTAssertTrue(sessions.displayed === replacement)
        XCTAssertEqual(sessions.devices.map(\.alias), ["one", "two"])
    }

    func testUnverifiedAliasDoesNotCreateACollectorOrSwitchEitherPicker() async throws {
        let sessions = DeviceSessions(defaults: nil) {
            MetricsViewModel(sessionStore: MemorySessionStore(username: "", token: nil), endpoint: $0)
        }
        let desk = try DashboardEndpoint(port: 11000, sshHost: "desk")
        let lab = try DashboardEndpoint(port: 11000, sshHost: "lab")
        sessions.didVerify(desk)
        let setup = DGXConnectionSetup(probe: { _ in throw DashboardError.unknownSSHHostKey }, fingerprint: { _, _ in "SHA256:digest" })
        setup.reset(to: .chooseAlias)
        await setup.loadAliases { ["DESK", "lab"] }
        let state = sessions.preferencesState(port: "11000", host: "lab", setup: setup)
        XCTAssertEqual(state.devices.map(\.alias), ["desk"])
        XCTAssertEqual(state.availableAliases, ["lab"])
        XCTAssertFalse(state.showsAccount)
        let unlisted = try DashboardEndpoint(port: 11000, sshHost: "unlisted")
        XCTAssertNil(setup.connect(unlisted, onConnected: sessions.didVerify))
        let probe = try XCTUnwrap(setup.connect(lab, onConnected: sessions.didVerify))
        await probe.value
        XCTAssertEqual(setup.step, .verify("SHA256:digest"))
        XCTAssertNil(setup.connect(lab, expected: "wrong", onConnected: sessions.didVerify))
        setup.reset()
        let cancelled = sessions.preferencesState(port: "11000", host: "desk", setup: setup)
        XCTAssertEqual(cancelled.devices.map(\.alias), ["desk"])
        XCTAssertNil(cancelled.availableAliases)
        XCTAssertFalse(sessions.manage("lab"))
        sessions.display("lab")
        XCTAssertEqual(sessions.displayed.endpoint, desk)
        XCTAssertEqual(sessions.managed.endpoint, desk)
        XCTAssertEqual(sessions.devices.map(\.alias), ["desk"])
        XCTAssertEqual(sessions.verifiedEndpoints, [desk])
    }
}
