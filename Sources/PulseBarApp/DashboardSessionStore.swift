import Foundation
import LoginKeychain
import Security

@MainActor
protocol DashboardKeychainAccessing {
    func copyMatching(_ query: [String: Any], allowInteraction: Bool) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ query: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any], allowInteraction: Bool) -> OSStatus
}

struct SystemDashboardKeychain: DashboardKeychainAccessing {
    func copyMatching(_ query: [String: Any], allowInteraction: Bool) -> (OSStatus, Data?) {
        var result: AnyObject?
        let read = { SecItemCopyMatching(query as CFDictionary, &result) }
        let status = allowInteraction ? read() : PBWithoutKeychainUI(read)
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }
    func delete(_ query: [String: Any], allowInteraction: Bool) -> OSStatus {
        let delete = { SecItemDelete(query as CFDictionary) }
        return allowInteraction ? delete() : PBWithoutKeychainUI(delete)
    }
}

enum SessionStoreError: LocalizedError {
    case keychainReadFailed(OSStatus)
    case keychainSaveFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case invalidTokenData

    var needsReadPermission: Bool {
        switch self {
        case .keychainReadFailed(errSecInteractionNotAllowed), .keychainReadFailed(errSecInteractionRequired),
            .keychainReadFailed(errSecAuthFailed):
            true
        default: false
        }
    }

    var errorDescription: String? {
        if needsReadPermission { return "Keychain did not allow access to this device’s saved session." }
        switch self {
        case .keychainReadFailed(let status):
            let statusMessage = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "PulseBar could not read the dashboard session token from Keychain: \(statusMessage)."
        case .keychainSaveFailed(let status):
            let statusMessage = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "PulseBar could not save the dashboard session token to Keychain: \(statusMessage)."
        case .keychainDeleteFailed(let status):
            let statusMessage = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "PulseBar could not remove the dashboard session token from Keychain: \(statusMessage)."
        case .invalidTokenData:
            return "PulseBar could not read the dashboard session token because its Keychain data is invalid."
        }
    }
}

@MainActor
protocol DashboardSessionStoring {
    func loadUsername() -> String
    func saveUsername(_ username: String)
    func clearUsername()
    func loadToken(allowInteraction: Bool) throws -> String?
    func saveToken(_ token: String) throws
    func clearToken(allowInteraction: Bool) throws
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

    func loadToken(allowInteraction: Bool = false) throws -> String? {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        let (status, result) = keychain.copyMatching(query, allowInteraction: allowInteraction)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SessionStoreError.keychainReadFailed(status) }
        guard let data = result, let token = String(data: data, encoding: .utf8) else {
            throw SessionStoreError.invalidTokenData
        }
        guard (try? DashboardSessionToken.validate(token)) != nil else { throw SessionStoreError.invalidTokenData }
        return token
    }

    func saveToken(_ token: String) throws {
        try DashboardSessionToken.validate(token)
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
        if let device = endpoint.sshHost {
            // The login Keychain uses the label at creation to name its default access prompt.
            let name = endpoint.port == DashboardEndpoint.standard.port ? device : "\(device):\(endpoint.port)"
            query[kSecAttrLabel as String] = "PulseBar Dashboard – \(name)"
        }

        let addStatus = keychain.add(query)
        guard addStatus == errSecSuccess else {
            throw SessionStoreError.keychainSaveFailed(addStatus)
        }
    }

    func clearToken(allowInteraction: Bool = false) throws {
        let status = keychain.delete(keychainQuery, allowInteraction: allowInteraction)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreError.keychainDeleteFailed(status)
        }
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }
}
