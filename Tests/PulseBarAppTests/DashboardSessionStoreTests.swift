import Foundation
import Security
import XCTest

@testable import PulseBarApp

@MainActor
final class DashboardSessionStoreTests: XCTestCase {
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
    var updateStatus: OSStatus?
    var addStatus: OSStatus?
    var readStatus: OSStatus?
    var readData: Data?
    var deleteStatus: OSStatus?

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
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
        items[key(query)] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let deleteStatus { return deleteStatus }
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }

    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
    }
}
