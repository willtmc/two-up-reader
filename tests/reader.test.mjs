import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

const readerHtml = fs.readFileSync(path.join(ROOT, "Resources/reader.html"), "utf8");
const extractJs = fs.readFileSync(path.join(ROOT, "Resources/extract.js"), "utf8");
const readabilityJs = fs.readFileSync(path.join(ROOT, "Resources/Readability.js"), "utf8");

function extractInlineScript(html) {
  const match = html.match(/<script>([\s\S]*?)<\/script>/);
  assert.ok(match, "reader.html must contain an inline <script> block");
  return match[1];
}

// ---------------------------------------------------------------------------
// Minimal zero-dependency HTML parser & DOM stub for testing sanitize() and
// __twoupExtract() directly against production JS without external packages.
// ---------------------------------------------------------------------------

const VOID_TAGS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input",
  "link", "meta", "param", "source", "track", "wbr",
]);
const RAW_TEXT_TAGS = new Set(["script", "style"]);
const HTML_NS = "http://www.w3.org/1999/xhtml";
const SVG_NS = "http://www.w3.org/2000/svg";
const MATH_NS = "http://www.w3.org/1998/Math/MathML";

function decodeEntities(str) {
  return str.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi, (_, ent) => {
    const lower = ent.toLowerCase();
    if (lower === "amp") return "&";
    if (lower === "lt") return "<";
    if (lower === "gt") return ">";
    if (lower === "quot") return '"';
    if (lower === "apos") return "'";
    if (lower.startsWith("#x")) return String.fromCodePoint(parseInt(lower.slice(2), 16));
    if (lower.startsWith("#")) return String.fromCodePoint(parseInt(lower.slice(1), 10));
    return `&${ent};`;
  });
}

function escapeAttr(val) {
  return String(val).replace(/&/g, "&amp;").replace(/"/g, "&quot;");
}

class MiniNode {
  constructor(nodeType, ownerDocument) {
    this.nodeType = nodeType;
    this.ownerDocument = ownerDocument;
    this.parentNode = null;
    this.childNodes = [];
  }
  get firstChild() {
    return this.childNodes[0] || null;
  }
  appendChild(child) {
    if (child.parentNode) child.remove();
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }
  insertBefore(child, ref) {
    if (child.parentNode) child.remove();
    child.parentNode = this;
    const idx = ref ? this.childNodes.indexOf(ref) : -1;
    if (idx === -1) this.childNodes.push(child);
    else this.childNodes.splice(idx, 0, child);
    return child;
  }
  remove() {
    if (!this.parentNode) return;
    const idx = this.parentNode.childNodes.indexOf(this);
    if (idx >= 0) this.parentNode.childNodes.splice(idx, 1);
    this.parentNode = null;
  }
  get textContent() {
    return this.childNodes.map((c) => (c.nodeType === 3 ? c.data : c.textContent)).join("");
  }
  querySelectorAll(selector) {
    const groups = selector.split(",").map((s) => s.trim()).filter(Boolean);
    const out = [];
    const visit = (node) => {
      for (const child of node.childNodes) {
        if (child.nodeType === 1) {
          if (groups.some((sel) => matchesSelector(child, sel))) out.push(child);
          visit(child);
        }
      }
    };
    visit(this);
    return out;
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
  get innerHTML() {
    return this.childNodes.map(serializeNode).join("");
  }
  set innerHTML(html) {
    this.childNodes = [];
    const parsed = parseHTMLFragment(String(html), this.ownerDocument);
    for (const child of [...parsed.childNodes]) this.appendChild(child);
  }
}

class MiniText extends MiniNode {
  constructor(data, ownerDocument) {
    super(3, ownerDocument);
    this.data = data;
  }
}

class MiniElement extends MiniNode {
  constructor(tagName, namespaceURI, ownerDocument) {
    super(1, ownerDocument);
    this._localName = tagName.toLowerCase();
    this.tagName = namespaceURI === HTML_NS ? tagName.toUpperCase() : tagName;
    this.namespaceURI = namespaceURI;
    this._attrs = [];
  }
  get attributes() {
    return this._attrs.map((a) => ({ name: a.name, value: a.value }));
  }
  getAttribute(name) {
    const lower = name.toLowerCase();
    const found = this._attrs.find((a) => a.name.toLowerCase() === lower);
    return found ? found.value : null;
  }
  setAttribute(name, value) {
    const lower = name.toLowerCase();
    const str = String(value);
    const found = this._attrs.find((a) => a.name.toLowerCase() === lower);
    if (found) found.value = str;
    else this._attrs.push({ name, value: str });
  }
  removeAttribute(name) {
    const lower = name.toLowerCase();
    this._attrs = this._attrs.filter((a) => a.name.toLowerCase() !== lower);
  }
  hasAttribute(name) {
    return this.getAttribute(name) !== null;
  }
  get href() {
    return this.getAttribute("href") || "";
  }
  set href(v) {
    this.setAttribute("href", v);
  }
  closest(tagSelector) {
    const target = tagSelector.toLowerCase();
    let cur = this;
    while (cur && cur.nodeType === 1) {
      if (cur._localName === target) return cur;
      cur = cur.parentNode;
    }
    return null;
  }
}

function matchesSimple(el, part) {
  if (part === "*") return true;
  const m = part.match(/^([a-z0-9_-]*)(?:\[([a-z0-9_:-]+)(?:(\^?=)['"]([^'"]*)['"])?\])?$/i);
  if (!m) return false;
  const [, tag, attr, op, val] = m;
  if (tag && el._localName !== tag.toLowerCase()) return false;
  if (attr) {
    const actual = el.getAttribute(attr);
    if (actual === null) return false;
    if (op === "=" && actual !== val) return false;
    if (op === "^=" && !actual.startsWith(val)) return false;
  }
  return true;
}

function matchesSelector(el, selector) {
  const parts = selector.trim().split(/\s+/);
  if (!matchesSimple(el, parts[parts.length - 1])) return false;
  let idx = parts.length - 2;
  let cur = el.parentNode;
  while (idx >= 0) {
    let matched = false;
    while (cur && cur.nodeType === 1) {
      if (matchesSimple(cur, parts[idx])) {
        matched = true;
        cur = cur.parentNode;
        break;
      }
      cur = cur.parentNode;
    }
    if (!matched) return false;
    idx--;
  }
  return true;
}

function serializeNode(node) {
  if (node.nodeType === 3) return node.data;
  const tag = node._localName;
  const attrs = node._attrs.map((a) => ` ${a.name}="${escapeAttr(a.value)}"`).join("");
  if (VOID_TAGS.has(tag)) return `<${tag}${attrs}>`;
  return `<${tag}${attrs}>${node.childNodes.map(serializeNode).join("")}</${tag}>`;
}

function parseAttributes(attrText) {
  const attrs = [];
  const re = /([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
  let m;
  while ((m = re.exec(attrText)) !== null) {
    const name = m[1];
    const rawVal = m[2] ?? m[3] ?? m[4] ?? "";
    attrs.push({ name, value: decodeEntities(rawVal) });
  }
  return attrs;
}

function parseHTMLFragment(html, ownerDocument) {
  const root = new MiniNode(11, ownerDocument);
  const stack = [root];
  let i = 0;

  while (i < html.length) {
    const parent = stack[stack.length - 1];
    const lt = html.indexOf("<", i);
    if (lt === -1) {
      parent.appendChild(new MiniText(html.slice(i), ownerDocument));
      break;
    }
    if (lt > i) {
      parent.appendChild(new MiniText(html.slice(i, lt), ownerDocument));
    }
    if (html.startsWith("<!--", lt)) {
      const end = html.indexOf("-->", lt + 4);
      i = end === -1 ? html.length : end + 3;
      continue;
    }
    if (html.startsWith("<!", lt)) {
      const end = html.indexOf(">", lt + 2);
      i = end === -1 ? html.length : end + 1;
      continue;
    }
    if (html[lt + 1] === "/") {
      const end = html.indexOf(">", lt + 2);
      const closeTag = (end === -1 ? html.slice(lt + 2) : html.slice(lt + 2, end)).trim().toLowerCase();
      for (let k = stack.length - 1; k >= 1; k--) {
        if (stack[k]._localName === closeTag) {
          stack.length = k;
          break;
        }
      }
      i = end === -1 ? html.length : end + 1;
      continue;
    }

    const gt = html.indexOf(">", lt + 1);
    if (gt === -1) {
      parent.appendChild(new MiniText(html.slice(lt), ownerDocument));
      break;
    }
    const inside = html.slice(lt + 1, gt);
    const selfClosing = inside.endsWith("/");
    const cleanInside = selfClosing ? inside.slice(0, -1).trim() : inside.trim();
    const spaceIdx = cleanInside.search(/\s/);
    const rawTag = spaceIdx === -1 ? cleanInside : cleanInside.slice(0, spaceIdx);
    const attrText = spaceIdx === -1 ? "" : cleanInside.slice(spaceIdx + 1);
    const lowerTag = rawTag.toLowerCase();

    const parentNS = parent.nodeType === 1 ? parent.namespaceURI : HTML_NS;
    let ns = parentNS;
    if (lowerTag === "svg") ns = SVG_NS;
    else if (lowerTag === "math") ns = MATH_NS;

    const el = new MiniElement(rawTag, ns, ownerDocument);
    for (const a of parseAttributes(attrText)) {
      el.setAttribute(a.name, a.value);
    }
    parent.appendChild(el);
    i = gt + 1;

    if (RAW_TEXT_TAGS.has(lowerTag) && !selfClosing) {
      const closeRe = new RegExp(`</${lowerTag}\\s*>`, "i");
      const rest = html.slice(i);
      const closeMatch = closeRe.exec(rest);
      if (closeMatch) {
        if (closeMatch.index > 0) {
          el.appendChild(new MiniText(rest.slice(0, closeMatch.index), ownerDocument));
        }
        i += closeMatch.index + closeMatch[0].length;
      } else {
        el.appendChild(new MiniText(rest, ownerDocument));
        i = html.length;
      }
      continue;
    }

    if (!selfClosing && !VOID_TAGS.has(lowerTag)) {
      stack.push(el);
    }
  }
  return root;
}

function createMiniDocument(html = "", { documentURI = "about:blank", configurableDocumentURI = true } = {}) {
  const doc = new MiniNode(9, null);
  doc.ownerDocument = doc;
  doc._defaultBaseURI = documentURI;
  Object.defineProperty(doc, "documentURI", {
    value: documentURI,
    writable: false,
    configurable: configurableDocumentURI,
  });
  Object.defineProperty(doc, "baseURI", {
    get() {
      const baseEl = doc.querySelector("base[href]");
      return baseEl ? baseEl.getAttribute("href") : doc._defaultBaseURI;
    },
    configurable: true,
  });
  doc.createElement = (tag) => {
    const lower = tag.toLowerCase();
    if (lower === "template") {
      const tmpl = new MiniElement("template", HTML_NS, doc);
      tmpl.content = new MiniNode(11, doc);
      Object.defineProperty(tmpl, "innerHTML", {
        get() { return tmpl.content.innerHTML; },
        set(v) { tmpl.content.innerHTML = v; },
      });
      return tmpl;
    }
    return new MiniElement(tag, HTML_NS, doc);
  };

  if (html) {
    const frag = parseHTMLFragment(html, doc);
    for (const child of [...frag.childNodes]) doc.appendChild(child);
  }
  const htmlEl = doc.querySelector("html") || doc.appendChild(new MiniElement("html", HTML_NS, doc));
  const headEl = htmlEl.querySelector("head") || htmlEl.insertBefore(new MiniElement("head", HTML_NS, doc), htmlEl.firstChild);
  doc.documentElement = htmlEl;
  doc.head = headEl;
  return doc;
}

// ---------------------------------------------------------------------------
// 1. JS Syntax Checks
// ---------------------------------------------------------------------------

test("JS assets and inline reader.html script parse cleanly", () => {
  assert.doesNotThrow(() => new vm.Script(extractJs, { filename: "Resources/extract.js" }));
  assert.doesNotThrow(() => new vm.Script(readabilityJs, { filename: "Resources/Readability.js" }));

  const inlineScript = extractInlineScript(readerHtml);
  assert.match(inlineScript, /\/\*__TWOUP_DATA__\*\//, "inline script must retain /*__TWOUP_DATA__*/ marker");
  assert.doesNotThrow(() => new vm.Script(inlineScript, { filename: "Resources/reader.html#<script>" }));
});

// ---------------------------------------------------------------------------
// 2. Readability.js version & @graph JSON-LD fix
// ---------------------------------------------------------------------------

test("Readability.js is @mozilla/readability v0.6.0 with @graph arrow-function fix", () => {
  assert.match(readabilityJs, /@mozilla\/readability\s+v?0\.6\.0/, "expected @mozilla/readability 0.6.0 header");
  assert.match(
    readabilityJs,
    /parsed\["@graph"\]\.find\(\s*(?:\(?it\)?\s*=>)/,
    "@graph.find must use an arrow function so this.REGEXPS stays bound"
  );

  // Execute _getJSONLD on a mock document with a JSON-LD @graph Article node.
  const ctx = vm.createContext({});
  vm.runInContext(readabilityJs, ctx);
  const jsonLd = JSON.stringify({
    "@context": "https://schema.org",
    "@graph": [
      { "@type": "WebSite", name: "Example Times" },
      { "@type": "NewsArticle", headline: "Graph Article Title", author: { "@type": "Person", name: "Ada Lovelace" } },
    ],
  });
  const fakeScript = {
    getAttribute: (name) => (name === "type" ? "application/ld+json" : null),
    textContent: jsonLd,
  };
  const fakeDoc = {
    firstChild: {},
    documentElement: { tagName: "HTML" },
    getElementsByTagName: (tag) => (tag === "script" ? [fakeScript] : []),
  };
  const reader = new ctx.Readability(fakeDoc);
  const metadata = reader._getJSONLD(fakeDoc);
  assert.equal(metadata.title, "Graph Article Title");
  assert.equal(metadata.byline, "Ada Lovelace");
});

// ---------------------------------------------------------------------------
// 3. WCAG AA Contrast Ratios across Paper, Sepia, and Dark themes
// ---------------------------------------------------------------------------

function parseHexRGB(hex) {
  assert.match(hex, /^#[0-9a-fA-F]{6}$/, `expected 6-digit hex color, got ${hex}`);
  return [
    parseInt(hex.slice(1, 3), 16),
    parseInt(hex.slice(3, 5), 16),
    parseInt(hex.slice(5, 7), 16),
  ];
}

function mixSRGB(fg, bg, fgWeight) {
  return fg.map((v, idx) => v * fgWeight + bg[idx] * (1 - fgWeight));
}

function relativeLuminance(rgb) {
  const [r, g, b] = rgb.map((channel) => {
    const s = channel / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrastRatio(rgb1, rgb2) {
  const l1 = relativeLuminance(rgb1);
  const l2 = relativeLuminance(rgb2);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

function extractThemeVars(html, selectorRegex) {
  const match = html.match(selectorRegex);
  assert.ok(match, `missing CSS rule matching ${selectorRegex}`);
  const vars = {};
  for (const [, name, value] of match[1].matchAll(/--([\w-]+):\s*(#[0-9a-fA-F]{6})/g)) {
    vars[name] = parseHexRGB(value);
  }
  return vars;
}

test("reader.html theme tokens satisfy WCAG AA contrast across Paper, Sepia, and Dark", () => {
  const themes = {
    paper: extractThemeVars(readerHtml, /:root\s*\{([^}]+)\}/),
    sepia: extractThemeVars(readerHtml, /:root\[data-theme="sepia"\]\s*\{([^}]+)\}/),
    dark: extractThemeVars(readerHtml, /:root\[data-theme="dark"\]\s*\{([^}]+)\}/),
  };

  for (const [themeName, vars] of Object.entries(themes)) {
    for (const token of ["bg", "fg", "muted", "border", "link", "err"]) {
      assert.ok(vars[token], `${themeName} theme must define --${token}`);
    }
    // #panel input uses color-mix(in srgb, var(--fg) 5%, var(--bg))
    const inputSurface = mixSRGB(vars.fg, vars.bg, 0.05);

    for (const textToken of ["fg", "muted", "link", "err"]) {
      const vsBg = contrastRatio(vars[textToken], vars.bg);
      const vsInput = contrastRatio(vars[textToken], inputSurface);
      assert.ok(vsBg >= 4.5, `${themeName} --${textToken} vs --bg contrast ${vsBg.toFixed(2)} < 4.5`);
      assert.ok(vsInput >= 4.5, `${themeName} --${textToken} vs input surface contrast ${vsInput.toFixed(2)} < 4.5`);
    }

    const borderVsBg = contrastRatio(vars.border, vars.bg);
    const borderVsInput = contrastRatio(vars.border, inputSurface);
    assert.ok(borderVsBg >= 3.0, `${themeName} --border vs --bg contrast ${borderVsBg.toFixed(2)} < 3.0`);
    assert.ok(borderVsInput >= 3.0, `${themeName} --border vs input surface contrast ${borderVsInput.toFixed(2)} < 3.0`);
  }
});

// ---------------------------------------------------------------------------
// 4. reader.html structural & accessibility invariants
// ---------------------------------------------------------------------------

test("reader.html preserves structural, layout, and accessibility invariants", () => {
  assert.match(readerHtml, /#clip\s*\{[^}]*overflow:\s*clip;/, "#clip must use overflow: clip");
  assert.match(readerHtml, /<main\b[^>]*id="main"/, "must include <main> landmark");
  assert.match(readerHtml, /<article\b[^>]*id="book"/, "must include <article> landmark");
  assert.match(readerHtml, /role="tablist"/, "queue tabs must use role=\"tablist\"");
  assert.match(readerHtml, /role="dialog"[^>]*aria-modal="true"/, "help overlay must be an accessible modal dialog");
  assert.match(readerHtml, /aria-live="polite"/, "status/feedback regions must use aria-live=\"polite\"");
  assert.match(readerHtml, /@media\s*\(prefers-reduced-motion:\s*reduce\)/, "must honor prefers-reduced-motion");
  assert.match(readerHtml, /id="twoup-end"/, "must insert twoup-end sentinel");
  assert.match(readerHtml, /\$\("twoup-end"\)/, "layout() must query twoup-end sentinel");
  assert.match(readerHtml, /window\.twoupZoom\s*=/, "must expose window.twoupZoom");
  assert.match(readerHtml, /\bD\.focusUrl\b/, "must support D.focusUrl");
  assert.match(readerHtml, /\bD\.dir\b/, "must support D.dir");
});

// ---------------------------------------------------------------------------
// 5. Sanitizer security tests (executing verbatim sanitizer code from reader.html)
// ---------------------------------------------------------------------------

function loadSanitizer(articleUrl = "https://example.com/posts/article") {
  const inlineScript = extractInlineScript(readerHtml);
  const startIdx = inlineScript.indexOf("const STRIP_TAGS =");
  const endMarker = "return t.content;\n}";
  const endIdx = inlineScript.indexOf(endMarker, startIdx);
  assert.ok(startIdx >= 0 && endIdx > startIdx, "failed to locate sanitize() block in reader.html");

  const sanitizerCode = inlineScript.slice(startIdx, endIdx + endMarker.length);
  const doc = createMiniDocument("");
  const ctx = vm.createContext({
    D: { url: articleUrl },
    URL,
    document: doc,
  });
  vm.runInContext(`${sanitizerCode}\nthis.__exports = { sanitize, normalizeUrlAttr, sanitizeSrcset };`, ctx);
  return ctx.__exports;
}

test("sanitize() strips dangerous tags, DOM-clobbering IDs, foreign hrefs, control chars, SVG data URIs, and bad srcsets", () => {
  const { sanitize } = loadSanitizer("https://example.com/posts/1");

  // <script> stripped
  const scriptFrag = sanitize('<p>Hello</p><script>alert("xss")</script>');
  assert.equal(scriptFrag.querySelectorAll("script").length, 0);
  assert.equal(scriptFrag.innerHTML, "<p>Hello</p>");

  // Clobbering IDs (#end, #status, #twoup-end) stripped
  const idFrag = sanitize('<div id="end">a</div><div id="status">b</div><span id="twoup-end">c</span>');
  for (const el of idFrag.querySelectorAll("*")) {
    assert.equal(el.getAttribute("id"), null, `id must be stripped from <${el._localName}>`);
  }

  // <base> stripped
  const baseFrag = sanitize('<base href="https://evil.test/"><p>safe</p>');
  assert.equal(baseFrag.querySelectorAll("base").length, 0);
  assert.equal(baseFrag.innerHTML, "<p>safe</p>");

  // <svg><a xlink:href="javascript:alert(1)"> & foreign href/use/animate stripped
  const svgFrag = sanitize(
    '<svg><a xlink:href="javascript:alert(1)" href="https://evil.test">x</a><use href="#bad"></use><foreignObject><b>no</b></foreignObject></svg>'
  );
  const svgLink = svgFrag.querySelector("a");
  assert.ok(svgLink, "svg <a> remains without dangerous attributes");
  assert.equal(svgLink.getAttribute("xlink:href"), null, "xlink:href must be removed");
  assert.equal(svgLink.getAttribute("href"), null, "foreign namespace href must be removed");
  assert.equal(svgFrag.querySelectorAll("use,foreignobject").length, 0, "dangerous SVG elements must be stripped");

  // Control-character obfuscated javascript: URLs stripped
  const ctrlFrag = sanitize('<a href="\u0001javascript:alert(1)">bad1</a><a href="\t\njavascript:alert(2)">bad2</a><img src="\u0000javascript:alert(3)">');
  const [a1, a2] = ctrlFrag.querySelectorAll("a");
  assert.equal(a1.getAttribute("href"), null, "leading \\x01 javascript: href must be stripped");
  assert.equal(a2.getAttribute("href"), null, "whitespace-prefixed javascript: href must be stripped");
  assert.equal(ctrlFrag.querySelector("img").getAttribute("src"), null, "control-char javascript: src must be stripped");

  // data:image/svg+xml rejected on img src
  const svgDataFrag = sanitize(
    '<img src="data:image/svg+xml,<svg onload=alert(1)>"><img src="data:image/svg+xml;base64,PHN2Zz4=">'
  );
  for (const img of svgDataFrag.querySelectorAll("img")) {
    assert.equal(img.getAttribute("src"), null, "data:image/svg+xml must be rejected");
  }

  // Inline event handlers, style, ping, form/iframe stripped
  const attrFrag = sanitize('<p onclick="alert(1)" style="color:red" ping="https://evil.test">txt</p><iframe src="https://evil.test"></iframe>');
  assert.equal(attrFrag.querySelectorAll("iframe").length, 0);
  const p = attrFrag.querySelector("p");
  assert.equal(p.getAttribute("onclick"), null);
  assert.equal(p.getAttribute("style"), null);
  assert.equal(p.getAttribute("ping"), null);

  // srcset validation: mixed unsafe candidate rejects entire srcset; safe + relative candidates preserved & resolved
  const srcsetFrag = sanitize(
    '<img id="ok" srcset="https://cdn.example.com/a.jpg 1x, /img/b.jpg 2x">' +
    '<img srcset="https://cdn.example.com/a.jpg 1x, javascript:alert(1) 2x">' +
    '<img srcset="data:image/svg+xml;base64,PHN2Zz4= 1x">'
  );
  const imgs = srcsetFrag.querySelectorAll("img");
  assert.equal(imgs[0].getAttribute("srcset"), "https://cdn.example.com/a.jpg 1x, https://example.com/img/b.jpg 2x");
  assert.equal(imgs[1].getAttribute("srcset"), null, "srcset containing javascript: must be stripped");
  assert.equal(imgs[2].getAttribute("srcset"), null, "srcset containing data:image/svg+xml must be stripped");
});

test("sanitize() preserves safe https:, mailto:, #hash, resolved relative URLs, and safe raster data:image/png", () => {
  const { sanitize } = loadSanitizer("https://example.com/posts/1");

  const safeFrag = sanitize(
    '<a href="https://example.org/ok">ext</a>' +
    '<a href="mailto:hi@example.com">mail</a>' +
    '<a href="#fn-1">fn</a>' +
    '<a href="../about">rel</a>' +
    '<img src="data:image/png;base64,iVBORw0KGgo=" alt="pixel">' +
    '<img src="https://cdn.example.com/photo.webp">' +
    '<video poster="https://cdn.example.com/poster.jpg"></video>' +
    '<video poster="javascript:alert(1)"></video>'
  );

  const links = safeFrag.querySelectorAll("a");
  assert.equal(links[0].getAttribute("href"), "https://example.org/ok");
  assert.equal(links[1].getAttribute("href"), "mailto:hi@example.com");
  assert.equal(links[2].getAttribute("href"), "#fn-1");
  assert.equal(links[3].getAttribute("href"), "https://example.com/about");

  const imgs = safeFrag.querySelectorAll("img");
  assert.equal(imgs[0].getAttribute("src"), "data:image/png;base64,iVBORw0KGgo=");
  assert.equal(imgs[0].getAttribute("alt"), "pixel");
  assert.equal(imgs[1].getAttribute("src"), "https://cdn.example.com/photo.webp");

  const videos = safeFrag.querySelectorAll("video");
  assert.equal(videos[0].getAttribute("poster"), "https://cdn.example.com/poster.jpg");
  assert.equal(videos[1].getAttribute("poster"), null);
});

// ---------------------------------------------------------------------------
// 6. extract.js behavioral tests (#hash preservation, lazy <picture>, rtl dir)
// ---------------------------------------------------------------------------

test("extract.js preserves #hash anchors, promotes lazy <picture><source data-srcset>, and passes through rtl dir", () => {
  const base = "https://example.com/articles/arabic-post";
  const sampleHtml = `<!doctype html><html dir="rtl" lang="ar"><head><title>RTL</title></head><body>
    <article>
      <p>Intro <a href="#fn1">footnote</a> and <a href="https://other.test/page">external</a></p>
      <picture>
        <source data-srcset="https://cdn.example.com/hero-800.webp 800w, https://cdn.example.com/hero-1600.webp 1600w">
        <img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==">
      </picture>
      <img data-src="https://cdn.example.com/inline.jpg" src="about:blank">
    </article>
  </body></html>`;

  // Case 1: configurable documentURI -> extract.js aligns doc.documentURI to baseURI,
  // promotes <picture><source data-srcset>, falls back placeholder <img>, and passes through dir: "rtl".
  let capturedDoc = null;
  const ctx1 = vm.createContext({
    URL,
    DOMParser: class {
      parseFromString(html) {
        return createMiniDocument(html, { documentURI: "about:blank", configurableDocumentURI: true });
      }
    },
    Readability: class {
      constructor(doc) {
        this.doc = doc;
      }
      parse() {
        capturedDoc = this.doc;
        return {
          title: "RTL Essay",
          byline: "Author",
          siteName: "Example",
          lang: "ar",
          dir: "rtl",
          content: '<p><a href="#fn1">footnote</a></p>',
        };
      }
    },
  });
  vm.runInContext(extractJs, ctx1);
  const res1 = ctx1.__twoupExtract(sampleHtml, base);

  assert.equal(res1.dir, "rtl", "must pass through rtl dir");
  assert.equal(res1.lang, "ar");
  assert.equal(res1.title, "RTL Essay");
  assert.equal(capturedDoc.documentURI, base, "should set documentURI to baseURI when configurable");

  const sourceEl = capturedDoc.querySelector("picture source");
  assert.equal(
    sourceEl.getAttribute("srcset"),
    "https://cdn.example.com/hero-800.webp 800w, https://cdn.example.com/hero-1600.webp 1600w",
    "must promote <picture><source data-srcset> to srcset"
  );
  const imgs = capturedDoc.querySelectorAll("img");
  assert.equal(
    imgs[0].getAttribute("src"),
    "https://cdn.example.com/hero-800.webp",
    "placeholder <img> inside <picture> must fall back to promoted <source srcset>"
  );
  assert.equal(
    imgs[1].getAttribute("src"),
    "https://cdn.example.com/inline.jpg",
    "lazy <img data-src> must be promoted over about:blank"
  );

  // Case 2: non-configurable documentURI -> Readability rewrites #fn1 to full base#fn1,
  // and extract.js restores the relative #fn1 anchor in returned content.
  const ctx2 = vm.createContext({
    URL,
    DOMParser: class {
      parseFromString(html) {
        return createMiniDocument(html, { documentURI: "about:blank", configurableDocumentURI: false });
      }
    },
    Readability: class {
      constructor(doc) {
        this.doc = doc;
      }
      parse() {
        return {
          title: "Footnote Post",
          byline: "",
          siteName: "Example",
          lang: "en",
          dir: "rtl",
          content: `<p><a href="${base}#fn1">footnote</a> <a href="https://other.test/page">external</a></p>`,
        };
      }
    },
  });
  vm.runInContext(extractJs, ctx2);
  const res2 = ctx2.__twoupExtract(sampleHtml, base);

  assert.equal(res2.dir, "rtl");
  assert.match(res2.content, /href="#fn1"/, "must restore relative #fn1 anchor when documentURI != baseURI");
  assert.match(res2.content, /href="https:\/\/other\.test\/page"/, "must leave non-hash links untouched");
});
