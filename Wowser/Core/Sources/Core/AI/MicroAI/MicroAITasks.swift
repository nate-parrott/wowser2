import Foundation
import FoundationModels

// Prompts + output types for each MicroAIFeature. Pure (no store access) so
// `MicroAIEvals` can run them against fixtures on every backend.
// The on-device model has a ~4K-token window, so inputs are trimmed hard.

// MARK: - Choose space for an opened link

enum LinkSpaceTask {
    struct Space {
        var name: String
        var recentDomains: [String]
        var openTabs: [String] // "title — host", most recently used first

        /// Hosts this space has open or recently visited.
        var hosts: Set<String> {
            Set(recentDomains + openTabs.compactMap { $0.components(separatedBy: " — ").last })
        }
    }

    /// {reason, space}, with `space` constrained to the actual space names.
    static func schema(spaces: [Space]) throws -> GenerationSchema {
        var names = [String]()
        for s in spaces where !names.contains(s.name) { names.append(s.name) }
        let root = DynamicGenerationSchema(name: "LinkSpace", properties: [
            .init(name: "reason", description: "One short sentence: what the link is about, and which space (if any) is clearly about that",
                  schema: .init(type: String.self)),
            .init(name: "space", description: "Name of the chosen space",
                  schema: .init(name: "SpaceName", anyOf: names)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Big multi-product domains where a subdomain says nothing about the
    /// space (docs.google.com isn't mail.google.com).
    private static let platformDomains: Set<String> = ["google.com", "apple.com", "microsoft.com", "amazon.com", "yahoo.com", "live.com", "office.com"]

    /// Spaces that already have `url`'s site open or in recent history.
    static func sameSiteSpaces(url: URL, spaces: [Space]) -> [Int] {
        let host = url.hostWithoutWWW
        guard !host.isEmpty else { return [] }
        let parent = host.split(separator: ".").dropFirst().joined(separator: ".")
        return spaces.indices.filter { i in
            let hosts = spaces[i].hosts
            return hosts.contains(host)
                || (parent.contains(".") && !platformDomains.contains(parent) && hosts.contains(parent))
        }
    }

    static func prompt(url: URL, spaces: [Space], currentIndex: Int?) -> MicroAIPrompt {
        let instructions = """
        You sort links into browser spaces. A space is a workspace for one part of the user's life, like work, a hobby, or a project.
        A link was just opened from another app. Pick the space it belongs in, judging by what the link is about.
        Move it only when the link is clearly about the subject of another space's name or its open tabs (e.g. a flight to Japan belongs in "Japan trip"). Sharing a big website like Google or YouTube is not enough.
        If the current space is a reasonable fit, or no space is clearly about the link's subject, answer the current space.
        """
        var lines = ["Link: \(url.absoluteString.truncateTailWithEllipsis(chars: 200))", "", "Spaces:"]
        for (i, space) in spaces.enumerated() {
            lines.append("- \"\(space.name)\"" + (i == currentIndex ? " (current space)" : ""))
            if !space.recentDomains.isEmpty {
                lines.append("   Recent sites: " + space.recentDomains.prefix(10).joined(separator: ", "))
            }
            if !space.openTabs.isEmpty {
                lines.append("   Open tabs:")
                for tab in space.openTabs.prefix(8) { lines.append("   - \(tab.truncateTailWithEllipsis(chars: 80))") }
            }
        }
        lines.append("")
        lines.append("Current space: " + (currentIndex.map { "\"\(spaces[$0].name)\"" } ?? "none"))
        return MicroAIPrompt(instructions: instructions, input: lines.joined(separator: "\n"))
    }

    /// Index of the space the model named, tolerating case/quote drift.
    static func index(named name: String, in spaces: [Space]) -> Int? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'"))).lowercased()
        return spaces.firstIndex { $0.name.lowercased() == key }
    }

    /// Index into `spaces` (nil to leave the link where it is) and a short
    /// reason for logging. A site that exactly one space already has open or
    /// recently visited goes there without asking the model.
    static func run(url: URL, spaces: [Space], currentIndex: Int?, backend: MicroAIBackend? = nil) async throws -> (index: Int?, reason: String) {
        let sameSite = sameSiteSpaces(url: url, spaces: spaces)
        if sameSite.count == 1 {
            return (sameSite[0], "same site as \"\(spaces[sameSite[0]].name)\" (no model call)")
        }
        if let currentIndex, sameSite.contains(currentIndex) {
            return (currentIndex, "same site as the current space (no model call)")
        }
        let out = try await MicroAI.generate(.linkSpace, prompt(url: url, spaces: spaces, currentIndex: currentIndex), schema: schema(spaces: spaces), backend: backend)
        let name = try out.value(String.self, forProperty: "space")
        let reason = try out.value(String.self, forProperty: "reason")
        return (index(named: name, in: spaces), "\(name): \(reason)")
    }
}

// MARK: - Organize tabs into sections

enum TabGroupsTask {
    struct TabInfo {
        var title: String?
        var url: URL
    }

    // Two steps: plan the section names looking at all tabs, then file each
    // tab (in order) under one of them. The small on-device model can't be
    // trusted with tab numbers, so step 2's schema fixes the list length and
    // limits `section` to the planned names.

    @Generable
    struct Plan {
        @Guide(description: "Section names, 1-3 words each, sentence case. Each should fit at least 2 tabs.", .maximumCount(8))
        var sections: [String]
    }

    static func tabList(_ tabs: [TabInfo]) -> String {
        tabs.enumerated().map { "\($0.offset + 1). " + tabLine(title: $0.element.title, url: $0.element.url) }.joined(separator: "\n")
    }

    static func planPrompt(tabs: [TabInfo], existingGroups: [String]) -> MicroAIPrompt {
        let instructions = """
        You organize a user's browser tabs into a few sections. Read all the tabs, find the topics or tasks they're about, and list one section per topic.
        - Name each section after the specific thing its tabs are about (a place, product, project, or task), in 1-3 words, sentence case.
        - Every section needs at least 2 tabs. Merge small related topics into one broader section rather than making a section for a single tab.
        - Several tabs from one site with no other shared topic can be a section named after the site.
        - If a few tabs fit no topic, one broad section can hold them, named for what they are.
        - Never use "Misc", "Other", "Tabs" or "Searches" as a name.
        - Reuse an existing section name when it fits.
        """
        var input = ""
        if !existingGroups.isEmpty {
            input += "Existing sections: " + existingGroups.map { "\"\($0)\"" }.joined(separator: ", ") + "\n\n"
        }
        input += "Tabs:\n" + tabList(tabs)
        return MicroAIPrompt(instructions: instructions, input: input)
    }

    static func assignPrompt(tabs: [TabInfo], sections: [String]) -> MicroAIPrompt {
        let instructions = """
        You file each of a user's browser tabs under one section. Go through the tabs in order; for each, copy a few words of its title and pick the section that fits it best.
        """
        let input = "Sections: " + sections.map { "\"\($0)\"" }.joined(separator: ", ") + "\n\nTabs:\n" + tabList(tabs)
        return MicroAIPrompt(instructions: instructions, input: input)
    }

    static func assignSchema(tabCount: Int, sections: [String]) throws -> GenerationSchema {
        let item = DynamicGenerationSchema(name: "Assignment", properties: [
            .init(name: "tab", description: "First few words of the tab's title", schema: .init(type: String.self)),
            .init(name: "section", schema: .init(name: "SectionName", anyOf: sections)),
        ])
        let root = DynamicGenerationSchema(name: "Assignments", properties: [
            .init(name: "assignments", description: "One entry per tab, in tab order",
                  schema: .init(arrayOf: item, minimumElements: tabCount, maximumElements: tabCount)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Group name per tab (same order as `tabs`); nil where the model skipped one.
    static func run(tabs allTabs: [TabInfo], existingGroups: [String], backend: MicroAIBackend? = nil) async throws -> [String?] {
        // ~40 tokens per tab across both steps; stay inside the on-device window.
        let limit = (backend ?? MicroAI.backend(for: .tabGroups)) == .onDevice ? 50 : 200
        let tabs = Array(allTabs.prefix(limit))
        let groups = try await groupNames(tabs: tabs, existingGroups: existingGroups, backend: backend)
        return groups + [String?](repeating: nil, count: allTabs.count - tabs.count)
    }

    private static func groupNames(tabs: [TabInfo], existingGroups: [String], backend: MicroAIBackend?) async throws -> [String?] {
        let plan = try await MicroAI.generate(.tabGroups, planPrompt(tabs: tabs, existingGroups: existingGroups), as: Plan.self, backend: backend)
        var sections = [String]()
        for s in plan.sections {
            let name = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !sections.contains(name) { sections.append(name) }
        }
        guard !sections.isEmpty else { return tabs.map { _ in nil } }
        let out = try await MicroAI.generate(.tabGroups, assignPrompt(tabs: tabs, sections: sections),
                                             schema: assignSchema(tabCount: tabs.count, sections: sections), backend: backend)
        let assignments: [(echo: String, section: String)] = try out.value([GeneratedContent].self, forProperty: "assignments").compactMap {
            guard let section = try? $0.value(String.self, forProperty: "section"), sections.contains(section) else { return nil }
            return ((try? $0.value(String.self, forProperty: "tab")) ?? "", section)
        }
        return align(assignments, to: tabs).map { $0.map { sentenceCased($0) } }
    }

    /// Matches each assignment to a tab by the title words it echoed (the
    /// model sometimes skips or repeats a row, shifting positions), falling
    /// back to position when the echo matches nothing.
    static func align(_ assignments: [(echo: String, section: String)], to tabs: [TabInfo]) -> [String?] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
        }
        let titleWords = tabs.map { words(tabLine(title: $0.title, url: $0.url)) }
        var result = [String?](repeating: nil, count: tabs.count)
        for (k, a) in assignments.enumerated() {
            let echo = words(a.echo)
            let candidates = tabs.indices.filter { result[$0] == nil }
            let best = candidates.max { i, j in
                let si = titleWords[i].intersection(echo).count, sj = titleWords[j].intersection(echo).count
                return si != sj ? si < sj : abs(i - k) > abs(j - k)
            }
            if let best, !titleWords[best].isDisjoint(with: echo) {
                result[best] = a.section
            } else if result.indices.contains(k), result[k] == nil {
                result[k] = a.section
            }
        }
        return result
    }

    /// Capitalizes the first letter ("wedding venues" → "Wedding venues"). Later
    /// words are left alone since they may be proper nouns.
    static func sentenceCased(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// "Title — host/path" for a tab, trimmed for small context windows.
func tabLine(title: String?, url: URL) -> String {
    var where_ = url.hostWithoutWWW
    let path = url.path
    if path.count > 1 { where_ += path.truncateTailWithEllipsis(chars: 40) }
    guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return where_ }
    return title.truncateTailWithEllipsis(chars: 80) + " — " + where_
}

// MARK: - Auto-title a space

enum SpaceTitleTask {
    @Generable
    struct Output {
        @Guide(description: "1-3 word name for the space, first word capitalized")
        var name: String
    }

    static func prompt(tabs: [TabGroupsTask.TabInfo]) -> MicroAIPrompt {
        let instructions = """
        You name a browser space: a workspace holding a set of tabs. Give it the short name a person would give it themselves: 1-3 words, first word capitalized.
        Name the part of life the tabs are for. Good names: "Work", "Apartment hunt", "Moving", "Japan trip", "Wedding", "Learning Rust", "School", "Home reno".
        If most tabs are about the user's job (code, issues, docs, team chat), the name is "Work".
        If the tabs are mixed, name the dominant theme.
        Never use the words "space", "hub", "tabs", "browsing", "websites", "stuff" or "misc".
        """
        let lines = tabs.prefix(40).map { "- " + tabLine(title: $0.title, url: $0.url) }
        return MicroAIPrompt(instructions: instructions, input: "Tabs in the space:\n" + lines.joined(separator: "\n"))
    }

    static func run(tabs: [TabGroupsTask.TabInfo], backend: MicroAIBackend? = nil) async throws -> String {
        let out = try await MicroAI.generate(.spaceTitle, prompt(tabs: tabs), as: Output.self, backend: backend)
        let name = out.name.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\".")))
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

// MARK: - Space emoji + color

enum SpaceIconTask {
    @Generable
    struct Output {
        @Guide(description: "A single emoji that represents the space's name. Prefer objects, places and symbols over faces.")
        var emoji: String
        @Guide(description: "The color that best fits the name", .anyOf(SpacePalette.allCases.map(\.rawValue)))
        var color: String
    }

    static func prompt(title: String) -> MicroAIPrompt {
        let instructions = """
        You pick a visual identity for a browser workspace ("space") from its name: one emoji and one color.
        Pick the most specific emoji for the name's subject (e.g. "Taxes" → 🧾, "Japan trip" → 🗾, "Garden" → 🌱, "Work" → 💼).
        Pick the color people associate with the subject:
        red: love, sports teams, urgent, Japan
        orange: food, cooking, autumn, energy
        amber: money, taxes, finance, wood
        yellow: sun, kids, ideas, school
        lime: fitness, running, fresh
        green: plants, garden, nature, outdoors
        teal: health, calm, travel
        cyan: water, beach, ocean, sky
        blue: work, tech, code, business
        indigo: study, night, science, reading
        violet: music, art, creative, games
        pink: babies, weddings, romance, beauty
        """
        return MicroAIPrompt(instructions: instructions, input: "Space name: \"\(title)\"")
    }

    static func run(title: String, backend: MicroAIBackend? = nil) async throws -> (emoji: String?, palette: SpacePalette?) {
        let out = try await MicroAI.generate(.spaceIcon, prompt(title: title), as: Output.self, backend: backend)
        let palette = SpacePalette(rawValue: out.color.lowercased().trimmingCharacters(in: .whitespaces))
        // Keep only the first grapheme and make sure it's actually
        // emoji-presenting, not a letter or word.
        let emoji: String? = out.emoji.trimmingCharacters(in: .whitespaces).first.flatMap { char in
            char.unicodeScalars.first?.properties.isEmojiPresentation == true
                || char.unicodeScalars.contains(where: { $0.properties.isEmojiModifierBase || $0.value == 0xFE0F })
                ? String(char) : nil
        }
        return (emoji, palette)
    }
}

// MARK: - Archive: tidy title + category

enum ArchiveTidyTask {
    @Generable
    struct Output {
        @Guide(description: "Short tidy version of the page title, 1-5 words")
        var tidyTitle: String
        @Guide(.anyOf(ArchiveItem.Category.allCases.map(\.rawValue)))
        var category: String
    }

    static func prompt(title: String?, url: URL) -> MicroAIPrompt {
        let instructions = """
        You are an archivist tidying a user's saved browser tabs. For a tab, write a short "tidy" title and pick a category.
        Tidy title: 1-5 words, cruft removed. Remove the site-name suffix unless it's the whole title. Remove notification counters like "(1)" but keep emoji. Remove SEO filler.
        Examples:
        "The New York Times: Breaking News, Sports, Stocks and More" → "New York Times"
        "PERKINS Space heater for small medium size apartment, radiator – Amazon" → "PERKINS Space heater"
        "The One That Got Away: a Fishing Odyssey" → "The One That Got Away: a Fishing Odyssey"
        "(1) 🏡 House Hunting - Notion" → "🏡 House Hunting"
        Category: the most specific fit from: \(ArchiveItem.Category.allCases.map(\.rawValue).joined(separator: ", ")).
        """
        let input = "Title: \(title?.truncateTailWithEllipsis(chars: 300) ?? "")\nURL: \(url.absoluteString.truncateTailWithEllipsis(chars: 300))"
        return MicroAIPrompt(instructions: instructions, input: input)
    }

    static func run(title: String?, url: URL, backend: MicroAIBackend? = nil) async throws -> (tidyTitle: String, category: ArchiveItem.Category?) {
        let out = try await MicroAI.generate(.archiveTidy, prompt(title: title, url: url), as: Output.self, backend: backend)
        return (out.tidyTitle, ArchiveItem.Category(rawValue: out.category))
    }
}
