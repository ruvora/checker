// Self-contained: Chrome serializes this function into the user-selected tab.
function collectCheckerPage() {
  const root = document.querySelector('main, article, [role="main"]') || document.body;
  const blocked = 'script,style,noscript,nav,header,footer,input,textarea,select,button,[hidden],[aria-hidden="true"],[contenteditable="true"],[role="textbox"]';
  const cache = new WeakMap();
  const all = [];
  const visible = [];
  let textSize = 0;
  let visibleSize = 0;
  let visited = 0;
  if (root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    while (walker.nextNode() && visited++ < 20000) {
      const node = walker.currentNode;
      const text = node.textContent.replace(/\s+/g, ' ').trim();
      const parent = node.parentElement;
      if (!text || !parent) continue;
      let info = cache.get(parent);
      if (!info) {
        const rect = parent.getBoundingClientRect();
        const style = getComputedStyle(parent);
        info = {readable: !parent.closest(blocked) && rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none',
          visible: rect.bottom >= 0 && rect.top <= innerHeight && rect.right >= 0 && rect.left <= innerWidth};
        cache.set(parent, info);
      }
      if (!info.readable) continue;
      if (textSize < 24000) { all.push(text); textSize += text.length + 1; }
      if (info.visible && visibleSize < 12000) { visible.push(text); visibleSize += text.length + 1; }
    }
  }
  return {sourceURL: location.href, title: document.title.slice(0, 1000),
    text: all.join('\n').slice(0, 24000), visibleText: visible.join('\n').slice(0, 12000),
    selectionText: (getSelection()?.toString() || '').slice(0, 6000),
    description: (document.querySelector('meta[name="description"]')?.content || '').slice(0, 1600)};
}
