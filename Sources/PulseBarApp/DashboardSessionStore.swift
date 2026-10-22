import Foundation
import Security

@MainActor
protocol DashboardKeychainAccessing {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemDashboardKeychain: DashboardKeychainAccessing {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum SessionStoreError: LocalizedError {
    case keychainSaveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainSaveFailed(let status):
            let statusMessage = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "PulseBar could not save the dashboard session token to Keychain: \(statusMessage)."
        }
    }
}

@MainActor
protocol DashboardSessionStoring {
    func loadUsername() -> String
    func saveUsername(_ username: String)
    func clearUsername()
    func loadToken() -> String?
    func saveToken(_ token: String) throws
    func clearToken()
}

struct DashboardSessionStore: DashboardSessionStoring {
    private let endpoint: DashboardEndpoint
    private let defaults: UserDefaults
    private let keychain: any DashboardKeychainAccessing
    private let keychainService = "PulseBar.Dashboard"
    private var usernameKey: String { endpoint.usernameKey }
    private var keychainAccount: String { endpoint.sessionAccount }
    init(
        endpoint: DashboardEndpoint = .current,
        defaults: UserDefaults = .standard,
        keychain: any DashboardKeychainAccessing = SystemDashboardKeychain()
    ) {
        self.endpoint = endpoint
        self.defaults = defaults
        self.keychain = keychain
    }

    func loadUsername() -> String {
        defaults.string(forKey: usernameKey) ?? ""
    }

    func saveUsername(_ username: String) {
        defaults.set(username, forKey: usernameKey)
    }

    func clearUsername() {
        defaults.removeObject(forKey: usernameKey)
    }

    func loadToken() -> String? {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        let (status, result) = keychain.copyMatching(query)
        guard status == errSecSuccess, let data = result else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) throws {
        let tokenData = Data(token.utf8)
        let updateAttributes = [
            kSecValueData as String: tokenData
        ]

        let updateStatus = keychain.update(keychainQuery, attributes: updateAttributes)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw SessionStoreError.keychainSaveFailed(updateStatus)
        }

        var query = keychainQuery
        query[kSecValueData as String] = tokenData

        let addStatus = keychain.add(query)
        guard addStatus == errSecSuccess else {
            throw SessionStoreError.keychainSaveFailed(addStatus)
        }
    }

    func clearToken() {
        _ = keychain.delete(keychainQuery)
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }
}
