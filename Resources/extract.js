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
  }

  // Promote lazy-loaded image sources so they survive extraction.
  doc.querySelectorAll("img").forEach(function (img) {
    var src = img.getAttribute("src") || "";
    var lazy = img.getAttribute("data-src") || img.getAttribute("data-lazy-src") ||
      img.getAttribute("data-original") || img.getAttribute("data-url");
    if (lazy && (!src || src.indexOf("data:") === 0)) img.setAttribute("src", lazy);
    var lazySet = img.getAttribute("data-srcset") || img.getAttribute("data-lazy-srcset");
    if (lazySet && !img.getAttribute("srcset")) img.setAttribute("srcset", lazySet);
  });

  var article = new Readability(doc).parse();
  if (!article) return null;
  return {
    title: article.title || "",
    byline: article.byline || "",
    site: article.siteName || "",
    lang: article.lang || "",
    content: article.content || ""
  };
}
