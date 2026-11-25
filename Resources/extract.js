// Runs in the loader web view's isolated content world, after Readability.js.
// html: the page's outerHTML grabbed from a browser tab, or null to read the loaded page.
function __twoupExtract(html, base) {
  var doc;
  if (html) {
    doc = new DOMParser().parseFromString(html, "text/html");
    var head = doc.head || doc.documentElement;
    var b = doc.createElement("base");
    b.href = base;
    head.insertBefore(b, head.firstChild);
  } else {
    doc = document.cloneNode(true);
    if (base && (!doc.baseURI || doc.baseURI === "about:blank")) {
      var fallbackHead = doc.head || doc.documentElement;
      var fallbackBase = doc.createElement("base");
      fallbackBase.href = base;
      fallbackHead.insertBefore(fallbackBase, fallbackHead.firstChild);
    }
  }

  // Keep #hash anchor/footnote links relative instead of letting Readability
  // rewrite them against baseURI when baseURI != documentURI (e.g. DOMParser docs).
  var hashHrefs = null;
  if (doc.baseURI && doc.documentURI !== doc.baseURI) {
    try {
      Object.defineProperty(doc, "documentURI", {
        value: doc.baseURI,
        configurable: true
      });
    } catch (e) {}
  }
  if (doc.documentURI !== doc.baseURI) {
    hashHrefs = Object.create(null);
    doc.querySelectorAll("a[href^='#']").forEach(function (a) {
      var raw = a.getAttribute("href");
      if (raw && raw.charAt(0) === "#") {
        try {
          hashHrefs[new URL(raw, doc.baseURI).href] = raw;
        } catch (e) {}
      }
    });
  }

  // Promote lazy-loaded <picture><source> srcsets so responsive images survive extraction.
  doc.querySelectorAll("picture source").forEach(function (source) {
    var lazySet = source.getAttribute("data-srcset") ||
      source.getAttribute("data-lazy-srcset") ||
      source.getAttribute("data-src");
    if (lazySet && !source.getAttribute("srcset")) {
      source.setAttribute("srcset", lazySet);
    }
  });

  // Promote lazy-loaded image sources so they survive extraction.
  doc.querySelectorAll("img").forEach(function (img) {
    var src = img.getAttribute("src") || "";
    var isPlaceholder = !src || src.indexOf("data:") === 0 || src === "about:blank";
    var lazy = img.getAttribute("data-src") || img.getAttribute("data-lazy-src") ||
      img.getAttribute("data-original") || img.getAttribute("data-url") ||
      img.getAttribute("data-actualsrc") || img.getAttribute("data-hi-res-src");
    if (lazy && isPlaceholder) img.setAttribute("src", lazy);
    var lazySet = img.getAttribute("data-srcset") || img.getAttribute("data-lazy-srcset");
    if (lazySet && !img.getAttribute("srcset")) img.setAttribute("srcset", lazySet);

    // If an <img> inside <picture> still lacks a usable src, fall back to its <source srcset>.
    var currentSrc = img.getAttribute("src") || "";
    if (!currentSrc || currentSrc.indexOf("data:") === 0 || currentSrc === "about:blank") {
      var picture = img.closest && img.closest("picture");
      if (picture) {
        var sources = picture.querySelectorAll("source[srcset]");
        for (var i = 0; i < sources.length; i++) {
          var firstCandidate = (sources[i].getAttribute("srcset") || "").split(",")[0].trim().split(/\s+/)[0];
          if (firstCandidate && firstCandidate.indexOf("data:") !== 0) {
            img.setAttribute("src", firstCandidate);
            break;
          }
        }
      }
    }
  });

  var article = new Readability(doc).parse();
  if (!article) return null;

  var content = article.content || "";
  if (hashHrefs && content) {
    var tmp = doc.createElement("div");
    tmp.innerHTML = content;
    tmp.querySelectorAll("a[href]").forEach(function (a) {
      var href = a.getAttribute("href");
      if (href && hashHrefs[href]) a.setAttribute("href", hashHrefs[href]);
    });
    content = tmp.innerHTML;
  }

  return {
    title: article.title || "",
    byline: article.byline || "",
    site: article.siteName || "",
    lang: article.lang || "",
    dir: article.dir || "",
    content: content
  };
}
