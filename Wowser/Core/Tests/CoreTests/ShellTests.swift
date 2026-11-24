import XCTest
@testable import Core

// The scripted UI (Core/Shell). The JS runtime itself is tested with bun in
// scripts/shell; these cover the Swift half: the branch store, the node tree,
// and one end-to-end pass through a real JavaScriptCore context.

#if os(macOS)
final class ShellBranchStoreTests: XCTestCase {
    private func tempStore() -> ShellBranchStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ShellBranchStore(root: root, bundledSeeds: ShellKit.bundledBranches)
        store.seedIfNeeded()
        return store
    }

    func testSeedsStockAndOverlaySeed() {
        let store = tempStore()
        XCTAssertEqual(store.list().map(\.name), ["stock", "chrome"])
        XCTAssertTrue(store.files(in: "chrome").contains("kit/TabStrip.xml"), "the chrome seed is stock plus an overlay")
        XCTAssertEqual(store.read(branch: "chrome", path: "mac/index.xml")?.contains("Chrome"), true)
        XCTAssertNil(store.manifest("chrome").seedBase)
        XCTAssertEqual(store.entry(branch: "stock", platform: "mac"), "mac/index.xml")
    }

    func testStockIsReadOnly() {
        let store = tempStore()
        XCTAssertThrowsError(try store.write(branch: "stock", files: ["a.ts": "x"], checkpointLabel: nil)) { error in
            XCTAssertEqual(error as? ShellBranchStore.StoreError, .readOnly("stock"))
        }
    }

    func testWriteUndoRedo() throws {
        let store = tempStore()
        try store.create(name: "mine", from: "stock", title: "Mine")
        let original = try XCTUnwrap(store.read(branch: "mine", path: "mac/index.xml"))
        try store.write(branch: "mine", files: ["mac/index.xml": "// v2", "widgets/new.tsx": "export default 1"], checkpointLabel: "Change entry")
        try store.write(branch: "mine", files: ["mac/index.xml": "// v3", "widgets/new.tsx": nil], checkpointLabel: "Third")
        XCTAssertEqual(store.read(branch: "mine", path: "mac/index.xml"), "// v3")
        XCTAssertFalse(store.fileExists(branch: "mine", path: "widgets/new.tsx"))

        XCTAssertEqual(try store.undo(branch: "mine"), "Third")
        XCTAssertEqual(store.read(branch: "mine", path: "mac/index.xml"), "// v2")
        XCTAssertTrue(store.fileExists(branch: "mine", path: "widgets/new.tsx"), "undo restores deleted files")
        _ = try store.undo(branch: "mine")
        XCTAssertEqual(store.read(branch: "mine", path: "mac/index.xml"), original)
        XCTAssertThrowsError(try store.undo(branch: "mine"))

        _ = try store.redo(branch: "mine")
        _ = try store.redo(branch: "mine")
        XCTAssertEqual(store.read(branch: "mine", path: "mac/index.xml"), "// v3")

        // A new change drops the redo stack.
        _ = try store.undo(branch: "mine")
        try store.write(branch: "mine", files: ["mac/index.xml": "// v4"], checkpointLabel: "Fourth")
        XCTAssertFalse(store.info(for: "mine").canRedo)
    }

    func testRestoreLastGoodIsUndoable() throws {
        let store = tempStore()
        try store.create(name: "mine")
        try store.write(branch: "mine", files: ["mac/index.xml": "// good"], checkpointLabel: "good")
        store.markGood(branch: "mine")
        try store.write(branch: "mine", files: ["mac/index.xml": "broken("], checkpointLabel: "break")
        try store.restoreGood(branch: "mine")
        XCTAssertEqual(store.read(branch: "mine", path: "mac/index.xml"), "// good")
        _ = try store.undo(branch: "mine")
        XCTAssertEqual(store.read(branch: "mine", path: "mac/index.xml"), "broken(")
    }

    func testRejectsUnsafePathsAndNames() throws {
        let store = tempStore()
        try store.create(name: "mine")
        for bad in ["../x", "a/../../x", ".git/config", "a/.hidden", ""] {
            XCTAssertThrowsError(try store.write(branch: "mine", files: [bad: "x"], checkpointLabel: nil), bad)
        }
        XCTAssertEqual(ShellBranchStore.safeRelativePath("/kit//TabRow.tsx"), "kit/TabRow.tsx")
        XCTAssertThrowsError(try store.create(name: "bad name!"))
        XCTAssertThrowsError(try store.create(name: "mine"), "duplicate")
    }

    func testStorageRoundTripAndFork() throws {
        let store = tempStore()
        try store.create(name: "mine")
        store.setStorageValue(branch: "mine", key: "layout", value: "chrome")
        XCTAssertEqual(store.storageValue(branch: "mine", key: "layout"), "chrome")
        try store.create(name: "fork", from: "mine")
        XCTAssertEqual(store.storageValue(branch: "fork", key: "layout"), "chrome")
    }
}

final class ShellTreeTests: XCTestCase {
    func testOpsAndStyleVariants() throws {
        let tree = ShellTree()
        let ops = try XCTUnwrap(ShellJSON.parse(##"""
        [["create",1,"root",{"rootKey":"main"}],
         ["create",2,"row",{"style":{"gap":4,"padding":[2,6],"background":"accent/0.5","hover":{"background":{"material":"glass","tint":"#ff000080"}}},"onPress":true}],
         ["create",3,"text",{"text":"hi"}],
         ["children",2,[3]],["children",1,[2]]]
        """##)?.array)
        try tree.apply(ops)
        let row = try XCTUnwrap(tree.roots["main"]?.children.first)
        XCTAssertTrue(row.handles("onPress"))
        XCTAssertFalse(row.handles("onHover"))
        XCTAssertEqual(row.style().gap, 4)
        XCTAssertEqual(row.style().background, .color("accent/0.5"))
        XCTAssertEqual(row.style([.hover]).background, .material(name: "glass", tint: "#ff000080", interactive: false))
        XCTAssertEqual(row.declaredStates, [.hover])

        try tree.apply(try XCTUnwrap(ShellJSON.parse(#"[["update",2,{"onPress":null,"style":{"gap":9}}],["remove",3],["children",2,[]]]"#)?.array))
        XCTAssertFalse(row.handles("onPress"))
        XCTAssertEqual(row.style().gap, 9)
        XCTAssertNil(row.style([.hover]).background)
        XCTAssertNil(tree.node(3))
    }

    func testColourTokens() {
        let token = ShellColorToken("#1e2228/0.5")
        XCTAssertEqual(token.alpha, 0.5)
        XCTAssertEqual(token.base, .rgba(30.0 / 255, 34.0 / 255, 40.0 / 255, 1))
        XCTAssertEqual(ShellColorToken("accent").base, .named("accent"))
        XCTAssertEqual(ShellColorToken.hex(1, 0, 0.5), "#ff0080")
    }

    /// The rules `ShellSizeLayout` applies on each axis.
    func testBoxSizing() {
        func size(_ proposed: CGFloat?, content: CGFloat, fixed: CGFloat? = nil, lo: CGFloat? = nil, hi: CGFloat? = nil, fill: Bool = false) -> CGFloat {
            let offered = ShellSizing.childProposal(proposed, fixed: fixed, lo: lo, hi: hi, fill: fill)
            let child = min(content, offered ?? content) // content that hugs
            return ShellSizing.boxSize(proposed, child: child, fixed: fixed, lo: lo, hi: hi, fill: fill)
        }
        XCTAssertEqual(size(300, content: 100), 100, "hug")
        XCTAssertEqual(size(60, content: 100), 60, "hug shrinks when offered less")
        XCTAssertEqual(size(300, content: 100, hi: 80), 80, "max is a cap")
        XCTAssertEqual(size(300, content: 50, hi: 80), 50, "a box under its cap does not grow to it")
        XCTAssertEqual(size(300, content: 10, lo: 44), 44, "min")
        XCTAssertEqual(size(nil, content: 100, fixed: 30), 30, "fixed")
        XCTAssertEqual(size(500, content: 100, hi: 220, fill: true), 220, "flex grows to its cap")
        XCTAssertEqual(size(120, content: 100, hi: 220, fill: true), 120, "flex takes what is offered")
        XCTAssertEqual(size(0, content: 100, lo: 44, fill: true), 44, "flex floor")
        XCTAssertEqual(size(nil, content: 100, fill: true), 100, "flex ideal size is the content's")
    }

    func testJSONKeepsBooleansAndNumbersApart() {
        XCTAssertEqual(ShellJSON.parse("[true, 1, 0, false]"), [.bool(true), .number(1), .number(0), .bool(false)])
    }
}

/// End to end: real branch files → transpiler → JS runtime → native tree,
/// and events / actions back the other way.
final class ShellEngineTests: XCTestCase {
    private var store: ShellBranchStore!
    private var windowID: ID<WindowState>!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-engine-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        store = ShellBranchStore(root: root, bundledSeeds: ShellKit.bundledBranches)
        store.seedIfNeeded()
        var id = ID<WindowState>.assign()
        BrowserStore.shared.modify { id = $0.newWindow().id }
        windowID = id
    }

    override func tearDown() {
        let id = windowID!
        BrowserStore.shared.modify { $0.windows.removeValue(forKey: id) }
        super.tearDown()
    }

    private func makeEngine(entry source: String) throws -> ShellEngine {
        try makeEngine(files: ["t/index.tsx": source], entry: "t/index.tsx")
    }

    /// A fork of stock with `files` added and `entry` as its Mac entry.
    private func makeEngine(files: [String: String], entry: String) throws -> ShellEngine {
        let name = "t" + UUID().uuidString.prefix(6).lowercased()
        try store.create(name: name)
        var all: [String: String?] = [:]
        for (path, source) in files { all[path] = source }
        all["manifest.json"] = #"{ "name": "Test", "entry": { "mac": "\#(entry)", "ios": "\#(entry)" } }"#
        try store.write(branch: name, files: all, checkpointLabel: nil)
        let engine = ShellEngine(branch: name, windowID: windowID, platform: "mac", store: store)
        addTeardownBlock { engine.stop() }
        engine.start()
        return engine
    }

    private func find(_ node: ShellNode, _ match: (ShellNode) -> Bool) -> ShellNode? {
        if match(node) { return node }
        for child in node.children {
            if let hit = find(child, match) { return hit }
        }
        return nil
    }

    private func text(_ node: ShellNode) -> String {
        var parts: [String] = []
        if node.type == "text", let t = node.string("text") { parts.append(t) }
        parts.append(contentsOf: node.children.map(text).filter { !$0.isEmpty })
        return parts.joined(separator: " ")
    }

    func testMountsUpdatesOnEventAndMapsNodesToSource() throws {
        let engine = try makeEngine(entry: """
        import { Row, Text, useState } from "wowser";
        export default function App() {
          const [n, setN] = useState(0);
          return <Row testID="btn" onPress={() => setN(n + 1)}><Text>Count {n}</Text></Row>;
        }
        """)
        XCTAssertNil(engine.failure, engine.failure?.summary ?? "")
        let root = try XCTUnwrap(engine.tree.roots[ShellEngine.rootKey])
        let button = try XCTUnwrap(find(root) { $0.string("testID") == "btn" })
        XCTAssertEqual(text(root), "Count 0")
        XCTAssertTrue(button.handles("onPress"))

        engine.dispatch(button.id, "onPress", ["modifiers": [:], "x": 0, "y": 0])
        XCTAssertEqual(text(root), "Count 1", "state set in a handler is rendered before dispatch returns")

        let info = try XCTUnwrap(engine.describeNode(button.id))
        XCTAssertEqual(info["type"]?.string, "row")
        XCTAssertEqual(info["file"]?.string, "t/index.tsx")
        XCTAssertEqual(info["line"]?.int, 4)
    }

    func testSyntaxErrorIsAFailureWithTheFileName() throws {
        let engine = try makeEngine(entry: "export default function App() { return <Row>; }")
        let failure = try XCTUnwrap(engine.failure)
        XCTAssertTrue(failure.fatal)
        XCTAssertTrue(failure.message.contains("t/index.tsx"), failure.message)
    }

    func testRootRenderErrorRendersTheErrorScreenNode() throws {
        let engine = try makeEngine(entry: "export default function App() { return missingThing.x; }")
        let root = try XCTUnwrap(engine.tree.roots[ShellEngine.rootKey])
        let screen = try XCTUnwrap(find(root) { $0.type == "native" && $0.string("name") == "ErrorScreen" })
        XCTAssertEqual(screen.string("message")?.contains("missingThing"), true)
    }

    func testSlicesReflectBrowserStateAndActionsChangeIt() throws {
        let engine = try makeEngine(entry: """
        import { Column, Text, useTabs, useWindow } from "wowser";
        export default function App() {
          const strip = useTabs();
          const sidebar = useWindow((w) => w.sidebarVisible);
          return <Column><Text testID="count">{strip.tabs.length} tabs</Text><Text testID="sidebar">{sidebar ? "shown" : "hidden"}</Text></Column>;
        }
        """)
        XCTAssertNil(engine.failure, engine.failure?.summary ?? "")
        let root = try XCTUnwrap(engine.tree.roots[ShellEngine.rootKey])
        func label(_ id: String) -> String? { find(root) { $0.string("testID") == id }?.string("text") }
        // Other tests may have left tabs in the shared store; count from here.
        let before = Int(label("count")?.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(before, 0)

        // JS → native action, then the changed slice comes straight back.
        let reply = engine.evaluate(#"__shell.require("wowser").tabs.create({ url: "https://example.com/", activate: true })"#)
        XCTAssertEqual(ShellJSON.parse(reply)?["ok"]?.bool, true, reply)
        XCTAssertEqual(BrowserStore.shared.model.windows[windowID]?.tabs.count, 1)
        engine.publishSlices()
        XCTAssertEqual(label("count"), "\(before + 1) tabs")

        XCTAssertEqual(label("sidebar"), "shown")
        _ = engine.evaluate(#"__shell.require("wowser").window.setSidebarVisible(false)"#)
        engine.publishSlices()
        XCTAssertEqual(label("sidebar"), "hidden")
    }

    func testSynchronousSuggestions() throws {
        let engine = try makeEngine(entry: "export default function App() { return null; }")
        let reply = engine.evaluate(#"JSON.stringify(__shell.require("wowser").search.suggest("example.com").map(s => s.kind))"#)
        let kinds = ShellJSON.parse(ShellJSON.parse(reply)?["value"]?.string ?? "")?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(kinds.first, "url", reply)
    }

    func testEveryStockLayoutMounts() throws {
        for layout in ["Classic", "ClassicKit", "Chrome", "MobileKit", "Playground"] {
            let engine = try makeEngine(entry: #"export { default } from "../layouts/\#(layout)";"#)
            XCTAssertNil(engine.failure, "\(layout): \(engine.failure?.summary ?? "")")
            XCTAssertGreaterThan(engine.tree.nodeCount, 3, layout)
            XCTAssertTrue(engine.errors.isEmpty, "\(layout): \(engine.errors.map(\.summary).joined(separator: "\n"))")
        }
    }

    func testNavigateListenerVerdicts() throws {
        let engine = try makeEngine(entry: """
        import { on } from "wowser";
        export function setup() {
          return on("navigate", (e) => e.url.includes("blocked") ? { cancel: true } : e.url.includes("old") ? { redirect: "https://new.example/" } : null);
        }
        export default function App() { return null; }
        """)
        XCTAssertTrue(engine.listening.contains("navigate"))
        XCTAssertEqual(engine.emit("navigate", ["url": "https://blocked.example/"])?["cancel"]?.bool, true)
        XCTAssertEqual(engine.emit("navigate", ["url": "https://old.example/"])?["redirect"]?.string, "https://new.example/")
        XCTAssertNil(engine.emit("navigate", ["url": "https://fine.example/"]))
    }
    // MARK: Templates

    func testTemplateWithLogicRendersAndHandlesEvents() throws {
        let engine = try makeEngine(files: [
            "t/index.xml": """
            <view>
              <Row testID="btn" height="30" hover:background="accent/0.2" onPress="bump()">
                <Text>Count {n} of {$tabs.tabs.length >= 0 ? "tabs" : "?"}</Text>
                <Text if="{n > 1}" testID="many">many</Text>
              </Row>
            </view>
            """,
            "t/index.ts": """
            import { useState } from "wowser";
            export default function () {
              const [n, setN] = useState(0);
              return { n, bump: () => setN(n + 1) };
            }
            """,
        ], entry: "t/index.xml")
        XCTAssertNil(engine.failure, engine.failure?.summary ?? "")
        let root = try XCTUnwrap(engine.tree.roots[ShellEngine.rootKey])
        let button = try XCTUnwrap(find(root) { $0.string("testID") == "btn" })
        XCTAssertEqual(button.type, "row")
        XCTAssertEqual(button.props["style"]?["height"]?.double, 30)
        XCTAssertEqual(button.props["style"]?["hover"]?["background"]?.string, "accent/0.2")
        XCTAssertEqual(text(root), "Count 0 of tabs")
        engine.dispatch(button.id, "onPress", ["modifiers": [:], "x": 0, "y": 0])
        engine.dispatch(button.id, "onPress", ["modifiers": [:], "x": 0, "y": 0])
        XCTAssertNotNil(find(root) { $0.string("testID") == "many" })
    }

    /// The point of templates: they draw without logic, and half-written.
    func testTemplateRendersWithoutLogicAndUnfinished() throws {
        let engine = try makeEngine(files: [
            "t/index.xml": """
            <view state="{ open: false }">
              <Column testID="col" onPress="open = !open">
                <Text testID="label">{open ? "open" : "closed"}</Text>
                <Row><Text>still being writ
            """,
            // A logic file that cannot load must not take the view down.
            "t/index.ts": "export default function () { return {; }",
        ], entry: "t/index.xml")
        XCTAssertNil(engine.failure, engine.failure?.summary ?? "")
        let root = try XCTUnwrap(engine.tree.roots[ShellEngine.rootKey])
        let column = try XCTUnwrap(find(root) { $0.string("testID") == "col" })
        func label() -> String? { find(root) { $0.string("testID") == "label" }.map(text) }
        XCTAssertEqual(label(), "closed")
        engine.dispatch(column.id, "onPress", ["modifiers": [:], "x": 0, "y": 0])
        XCTAssertEqual(label(), "open")
        XCTAssertTrue(text(root).contains("still being writ"))
        XCTAssertFalse(engine.errors.isEmpty, "the broken logic file is reported, not fatal")
    }

    // MARK: Windows, pointer, web framing

    func testWindowNodesPointerSliceAndGlobalCommands() throws {
        let engine = try makeEngine(files: [
            "t/index.xml": """
            <view>
              <Stack flex="1">
                <Text testID="mouse">{$mouse.inside ? $mouse.x + "," + $mouse.y : "outside"}</Text>
                <Window testID="panel" kind="panel" width="320" height="180" anchor="bottomTrailing" inset="20" resizable>
                  <Text>in a panel</Text>
                </Window>
              </Stack>
            </view>
            """,
            "t/index.ts": """
            import { useGlobalHotkey } from "wowser";
            export default function () { useGlobalHotkey("ctrl+alt+shift+f19", () => {}); return {}; }
            """,
        ], entry: "t/index.xml")
        XCTAssertNil(engine.failure, engine.failure?.summary ?? "")
        let root = try XCTUnwrap(engine.tree.roots[ShellEngine.rootKey])
        let panel = try XCTUnwrap(find(root) { $0.type == "window" })
        XCTAssertEqual(panel.double("width"), 320)
        XCTAssertEqual(panel.string("anchor"), "bottomTrailing")
        XCTAssertTrue(panel.bool("resizable"))
        XCTAssertNil(panel.props["style"], "a window's geometry is props, not style")
        XCTAssertEqual(text(panel), "in a panel")

        func mouse() -> String? { find(root) { $0.string("testID") == "mouse" }.map(text) }
        XCTAssertEqual(mouse(), "outside")
        engine.mouseMoved(to: CGPoint(x: 12, y: 34), inside: true)
        XCTAssertEqual(mouse(), "12,34")

        XCTAssertEqual(engine.commands.values.filter(\.global).map(\.hotkey), ["ctrl+alt+shift+f19"])
    }

    func testWebFraming() {
        let node = CGSize(width: 300, height: 200)
        // A 1200-wide viewport in a 300-wide node: quarter scale, page fills the node.
        var p = ShellWebFraming(viewportWidth: 1200).placement(in: node)
        XCTAssertEqual(p.layout, CGSize(width: 1200, height: 800))
        XCTAssertEqual(p.scale, 0.25)
        XCTAssertEqual(p.offset, .zero)

        // Crop to a 600×200 strip at (100, 50): fits the width, centred vertically.
        p = ShellWebFraming(crop: CGRect(x: 100, y: 50, width: 600, height: 200)).placement(in: node)
        XCTAssertEqual(p.layout, node, "without a viewport the page lays out at the node's size")
        XCTAssertEqual(p.scale, 0.5)
        XCTAssertEqual(p.offset, CGPoint(x: -50, y: 25))

        // Fill instead of fit: covers the node, cropping the sides.
        p = ShellWebFraming(crop: CGRect(x: 100, y: 50, width: 600, height: 200), fill: true).placement(in: node)
        XCTAssertEqual(p.scale, 1)
        XCTAssertEqual(p.offset, CGPoint(x: -250, y: -50))

        XCTAssertNil(ShellWebFraming.rect(["x": 0, "y": 0, "width": 0, "height": 10]), "an empty element is no crop")
        XCTAssertEqual(ShellWebFraming.rect(["x": 5, "y": 6, "width": 70, "height": 80]), CGRect(x: 5, y: 6, width: 70, height: 80))
    }
}
#endif
