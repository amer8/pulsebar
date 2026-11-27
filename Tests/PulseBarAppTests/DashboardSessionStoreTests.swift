import Foundation
import Security
import XCTest

@testable import PulseBarApp

@MainActor
final class DashboardSessionStoreTests: XCTestCase {
    func testInvalidTokensAreNotSavedOrLoaded() throws {
        let keychain = MemoryDashboardKeychain()
        let store = makeStore(keychain: keychain)
        try store.saveToken("valid-token")
        for token in ["", " ", "a b", "a\r\nb", "é", "=", "a=b"] {
            XCTAssertThrowsError(try store.saveToken(token), token)
            XCTAssertEqual(try store.loadToken(), "valid-token")
            keychain.readData = Data(token.utf8)
            XCTAssertThrowsError(try store.loadToken(), token)
            keychain.readData = nil
        }
        try store.saveToken("abc-._~+/==")
        XCTAssertEqual(try store.loadToken(), "abc-._~+/==")
    }

    func testTokenCanBeInsertedUpdatedAndCleared() throws {
        let keychain = MemoryDashboardKeychain()
        let store = makeStore(keychain: keychain)
        XCTAssertNil(try store.loadToken())
        try store.saveToken("first-fake-token")
        XCTAssertEqual(try store.loadToken(), "first-fake-token")
        XCTAssertEqual(keychain.addCount, 1)
        try store.saveToken("replacement-fake-token")
        XCTAssertEqual(try store.loadToken(), "replacement-fake-token")
        XCTAssertEqual(keychain.addCount, 1)
        try store.clearToken()
        XCTAssertNil(try store.loadToken())
    }

    func testNewKeychainPromptNamesDistinguishDevicesAndCustomPorts() throws {
        let keychain = MemoryDashboardKeychain()
        for (alias, port, label) in [
            ("desk", 11000, "PulseBar Dashboard – desk"),
            ("lab", 11000, "PulseBar Dashboard – lab"),
            ("desk", 12000, "PulseBar Dashboard – desk:12000"),
        ] {
            let endpoint = try DashboardEndpoint(port: port, sshHost: alias)
            let store = makeStore(keychain: keychain, endpoint: endpoint)
            try store.saveToken("first-token")
            try store.saveToken("updated-token")
            XCTAssertEqual(keychain.addedLabels[endpoint.sessionAccount], label)
            XCTAssertEqual(try store.loadToken(), "updated-token")
        }
        XCTAssertEqual(keychain.addCount, 3)
    }

    func testLegacyItemRestoresInPlaceAndGetsNamedAfterSignOutAndSignIn() throws {
        let keychain = MemoryDashboardKeychain()
        let endpoint = try DashboardEndpoint(port: 11000, sshHost: "lab")
        let store = makeStore(keychain: keychain, endpoint: endpoint)
        _ = keychain.add([
            kSecAttrService as String: "PulseBar.Dashboard", kSecAttrAccount as String: endpoint.sessionAccount,
            kSecValueData as String: Data("old-token".utf8),
        ])
        XCTAssertEqual(try store.loadToken(allowInteraction: true), "old-token")
        XCTAssertEqual(keychain.addCount, 1)
        XCTAssertTrue(keychain.deleteInteractions.isEmpty)
        try store.clearToken(allowInteraction: true)
        try store.saveToken("new-token")
        XCTAssertEqual(keychain.addedLabels[endpoint.sessionAccount], "PulseBar Dashboard – lab")
        XCTAssertEqual(try store.loadToken(), "new-token")
    }

    func testUpdateFailureIsReportedWithoutTryingToAdd() throws {
        let keychain = MemoryDashboardKeychain()
        let store = makeStore(keychain: keychain)
        try store.saveToken("existing-fake-token")
        keychain.updateStatus = errSecAuthFailed
        assertSaveFailure(store, status: errSecAuthFailed)
        XCTAssertEqual(keychain.addCount, 1)
        XCTAssertEqual(try store.loadToken(), "existing-fake-token")
    }

    func testInsertFailureIsReported() throws {
        let keychain = MemoryDashboardKeychain()
        keychain.addStatus = errSecInteractionNotAllowed
        let store = makeStore(keychain: keychain)
        assertSaveFailure(store, status: errSecInteractionNotAllowed)
        XCTAssertNil(try store.loadToken())
    }

    func testUnreadableTokensAreReported() throws {
        let keychain = MemoryDashboardKeychain()
        let store = makeStore(keychain: keychain)
        try store.saveToken("fake-token")
        keychain.readStatus = errSecAuthFailed
        XCTAssertThrowsError(try store.loadToken()) { error in
            guard case SessionStoreError.keychainReadFailed(let status) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(status, errSecAuthFailed)
        }
        keychain.readStatus = nil
        keychain.readData = Data([0xFF])
        XCTAssertThrowsError(try store.loadToken()) { error in
            guard case SessionStoreError.invalidTokenData = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTokenOperationsStayIsolatedBetweenEndpoints() throws {
        let keychain = MemoryDashboardKeychain()
        let first = makeStore(keychain: keychain)
        let second = makeStore(keychain: keychain, endpoint: try DashboardEndpoint(port: 11001))
        try first.saveToken("first-endpoint-token")
        try second.saveToken("second-endpoint-token")
        XCTAssertEqual(try first.loadToken(), "first-endpoint-token")
        XCTAssertEqual(try second.loadToken(), "second-endpoint-token")
        try first.clearToken()
        XCTAssertNil(try first.loadToken())
        XCTAssertEqual(try second.loadToken(), "second-endpoint-token")
    }

    func testLaunchRestoresAuthorizedDeviceAndWaitsForExplicitApprovalForOtherDevice() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lab = try DashboardEndpoint(port: 11000, sshHost: "lab")
        let desk = try DashboardEndpoint(port: 11000, sshHost: "desk")
        let keychain = MemoryDashboardKeychain()
        let pause = DashboardReconnectPauseStore(defaults: defaults)
        defaults.set([["host": "lab", "port": 11000], ["host": "desk", "port": 11000]], forKey: "PulseBar.Dashboard.Devices")
        for endpoint in [lab, desk] {
            let store = DashboardSessionStore(endpoint: endpoint, defaults: defaults, keychain: keychain)
            store.saveUsername(endpoint == lab ? "alice" : "bob")
            try store.saveToken(endpoint == lab ? "lab-token" : "desk-token")
            pause.setPaused(true, for: endpoint)
        }
        keychain.protectedAccount = lab.sessionAccount
        let sessions = DeviceSessions(defaults: defaults) { endpoint in
            let store = DashboardSessionStore(endpoint: endpoint, defaults: defaults, keychain: keychain)
            return MetricsViewModel(sessionStore: store, endpoint: endpoint, reconnectPauseStore: pause)
        }
        let blocked = sessions.managed
        XCTAssertFalse(blocked.isSignedIn)
        XCTAssertEqual(blocked.username, "alice")
        let preferences = blocked.preferencesState(port: "11000", host: "lab", defaults: defaults)
        XCTAssertTrue(preferences.showsAccount && preferences.canUseProfile && preferences.sessionLoadIssue == .permissionRequired)
        XCTAssertNil(preferences.accountNote)
        XCTAssertEqual(preferences.restoreSessionTitle, "Restore Saved Session for lab")
        XCTAssertTrue(blocked.panelState(at: .now, historyWindow: .minute).needsSessionRestore)
        XCTAssertTrue(sessions.manage("desk"))
        sessions.display("desk")
        XCTAssertEqual(sessions.managed.signedInUsername, "bob")
        XCTAssertTrue(sessions.manage("lab"))
        XCTAssertEqual(keychain.readAccounts, [lab.sessionAccount, desk.sessionAccount])
        XCTAssertEqual(keychain.readInteractions, [false, false])
        blocked.retrySavedSession()
        XCTAssertEqual(keychain.readAccounts, [lab.sessionAccount, desk.sessionAccount, lab.sessionAccount])
        XCTAssertEqual(keychain.readInteractions, [false, false, true])
        XCTAssertEqual(blocked.signedInUsername, "alice")
        XCTAssertFalse(blocked.panelState(at: .now, historyWindow: .minute).needsSessionRestore)
        XCTAssertEqual(sessions.displayed.signedInUsername, "bob")
        blocked.signOut()
        XCTAssertEqual(keychain.deleteInteractions, [true])
    }

    func testSavedSessionsRequireTheSameSSHAliasAndIgnorePortOnlyTokens() throws {
        let keychain = MemoryDashboardKeychain()
        for port in [11000, 11001] {
            let legacyAccount = port == 11000 ? "dashboard-token" : "dashboard-token:\(port)"
            _ = keychain.add([
                kSecAttrService as String: "PulseBar.Dashboard", kSecAttrAccount as String: legacyAccount,
                kSecValueData as String: Data("legacy-token".utf8),
            ])
            let first = makeStore(keychain: keychain, endpoint: try DashboardEndpoint(port: port, sshHost: "dgx"))
            let second = makeStore(keychain: keychain, endpoint: try DashboardEndpoint(port: port, sshHost: "lab"))
            XCTAssertNil(try first.loadToken())
            try first.saveToken("dgx-session")
            XCTAssertNil(try second.loadToken())
            XCTAssertEqual(try first.loadToken(), "dgx-session")
        }
    }

    func testDeletionFailureIsReportedAndTokenIsRetained() throws {
        let keychain = MemoryDashboardKeychain()
        let store = makeStore(keychain: keychain)
        try store.clearToken()  // An absent item is already cleared.
        try store.saveToken("fake-token")
        keychain.deleteStatus = errSecAuthFailed
        XCTAssertThrowsError(try store.clearToken()) { error in
            guard case SessionStoreError.keychainDeleteFailed(let status) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, errSecAuthFailed)
        }
        XCTAssertEqual(try store.loadToken(), "fake-token")
        keychain.deleteStatus = nil
        try store.clearToken()
        XCTAssertNil(try store.loadToken())
    }

    private func makeStore(keychain: MemoryDashboardKeychain, endpoint: DashboardEndpoint = .standard) -> DashboardSessionStore {
        let suite = "PulseBarSessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return DashboardSessionStore(endpoint: endpoint, defaults: defaults, keychain: keychain)
    }

    private func assertSaveFailure(
        _ store: DashboardSessionStore, status: OSStatus, file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            try store.saveToken("unsaved-fake-token")
            XCTFail("Expected the storage error to be reported", file: file, line: line)
        } catch SessionStoreError.keychainSaveFailed(let actual) {
            XCTAssertEqual(actual, status, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

// This adapter never calls Security.framework or accesses the user's Keychain.
@MainActor
private final class MemoryDashboardKeychain: DashboardKeychainAccessing {
    private var items: [String: Data] = [:]
    private(set) var addCount = 0
    private(set) var addedLabels: [String: String] = [:]
    var updateStatus: OSStatus?
    var addStatus: OSStatus?
    var readStatus: OSStatus?
    var readData: Data?
    var deleteStatus: OSStatus?
    var protectedAccount: String?
    private(set) var readAccounts: [String] = []
    private(set) var readInteractions: [Bool] = []
    private(set) var deleteInteractions: [Bool] = []

    func copyMatching(_ query: [String: Any], allowInteraction: Bool) -> (OSStatus, Data?) {
        let account = query[kSecAttrAccount as String] as? String ?? ""
        readAccounts.append(account)
        readInteractions.append(allowInteraction)
        if account == protectedAccount && !allowInteraction { return (errSecAuthFailed, nil) }
        if let readStatus { return (readStatus, nil) }
        guard let data = readData ?? items[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if let updateStatus { return updateStatus }
        guard items[key(query)] != nil else { return errSecItemNotFound }
        items[key(query)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> OSStatus {
        addCount += 1
        if let addStatus { return addStatus }
        if let account = query[kSecAttrAccount as String] as? String {
            addedLabels[account] = query[kSecAttrLabel as String] as? String
        }
        items[key(query)] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any], allowInteraction: Bool) -> OSStatus {
        deleteInteractions.append(allowInteraction)
        if let deleteStatus { return deleteStatus }
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }

    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
    }
}
