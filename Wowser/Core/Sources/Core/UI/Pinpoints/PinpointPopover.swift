#if os(macOS)
import SwiftUI
import AppKit

// The pinpoint toolbar button and its popover: a to-do list of changes for an
// agent to make to this page. See Data/Pinpoints.swift.

struct PinpointToolbarButton: View {
    var paneID: ID<WebContent>
    var windowID: ID<WindowState>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            PinpointButtonSnapshot(
                openCount: state.pinpoints(paneID: paneID).openItems.count,
                popoverShown: state.isPinpointPopoverShown(windowID: windowID, paneID: paneID)
            )
        } main: { snapshot in
            Button(action: { BrowserStore.shared.modify { $0.setPinpointPopover(windowID: windowID, paneID: paneID) } }) {
                Image(systemName: "checklist")
                    .imageScale(.medium)
                    .overlay(alignment: .topTrailing) {
                        if snapshot.openCount > 0 {
                            PinpointCountBadge(count: snapshot.openCount)
                        }
                    }
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Pinpoint: notes for Claude about this page")
            .popover(
                isPresented: Binding(get: { snapshot.popoverShown }, set: { if !$0 { dismiss() } }),
                arrowEdge: .bottom
            ) {
                PinpointPopover(paneID: paneID, windowID: windowID)
            }
        }
    }

    private func dismiss() {
        BrowserStore.shared.modify { state in
            // The popover hides itself while drawing; that isn't a dismissal.
            guard let win = state.windows[windowID], win.pinpointDrawing == nil, win.pinpointPopoverPaneID == paneID else { return }
            state.commitPinpointDraft(paneID: paneID)
            state.setPinpointPopover(windowID: windowID, paneID: nil)
        }
    }
}

private struct PinpointButtonSnapshot: Equatable {
    var openCount: Int
    var popoverShown: Bool
}

private struct PinpointCountBadge: View {
    var count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 11, minHeight: 11)
            .background(Capsule().fill(Color.accentColor))
            .offset(x: 7, y: -6)
    }
}

// MARK: - Popover

private struct PinpointPopover: View {
    var paneID: ID<WebContent>
    var windowID: ID<WindowState>

    var body: some View {
        WithSnapshotMain(store: BrowserStore.shared) { state in
            state.pinpoints(paneID: paneID)
        } main: { list in
            PinpointPopoverContent(list: list, paneID: paneID, windowID: windowID)
        }
    }
}

private struct PinpointPopoverContent: View {
    var list: PinpointList
    var paneID: ID<WebContent>
    var windowID: ID<WindowState>

    @State private var draftFocusDate: Date?
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("List edits to make")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 2)
            // One copy of the rows (ViewThatFits builds both branches, and the
            // growing text fields re-trigger its sizing pass forever). Content
            // height inside a ScrollView doesn't depend on the ScrollView's.
            ScrollView {
                rows.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowsHeight = $0 }
            }
            .frame(height: min(max(rowsHeight, 1), 440))

            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { draftFocusDate = Date() }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            row(list.draft, isDraft: true)
            ForEach(list.items) { item in
                Divider().padding(.leading, 36)
                row(item, isDraft: false)
            }
        }
        .padding(.vertical, 6)
    }

    private func row(_ item: Pinpoint, isDraft: Bool) -> some View {
        PinpointRow(
            item: item,
            isDraft: isDraft,
            focusDate: isDraft ? draftFocusDate : nil,
            paneID: paneID,
            windowID: windowID,
            focusDraft: { draftFocusDate = Date() }
        )
    }

    private var footer: some View {
        HStack {
            Text(list.openItems.isEmpty ? "Press Return to add a note" : "\(list.openItems.count) to do")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { PinpointActions.sendToClaude(paneID: paneID, windowID: windowID) }) {
                Label("Send all to Claude", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent)
            .disabled(list.openItems.isEmpty && list.draft.isEmpty)
        }
        .padding(10)
    }
}

/// One note: a borderless, growing text field (Reminders-style), its drawing,
/// and a pen to draw one. The draft row at the top looks the same.
private struct PinpointRow: View {
    var item: Pinpoint
    var isDraft: Bool
    var focusDate: Date?
    var paneID: ID<WebContent>
    var windowID: ID<WindowState>
    var focusDraft: () -> Void

    @State private var contentSize: CGSize = .zero
    /// The field edits this, not the store directly: `item` lags the store by
    /// a frame, and a binding reading it would write stale text back into the
    /// field on any re-render in between.
    @State private var text: String

    init(item: Pinpoint, isDraft: Bool, focusDate: Date?, paneID: ID<WebContent>, windowID: ID<WindowState>, focusDraft: @escaping () -> Void) {
        self.item = item
        self.isDraft = isDraft
        self.focusDate = focusDate
        self.paneID = paneID
        self.windowID = windowID
        self.focusDraft = focusDraft
        _text = State(initialValue: item.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            checkbox
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                InputTextField(
                    text: $text,
                    options: InputTextFieldOptions(
                        placeholder: isDraft ? "What should change here?" : "",
                        font: .systemFont(ofSize: 13),
                        insets: CGSize(width: 0, height: 2),
                        wantsUpDownArrowEvents: false,
                        disableFindReplace: true
                    ),
                    focusDate: focusDate,
                    onEvent: handle,
                    contentSize: $contentSize
                )
                .frame(height: max(20, contentSize.height))
                .opacity(item.isResolved ? 0.5 : 1)

                if let resolution = item.resolution {
                    Text(resolution)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let path = item.imagePath {
                    PinpointThumbnail(path: path, onRemove: removeImage)
                }
            }
            Button(action: draw) {
                Image(systemName: "photo.badge.plus")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a drawing")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onChange(of: item.text) { _, stored in
            if stored != text { text = stored }
        }
        .onChange(of: text) { _, edited in
            guard edited != item.text else { return }
            BrowserStore.shared.modify { $0.updatePinpoint(paneID: paneID, itemID: item.id) { $0.text = edited } }
        }
    }

    @ViewBuilder private var checkbox: some View {
        if isDraft {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 18)
        } else {
            Button(action: toggleResolved) {
                Image(systemName: item.isResolved ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isResolved ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: 18)
            }
            .buttonStyle(.plain)
        }
    }

    private func handle(_ event: TextFieldEvent) {
        switch event {
        case .key(.enter):
            if isDraft {
                BrowserStore.shared.modify { $0.commitPinpointDraft(paneID: paneID) }
            } else {
                focusDraft()
            }
        case .key(.escape):
            BrowserStore.shared.modify { state in
                state.commitPinpointDraft(paneID: paneID)
                state.setPinpointPopover(windowID: windowID, paneID: nil)
            }
        case .backspaceOnEmptyField where !isDraft && item.imagePath == nil:
            remove()
            focusDraft()
        case .blur where !isDraft && item.isEmpty:
            remove()
        default:
            break
        }
    }

    private func draw() {
        BrowserStore.shared.modify { $0.startPinpointDrawing(windowID: windowID, paneID: paneID, itemID: item.id) }
    }

    private func toggleResolved() {
        BrowserStore.shared.modify { $0.setPinpointResolved(paneID: paneID, itemID: item.id, !item.isResolved) }
    }

    private func remove() {
        var imagePath: String?
        BrowserStore.shared.modify { imagePath = $0.removePinpoint(paneID: paneID, itemID: item.id) }
        PinpointImages.remove(path: imagePath)
    }

    private func removeImage() {
        let path = item.imagePath
        BrowserStore.shared.modify { $0.updatePinpoint(paneID: paneID, itemID: item.id) { $0.imagePath = nil } }
        PinpointImages.remove(path: path)
    }
}

private struct PinpointThumbnail: View {
    var path: String
    var onRemove: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.primary.opacity(0.05).frame(width: 120, height: 75)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .overlay(alignment: .topLeading) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Remove drawing")
            }
        }
        .frame(maxHeight: 80, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        .help("Click to open")
        .task(id: path) {
            let data = await Task.detached { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

// MARK: - Send to Claude

@MainActor
enum PinpointActions {
    /// Opens an agent chat in a split beside the page (in the space's folder,
    /// asking for one if needed) with the open notes and their drawings.
    static func sendToClaude(paneID: ID<WebContent>, windowID: ID<WindowState>) {
        BrowserStore.shared.modify { state in
            state.commitPinpointDraft(paneID: paneID)
            state.setPinpointPopover(windowID: windowID, paneID: nil)
        }
        let state = BrowserStore.shared.model
        guard !state.pinpointsToSend(paneID: paneID).isEmpty else { return }
        if let url = state.pane(forId: paneID)?.info.url, url.scheme == TangSchemeHandler.scheme, let slug = url.host, !slug.isEmpty {
            // Built-in apps have no folder until overridden; work from the Apps folder.
            let appFolder = TangAppStore.shared.dir.appendingPathComponent(slug, isDirectory: true).path
            let folder = FileManager.default.fileExists(atPath: appFolder) ? appFolder : TangAppStore.shared.dir.path
            openChat(paneID: paneID, folder: folder, tangApp: true, windowID: windowID)
        } else if let folder = state.spaceFolderPath(windowID: windowID) ?? state.mostRecentNativeFolderPath(windowID: windowID) {
            openChat(paneID: paneID, folder: folder, tangApp: false, windowID: windowID)
        } else {
            FolderPicker.pick(prompt: "Choose", message: "Choose the project folder Claude should work in") { folder in
                openChat(paneID: paneID, folder: folder, tangApp: false, windowID: windowID)
            }
        }
    }

    /// The agent works in `folder`: the Tang app's own folder, or else the
    /// space's (which `folder` becomes, if the space has none yet).
    private static func openChat(paneID: ID<WebContent>, folder: String, tangApp: Bool, windowID: ID<WindowState>) {
        var notes: [Pinpoint] = []
        var prompt = ""
        BrowserStore.shared.modify { state in
            if !tangApp, let profileID = state.windows[windowID]?.profile {
                state.setFolderIfMissing(path: folder, forProfile: profileID)
            }
            notes = state.pinpointsToSend(paneID: paneID)
            prompt = state.pinpointsPrompt(paneID: paneID, notes: notes, tangAppFolder: tangApp ? TangAppStore.shared.dir.path : nil)
        }
        AgentChatTabs.askInSplit(
            query: prompt,
            windowID: windowID,
            attachments: notes.compactMap { $0.imagePath.map(URL.init(fileURLWithPath:)) },
            fileSystemTools: true,
            workingDirectory: folder
        )
    }
}
#endif
