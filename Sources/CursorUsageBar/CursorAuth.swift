import CommonCrypto
import Foundation
import Security
import SQLite3

enum CursorAuthError: LocalizedError {
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case tokenNotFound
    case invalidToken
    case keychainDenied
    case keychainFailed(OSStatus)
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path): return "Cursor database not found at \(path). Is Cursor installed and signed in?"
        case .databaseOpenFailed(let msg): return "Couldn't open Cursor database: \(msg)"
        case .tokenNotFound: return "No Cursor access token found. Sign in to Cursor first."
        case .invalidToken: return "Cursor access token couldn't be decoded."
        case .keychainDenied: return "Keychain access to \"Cursor Safe Storage\" was denied. Click ↻ and choose Always Allow."
        case .keychainFailed(let status): return "Couldn't read \"Cursor Safe Storage\" from Keychain (error \(status))."
        case .decryptFailed: return "Couldn't decrypt Cursor's access token."
        }
    }
}

struct CursorCredentials {
    let accessToken: String
    let userId: String

    /// Cookie value accepted by cursor.com's dashboard API.
    var sessionCookie: String {
        "WorkosCursorSessionToken=\(userId)%3A%3A\(accessToken)"
    }
}

enum CursorAuth {
    static var databasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    /// Since Cursor 3.27, tokens are stored as this prefix + base64 of Electron `safeStorage` ciphertext.
    private static let encryptedPrefix = "cursor-safe-storage:v1:"

    /// Derived AES key, cached so Keychain is only asked once per launch.
    private static var cachedKey: Data?

    /// Reads the access token Cursor stores in its local VS Code state DB, decrypting it if needed.
    /// Re-read on every fetch, since Cursor rotates the token itself.
    static func loadCredentials() throws -> CursorCredentials {
        let values = try readValues(keys: [
            "cursorAuth/accessToken", "cursorAuth/stripeMembershipAuthId", "cursorAuth/cachedScopedProfile",
        ])

        guard var token = values["cursorAuth/accessToken"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")),
              !token.isEmpty
        else { throw CursorAuthError.tokenNotFound }

        if token.hasPrefix(encryptedPrefix) {
            token = try decrypt(String(token.dropFirst(encryptedPrefix.count)))
        }

        let userId = userId(fromJWT: token)
            ?? values["cursorAuth/stripeMembershipAuthId"].flatMap(lastAuthSegment)
            ?? values["cursorAuth/cachedScopedProfile"].flatMap(userId(fromProfileJSON:))
        guard let userId else { throw CursorAuthError.invalidToken }

        return CursorCredentials(accessToken: token, userId: userId)
    }

    // MARK: - Database

    private static func readValues(keys: [String]) throws -> [String: String] {
        let path = databasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw CursorAuthError.databaseNotFound(path)
        }

        var db: OpaquePointer?
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw CursorAuthError.databaseOpenFailed(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var stmt: OpaquePointer?
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let sql = "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CursorAuthError.databaseOpenFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, key) in keys.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), key, -1, transient)
        }

        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) else { continue }
            result[String(cString: k)] = String(cString: v)
        }
        return result
    }

    // MARK: - Decryption

    /// Electron `safeStorage` on macOS (Chromium OSCrypt): "v10" + AES-128-CBC/PKCS7,
    /// key = PBKDF2-SHA1(Keychain "Cursor Safe Storage" password, "saltysalt", 1003 rounds), IV = 16 spaces.
    private static func decrypt(_ base64: String) throws -> String {
        guard let blob = Data(base64Encoded: base64), blob.count > 3, blob.prefix(3) == Data("v10".utf8) else {
            throw CursorAuthError.decryptFailed
        }
        let ciphertext = blob.dropFirst(3)
        let key = try encryptionKey()
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var outLength = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, ciphertext.count,
                                outPtr.baseAddress, outCapacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess, let token = String(data: out.prefix(outLength), encoding: .utf8) else {
            cachedKey = nil  // key may have been rotated; re-read Keychain next time
            throw CursorAuthError.decryptFailed
        }
        return token
    }

    private static func encryptionKey() throws -> Data {
        if let key = cachedKey { return key }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw CursorAuthError.keychainDenied
        default: throw CursorAuthError.keychainFailed(status)
        }
        guard let password = item as? Data else { throw CursorAuthError.keychainFailed(status) }

        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let result = key.withUnsafeMutableBytes { keyPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), keyCount)
                }
            }
        }
        guard result == kCCSuccess else { throw CursorAuthError.decryptFailed }
        cachedKey = key
        return key
    }

    // MARK: - User ID

    /// The JWT `sub` claim looks like "auth0|user_XXXX"; the API wants the part after "|".
    private static func userId(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String
        else { return nil }
        return lastAuthSegment(sub)
    }

    private static func userId(fromProfileJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj.values.compactMap { $0 as? String }.first { $0.contains("|") }.flatMap(lastAuthSegment)
    }

    private static func lastAuthSegment(_ authId: String) -> String? {
        authId.split(separator: "|").last.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }
}
