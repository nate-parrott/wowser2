import Foundation

/// Reads password exports: Chrome (`name,url,username,password,note`),
/// Safari / Passwords app (`Title,URL,Username,Password,Notes,OTPAuth`),
/// Firefox (`"url","username","password",…`), 1Password, Bitwarden, etc.
/// Columns are found by header name, case-insensitively.
enum PasswordsCSV {
    static func read(_ url: URL) throws -> [ImportedLogin] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if ImportSQLite.isPermissionError(error) { throw ImportError.needsFullDiskAccess }
            throw ImportError.unreadable("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> [ImportedLogin] {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return [] }
        func col(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlCol = col(["url", "website", "login_uri", "login url", "origin", "web site"]),
              let userCol = col(["username", "login", "login_username", "user name", "email"]),
              let passCol = col(["password", "login_password"])
        else {
            throw ImportError.unreadable("This CSV doesn't look like a password export (need URL, Username and Password columns).")
        }
        let usedCol = col(["timelastused"])
        let countCol = col(["timesused"])

        var logins: [ImportedLogin] = []
        for row in rows.dropFirst() {
            guard row.count > max(urlCol, userCol, passCol) else { continue }
            let rawURL = row[urlCol].trimmingCharacters(in: .whitespaces)
            // Some exports store bare hosts ("example.com").
            guard let url = URL(string: rawURL).flatMap({ $0.scheme == nil ? URL(string: "https://" + rawURL) : $0 }) else { continue }
            var lastUsed: Date?
            if let usedCol, row.count > usedCol, let ms = Double(row[usedCol]), ms > 0 {
                lastUsed = Date(timeIntervalSince1970: ms / 1000) // Firefox: ms since 1970
            }
            let times = countCol.flatMap { row.count > $0 ? Int(row[$0]) : nil } ?? 0
            logins.append(ImportedLogin(url: url, username: row[userCol], password: row[passCol], lastUsed: lastUsed, timesUsed: times))
        }
        return logins
    }
}

/// Minimal RFC 4180 CSV parser (quoted fields, doubled quotes, CRLF, newlines in quotes).
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }
        // Skip a UTF-8 BOM.
        if let first = chars.next(), first != "\u{FEFF}" { pending = first }

        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": break
                case "\n":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
