import Foundation

// MARK: - Pinpoints
//
// A per-tab to-do list of changes the user wants an agent to make to the page
// they're looking at (dev mode only). Each note can carry a screenshot of the
// page with the user's pen marks on it. The list lives on the `Pane`; images
// live on disk (`PinpointImages`) and the note stores the path.
//
// UI: the toolbar's pinpoint button opens a popover (PinpointPopover.swift);
// its pen hides the popover and puts a drawing canvas over the page
// (PinpointDrawingOverlay.swift). "Send all to Claude" opens an agent chat
// split (with file tools, in the space's folder) and the agent checks notes
// off via `browser.pinpoints.resolve`.

public struct Pinpoint: Equatable, Codable, Identifiable {
    public var id: String = UUID().uuidString.lowercased()
    public var text: String = ""
    /// PNG of the page with the user's drawing on it (see `PinpointImages`).
    public var imagePath: String?
    public var createdAt = Date()
    public var resolvedAt: Date?
    /// What the agent says it did, set when it resolves the note.
    public var resolution: String?

    public init() {}

    public var isResolved: Bool { resolvedAt != nil }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imagePath == nil }
}

public struct PinpointList: Equatable, Codable {
    /// Committed notes, newest first.
    public var items: [Pinpoint] = []
    /// The always-present row at the top of the popover that the user types into.
    /// Its id and date are fixed so an empty list always compares equal to
    /// another (snapshots of it would otherwise never stop changing).
    public var draft = PinpointList.emptyDraft

    static var emptyDraft: Pinpoint {
        var draft = Pinpoint()
        draft.id = "draft"
        draft.createdAt = .distantPast
        return draft
    }

    public init() {}

    public var openItems: [Pinpoint] { items.filter { !$0.isResolved } }
}

/// The note the drawing canvas will attach its image to.
public struct PinpointDrawTarget: Equatable, Codable {
    public var paneID: ID<WebContent>
    public var itemID: String
}

public extension BrowserState {
    func pinpoints(paneID: ID<WebContent>) -> PinpointList {
        pane(forId: paneID)?.pinpoints ?? PinpointList()
    }

    mutating func modifyPinpoints(paneID: ID<WebContent>, _ block: (inout PinpointList) -> Void) {
        modifyPaneAndTab(forWebContentId: paneID) { pane, _ in
            var list = pane.pinpoints ?? PinpointList()
            block(&list)
            pane.pinpoints = list.items.isEmpty && list.draft.isEmpty ? nil : list
        }
    }

    /// Edits a committed note or the draft (whichever has `itemID`).
    mutating func updatePinpoint(paneID: ID<WebContent>, itemID: String, _ block: (inout Pinpoint) -> Void) {
        modifyPinpoints(paneID: paneID) { list in
            if list.draft.id == itemID {
                block(&list.draft)
            } else if let idx = list.items.firstIndex(where: { $0.id == itemID }) {
                block(&list.items[idx])
            }
        }
    }

    /// Moves a non-empty draft into the list and starts a fresh one.
    mutating func commitPinpointDraft(paneID: ID<WebContent>) {
        modifyPinpoints(paneID: paneID) { list in
            guard !list.draft.isEmpty else { return }
            var item = list.draft
            item.id = UUID().uuidString.lowercased()
            item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            item.createdAt = Date()
            list.items.insert(item, at: 0)
            list.draft = PinpointList.emptyDraft
        }
    }

    /// Returns the removed note's image path so the caller can delete the file.
    @discardableResult
    mutating func removePinpoint(paneID: ID<WebContent>, itemID: String) -> String? {
        var imagePath: String?
        modifyPinpoints(paneID: paneID) { list in
            if let idx = list.items.firstIndex(where: { $0.id == itemID }) {
                imagePath = list.items.remove(at: idx).imagePath
            }
        }
        return imagePath
    }

    mutating func setPinpointResolved(paneID: ID<WebContent>, itemID: String, _ resolved: Bool, resolution: String? = nil) {
        updatePinpoint(paneID: paneID, itemID: itemID) { item in
            item.resolvedAt = resolved ? Date() : nil
            item.resolution = resolved ? resolution?.nilIfEmpty : nil
        }
    }

    // MARK: Popover + drawing

    func isPinpointPopoverShown(windowID: ID<WindowState>, paneID: ID<WebContent>) -> Bool {
        guard let win = windows[windowID] else { return false }
        return win.pinpointPopoverPaneID == paneID && win.pinpointDrawing == nil
    }

    mutating func setPinpointPopover(windowID: ID<WindowState>, paneID: ID<WebContent>?) {
        windows[windowID]?.pinpointPopoverPaneID = paneID
        if paneID == nil { windows[windowID]?.pinpointDrawing = nil }
    }

    /// Hides the popover and shows the drawing canvas over `paneID`.
    mutating func startPinpointDrawing(windowID: ID<WindowState>, paneID: ID<WebContent>, itemID: String) {
        windows[windowID]?.pinpointPopoverPaneID = paneID
        windows[windowID]?.pinpointDrawing = PinpointDrawTarget(paneID: paneID, itemID: itemID)
    }

    /// Ends drawing (attaching `imagePath`, if any) and brings the popover back.
    mutating func finishPinpointDrawing(windowID: ID<WindowState>, imagePath: String?) {
        guard let target = windows[windowID]?.pinpointDrawing else { return }
        windows[windowID]?.pinpointDrawing = nil
        if let imagePath {
            updatePinpoint(paneID: target.paneID, itemID: target.itemID) { $0.imagePath = imagePath }
        }
    }

    // MARK: Agent prompt

    /// The open notes, oldest first — what "Send all" hands the agent.
    func pinpointsToSend(paneID: ID<WebContent>) -> [Pinpoint] {
        pinpoints(paneID: paneID).openItems.reversed()
    }

    /// The first message of the chat that "Send all" opens. Drawings of
    /// `notes` are attached to it as images, in order.
    func pinpointsPrompt(paneID: ID<WebContent>, notes: [Pinpoint], tangAppFolder: String?) -> String {
        let url = pane(forId: paneID)?.info.url?.absoluteString ?? "the page beside this chat"
        var drawingIdx = 0
        let list = notes.enumerated().map { idx, item in
            var line = "\(idx + 1). \(item.text.isEmpty ? "(see drawing)" : item.text)"
            if item.imagePath != nil {
                drawingIdx += 1
                line += " — drawing \(drawingIdx)"
            }
            return line + " [id: \(item.id)]"
        }.joined(separator: "\n")
        return """
        Please make these changes to the app at \(url):

        \(list)

        \(drawingIdx > 0 ? "The attached drawings are screenshots of the page with my red pen marks showing what I mean. " : "")\
        \(tangAppFolder.map { "This is a Tang app (`tang://<slug>/` is served from `<slug>/` in `\($0)`). If its folder doesn't exist it's a built-in app: override it by writing a full copy with `browser.webapp.create`. " } ?? "")\
        Make the changes in the code in your working directory, check your work with a screenshot of the page (reload it first), \
        then check each note off: `await browser.pinpoints.resolve("\(paneID.raw)", "<id>", "one line on what you changed")`.
        """
    }
}

/// Where pinpoint drawings are saved.
public enum PinpointImages {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WowserDataStores-\(isProd() ? "prod" : "dev")")
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Unknown")
            .appendingPathComponent("Pinpoints")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the PNG and returns its path.
    static func save(png: Data) throws -> String {
        let url = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".png")
        try png.write(to: url)
        return url.path
    }

    static func remove(path: String?) {
        guard let path else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
