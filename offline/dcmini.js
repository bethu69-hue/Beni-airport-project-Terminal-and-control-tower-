/* dcmini: a small offline runtime for the BENI prototype pages (.dc.html sources). */
(function () {
  'use strict';
  const SRC = window.__DC_SOURCES || {};
  const IMG = window.__DC_IMG || '';
  const HOLE = /\{\{\s*([^}]*?)\s*\}\}/g, WHOLE = /^\s*\{\{\s*([^}]*?)\s*\}\}\s*$/;
  class DCLogic {
    constructor(props) { this.props = props || {}; this.state = {}; this._inst = null; }
    setState(p, cb) { const n = typeof p === 'function' ? p(this.state, this.props) : p; if (n) this.state = Object.assign({}, this.state, n); if (this._inst) this._inst.schedule(cb); }
    forceUpdate(cb) { if (this._inst) this._inst.schedule(cb); }
  }
  const cache = {};
  function kids(n) { return n.tagName === 'TEMPLATE' ? n.content.childNodes : n.childNodes; }
  function compile(name) {
    if (cache[name]) return cache[name];
    let s = SRC[name]; if (s == null) throw new Error('Unknown component ' + name);
    s = s.replace(/<sc-for\b/g, '<template data-t="for"').replace(/<\/sc-for>/g, '</template>')
      .replace(/<sc-if\b/g, '<template data-t="if"').replace(/<\/sc-if>/g, '</template>')
      .replace(/<dc-import\b/g, '<template data-t="import"').replace(/<\/dc-import>/g, '</template>');
    const doc = new DOMParser().parseFromString(s, 'text/html');
    const xdc = doc.querySelector('x-dc'), script = doc.querySelector('script[data-dc-script]');
    let decl = {}; try { decl = JSON.parse(script.getAttribute('data-props') || '{}'); } catch (e) {}
    const Cls = new Function('DCLogic', script.textContent + '\nreturn Component;')(DCLogic);
    const helmet = xdc.querySelector('helmet');
    const head = helmet ? Array.from(helmet.children) : [];
    const title = (doc.querySelector('title') || {}).textContent || '';
    return (cache[name] = { Cls, decl, xdc, helmet, head, title });
  }
  function resolve(path, scope) {
    path = path.trim();
    if (path === 'true') return true; if (path === 'false') return false; if (path === 'null') return null; if (path === 'undefined') return undefined;
    if (/^-?\d+(\.\d+)?$/.test(path)) return Number(path);
    const parts = path.split('.'); let v = scope[parts[0]];
    for (let i = 1; i < parts.length; i++) { if (v == null) return undefined; v = v[parts[i]]; }
    return v;
  }
  function interp(str, scope) {
    return str.replace(HOLE, (m, p) => { const v = resolve(p, scope); return (v == null || typeof v === 'object' || typeof v === 'function' || typeof v === 'boolean') ? '' : String(v); });
  }
  const camel = (k) => k.replace(/-([a-z])/g, (m, c) => c.toUpperCase());
  const EV = { onclick: 'click', oninput: 'input', onchange: 'change', onkeydown: 'keydown', onkeyup: 'keyup', onsubmit: 'submit', ondragover: 'dragover', ondragleave: 'dragleave', ondrop: 'drop', onfocus: 'focus', onblur: 'blur' };
  function domEvent(el, attr) {
    if (attr === 'onchange') { const t = el.nodeName, ty = (el.getAttribute && el.getAttribute('type') || '').toLowerCase(); if (t === 'TEXTAREA' || (t === 'INPUT' && !/^(checkbox|radio|file|range|color)$/.test(ty))) return 'input'; return 'change'; }
    return EV[attr];
  }
  function ensureListener(el, ev) {
    el.__l = el.__l || {};
    if (el.__l[ev]) return; el.__l[ev] = 1;
    el.addEventListener(ev, (e) => { const f = el.__h && el.__h[ev]; if (typeof f === 'function') f(e); });
  }
  function fixHref(v) { return typeof v === 'string' ? v.replace(/([A-Za-z0-9_]+)\.dc\.html/g, '#/$1') : v; }
  function fixSrc(v) { return (typeof v === 'string' && v.indexOf('/_blob/') === 0) ? IMG : v; }
  function attrs(tpl, el, scope) {
    const a = {}, h = {}, p = {};
    for (const at of Array.from(tpl.attributes)) {
      const n = at.name, raw = at.value;
      if (EV[n]) { const m = raw.match(WHOLE); const f = m ? resolve(m[1], scope) : null; const ev = domEvent(el, n); if (ev) { h[ev] = f; } continue; }
      let v; const m = raw.match(WHOLE);
      if (m) v = resolve(m[1], scope); else if (raw.indexOf('{{') >= 0) v = interp(raw, scope); else v = raw;
      if (n === 'value' && /^(INPUT|TEXTAREA|SELECT)$/.test(el.nodeName) && raw.indexOf('{{') >= 0) { p.value = v == null ? '' : String(v); continue; }
      if (n === 'checked' && raw.indexOf('{{') >= 0) { p.checked = !!v; continue; }
      if (typeof v === 'function' || v == null || v === false) continue;
      if (v === true) v = '';
      v = String(v);
      if (n === 'href') v = fixHref(v);
      if (n === 'src') v = fixSrc(v);
      a[n] = v;
    }
    el.__a = a; el.__h = h; el.__p = p;
    for (const k in a) { try { el.setAttribute(k, a[k]); } catch (e) {} }
    for (const ev in h) ensureListener(el, ev);
  }
  function build(nodes, scope, parent) {
    for (const t of Array.from(nodes)) {
      if (t.nodeType === 3) { const tv = t.nodeValue.indexOf('{{') >= 0 ? interp(t.nodeValue, scope) : t.nodeValue; const tn = document.createTextNode(tv); tn.__v = tv; parent.appendChild(tn); continue; }
      if (t.nodeType !== 1) continue;
      const tag = t.nodeName;
      if (tag === 'TEMPLATE') {
        const kind = t.getAttribute('data-t');
        if (kind === 'for') {
          const m = (t.getAttribute('list') || '').match(WHOLE); const list = m ? resolve(m[1], scope) : []; const as = t.getAttribute('as') || 'item';
          (Array.isArray(list) ? list : []).forEach((item, i) => { const sc = Object.create(scope); sc[as] = item; sc.$index = i; build(kids(t), sc, parent); });
        } else if (kind === 'if') {
          const m = (t.getAttribute('value') || '').match(WHOLE); const v = m ? resolve(m[1], scope) : t.getAttribute('value');
          if (v) build(kids(t), scope, parent);
        } else if (kind === 'import') {
          const el = document.createElement('dc-mount'); el.style.display = 'contents';
          const props = {}; let name = '';
          for (const at of Array.from(t.attributes)) {
            if (at.name === 'data-t') continue; if (at.name === 'name') { name = at.value; continue; } if (/^hint-/.test(at.name)) continue;
            const m = at.value.match(WHOLE); props[camel(at.name)] = m ? resolve(m[1], scope) : (at.value.indexOf('{{') >= 0 ? interp(at.value, scope) : at.value);
          }
          el.__imp = { name, props }; parent.appendChild(el);
        }
        continue;
      }
      if (tag === 'HELMET') continue;
      const el = t.namespaceURI && t.namespaceURI !== 'http://www.w3.org/1999/xhtml' ? document.createElementNS(t.namespaceURI, t.localName) : document.createElement(t.localName);
      attrs(t, el, scope);
      build(kids(t), scope, el);
      applyProps(el, el.__p);
      parent.appendChild(el);
    }
  }
  function applyProps(el, p) {
    if (!p) return;
    if ('value' in p && el.value !== p.value) { try { el.value = p.value; } catch (e) {} }
    if ('checked' in p && el.checked !== p.checked) el.checked = p.checked;
  }
  function same(l, v) { return l.nodeType === v.nodeType && (l.nodeType === 3 || (l.nodeName === v.nodeName && l.namespaceURI === v.namespaceURI)); }
  function patch(l, v) {
    if (l.nodeType === 3) { if (l.__v !== v.nodeValue) { l.nodeValue = v.nodeValue; l.__v = v.nodeValue; } return; }
    const prev = l.__a || {}, next = v.__a || {};
    for (const k in next) if (prev[k] !== next[k]) { try { l.setAttribute(k, next[k]); } catch (e) {} }
    for (const k in prev) if (!(k in next)) l.removeAttribute(k);
    l.__a = next; l.__h = v.__h; for (const ev in v.__h) ensureListener(l, ev); l.__p = v.__p;
    if (l.nodeName === 'DC-MOUNT') { l.__imp = v.__imp; return; }
    morph(l, v);
    applyProps(l, v.__p);
  }
  function morph(live, virt) {
    const lc = Array.from(live.childNodes), vc = Array.from(virt.childNodes);
    for (let i = 0; i < vc.length; i++) {
      const v = vc[i], l = lc[i];
      if (!l) { live.appendChild(v); continue; }
      if (same(l, v)) patch(l, v); else live.replaceChild(v, l);
    }
    for (let i = lc.length - 1; i >= vc.length; i--) live.removeChild(lc[i]);
  }
  const shallowEq = (a, b) => { const ka = Object.keys(a), kb = Object.keys(b); if (ka.length !== kb.length) return false; for (const k of ka) if (a[k] !== b[k]) return false; return true; };
  let styleOwner = null;
  function addHead(c, page) {
    for (const n of c.head) {
      if (n.nodeName === 'STYLE') { const s = document.createElement('style'); s.textContent = n.textContent; s.setAttribute('data-dc-page', page); document.head.appendChild(s); }
      else if (n.nodeName === 'LINK') { const href = n.getAttribute('href'); if (!document.head.querySelector('link[href="' + href.replace(/"/g, '\\"') + '"]')) { const l = document.createElement('link'); for (const a of Array.from(n.attributes)) l.setAttribute(a.name, a.value); l.setAttribute('data-dc-page', page); document.head.appendChild(l); } }
    }
  }
  class Inst {
    constructor(name, props, host, page) {
      this.name = name; this.host = host; this.page = page; this.c = compile(name); this.rawProps = props;
      const dflt = {}; for (const k in this.c.decl) if (k[0] !== '$' && this.c.decl[k] && this.c.decl[k].default !== undefined) dflt[k] = this.c.decl[k].default;
      this.logic = new this.c.Cls(Object.assign({}, dflt, props)); this.logic._inst = this; this.dflt = dflt; this.queued = false; this.cbs = [];
      addHead(this.c, page);
    }
    setProps(props) { this.rawProps = props; this.logic.props = Object.assign({}, this.dflt, props); }
    render() {
      const vals = this.logic.renderVals() || {};
      const virt = document.createElement('div');
      build(kids(this.c.xdc), vals, virt);
      morph(this.host, virt);
      this.mountImports();
    }
    mountImports() {
      const own = this.host.nodeName === 'DC-MOUNT' ? this.host : null;
      for (const m of Array.from(this.host.querySelectorAll('dc-mount'))) {
        const up = m.parentElement && m.parentElement.closest('dc-mount');
        if ((up || null) !== own) continue;
        const imp = m.__imp; if (!imp) continue;
        if (!m.__inst) { m.__inst = new Inst(imp.name, imp.props, m, this.page); m.__inst.render(); if (m.__inst.logic.componentDidMount) { try { m.__inst.logic.componentDidMount(); } catch (e) { console.error(e); } } }
        else if (!shallowEq(m.__inst.rawProps, imp.props)) { m.__inst.setProps(imp.props); m.__inst.render(); }
      }
    }
    schedule(cb) { if (cb) this.cbs.push(cb); if (this.queued) return; this.queued = true; Promise.resolve().then(() => { this.queued = false; try { this.render(); } catch (e) { console.error(e); } const c = this.cbs; this.cbs = []; c.forEach(f => { try { f(); } catch (e) { console.error(e); } }); }); }
  }
  let current = null;
  function show(name) {
    const app = document.getElementById('app');
    document.querySelectorAll('style[data-dc-page],link[data-dc-page]').forEach(n => n.remove());
    app.textContent = '';
    if (!SRC[name] || name === 'Nav' || name === 'DocFolder') name = 'Landing';
    current = new Inst(name, {}, app, name);
    document.title = (compile(name).title || 'BENI Airport Project');
    current.render();
    if (current.logic.componentDidMount) { try { current.logic.componentDidMount(); } catch (e) { console.error(e); } }
    window.scrollTo(0, 0);
    try { if (window.__beniTr) window.__beniTr.later(); } catch (e) {}
  }
  function route() { const m = (location.hash || '').match(/^#\/([A-Za-z0-9_]+)/); show(m ? m[1] : 'Landing'); }
  window.addEventListener('hashchange', route);
  window.__dcmini = { show, route };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', route); else route();
})();
