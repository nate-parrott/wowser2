// A mirror of the native node tree: applies the ops stream the reconciler
// emits. The Swift equivalent is ShellTree.
"use strict";

function createTree() {
  const nodes = new Map();
  const roots = new Map(); // rootKey -> node id
  const listeners = new Set();
  let opCount = 0;

  function apply(ops) {
    for (const op of ops) {
      opCount++;
      const [kind, id, a, b] = op;
      if (kind === "create") {
        nodes.set(id, { id, type: a, props: b || {}, children: [] });
        if (a === "root") roots.set(b.rootKey, id);
      } else if (kind === "update") {
        const n = nodes.get(id);
        if (!n) throw new Error("update of unknown node " + id);
        for (const k in a) {
          if (a[k] === null) delete n.props[k];
          else n.props[k] = a[k];
        }
      } else if (kind === "children") {
        const n = nodes.get(id);
        if (!n) throw new Error("children of unknown node " + id);
        n.children = a.map((cid) => {
          const c = nodes.get(cid);
          if (!c) throw new Error("child " + cid + " of " + id + " does not exist");
          return c;
        });
      } else if (kind === "remove") {
        const drop = (n) => {
          if (!n) return;
          nodes.delete(n.id);
          n.children.forEach(drop);
        };
        drop(nodes.get(id));
      } else {
        throw new Error("unknown op " + kind);
      }
    }
    listeners.forEach((l) => l());
  }

  const root = (key) => nodes.get(roots.get(key || "main"));

  /** All nodes under `from` matching `pred`, depth first. */
  function findAll(pred, from) {
    const out = [];
    const walk = (n) => {
      if (!n) return;
      if (pred(n)) out.push(n);
      n.children.forEach(walk);
    };
    walk(from || root());
    return out;
  }
  const find = (pred, from) => findAll(pred, from)[0] || null;

  /** Concatenated text under a node. */
  function text(n) {
    n = n || root();
    if (!n) return "";
    let s = "";
    if (n.type === "text") s += n.props.text != null ? n.props.text : (n.props.runs || []).map((r) => r.text).join("");
    for (const c of n.children) s += (s && !s.endsWith(" ") ? " " : "") + text(c);
    return s.trim();
  }
  const byText = (t) => find((n) => n.type === "text" && text(n) === t);
  const byTestId = (id) => find((n) => n.props.testID === id);

  return { nodes, roots, apply, root, find, findAll, text, byText, byTestId, listeners, get opCount() { return opCount; } };
}

module.exports = { createTree };
