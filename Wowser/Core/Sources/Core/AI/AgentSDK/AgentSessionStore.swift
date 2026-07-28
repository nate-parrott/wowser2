import Foundation

// On-disk registry of named agent sessions, so an agent survives page reloads
// and app restarts. A record is just how the agent was configured plus its
// harness session id — resuming that session is what carries the agent's
// memory of the conversation.
//
// Transcripts are deliberately NOT stored: replaying old messages back to a
// caller that reattaches would re-deliver things it has already seen. A
// reattached agent starts with an empty transcript and remembers the
// conversation itself.
//
// One JSON file per key at:
//   ~/Library/Application Support/Wowser/agents/<slug>.json

public struct AgentSessionRecord: Codable, Sendable {
    public var key: String
    public var agentID: String
    public var name: String?
    public var model: String?
    public var effort: String?
    public var systemPrompt: String?
    public var exposeBrowserJS: Bool
    public var fileSystemTools: Bool
    public var workingDirectory: String?
    /// Harness session id — resumed to restore the agent's memory of the
    /// conversation. The transcript is not stored; see the note above.
    public var sessionID: String?
    public var updatedAt: Date

    public init(key: String, agentID: String, name: String? = nil, model: String? = nil, effort: String? = nil, systemPrompt: String? = nil, exposeBrowserJS: Bool = true, fileSystemTools: Bool = false, workingDirectory: String? = nil, sessionID: String? = nil, updatedAt: Date = Date()) {
        self.key = key; self.agentID = agentID; self.name = name
        self.model = model; self.effort = effort; self.systemPrompt = systemPrompt
        self.exposeBrowserJS = exposeBrowserJS; self.fileSystemTools = fileSystemTools
        self.workingDirectory = workingDirectory; self.sessionID = sessionID
        self.updatedAt = updatedAt
    }
}

public protocol AgentSessionStoring: Sendable {
    func load(key: String) -> AgentSessionRecord?
    func save(_ record: AgentSessionRecord)
    func delete(key: String)
    func all() -> [AgentSessionRecord]
}

public final class AgentSessionStore: AgentSessionStoring, @unchecked Sendable {
    public static let shared = AgentSessionStore()

    private let dir: URL
    private let queue = DispatchQueue(label: "AgentSessionStore")

    public init(dir: URL? = nil) {
        if let dir {
            self.dir = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.dir = appSupport
                .appendingPathComponent("Wowser", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    /// Keys are user-supplied; keep them to safe filename characters.
    static func slug(for key: String) -> String {
        let mapped = key.lowercased().map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }
        let slug = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "agent" : String(slug.prefix(80))
    }

    private func url(for key: String) -> URL {
        dir.appendingPathComponent(Self.slug(for: key) + ".json")
    }

    public func load(key: String) -> AgentSessionRecord? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
            return try? JSONDecoder().decode(AgentSessionRecord.self, from: data)
        }
    }

    public func save(_ record: AgentSessionRecord) {
        queue.sync {
            var record = record
            record.updatedAt = Date()
            guard let data = try? JSONEncoder().encode(record) else { return }
            try? data.write(to: url(for: record.key), options: .atomic)
        }
    }

    public func delete(key: String) {
        queue.sync { try? FileManager.default.removeItem(at: url(for: key)) }
    }

    public func all() -> [AgentSessionRecord] {
        queue.sync {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return urls
                .filter { $0.pathExtension == "json" }
                .compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? JSONDecoder().decode(AgentSessionRecord.self, from: $0) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}
