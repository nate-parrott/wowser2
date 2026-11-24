import SwiftUI

/// Point-and-comment: while `engine.inspecting` is on, hovering outlines the
/// element under the pointer and names where it comes from in the branch's
/// source; clicking it opens a note field. Notes go to an agent right away or
/// wait in `ShellFeedbackStore` for one to collect (`shell` → "feedback").
struct ShellInspectorOverlay: View {
    let engine: ShellEngine
    @State private var hovered: ShellNode?
    @State private var picked: ShellNode?
    @State private var info: ShellJSON?
    @State private var comment = ""

    var body: some View {
        if engine.inspecting {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard picked == nil else { return }
                        switch phase {
                        case .active(let point): target(engine.tree.hitTest(rootKey: ShellEngine.rootKey, point: point))
                        case .ended: target(nil)
                        }
                    }
                    .onTapGesture { point in
                        if picked != nil {
                            picked = nil
                        } else if let node = engine.tree.hitTest(rootKey: ShellEngine.rootKey, point: point) {
                            target(node)
                            picked = node
                        }
                    }
                if let node = picked ?? hovered, let frame = node.frame {
                    outline(frame)
                    label(for: node, frame: frame)
                }
                if let node = picked, let frame = node.frame {
                    noteCard(node: node, frame: frame)
                }
                hint
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func target(_ node: ShellNode?) {
        guard node?.id != hovered?.id else { return }
        hovered = node
        info = node.flatMap { engine.describeNode($0.id) }
    }

    private func outline(_ frame: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.12))
            .frame(width: max(frame.width, 2), height: max(frame.height, 2))
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }

    private var title: String {
        guard let info else { return "" }
        var out = "<\(info["type"]?.string ?? "?")>"
        if let file = info["file"]?.string { out += "  \(file):\(info["line"]?.int ?? 0)" }
        let owners = (info["owners"]?.array ?? []).compactMap { $0["component"]?.string }.prefix(3)
        if !owners.isEmpty { out += "  ·  " + owners.joined(separator: " ‹ ") }
        return out
    }

    private func label(for node: ShellNode, frame: CGRect) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .offset(x: max(4, frame.minX), y: frame.minY > 24 ? frame.minY - 22 : frame.maxY + 4)
            .allowsHitTesting(false)
    }

    private func noteCard(node: ShellNode, frame: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What should change here?", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { send(node: node, toAgent: true) }
            HStack {
                Button("Ask Agent") { send(node: node, toAgent: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Save Note") { send(node: node, toAgent: false) }
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("Cancel") { picked = nil }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .offset(x: max(8, frame.minX), y: frame.maxY + 28)
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.point.up.left.fill")
            Text("Click part of the browser to leave a note about it")
            Button("Done") {
                engine.inspecting = false
                picked = nil
                hovered = nil
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 16)
    }

    private func send(node: ShellNode, toAgent: Bool) {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let note = ShellFeedbackStore.Note(branch: engine.branch, comment: text, node: info ?? ["type": .string(node.type)], frame: node.frame)
        comment = ""
        picked = nil
        if toAgent {
            let dir = ShellBranchStore.shared.directory(for: engine.branch).path
            let stock = engine.branch == ShellBranchStore.stockName
            AgentChatTabs.ask(query: """
            \(note.text)

            The branch's files are in \(dir). \(stock ? "It is the read-only built-in UI: create a branch from it first (shell \"create\") and edit that. " : "")\
            Read the guide (shell \"docs\") if you haven't, make the change with shell \"write\", check it, and show me a preview.
            """, windowID: engine.windowID)
        } else {
            ShellFeedbackStore.shared.add(note)
            BrowserStore.shared.modify { $0.addToast(message: "Note saved for your agent", icon: "text.bubble", in: engine.windowID) }
        }
    }
}
