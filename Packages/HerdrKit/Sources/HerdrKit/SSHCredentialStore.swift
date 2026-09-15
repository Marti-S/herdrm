#if os(macOS)
import Foundation
import Security

public enum SSHCredentialStore {
    public static let askPassModeEnvironmentKey = "HERDRM_SSH_ASKPASS"
    public static let authorizationIDEnvironmentKey = "HERDRM_SSH_AUTHORIZATION_ID"
    public static let persistenceDescription = "Saved in your macOS login Keychain"

    private static let passwordService = "dev.bybee.herdrm.ssh-password"
    private static let authorizationService = "dev.bybee.herdrm.ssh-authorization"

    public static func password(for deviceID: UUID) throws -> String? {
        if let password = try keychainPassword(for: deviceID) { return password }

        // Migrate credentials written by the short-lived Debug file-store implementation.
        guard let legacyData = try legacyLocalData(directory: "passwords", id: deviceID) else {
            return nil
        }
        let password = try decodePassword(legacyData)
        try setKeychainPassword(password, for: deviceID)
        try removeLegacyLocalData(directory: "passwords", id: deviceID)
        return password
    }

    public static func setPassword(_ password: String, for deviceID: UUID) throws {
        guard !password.isEmpty else {
            try removePassword(for: deviceID)
            return
        }

        try setKeychainPassword(password, for: deviceID)
    }

    public static func removePassword(for deviceID: UUID) throws {
        try removeKeychainPassword(for: deviceID)
        try? removeLegacyLocalData(directory: "passwords", id: deviceID)
    }

    // MARK: - One-shot askpass hand-off
    //
    // The password is looked up in the Keychain exactly once, here, by the
    // running app. It is then handed to `ssh` through a private 0600 file that
    // a shell-script `SSH_ASKPASS` prints and deletes. The askpass helper used
    // to be this app's own executable doing a second Keychain lookup, which
    // launched a GUI process per `ssh` (dock bounce) and re-prompted for
    // Keychain access on every differently-signed build; when the prompt was
    // killed by the tunnel deadline the retry loop bounced the icon forever.

    public static let passwordFileEnvironmentKey = "HERDRM_SSH_PASSWORD_FILE"

    static func createAuthorization(for deviceID: UUID) throws -> UUID? {
        guard let password = try password(for: deviceID) else { return nil }
        let authorizationID = UUID()
        let url = authorizationURL(authorizationID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("\(password)\n".utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return authorizationID
    }

    /// Absolute path of the one-shot password file for `SSH_ASKPASS`.
    public static func authorizationFilePath(_ authorizationID: UUID) -> String {
        authorizationURL(authorizationID).path
    }

    /// Drops hand-off files stranded by a crash between creation and askpass
    /// consumption, plus any grants left in the Keychain by older builds.
    public static func purgeAuthorizations() {
        let directory = authorizationsDirectory
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: authorizationService,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Reads and deletes the hand-off file. Used by the in-process fallback
    /// askpass and by tests; the shell helper does the same with `cat`+`rm`.
    public static func consumePassword(authorizationID: UUID) throws -> String? {
        let url = authorizationURL(authorizationID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? removeAuthorization(authorizationID) }
        guard var password = String(data: data, encoding: .utf8) else {
            throw SSHCredentialStoreError(status: errSecDecode)
        }
        if password.hasSuffix("\n") { password.removeLast() }
        return password
    }

    public static func removeAuthorization(_ authorizationID: UUID) throws {
        let url = authorizationURL(authorizationID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try? removeLegacyLocalData(directory: "authorizations", id: authorizationID)
    }

    /// The `SSH_ASKPASS` program: a two-line shell script materialized in the
    /// app's private directory so `ssh` never launches the GUI binary.
    public static func askPassHelperPath() throws -> String {
        let url = privateRoot.appendingPathComponent("herdrm-askpass.sh", isDirectory: false)
        let script = """
        #!/bin/sh
        # HerdrM SSH_ASKPASS: print the one-shot password hand-off, then remove it.
        f="$\(passwordFileEnvironmentKey)"
        [ -n "$f" ] && [ -f "$f" ] || exit 1
        cat "$f"
        rm -f "$f"

        """
        let data = Data(script.utf8)
        if (try? Data(contentsOf: url)) != data {
            try FileManager.default.createDirectory(
                at: privateRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    private static var privateRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
            .appendingPathComponent("SSHAskPass", isDirectory: true)
    }

    private static var authorizationsDirectory: URL {
        privateRoot.appendingPathComponent("pending", isDirectory: true)
    }

    private static func authorizationURL(_ authorizationID: UUID) -> URL {
        authorizationsDirectory.appendingPathComponent(authorizationID.uuidString, isDirectory: false)
    }

    private static func decodePassword(_ data: Data) throws -> String {
        guard let password = String(data: data, encoding: .utf8) else {
            throw SSHCredentialStoreError(status: errSecDecode)
        }
        return password
    }

    private static func keychainPassword(for deviceID: UUID) throws -> String? {
        guard let data = try keychainData(
            service: passwordService,
            account: deviceID.uuidString
        ) else { return nil }
        return try decodePassword(data)
    }

    private static func setKeychainPassword(_ password: String, for deviceID: UUID) throws {
        let passwordData = Data(password.utf8)
        let query = keychainQuery(service: passwordService, account: deviceID.uuidString)
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SSHCredentialStoreError(status: updateStatus)
        }

        var newItem = query
        newItem[kSecValueData as String] = passwordData
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SSHCredentialStoreError(status: addStatus) }
    }

    private static func removeKeychainPassword(for deviceID: UUID) throws {
        let status = SecItemDelete(
            keychainQuery(service: passwordService, account: deviceID.uuidString) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHCredentialStoreError(status: status)
        }
    }

    private static func keychainData(service: String, account: String) throws -> Data? {
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SSHCredentialStoreError(status: status) }
        guard let data = result as? Data else { throw SSHCredentialStoreError(status: errSecDecode) }
        return data
    }

    private static func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func legacyLocalData(directory: String, id: UUID) throws -> Data? {
        let url = legacyLocalURL(directory: directory, id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func removeLegacyLocalData(directory: String, id: UUID) throws {
        let url = legacyLocalURL(directory: directory, id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let children = ["passwords", "authorizations"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        for directory in children + [root] {
            guard (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
            else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func legacyLocalURL(directory: String, id: UUID) -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = applicationSupport
            .appendingPathComponent("HerdrM", isDirectory: true)
            .appendingPathComponent("SSHCredentials", isDirectory: true)
        return root
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: false)
    }
}

public struct SSHCredentialStoreError: LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "could not access SSH password in Keychain: \(detail)"
    }
}#endif  // os(macOS)
