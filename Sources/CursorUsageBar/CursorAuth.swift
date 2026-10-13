import Foundation
import SQLite3

enum CursorAuthError: LocalizedError {
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case tokenNotFound
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path): return "Cursor database not found at \(path). Is Cursor installed and signed in?"
        case .databaseOpenFailed(let msg): return "Couldn't open Cursor database: \(msg)"
        case .tokenNotFound: return "No Cursor access token found. Sign in to Cursor first."
        case .invalidToken: return "Cursor access token couldn't be decoded."
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

    /// Reads the access token Cursor stores in its local VS Code state DB.
    /// Re-read on every fetch, since Cursor rotates the token itself.
    static func loadCredentials() throws -> CursorCredentials {
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
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CursorAuthError.databaseOpenFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else {
            throw CursorAuthError.tokenNotFound
        }
        let token = String(cString: raw).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard !token.isEmpty else { throw CursorAuthError.tokenNotFound }

        return CursorCredentials(accessToken: token, userId: try userId(fromJWT: token))
    }

    /// The JWT `sub` claim looks like "auth0|user_XXXX"; the API wants the part after "|".
    private static func userId(fromJWT token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw CursorAuthError.invalidToken }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let id = sub.split(separator: "|").last
        else { throw CursorAuthError.invalidToken }
        return String(id)
    }
}
