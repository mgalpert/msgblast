import Foundation

/// One HTML document for the comparison MCP App. Inlined so the stdio and HTTP servers both have it.
enum AgentControlMCPAppHTML {
    static let html = ##"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>msgblast comparison</title>
<style>
:root {
  color-scheme: light dark;
  --color-background-primary: #ffffff;
  --color-background-primary: light-dark(#ffffff, #171717);
  --color-background-secondary: #f4f4f5;
  --color-background-secondary: light-dark(#f4f4f5, #262626);
  --color-background-tertiary: #e7e7ea;
  --color-background-tertiary: light-dark(#e7e7ea, #333333);
  --color-background-danger: #fde8e8;
  --color-background-danger: light-dark(#fde8e8, #3f1d1d);
  --color-text-primary: #171717;
  --color-text-primary: light-dark(#171717, #fafafa);
  --color-text-secondary: #52525b;
  --color-text-secondary: light-dark(#52525b, #a1a1aa);
  --color-text-danger: #9f1239;
  --color-text-danger: light-dark(#9f1239, #fda4af);
  --color-border-primary: #e4e4e7;
  --color-border-primary: light-dark(#e4e4e7, #3f3f46);
  --color-border-secondary: #d4d4d8;
  --color-border-secondary: light-dark(#d4d4d8, #52525b);
  --color-ring-primary: #2563eb;
  --color-ring-primary: light-dark(#2563eb, #93c5fd);
  --font-sans: ui-sans-serif, system-ui, sans-serif;
  --font-text-sm-size: 13px;
  --font-text-md-size: 15px;
  --font-heading-sm-size: 18px;
  --font-weight-medium: 500;
  --font-weight-semibold: 600;
  --border-radius-sm: 6px;
  --border-radius-md: 10px;
  --border-width-regular: 1px;
}
html[data-theme="light"] { color-scheme: light; }
html[data-theme="dark"] { color-scheme: dark; }
* { box-sizing: border-box; }
body {
  margin: 0; padding: 16px;
  background: var(--color-background-primary); color: var(--color-text-primary);
  font-family: var(--font-sans); font-size: var(--font-text-md-size); line-height: 1.45;
}
header { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
h1 { margin: 0; font-size: var(--font-heading-sm-size); font-weight: var(--font-weight-semibold); overflow-wrap: anywhere; }
.actions { display: flex; gap: 8px; flex: none; }
button {
  border: var(--border-width-regular) solid var(--color-border-secondary);
  background: var(--color-background-secondary); color: var(--color-text-primary);
  border-radius: var(--border-radius-sm); padding: 4px 10px; font: inherit;
  font-size: var(--font-text-sm-size); cursor: pointer;
}
button:focus-visible { outline: 2px solid var(--color-ring-primary); outline-offset: 2px; }
.list { list-style: none; margin: 0; padding: 0; }
.row { border-bottom: var(--border-width-regular) solid var(--color-border-primary); padding: 10px 0; }
.link { background: transparent; border: 0; padding: 0; font-weight: var(--font-weight-medium); text-align: left; }
.meta { margin: 4px 0 0; color: var(--color-text-secondary); font-size: var(--font-text-sm-size); }
.empty { color: var(--color-text-secondary); }
.error { background: var(--color-background-danger); color: var(--color-text-danger); border-radius: var(--border-radius-md); padding: 10px 12px; }
.grid { display: grid; gap: 12px; grid-template-columns: repeat(var(--cols, 1), minmax(0, 1fr)); }
.col { min-width: 0; }
.agent { margin: 0 0 8px; font-size: var(--font-text-md-size); font-weight: var(--font-weight-semibold); }
.turn { border: var(--border-width-regular) solid var(--color-border-primary); border-radius: var(--border-radius-md); padding: 8px 10px; margin: 0 0 8px; }
.turn.out { background: var(--color-background-tertiary); }
.turn.in { background: var(--color-background-secondary); }
.who { margin: 0 0 4px; color: var(--color-text-secondary); font-size: var(--font-text-sm-size); font-weight: var(--font-weight-medium); }
.body { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
@media (max-width: 600px) { .grid { grid-template-columns: minmax(0, 1fr); } }
</style>
</head>
<body>
<header>
  <h1 id="title">Comparisons</h1>
  <div class="actions">
    <button id="back" type="button" hidden>All comparisons</button>
    <button id="full" type="button" hidden>Full screen</button>
  </div>
</header>
<main id="main"><p class="empty">Loading...</p></main>
<script>
(function () {
  var nextId = 1, pending = {}, host = { availableDisplayModes: [], toolName: "" };
  function post(message) { window.parent.postMessage(message, "*"); }
  function request(method, params) {
    var id = nextId++;
    post({ jsonrpc: "2.0", id: id, method: method, params: params });
    return new Promise(function (resolve, reject) { pending[id] = { resolve: resolve, reject: reject }; });
  }
  function notify(method, params) { post({ jsonrpc: "2.0", method: method, params: params || {} }); }
  function text(value) { return value == null ? "" : String(value); }
  function el(tag, className, content) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (content != null) node.textContent = content;
    return node;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function contentText(result) {
    var blocks = result && result.content, parts = [], i;
    if (!blocks) return "";
    for (i = 0; i < blocks.length; i++) if (blocks[i] && blocks[i].text) parts.push(blocks[i].text);
    return parts.join("\n");
  }
  function showError(message) {
    var main = document.getElementById("main");
    clear(main);
    var note = el("p", "error", message || "msgblast could not show this.");
    note.setAttribute("role", "alert");
    main.appendChild(note);
  }
  function formatDate(value) {
    var date = new Date(value);
    return isNaN(date.getTime()) ? text(value) : date.toLocaleString();
  }
  function setTitle(value) { document.getElementById("title").textContent = value; }
  function showBack(on) { document.getElementById("back").hidden = !on; }
  function applyContext(partial) {
    if (!partial) return;
    if (partial.theme === "light" || partial.theme === "dark") {
      host.theme = partial.theme;
      document.documentElement.setAttribute("data-theme", partial.theme);
      document.documentElement.style.colorScheme = partial.theme;
    }
    var variables = partial.styles && partial.styles.variables;
    if (variables) Object.keys(variables).forEach(function (key) {
      if (key.indexOf("--") === 0 && variables[key] != null) document.documentElement.style.setProperty(key, String(variables[key]));
    });
    if (partial.availableDisplayModes) host.availableDisplayModes = partial.availableDisplayModes;
    if (partial.displayMode) host.displayMode = partial.displayMode;
    if (partial.toolInfo && partial.toolInfo.tool && partial.toolInfo.tool.name) host.toolName = partial.toolInfo.tool.name;
    document.getElementById("full").hidden = host.availableDisplayModes.indexOf("fullscreen") === -1;
  }
  // The list tool's payload is a JSON array, so it arrives in content text. Objects also set structuredContent.
  function payload(result) {
    var structured = result && result.structuredContent, raw = contentText(result), parsed = null;
    if (raw) { try { parsed = JSON.parse(raw); } catch (error) { parsed = null; } }
    if (structured && typeof structured === "object" && (structured.turns || structured.events || structured.prompt != null)) return structured;
    if (parsed !== null) return parsed;
    return structured || null;
  }
  function renderList(items) {
    setTitle("Comparisons");
    showBack(false);
    var main = document.getElementById("main");
    clear(main);
    if (!items.length) { main.appendChild(el("p", "empty", "No comparisons yet.")); return; }
    var list = el("ul", "list");
    items.forEach(function (item) {
      var row = el("li", "row");
      var button = el("button", "link", text(item.title || item.name || "Comparison"));
      button.type = "button";
      button.addEventListener("click", function () { openComparison(item.id); });
      row.appendChild(button);
      var count = Array.isArray(item.agents) ? item.agents.length : 0;
      var when = item.created ? formatDate(item.created) : "";
      row.appendChild(el("p", "meta", [when, count + (count === 1 ? " agent" : " agents")].filter(Boolean).join(" · ")));
      list.appendChild(row);
    });
    main.appendChild(list);
  }
  function renderComparison(item) {
    setTitle(text(item.prompt || "Comparison"));
    showBack(true);
    var main = document.getElementById("main"), turns = Array.isArray(item.turns) ? item.turns : [];
    var order = [], byAgent = {};
    clear(main);
    turns.forEach(function (turn) {
      var name = text(turn.agent || "Agent");
      if (!byAgent[name]) { byAgent[name] = []; order.push(name); }
      byAgent[name].push(turn);
    });
    if (item.submissions) Object.keys(item.submissions).forEach(function (name) {
      if (!byAgent[name]) { byAgent[name] = []; order.push(name); }
    });
    if (!order.length) { main.appendChild(el("p", "empty", "No comparisons yet.")); return; }
    var grid = el("div", "grid");
    grid.style.setProperty("--cols", String(order.length));
    order.forEach(function (name) {
      var column = el("section", "col");
      column.appendChild(el("h2", "agent", name));
      if (item.submissions && item.submissions[name]) column.appendChild(el("p", "meta", text(item.submissions[name])));
      byAgent[name].forEach(function (turn) {
        var bubble = el("article", turn.outgoing ? "turn out" : "turn in");
        bubble.appendChild(el("p", "who", turn.outgoing ? "Prompt" : "Reply"));
        bubble.appendChild(el("p", "body", text(turn.text)));
        if (turn.date) bubble.appendChild(el("p", "meta", formatDate(turn.date)));
        column.appendChild(bubble);
      });
      grid.appendChild(column);
    });
    main.appendChild(grid);
  }
  function renderEvents(item) {
    setTitle("Replies");
    showBack(true);
    var main = document.getElementById("main"), events = Array.isArray(item.events) ? item.events : [];
    var names = { replyArrived: "Reply arrived", agentBusy: "Agent busy", agentReady: "Agent ready", sendResult: "Send finished", messageReceived: "Message received", reportReady: "Report ready" };
    clear(main);
    if (!events.length) { main.appendChild(el("p", "empty", "No comparisons yet.")); return; }
    var list = el("ul", "list");
    events.forEach(function (event) {
      var row = el("li", "row");
      var bits = [names[event.kind] || event.kind, event.agent, event.detail].filter(Boolean);
      row.appendChild(el("p", "body", bits.join(" · ") || "Event"));
      if (event.date) row.appendChild(el("p", "meta", formatDate(event.date)));
      var id = event.comparisonId || event.comparisonID;
      if (id) {
        var button = el("button", "link", "Show comparison");
        button.type = "button";
        button.addEventListener("click", function () { openComparison(id); });
        row.appendChild(button);
      }
      list.appendChild(row);
    });
    main.appendChild(list);
  }
  function render(result, toolName) {
    if (result && result.isError) { showError(contentText(result)); return; }
    var value = payload(result), name = toolName || host.toolName || "";
    if (Array.isArray(value) || name === "msgblast_comparisons_list") { renderList(Array.isArray(value) ? value : []); return; }
    if ((value && Array.isArray(value.events)) || name === "msgblast_blast_wait") { renderEvents(value || { events: [] }); return; }
    if (value && (Array.isArray(value.turns) || value.prompt != null || name === "msgblast_comparison_read")) { renderComparison(value); return; }
    showError(contentText(result) || "Nothing to show.");
  }
  function openComparison(id) {
    if (!id) { showError("This comparison has no id."); return; }
    setTitle("Comparison");
    var main = document.getElementById("main");
    clear(main);
    main.appendChild(el("p", "empty", "Loading..."));
    request("tools/call", { name: "msgblast_comparison_read", arguments: { id: String(id) } }).then(function (result) {
      render(result, "msgblast_comparison_read");
    }).catch(function (error) { showError(error && error.message ? error.message : "Could not open the comparison."); });
  }
  document.getElementById("back").addEventListener("click", function () {
    request("tools/call", { name: "msgblast_comparisons_list", arguments: {} }).then(function (result) {
      render(result, "msgblast_comparisons_list");
    }).catch(function (error) { showError(error && error.message ? error.message : "Could not list comparisons."); });
  });
  document.getElementById("full").addEventListener("click", function () {
    if (host.availableDisplayModes.indexOf("fullscreen") === -1) return;
    request("ui/request-display-mode", { mode: "fullscreen" }).then(function (result) {
      if (result && result.mode) host.displayMode = result.mode;
    }).catch(function () {});
  });
  window.addEventListener("message", function (event) {
    var data = event.data;
    if (!data || data.jsonrpc !== "2.0") return;
    if (event.source && event.source !== window.parent) return;
    if (data.id != null && data.method) {
      if (data.method === "ui/resource-teardown") post({ jsonrpc: "2.0", id: data.id, result: {} });
      return;
    }
    if (data.id != null && pending[data.id]) {
      var waiter = pending[data.id];
      delete pending[data.id];
      if (data.error) waiter.reject(new Error(data.error.message || "Request failed."));
      else waiter.resolve(data.result);
      return;
    }
    if (data.method === "ui/notifications/tool-input") host.arguments = (data.params && data.params.arguments) || {};
    else if (data.method === "ui/notifications/tool-result") render(data.params || {}, host.toolName);
    else if (data.method === "ui/notifications/host-context-changed") applyContext(data.params || {});
  });
  request("ui/initialize", {
    protocolVersion: "2025-06-18",
    appInfo: { name: "msgblast", version: "1" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }
  }).then(function (result) {
    applyContext(result && result.hostContext);
    notify("ui/notifications/initialized");
  }).catch(function (error) { showError(error && error.message ? error.message : "Could not connect to the host."); });
})();
</script>
</body>
</html>
"""##
}
