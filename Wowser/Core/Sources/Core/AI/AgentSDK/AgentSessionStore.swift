import Foundation

// On-disk registry of named agent sessions, so an agent survives page reloads
// and app restarts. A record is just how the agent was configured plus its
// harness session id — resuming that session is what carries the agent's
// memory of the conversation.
//
// The rendered transcript is stored beside it, so a reattached agent comes
// back with its history visible and message indices continuing where they
// left off (the harness remembers the conversation; the sidecar is only what
// the UI shows).
//
// Two JSON files per key at:
//   ~/Library/Application Support/Wowser/agents/<slug>.json
//   ~/Library/Application Support/Wowser/agents/<slug>.transcript.json

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
    /// App-implemented (JS) tools this agent was created with, so a resumed
    /// agent still has them. The app must re-`serve` them after reattaching.
    public var appTools: [BrowserJSAgentToolSpec]
    /// Harness session id — resumed to restore the agent's memory of the
    /// conversation.
    public var sessionID: String?
    /// Which agent implementation runs this session: nil = the platform
    /// default (Claude Code), `LocalAgentProvider.harnessID` = on-device.
    public var harness: String?
    public var updatedAt: Date

    public init(key: String, agentID: String, name: String? = nil, model: String? = nil, effort: String? = nil, systemPrompt: String? = nil, exposeBrowserJS: Bool = true, fileSystemTools: Bool = false, workingDirectory: String? = nil, appTools: [BrowserJSAgentToolSpec] = [], sessionID: String? = nil, updatedAt: Date = Date()) {
        self.key = key; self.agentID = agentID; self.name = name
        self.model = model; self.effort = effort; self.systemPrompt = systemPrompt
        self.exposeBrowserJS = exposeBrowserJS; self.fileSystemTools = fileSystemTools
        self.workingDirectory = workingDirectory; self.appTools = appTools
        self.sessionID = sessionID; self.updatedAt = updatedAt
    }
}

public protocol AgentSessionStoring: Sendable {
    func load(key: String) -> AgentSessionRecord?
    func save(_ record: AgentSessionRecord)
    func delete(key: String)
    func all() -> [AgentSessionRecord]
    /// The transcript last saved for this key ([] if none).
    func loadTranscript(key: String) -> [BrowserJSAgentMessage]
    func saveTranscript(key: String, messages: [BrowserJSAgentMessage])
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

    private func transcriptURL(for key: String) -> URL {
        dir.appendingPathComponent(Self.slug(for: key) + ".transcript.json")
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
        queue.sync {
            try? FileManager.default.removeItem(at: url(for: key))
            try? FileManager.default.removeItem(at: transcriptURL(for: key))
        }
    }

    public func loadTranscript(key: String) -> [BrowserJSAgentMessage] {
        queue.sync {
            guard let data = try? Data(contentsOf: transcriptURL(for: key)) else { return [] }
            return (try? JSONDecoder().decode([BrowserJSAgentMessage].self, from: data)) ?? []
        }
    }

    public func saveTranscript(key: String, messages: [BrowserJSAgentMessage]) {
        // Encode and write off the caller's thread; transcripts can be large.
        queue.async { [transcriptURL = transcriptURL(for: key)] in
            guard let data = try? JSONEncoder().encode(messages) else { return }
            try? data.write(to: transcriptURL, options: .atomic)
        }
    }

    public func all() -> [AgentSessionRecord] {
        queue.sync {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return urls
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".transcript.json") }
                .compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? JSONDecoder().decode(AgentSessionRecord.self, from: $0) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}
