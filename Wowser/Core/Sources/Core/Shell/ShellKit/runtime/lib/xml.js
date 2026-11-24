// A small, forgiving XML parser for view templates.
//
// Templates are XML so they can be read, diffed and generated a tag at a
// time — including while they are still being written. So this parser never
// gives up: a file that stops in the middle of a tag still yields a tree
// (unclosed elements are closed at the end of input) plus a list of problems
// with line numbers.
//
// It is XML with three allowances, all for `{…}` bindings:
//   - `{ }` may contain quotes, `<` and `>`      title="{a < b ? "x" : "y"}"
//   - an attribute value may be a bare `{…}`     count={items.length}
//   - an attribute without a value is `true`     <Row group>
"use strict";

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

function decodeEntities(s) {
  if (s.indexOf("&") < 0) return s;
  return s.replace(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/g, (m, name) => {
    if (name[0] === "#") {
      const code = name[1] === "x" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    return Object.prototype.hasOwnProperty.call(ENTITIES, name) ? ENTITIES[name] : m;
  });
}

/**
 * @returns {{ children: Node[], problems: {message: string, line: number}[] }}
 *   Node = { type: "el", tag, attrs: [{name, value, line}], children, line }
 *        | { type: "text", value, line }
 */
function parse(source) {
  const src = String(source);
  const n = src.length;
  let i = 0;
  let line = 1;
  const problems = [];
  const root = { type: "el", tag: "#root", attrs: [], children: [], line: 1 };
  const stack = [root];
  const top = () => stack[stack.length - 1];
  const problem = (message, atLine) => problems.push({ message, line: atLine || line });

  function advance(to) {
    for (let k = i; k < to && k < n; k++) if (src.charCodeAt(k) === 10) line++;
    i = Math.min(to, n);
  }

  /** Index just past the `}` matching the `{` at `from`, skipping strings. */
  function endOfBraces(from) {
    let depth = 0;
    let k = from;
    while (k < n) {
      const c = src[k];
      if (c === "{") depth++;
      else if (c === "}") {
        depth--;
        if (depth === 0) return k + 1;
      } else if (c === '"' || c === "'" || c === "`") {
        k++;
        while (k < n && src[k] !== c) {
          if (src[k] === "\\") k++;
          k++;
        }
      }
      k++;
    }
    return n;
  }

  function readText() {
    const start = i;
    const startLine = line;
    let k = i;
    while (k < n && src[k] !== "<") {
      if (src[k] === "{") k = endOfBraces(k);
      else k++;
    }
    const raw = src.slice(start, k);
    advance(k);
    if (raw.trim() !== "") top().children.push({ type: "text", value: decodeEntities(raw), line: startLine });
  }

  function skipSpace() {
    let k = i;
    while (k < n && /\s/.test(src[k])) k++;
    advance(k);
  }

  function readName() {
    let k = i;
    while (k < n && /[^\s=<>/"'{}]/.test(src[k])) k++;
    const name = src.slice(i, k);
    advance(k);
    return name;
  }

  function readAttrValue() {
    const c = src[i];
    if (c === "{") {
      const end = endOfBraces(i);
      const v = src.slice(i, end);
      advance(end);
      return v;
    }
    if (c === '"' || c === "'") {
      let k = i + 1;
      while (k < n && src[k] !== c) {
        // A quote inside a binding does not end the value.
        if (src[k] === "{") k = endOfBraces(k);
        else k++;
      }
      const v = src.slice(i + 1, k);
      if (k >= n) problem("unterminated attribute value");
      advance(k + 1);
      return decodeEntities(v);
    }
    // Unquoted: up to whitespace or the end of the tag.
    let k = i;
    while (k < n && !/[\s>]/.test(src[k]) && !(src[k] === "/" && src[k + 1] === ">")) k++;
    const v = src.slice(i, k);
    advance(k);
    return decodeEntities(v);
  }

  function readOpenTag() {
    const startLine = line;
    advance(i + 1); // <
    const tag = readName();
    if (!tag) {
      problem("expected a tag name after '<'");
      return;
    }
    const el = { type: "el", tag, attrs: [], children: [], line: startLine };
    top().children.push(el);
    for (;;) {
      skipSpace();
      if (i >= n) {
        // Input ended inside the tag: keep what we have.
        problem(`<${tag}> is not finished`, startLine);
        return;
      }
      if (src[i] === ">") {
        advance(i + 1);
        stack.push(el);
        return;
      }
      if (src[i] === "/" && src[i + 1] === ">") {
        advance(i + 2);
        return;
      }
      const attrLine = line;
      const name = readName();
      if (!name) {
        problem(`unexpected '${src[i]}' in <${tag}>`);
        advance(i + 1);
        continue;
      }
      skipSpace();
      let value = true;
      if (src[i] === "=") {
        advance(i + 1);
        skipSpace();
        value = i < n ? readAttrValue() : "";
      }
      el.attrs.push({ name, value, line: attrLine });
    }
  }

  function readCloseTag() {
    const end = src.indexOf(">", i);
    const tag = src.slice(i + 2, end < 0 ? n : end).trim();
    const at = line;
    advance(end < 0 ? n : end + 1);
    // Close the nearest open element with this name; anything opened inside
    // it that wasn't closed is closed with it.
    for (let d = stack.length - 1; d > 0; d--) {
      if (stack[d].tag === tag) {
        for (let u = stack.length - 1; u > d; u--) problem(`<${stack[u].tag}> was never closed`, stack[u].line);
        stack.length = d;
        return;
      }
    }
    problem(`</${tag}> has no matching opening tag`, at);
  }

  while (i < n) {
    if (src[i] !== "<") {
      readText();
    } else if (src.startsWith("<!--", i)) {
      const end = src.indexOf("-->", i + 4);
      advance(end < 0 ? n : end + 3);
    } else if (src.startsWith("<![CDATA[", i)) {
      const end = src.indexOf("]]>", i + 9);
      const startLine = line;
      const text = src.slice(i + 9, end < 0 ? n : end);
      advance(end < 0 ? n : end + 3);
      top().children.push({ type: "text", value: text, line: startLine, raw: true });
    } else if (src.startsWith("<?", i) || src.startsWith("<!", i)) {
      const end = src.indexOf(">", i);
      advance(end < 0 ? n : end + 1);
    } else if (src[i + 1] === "/") {
      readCloseTag();
    } else {
      readOpenTag();
    }
  }
  // Whatever is still open at the end of input is simply closed: a template
  // that is still being written shows what has been written so far.
  for (let u = stack.length - 1; u > 0; u--) problem(`<${stack[u].tag}> was never closed`, stack[u].line);
  return { children: root.children, problems };
}

module.exports = { parse, decodeEntities };
