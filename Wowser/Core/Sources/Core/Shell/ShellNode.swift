import Foundation
import Observation

/// One node of the tree a branch renders: the native twin of a host element
/// in the JS reconciler (`<Row>`, `<Text>`, `<WebPane>` …).
///
/// Nodes are reference types observed individually, so a prop change
/// re-renders that node's view and nothing else.
@Observable
public final class ShellNode: Identifiable {
    public let id: Int
    public let type: String
    public private(set) var props: [String: ShellJSON]
    public fileprivate(set) var children: [ShellNode] = []

    @ObservationIgnored private var styleCache: [UInt8: ShellStyle] = [:]
    /// Last laid-out frame in window coordinates (inspector, `ref.measure()`).
    @ObservationIgnored public var frame: CGRect?

    init(id: Int, type: String, props: [String: ShellJSON]) {
        self.id = id
        self.type = type
        self.props = props
    }

    fileprivate func merge(_ changes: [String: ShellJSON]) {
        var next = props
        for (key, value) in changes {
            if value.isNull { next.removeValue(forKey: key) } else { next[key] = value }
        }
        styleCache.removeAll(keepingCapacity: true)
        props = next
    }

    // MARK: Prop access

    public func string(_ key: String) -> String? { props[key]?.string }
    public func double(_ key: String) -> Double? { props[key]?.double }
    public func bool(_ key: String) -> Bool { props[key]?.bool ?? false }
    /// Whether JS attached a handler for this event.
    public func handles(_ event: String) -> Bool { props[event]?.isTrue ?? false }

    /// The node's style with the variants for `state` folded in.
    public func style(_ state: ShellStyleState = []) -> ShellStyle {
        // Touch `props` so observers of the style re-evaluate when it changes.
        let raw = props["style"]?.object
        if let cached = styleCache[state.rawValue] { return cached }
        let resolved = ShellStyle(raw: raw ?? [:], state: state)
        styleCache[state.rawValue] = resolved
        return resolved
    }

    /// Which state variants this node's style declares at all. Lets the
    /// renderer skip hover tracking for nodes that don't react to it.
    public var declaredStates: ShellStyleState {
        guard let raw = props["style"]?.object else { return [] }
        var out: ShellStyleState = []
        for (key, state) in ShellStyleState.keys where raw[key] != nil { out.insert(state) }
        return out
    }
}

/// Applies the reconciler's op stream to a set of `ShellNode`s.
@Observable
public final class ShellTree {
    @ObservationIgnored private var nodes: [Int: ShellNode] = [:]
    /// Root nodes by the key passed to `__shell.mount`.
    public private(set) var roots: [String: ShellNode] = [:]
    @ObservationIgnored public private(set) var appliedOps = 0

    public init() {}

    public func node(_ id: Int) -> ShellNode? { nodes[id] }
    public var nodeCount: Int { nodes.count }

    public enum OpError: Error, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            switch self {
            case .malformed(let why): return "Malformed shell op: \(why)"
            }
        }
    }

    /// `ops` is the decoded array the reconciler passed to `host.commit`:
    ///   ["create", id, type, props] · ["update", id, changedProps]
    ///   ["children", id, [childIds]] · ["remove", id]
    public func apply(_ ops: [ShellJSON]) throws {
        for op in ops {
            guard let parts = op.array, parts.count >= 2,
                  let kind = parts[0].string, let id = parts[1].int
            else { throw OpError.malformed(op.jsonString()) }
            appliedOps += 1
            switch kind {
            case "create":
                guard parts.count >= 3, let type = parts[2].string else { throw OpError.malformed("create without type") }
                let props = parts.count > 3 ? (parts[3].object ?? [:]) : [:]
                let node = ShellNode(id: id, type: type, props: props)
                nodes[id] = node
                if type == "root", let key = props["rootKey"]?.string {
                    roots[key] = node
                }
            case "update":
                guard let node = nodes[id] else { throw OpError.malformed("update of unknown node \(id)") }
                guard parts.count > 2, let changes = parts[2].object else { throw OpError.malformed("update without props") }
                node.merge(changes)
            case "children":
                guard let node = nodes[id] else { throw OpError.malformed("children of unknown node \(id)") }
                guard parts.count > 2, let ids = parts[2].array else { throw OpError.malformed("children without ids") }
                var kids: [ShellNode] = []
                kids.reserveCapacity(ids.count)
                for childID in ids {
                    guard let cid = childID.int, let child = nodes[cid] else {
                        throw OpError.malformed("child \(childID.jsonString()) of \(id) does not exist")
                    }
                    kids.append(child)
                }
                node.children = kids
            case "remove":
                if let node = nodes[id] { drop(node) }
            default:
                throw OpError.malformed("unknown op \(kind)")
            }
        }
    }

    private func drop(_ node: ShellNode) {
        nodes.removeValue(forKey: node.id)
        if node.type == "root", let key = node.props["rootKey"]?.string, roots[key] === node {
            roots.removeValue(forKey: key)
        }
        for child in node.children { drop(child) }
    }

    public func removeAll() {
        nodes.removeAll()
        roots.removeAll()
    }

    /// The tree under a root as plain JSON, with frames (for `shell_inspect`).
    public func dump(rootKey: String, maxDepth: Int = 64) -> ShellJSON? {
        guard let root = roots[rootKey] else { return nil }
        func walk(_ node: ShellNode, depth: Int) -> ShellJSON {
            var out: [String: ShellJSON] = ["id": .number(Double(node.id)), "type": .string(node.type)]
            var props = node.props
            props.removeValue(forKey: "rootKey")
            if !props.isEmpty { out["props"] = .object(props) }
            if let f = node.frame {
                out["frame"] = .array([f.minX, f.minY, f.width, f.height].map { .number(Double(($0 * 10).rounded() / 10)) })
            }
            if !node.children.isEmpty, depth < maxDepth {
                out["children"] = .array(node.children.map { walk($0, depth: depth + 1) })
            }
            return .object(out)
        }
        return walk(root, depth: 0)
    }

    /// The deepest node whose frame contains `point` (window coordinates),
    /// preferring later siblings (drawn on top).
    public func hitTest(rootKey: String, point: CGPoint) -> ShellNode? {
        guard let root = roots[rootKey] else { return nil }
        func walk(_ node: ShellNode) -> ShellNode? {
            for child in node.children.reversed() {
                if let hit = walk(child) { return hit }
            }
            if let f = node.frame, f.contains(point), node.type != "root" { return node }
            return nil
        }
        return walk(root)
    }
}
