/*
 * Autofill playground — shared instrumentation.
 *
 * Adds a fixed side panel that:
 *   - logs focusin/focusout, keydown, beforeinput (with inputType), input, change and
 *     submit for every field on the page (including open shadow roots via composedPath);
 *   - shows a live "values" readout of every field, polled every 500 ms, and flags values
 *     that changed WITHOUT an input/change event (a "silent" fill that frameworks miss);
 *   - has Clear log / Reset page buttons.
 *
 * Pages can call:
 *   PG.log(msg)          — add a bold note line to the log (e.g. "fetch /api/login -> ok")
 *   PG.watch(root)       — instrument a closed shadow root (or any node) the panel can't reach
 */
(function () {
  "use strict";
  if (window.PG) return;

  var MAX_LINES = 400;
  var startTime = performance.now();
  var extraRoots = [];               // closed shadow roots registered via PG.watch
  var lastEventValue = new WeakMap(); // element -> value as of its last input/change event
  var silentFlagged = new WeakMap();  // element -> value we already logged as silent
  var ids = new WeakMap();
  var nextId = 1;
  var filters = { keydown: true, focus: true };

  function t() { return ((performance.now() - startTime) / 1000).toFixed(2).padStart(7, " "); }

  function isField(el) {
    if (!el || el.nodeType !== 1) return false;
    var tag = el.tagName;
    if (tag === "INPUT") return !/^(button|submit|reset|image)$/i.test(el.type);
    return tag === "SELECT" || tag === "TEXTAREA" || el.isContentEditable === true && el.getAttribute("contenteditable") !== null;
  }

  function inPanel(el) { return !!(el && el.closest && el.closest("#pg-panel")); }

  function uid(el) {
    if (!ids.has(el)) ids.set(el, nextId++);
    return ids.get(el);
  }

  function describe(el) {
    if (!el || el.nodeType !== 1) return String(el);
    var s = el.tagName.toLowerCase();
    if (el.tagName === "INPUT") s += "[" + (el.getAttribute("type") || "text") + "]";
    if (el.id) s += "#" + el.id;
    var name = el.getAttribute("name");
    if (name) s += " name=" + name;
    var ac = el.getAttribute("autocomplete");
    if (ac) s += " ac=" + ac;
    if (!el.id && !name) {
      var hint = el.getAttribute("placeholder") || el.getAttribute("aria-label") || el.getAttribute("data-label");
      if (hint) s += ' "' + hint + '"';
      else s += " @" + uid(el);
    }
    var root = el.getRootNode && el.getRootNode();
    if (root && root instanceof ShadowRoot) s = "shadow(" + (root.mode) + "):" + s;
    return s;
  }

  function valueOf(el) {
    if (el.tagName === "INPUT" && (el.type === "checkbox" || el.type === "radio")) return el.checked ? "[x]" : "[ ]";
    if (el.tagName === "SELECT") {
      var o = el.options[el.selectedIndex];
      return o ? JSON.stringify(el.value) + (o.text !== el.value ? " (" + o.text.trim() + ")" : "") : '""';
    }
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") return JSON.stringify(el.value);
    return JSON.stringify(el.textContent);
  }

  function rawValue(el) {
    if (el.tagName === "INPUT" && (el.type === "checkbox" || el.type === "radio")) return el.checked;
    if ("value" in el && el.tagName !== "DIV" && el.tagName !== "SPAN") return el.value;
    return el.textContent;
  }

  // ---------- panel ----------
  var panel, logEl, valuesEl;

  function buildPanel() {
    panel = document.createElement("aside");
    panel.id = "pg-panel";
    panel.setAttribute("data-autofill-playground", "panel");
    panel.innerHTML =
      '<header><b>Event log</b>' +
      '<button type="button" data-act="clear">Clear log</button>' +
      '<button type="button" data-act="reset">Reset page</button>' +
      '<button type="button" data-act="toggle">Hide</button></header>' +
      '<div class="pg-body">' +
      '<div class="pg-filters">' +
      '<label><input type="checkbox" data-filter="keydown" checked> keydown</label>' +
      '<label><input type="checkbox" data-filter="focus" checked> focus/blur</label>' +
      '</div>' +
      '<h4>Values (red = changed with no input/change event)</h4><div id="pg-values"></div>' +
      '<h4>Events</h4><div id="pg-log"></div></div>';
    document.body.appendChild(panel);
    logEl = panel.querySelector("#pg-log");
    valuesEl = panel.querySelector("#pg-values");
    panel.addEventListener("click", function (e) {
      var act = e.target.getAttribute && e.target.getAttribute("data-act");
      if (act === "clear") logEl.textContent = "";
      if (act === "reset") location.href = location.pathname;
      if (act === "toggle") {
        var collapsed = panel.classList.toggle("collapsed");
        document.body.classList.toggle("pg-panel-hidden", collapsed);
        e.target.textContent = collapsed ? "Show" : "Hide";
      }
    });
    panel.addEventListener("change", function (e) {
      var f = e.target.getAttribute && e.target.getAttribute("data-filter");
      if (f) filters[f] = e.target.checked;
    });
  }

  function addLine(cls, text) {
    if (!logEl) return;
    var d = document.createElement("div");
    d.className = "ev-" + cls;
    var ts = document.createElement("span");
    ts.className = "t";
    ts.textContent = t() + " ";
    d.appendChild(ts);
    d.appendChild(document.createTextNode(text));
    logEl.appendChild(d);
    while (logEl.childNodes.length > MAX_LINES) logEl.removeChild(logEl.firstChild);
    logEl.scrollTop = logEl.scrollHeight;
  }

  // ---------- event logging ----------
  function target(e) {
    var path = e.composedPath ? e.composedPath() : [];
    return path.length ? path[0] : e.target;
  }

  function onEvent(e) {
    var el = target(e);
    if (inPanel(el) || (e.target && inPanel(e.target))) return;
    var type = e.type;
    if (type === "submit") {
      var f = e.target;
      addLine("submit", "submit  form" + (f.id ? "#" + f.id : "") + " method=" + (f.getAttribute("method") || "get") +
        " action=" + (f.getAttribute("action") || "(self)") + (e.submitter ? " submitter=" + describe(e.submitter) : ""));
      return;
    }
    if (!isField(el) && type !== "keydown") return;
    switch (type) {
      case "focusin":
      case "focusout":
        if (!filters.focus) return;
        addLine(type, type + " " + describe(el));
        break;
      case "keydown":
        if (!filters.keydown) return;
        if (!isField(el) && el !== document.body && !(el && el.getAttribute && el.getAttribute("tabindex") !== null)) return;
        var mods = (e.metaKey ? "Cmd+" : "") + (e.ctrlKey ? "Ctrl+" : "") + (e.altKey ? "Opt+" : "") + (e.shiftKey && e.key.length > 1 ? "Shift+" : "");
        addLine("keydown", "keydown " + mods + JSON.stringify(e.key) + (e.isTrusted ? "" : " (untrusted)") + (e.isComposing ? " composing" : "") + "  " + describe(el));
        break;
      case "beforeinput":
        addLine("beforeinput", "beforeinput " + e.inputType + (e.data != null ? " data=" + JSON.stringify(e.data) : "") +
          (e.isTrusted ? "" : " (untrusted)") + "  " + describe(el));
        break;
      case "input":
        lastEventValue.set(el, rawValue(el));
        addLine("input", "input " + (e.inputType || "(no inputType)") + (e.isTrusted ? "" : " (untrusted)") + "  " + describe(el) + " = " + valueOf(el));
        break;
      case "change":
        lastEventValue.set(el, rawValue(el));
        addLine("change", "change " + (e.isTrusted ? "" : "(untrusted) ") + describe(el) + " = " + valueOf(el));
        break;
    }
  }

  var EVENTS = ["focusin", "focusout", "keydown", "beforeinput", "input", "change", "submit"];
  function instrument(root) {
    EVENTS.forEach(function (type) { root.addEventListener(type, onEvent, true); });
  }

  // ---------- values readout ----------
  function collectFields(root, out) {
    var all = root.querySelectorAll("*");
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.id === "pg-panel") { continue; }
      if (inPanel(el)) continue;
      if (isField(el)) out.push(el);
      if (el.shadowRoot) collectFields(el.shadowRoot, out);
    }
    return out;
  }

  function renderValues() {
    if (!valuesEl) return;
    var fields = collectFields(document, []);
    extraRoots.forEach(function (r) { collectFields(r, fields); });
    var rows = [];
    fields.forEach(function (el) {
      var raw = rawValue(el);
      if (!lastEventValue.has(el)) lastEventValue.set(el, raw); // baseline on first sight
      var silent = lastEventValue.get(el) !== raw;
      if (silent && silentFlagged.get(el) !== raw) {
        silentFlagged.set(el, raw);
        addLine("silent", "SILENT CHANGE (no input/change event)  " + describe(el) + " = " + valueOf(el));
      }
      var hidden = el.type === "hidden" ? " (hidden)" : "";
      rows.push('<tr class="' + (silent ? "silent" : "") + '"><td>' + esc(describe(el) + hidden) + "</td><td>" + esc(valueOf(el)) + "</td></tr>");
    });
    var html = "<table>" + rows.join("") + "</table>";
    if (valuesEl._last !== html) { valuesEl.innerHTML = html; valuesEl._last = html; }
  }

  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  // ---------- public API ----------
  window.PG = {
    log: function (msg) { addLine("note", "» " + msg); },
    watch: function (root) { extraRoots.push(root); instrument(root); },
    describe: describe
  };

  instrument(document);
  function init() {
    buildPanel();
    addLine("note", "» loaded " + location.href);
    renderValues();
    setInterval(renderValues, 500);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
  window.addEventListener("popstate", function () { addLine("note", "» popstate " + location.href); });
  window.addEventListener("hashchange", function () { addLine("note", "» hashchange " + location.href); });
  window.addEventListener("pagehide", function () { addLine("note", "» pagehide"); });
})();
