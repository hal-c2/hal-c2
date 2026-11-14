// desktop-qt's preview automation runtime (src/native/PreviewAutomationScript.cpp's
// kRuntime), called as `(<this>)(name, args)`: it answers one JSON string,
// {ok: true, value} or {ok: false, kind, reason}. Keep the two the same.
(function (name, args) {
  "use strict";
  var MAX_ELEMENTS = 200, MAX_TEXT = 20000, MAX_NAME = 200, MAX_TREE = 300;
  var state = window.__halc2 || (window.__halc2 = {});
  function Fail(kind, reason) { this.kind = kind; this.reason = reason; }
  function norm(s) { return String(s == null ? "" : s).replace(/\s+/g, " ").trim(); }
  function shown(el) {
    if (!el || el.nodeType !== 1 || !el.isConnected) return false;
    var style = getComputedStyle(el);
    if (style.visibility === "hidden" || style.display === "none") return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function disabled(el) {
    if (el.disabled || el.getAttribute("aria-disabled") === "true") return true;
    var set = el.closest && el.closest("fieldset[disabled]");
    return !!(set && /^(BUTTON|INPUT|SELECT|TEXTAREA)$/.test(el.tagName));
  }
  var TEXT_INPUTS = /^(text|search|email|url|tel|password|number|date|datetime-local|month|time|week)$/;
  function textField(el) {
    if (el.tagName === "TEXTAREA") return true;
    return el.tagName === "INPUT" && TEXT_INPUTS.test((el.getAttribute("type") || "text").toLowerCase());
  }
  function editable(el) {
    if (!el || el.nodeType !== 1) return false;
    if (textField(el)) return !el.disabled && !el.readOnly;
    return !!el.isContentEditable;
  }
  // What password fields hold, and the text of anything the page draws as
  // dots, so no snapshot says it; `print` changes when any of it does.
  function dotted(el) {
    var style = getComputedStyle(el);
    return (style.webkitTextSecurity || style.getPropertyValue("-webkit-text-security") || "none") !== "none";
  }
  function password(el) {
    return el.tagName === "INPUT" && (el.getAttribute("type") || "").toLowerCase() === "password";
  }
  function secrets() {
    var texts = [], print = [], hash = 5381;
    if (document.body) {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
      for (var el = walker.currentNode; el; el = walker.nextNode()) {
        var field = password(el) || (textField(el) && dotted(el));
        if (!field && (/^(SCRIPT|STYLE|TEMPLATE|INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || !dotted(el))) continue;
        var text = field ? el.value : el.innerText;
        print.push(el.tagName + ":" + (el.getAttribute("type") || "") + ":" + text);
        if (text && text.length > 1) texts.push(text);
      }
    }
    var all = print.join("\u0000");
    for (var i = 0; i < all.length; i++) hash = ((hash << 5) + hash + all.charCodeAt(i)) | 0;
    texts.sort(function (a, b) { return b.length - a.length; });
    return { texts: texts, print: print.length + ":" + hash };
  }
  var hidden = [];
  function scrub(s) {
    s = String(s);
    for (var i = 0; i < hidden.length; i++) {
      if (s.indexOf(hidden[i]) >= 0) s = s.split(hidden[i]).join(new Array(Math.min(hidden[i].length, 12) + 1).join("\u2022"));
    }
    return s;
  }
  function secret(el) { return password(el) || dotted(el); }
  function esc(s) { return window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^\w-]/g, "\\$&"); }
  function quoted(s) { return '"' + String(s).replace(/["\\]/g, "\\$&") + '"'; }
  function selectorFor(el) {
    if (el.id) return "#" + esc(el.id);
    var tag = el.tagName.toLowerCase();
    var testId = el.getAttribute("data-testid");
    if (testId) return tag + "[data-testid=" + quoted(testId) + "]";
    var named = el.getAttribute("name");
    if (named) return tag + "[name=" + quoted(named) + "]";
    var parts = [], node = el;
    while (node && node.nodeType === 1 && parts.length < 8) {
      if (node.id) { parts.unshift("#" + esc(node.id)); break; }
      var part = node.tagName.toLowerCase(), parent = node.parentElement;
      if (parent) {
        var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === node.tagName; });
        if (same.length > 1) part += ":nth-of-type(" + (same.indexOf(node) + 1) + ")";
      }
      parts.unshift(part);
      node = parent;
    }
    return parts.join(" > ");
  }
  var INPUT_ROLES = { button: "button", submit: "button", reset: "button", image: "button", checkbox: "checkbox",
    radio: "radio", range: "slider", search: "searchbox", number: "spinbutton" };
  var TAG_ROLES = { button: "button", textarea: "textbox", option: "option", nav: "navigation", main: "main",
    header: "banner", footer: "contentinfo", form: "form", dialog: "dialog", ul: "list", ol: "list", li: "listitem",
    table: "table", tr: "row", td: "cell", th: "columnheader", summary: "button", progress: "progressbar",
    h1: "heading", h2: "heading", h3: "heading", h4: "heading", h5: "heading", h6: "heading" };
  function roleOf(el) {
    var explicit = el.getAttribute("role");
    if (explicit) return explicit.split(/\s+/)[0].toLowerCase();
    var tag = el.tagName.toLowerCase();
    if (tag === "a" || tag === "area") return el.hasAttribute("href") ? "link" : null;
    if (tag === "input") {
      var type = (el.getAttribute("type") || "text").toLowerCase();
      return type === "hidden" ? null : INPUT_ROLES[type] || "textbox";
    }
    if (tag === "select") return el.multiple || el.size > 1 ? "listbox" : "combobox";
    if (tag === "img") return el.getAttribute("alt") === "" ? "presentation" : "img";
    if (TAG_ROLES[tag]) return TAG_ROLES[tag];
    if (el.isContentEditable && el.hasAttribute("contenteditable")) return "textbox";
    return null;
  }
  function nameOf(el) {
    var tag = el.tagName.toLowerCase(), name = norm(el.getAttribute("aria-label"));
    var by = el.getAttribute("aria-labelledby");
    if (!name && by) {
      name = norm(by.split(/\s+/).map(function (id) {
        var n = document.getElementById(id);
        return n ? n.innerText || n.textContent : "";
      }).join(" "));
    }
    if (!name && el.labels && el.labels.length) {
      name = norm(Array.prototype.map.call(el.labels, function (l) { return l.innerText || l.textContent; }).join(" "));
    }
    if (!name && tag === "input" && /^(button|submit|reset)$/.test((el.getAttribute("type") || "").toLowerCase())) name = norm(el.value);
    if (!name && (tag === "input" || tag === "textarea")) name = norm(el.getAttribute("placeholder"));
    if (!name && tag === "img") name = norm(el.getAttribute("alt"));
    if (!name && tag !== "input" && tag !== "textarea" && tag !== "select") name = norm(el.innerText);
    if (!name) name = norm(el.getAttribute("title")) || norm(el.getAttribute("name"));
    return scrub(name).slice(0, MAX_NAME);
  }
  function describe(el) {
    var r = el.getBoundingClientRect();
    return { tag: el.tagName.toLowerCase(), role: roleOf(el), name: nameOf(el), selector: selectorFor(el),
      x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) };
  }
  var INTERACTIVE = "a[href],button,input:not([type=hidden]),textarea,select,summary,[role],[tabindex],[contenteditable]";
  function tree() {
    var left = MAX_TREE;
    function walk(el, depth) {
      var out = [];
      for (var c = el.firstElementChild; c && left > 0 && depth < 40; c = c.nextElementSibling) {
        if (/^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT)$/.test(c.tagName)) continue;
        if (getComputedStyle(c).display === "none") continue;
        var role = roleOf(c);
        if (role && role !== "presentation" && role !== "none" && shown(c)) {
          left--;
          var node = { role: role, name: nameOf(c) };
          var kids = walk(c, depth + 1);
          if (kids.length) node.children = kids;
          out.push(node);
        } else {
          out = out.concat(walk(c, depth + 1));
        }
      }
      return out;
    }
    return { role: "document", name: scrub(norm(document.title)), children: document.body ? walk(document.body, 0) : [] };
  }

  // Locators.
  function split(s) {
    var parts = [], depth = 0, quote = null, start = 0;
    for (var i = 0; i < s.length; i++) {
      var ch = s[i];
      if (quote) { if (ch === "\\") i++; else if (ch === quote) quote = null; continue; }
      if (ch === '"' || ch === "'") quote = ch;
      else if (ch === "[" || ch === "(") depth++;
      else if (ch === "]" || ch === ")") depth--;
      else if (ch === ">" && s[i + 1] === ">" && depth === 0) { parts.push(s.slice(start, i).trim()); i++; start = i + 1; }
    }
    if (quote) throw new Fail("invalid", "Unterminated quote in " + JSON.stringify(s));
    parts.push(s.slice(start).trim());
    return parts;
  }
  function unquote(v) {
    v = String(v).trim();
    var m = /^(["'])([\s\S]*)\1\s*([is]?)$/.exec(v);
    return m ? { text: m[2].replace(/\\(.)/g, "$1"), exact: m[3] !== "i" } : { text: v, exact: false };
  }
  function matches(actual, want) {
    actual = norm(actual).toLowerCase();
    var w = norm(want.text).toLowerCase();
    return want.exact ? actual === w : actual.indexOf(w) >= 0;
  }
  function textOf(el) { return el.tagName === "INPUT" ? el.value : el.innerText !== undefined ? el.innerText : el.textContent; }
  function each(scopes, fn) {
    scopes.forEach(function (scope) {
      var all = scope.querySelectorAll("*");
      for (var i = 0; i < all.length; i++) fn(all[i]);
    });
  }
  function byCss(scopes, css) {
    var out = [];
    scopes.forEach(function (scope) {
      try { out.push.apply(out, scope.querySelectorAll(css)); } catch (e) { throw new Fail("invalid", e.message); }
    });
    return out;
  }
  function byText(scopes, raw) {
    var want = unquote(raw), out = [];
    if (!want.text) throw new Fail("invalid", "text= needs the text to look for");
    each(scopes, function (el) {
      if (/^(SCRIPT|STYLE|HEAD|TITLE|NOSCRIPT)$/.test(el.tagName) || !matches(textOf(el), want)) return;
      // The innermost element that says it.
      for (var c = el.firstElementChild; c; c = c.nextElementSibling) if (matches(textOf(c), want)) return;
      out.push(el);
    });
    return out;
  }
  function byRole(scopes, raw) {
    var m = /^([a-zA-Z]+)\s*([\s\S]*)$/.exec(raw.trim());
    if (!m) throw new Fail("invalid", "role= wants a role, as in role=button[name=\"Send\"]");
    var role = m[1].toLowerCase(), rest = m[2], name = null, level = null;
    var attr = /^\[\s*([a-zA-Z-]+)\s*(?:=\s*("(?:[^"\\]|\\.)*"\s*[is]?|'(?:[^'\\]|\\.)*'\s*[is]?|\/(?:[^\/\\]|\\.)*\/[a-z]*|[^\]]*?))?\s*\]\s*/;
    while (rest.length) {
      var a = attr.exec(rest);
      if (!a) throw new Fail("invalid", "Could not read " + JSON.stringify(rest) + " after role=" + role);
      rest = rest.slice(a[0].length);
      if (a[1] === "name" && a[2] !== undefined) {
        var rx = /^\/([\s\S]*)\/([a-z]*)$/.exec(a[2]);
        if (rx) {
          var re;
          try { re = new RegExp(rx[1], rx[2]); } catch (e) { throw new Fail("invalid", e.message); }
          name = function (s) { return re.test(s); };
        } else {
          var want = unquote(a[2]);
          name = function (s) { return matches(s, want); };
        }
      } else if (a[1] === "level") {
        level = parseInt(a[2], 10);
      }
    }
    var out = [];
    each(scopes, function (el) {
      if (roleOf(el) !== role) return;
      if (level !== null && el.tagName !== "H" + level && el.getAttribute("aria-level") !== String(level)) return;
      if (name && !name(nameOf(el))) return;
      out.push(el);
    });
    return out;
  }
  function byXpath(scopes, xpath) {
    var out = [];
    scopes.forEach(function (scope) {
      var r;
      try { r = document.evaluate(xpath, scope, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null); }
      catch (e) { throw new Fail("invalid", e.message); }
      for (var i = 0; i < r.snapshotLength; i++) if (r.snapshotItem(i).nodeType === 1) out.push(r.snapshotItem(i));
    });
    return out;
  }
  var ENGINES = { css: 1, text: 1, role: 1, xpath: 1, nth: 1, id: 1, "data-testid": 1 };
  function locate(locator) {
    var els = null, scopes = [document];
    split(locator).forEach(function (part) {
      if (!part) throw new Fail("invalid", "An empty part in " + JSON.stringify(locator));
      var m = /^([a-zA-Z-]+)\s*=\s*([\s\S]*)$/.exec(part);
      var engine = m && m[1].toLowerCase(), body = m ? m[2] : part;
      if (m && !ENGINES[engine]) throw new Fail("invalid", "Unknown selector engine " + JSON.stringify(m[1]));
      if (!engine) engine = /^(\/|\.\.|\()/.test(part) ? "xpath" : /^["']/.test(part) ? "text" : "css";
      if (engine === "nth") {
        var n = parseInt(body, 10);
        if (isNaN(n)) throw new Fail("invalid", "nth= wants a number");
        var pick = (els || [])[n < 0 ? (els || []).length + n : n];
        els = pick ? [pick] : [];
      } else if (engine === "css") els = byCss(scopes, body);
      else if (engine === "text") els = byText(scopes, body);
      else if (engine === "role") els = byRole(scopes, body);
      else if (engine === "xpath") els = byXpath(scopes, body);
      else if (engine === "id") els = byCss(scopes, "#" + esc(unquote(body).text));
      else els = byCss(scopes, "[data-testid=" + quoted(unquote(body).text) + "]");
      scopes = els;
    });
    return (els || []).filter(function (el, i, all) { return all.indexOf(el) === i; });
  }
  function candidates(a) {
    if (a.locator) return locate(a.locator);
    return byCss([document], a.selector);
  }
  // The first match a user could act on: shown, and enabled when it must be.
  function find(a, enabled) {
    var els = candidates(a);
    for (var i = 0; i < els.length; i++) if (shown(els[i]) && (!enabled || !disabled(els[i]))) return els[i];
    throw new Fail("missing");
  }
  function centre(el) {
    var before = el.getBoundingClientRect();
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    var r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, scrolled: r.top !== before.top || r.left !== before.left };
  }
  function armClick(el) {
    state.clicked = null;
    if (state.clickListener) document.removeEventListener("click", state.clickListener, true);
    state.clickListener = function (e) {
      state.clicked = { trusted: e.isTrusted, hit: !el || el === e.target || el.contains(e.target) };
      document.removeEventListener("click", state.clickListener, true);
      state.clickListener = null;
    };
    document.addEventListener("click", state.clickListener, true);
  }
  function mouse(el, type, x, y) {
    el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, composed: true, view: window,
      clientX: x, clientY: y, button: 0, buttons: type === "mousedown" ? 1 : 0 }));
  }
  function setValue(el, value) {
    var proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }
  function valueOf(el) { return textField(el) ? el.value : el.innerText; }
  function caretToEnd(el) {
    if (textField(el)) {
      try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
      return;
    }
    var range = document.createRange();
    range.selectNodeContents(el);
    range.collapse(false);
    var sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }
  function selectAll(el) {
    if (textField(el)) { try { el.select(); } catch (e) {} return; }
    var range = document.createRange();
    range.selectNodeContents(el);
    var sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }
  var KEYS = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, Space: 32, " ": 32, ArrowLeft: 37, ArrowUp: 38,
    ArrowRight: 39, ArrowDown: 40, Home: 36, End: 35, PageUp: 33, PageDown: 34 };

  var ops = {
    snapshot: function () {
      var found = secrets();
      hidden = found.texts;
      var els = Array.prototype.slice.call(document.querySelectorAll(INTERACTIVE)).filter(shown);
      var failed = [];
      try {
        performance.getEntriesByType("resource").forEach(function (e) {
          var status = typeof e.responseStatus === "number" ? e.responseStatus : 0;
          var sameOrigin = e.name.indexOf(location.origin) === 0;
          if (status >= 400 || (status === 0 && sameOrigin && e.transferSize === 0 && e.decodedBodySize === 0 && e.duration > 0 && e.responseEnd === 0)) {
            failed.push({ url: e.name, method: "GET", status: status || null, failed: status === 0,
              timestamp: new Date(performance.timeOrigin + e.startTime).toISOString() });
          }
        });
      } catch (e) {}
      return { url: location.href, title: scrub(document.title), loading: document.readyState !== "complete",
        visibleText: scrub(document.body ? document.body.innerText : "").slice(0, MAX_TEXT),
        interactiveElements: els.slice(0, MAX_ELEMENTS).map(describe), accessibilityTree: tree(),
        networkEntries: failed, viewport: { width: innerWidth, height: innerHeight }, secrets: found.print };
    },
    // What snapshot's `secrets` says, now: a snapshot whose secrets changed
    // while it was taken cannot say it hid them.
    secrets: function () { return { print: secrets().print }; },
    // Scrolls the click's target to the middle of the view and listens for the click.
    clickTarget: function (a) {
      if (a.x !== undefined) {
        armClick(null);
        return { x: a.x, y: a.y, scrolled: false };
      }
      var el = find(a, true);
      hidden = secrets().texts;
      var at = centre(el);
      armClick(el);
      state.target = el;
      return { x: at.x, y: at.y, scrolled: at.scrolled, label: nameOf(el) };
    },
    clicked: function () { return state.clicked; },
    // What a user click would do, for a page that cannot take real input.
    clickScript: function (a) {
      var el = a.x !== undefined ? document.elementFromPoint(a.x, a.y) : state.target;
      if (!el) throw new Fail("missing");
      var r = el.getBoundingClientRect(), x = a.x !== undefined ? a.x : r.left + r.width / 2, y = a.y !== undefined ? a.y : r.top + r.height / 2;
      mouse(el, "mousedown", x, y);
      if (el.focus) el.focus();
      mouse(el, "mouseup", x, y);
      if (el.click) el.click(); else mouse(el, "click", x, y);
      return { x: x, y: y };
    },
    type: function (a) {
      var el;
      if (a.selector || a.locator) {
        el = find(a, false);
        if (!editable(el)) throw new Fail("notEditable");
      } else {
        el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        if (!editable(el)) throw new Fail("notEditable");
      }
      el.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
      if (document.activeElement !== el) el.focus();
      if (a.clear) selectAll(el); else caretToEnd(el);
      var before = valueOf(el);
      var inserted = false;
      try { inserted = document.execCommand("insertText", false, a.text); } catch (e) {}
      if (!inserted || (valueOf(el) === before && a.text.length)) {
        if (textField(el)) setValue(el, (a.clear ? "" : el.value) + a.text);
        else { if (a.clear) el.textContent = ""; el.textContent += a.text; el.dispatchEvent(new Event("input", { bubbles: true })); }
      }
      hidden = secrets().texts;
      var r = el.getBoundingClientRect();
      return { value: secret(el) ? "" : scrub(valueOf(el)).slice(0, 2000), x: r.left + r.width / 2, y: r.top + r.height / 2, label: nameOf(el) };
    },
    armKey: function () {
      state.key = null;
      if (state.keyListener) document.removeEventListener("keydown", state.keyListener, true);
      state.keyListener = function (e) {
        state.key = { key: e.key, trusted: e.isTrusted };
        document.removeEventListener("keydown", state.keyListener, true);
        state.keyListener = null;
      };
      document.addEventListener("keydown", state.keyListener, true);
      return true;
    },
    key: function () { return state.key; },
    keyScript: function (a) {
      var el = document.activeElement || document.body;
      var init = { key: a.key, code: a.key.length === 1 ? "Key" + a.key.toUpperCase() : a.key, keyCode: KEYS[a.key] || a.key.toUpperCase().charCodeAt(0),
        bubbles: true, cancelable: true, composed: true, altKey: a.alt, ctrlKey: a.control, metaKey: a.meta, shiftKey: a.shift };
      el.dispatchEvent(new KeyboardEvent("keydown", init));
      el.dispatchEvent(new KeyboardEvent("keyup", init));
      return true;
    },
    scroll: function (a) {
      var dx = a.deltaX || 0, dy = a.deltaY || 0;
      if (a.selector || a.locator) {
        var el = find(a, false);
        el.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
        if (dx || dy) el.scrollBy({ left: dx, top: dy, behavior: "instant" });
        var r = el.getBoundingClientRect();
        return { scrollX: el.scrollLeft, scrollY: el.scrollTop, x: r.left + r.width / 2, y: r.top + r.height / 2 };
      }
      window.scrollBy({ left: dx, top: dy, behavior: "instant" });
      return { scrollX: window.scrollX, scrollY: window.scrollY };
    },
    // Whether everything the wait names is true at once.
    check: function (a) {
      if (a.urlIncludes && location.href.indexOf(a.urlIncludes) < 0) return false;
      if (a.text && (!document.body || document.body.innerText.indexOf(a.text) < 0)) return false;
      if (a.selector || a.locator) {
        if (!candidates(a).some(shown)) return false;
      }
      return true;
    },
    ready: function () { return { readyState: document.readyState, url: location.href }; }
  };

  try {
    var value = ops[name](args || {});
    return JSON.stringify({ ok: true, value: value === undefined ? null : value });
  } catch (e) {
    if (e instanceof Fail) return JSON.stringify({ ok: false, kind: e.kind, reason: e.reason || null });
    return JSON.stringify({ ok: false, kind: "error", reason: String(e && e.message || e) });
  }
})
