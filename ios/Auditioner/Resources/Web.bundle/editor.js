/*
 * Auditioner notation editor page: renders MusicXML with Verovio, lets the player tap a note,
 * shows the selected note, tints bars that don't add up and follows the preview playback.
 *
 * Native → JS:
 *   window.editor.load(base64MusicXML, widthPx)      render, build the timemap, re-apply selection/flags
 *   window.editor.select(measureIndex, noteOrder)    mark the editable note (-1, -1 clears)
 *   window.editor.flagBars([measureIndex, ...])      tint these bars red (empty list clears)
 *   window.editor.highlight(qstamp)                  mark the notes sounding at qstamp (quarter notes)
 *   window.editor.clear()                            remove the playback highlight
 *
 * JS → native (webkit.messageHandlers.editor):
 *   {type:'init'}
 *   {type:'ready', pages, measures:[{index, n, qstamp, count}], totalQstamp}
 *   {type:'tapNote', measureIndex, measureN, noteOrder, qstamp, id}   noteOrder is -1 when not editable
 *   {type:'error', message}
 *
 * Addressing matches ScoreEditing.swift: a measure's editable notes are the notes, chords and rests of
 * the first staff's layer 1 (voice 1), in order, skipping grace notes and the notes inside a chord.
 *
 * The non-DOM logic and the DOM helpers that take a root element live in `core` so they can be
 * tested in Node (jsdom) against real Verovio output.
 */
(function (global) {
  'use strict';

  var DEFAULT_SCALE = 40;
  var SOUNDING_CLASS = 'is-sounding';
  var SELECTED_CLASS = 'is-selected';
  var FLAGGED_CLASS = 'is-off';
  var UNIT_SELECTOR = 'g.note, g.chord, g.rest, g.mRest';
  var SVG_NS = 'http://www.w3.org/2000/svg';

  // ---------------------------------------------------------------------------
  // Pure logic (no DOM)
  // ---------------------------------------------------------------------------

  function makeOptions(widthPx, scale) {
    var s = scale || DEFAULT_SCALE;
    var w = Math.max(200, Math.round(widthPx || 0));
    return {
      pageWidth: Math.round(w * 100 / s),
      scale: s,
      adjustPageHeight: true,
      breaks: 'auto',
      footer: 'none',
      header: 'none',
      svgViewBox: false,
      svgAdditionalAttribute: ['measure@n', 'staff@n', 'layer@n', 'note@grace', 'chord@grace']
    };
  }

  function decodeBase64Utf8(b64) {
    if (typeof atob === 'function') {
      var binary = atob(b64);
      var bytes = new Uint8Array(binary.length);
      for (var i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
      }
      if (typeof TextDecoder !== 'undefined') {
        return new TextDecoder('utf-8').decode(bytes);
      }
      return decodeURIComponent(escape(binary));
    }
    if (typeof Buffer !== 'undefined') {
      return Buffer.from(b64, 'base64').toString('utf8');
    }
    throw new Error('No base64 decoder available');
  }

  /** Renders every page and returns the SVG strings plus the timemap. */
  function renderAll(toolkit, musicXML, widthPx, scale) {
    toolkit.setOptions(makeOptions(widthPx, scale));
    var ok = toolkit.loadData(musicXML);
    if (ok === false) {
      throw new Error('Verovio could not read this file');
    }
    var pageCount = toolkit.getPageCount();
    var svgs = [];
    for (var p = 1; p <= pageCount; p++) {
      svgs.push(toolkit.renderToSVG(p, false));
    }
    var timemap = toolkit.renderToTimemap({ includeMeasures: true, includeRests: true });
    return { svgs: svgs, pages: pageCount, timemap: timemap };
  }

  function isGraceNote(toolkit, id) {
    try {
      var attrs = toolkit.getElementAttr(id);
      return !!(attrs && typeof attrs.grace !== 'undefined');
    } catch (e) {
      return false;
    }
  }

  /**
   * Model for highlighting and tapping from a Verovio timemap:
   * entries (qstamp order, each with the ids sounding from there), noteStart (id → qstamp), measures.
   */
  function buildModel(toolkit, timemap, isGraceFn) {
    var isGrace = isGraceFn || function (id) { return isGraceNote(toolkit, id); };
    var entries = [];
    var noteStart = {};
    var measures = [];
    var current = [];
    var i, j, id;

    var sorted = timemap.slice().sort(function (a, b) { return a.qstamp - b.qstamp; });

    for (i = 0; i < sorted.length; i++) {
      var e = sorted[i];
      var on = (e.on || []).concat(e.restsOn || []);
      var off = (e.off || []).concat(e.restsOff || []);
      for (j = 0; j < off.length; j++) {
        var k = current.indexOf(off[j]);
        if (k >= 0) { current.splice(k, 1); }
      }
      for (j = 0; j < on.length; j++) {
        id = on[j];
        if (current.indexOf(id) < 0) { current.push(id); }
        if (typeof noteStart[id] === 'undefined') { noteStart[id] = e.qstamp; }
      }
      if (e.measureOn) {
        var n = '';
        try {
          var attrs = toolkit.getElementAttr(e.measureOn);
          n = (attrs && typeof attrs.n !== 'undefined') ? String(attrs.n) : '';
        } catch (err) {
          n = '';
        }
        measures.push({ index: measures.length, id: e.measureOn, n: n, qstamp: e.qstamp });
      }
      entries.push({ qstamp: e.qstamp, tstamp: e.tstamp, on: on, sounding: current.slice() });
    }

    // Grace notes steal time from the next note in the timemap; the main note starts where it is
    // written, i.e. at the grace note's qstamp (other voices starting there do not change that).
    for (i = 0; i < entries.length; i++) {
      var onIds = entries[i].on;
      var anyGrace = false;
      for (j = 0; j < onIds.length; j++) {
        if (isGrace(onIds[j])) { anyGrace = true; break; }
      }
      if (!anyGrace) { continue; }
      for (var m = i + 1; m < entries.length; m++) {
        var later = entries[m].on;
        var hasMain = false;
        for (j = 0; j < later.length; j++) {
          if (!isGrace(later[j])) {
            hasMain = true;
            if (noteStart[later[j]] > entries[i].qstamp) { noteStart[later[j]] = entries[i].qstamp; }
          }
        }
        if (hasMain) { break; }
      }
    }

    var maxQstamp = entries.length ? entries[entries.length - 1].qstamp : 0;
    return { entries: entries, noteStart: noteStart, measures: measures, maxQstamp: maxQstamp };
  }

  /** Index of the last entry whose qstamp <= q, or -1. */
  function findEntryIndex(model, q) {
    var entries = model.entries;
    var lo = 0, hi = entries.length - 1, best = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (entries[mid].qstamp <= q + 1e-6) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  function soundingAt(model, q) {
    var index = findEntryIndex(model, q);
    if (index < 0) { return []; }
    return model.entries[index].sounding;
  }

  function sameIds(a, b) {
    if (a.length !== b.length) { return false; }
    for (var i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) { return false; }
    }
    return true;
  }

  function sameInts(a, b) {
    return sameIds(a || [], b || []);
  }

  // ---------------------------------------------------------------------------
  // DOM helpers (take the element that holds the SVG so they can run under jsdom)
  // ---------------------------------------------------------------------------

  function toArray(list) {
    var out = [];
    if (!list) { return out; }
    for (var i = 0; i < list.length; i++) { out.push(list[i]); }
    return out;
  }

  function hasClass(el, cls) {
    return !!(el && el.classList && el.classList.contains(cls));
  }

  function childrenWithClass(el, cls) {
    var out = [];
    var kids = el ? el.childNodes : null;
    if (!kids) { return out; }
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].nodeType === 1 && hasClass(kids[i], cls)) { out.push(kids[i]); }
    }
    return out;
  }

  /** The element with data-n="1", else the first one. */
  function pickFirstN(list) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].getAttribute('data-n') === '1') { return list[i]; }
    }
    return list.length ? list[0] : null;
  }

  function measureElements(root) {
    return toArray(root.querySelectorAll('g.measure'));
  }

  /** Layer 1 of staff 1 of a measure (voice 1 of the first part). */
  function editableLayer(measureEl) {
    var staff = pickFirstN(childrenWithClass(measureEl, 'staff'));
    if (!staff) { return null; }
    return pickFirstN(childrenWithClass(staff, 'layer'));
  }

  /** Nearest ancestor with the class, stopping at (and excluding) `boundary`. */
  function ancestorWithClass(el, cls, boundary) {
    var p = el ? el.parentNode : null;
    while (p && p !== boundary) {
      if (hasClass(p, cls)) { return p; }
      p = p.parentNode;
    }
    return null;
  }

  function closestWithClass(el, cls) {
    var p = el;
    while (p) {
      if (hasClass(p, cls)) { return p; }
      p = p.parentNode;
    }
    return null;
  }

  /** The measure's editable units in order: notes, chords and rests of voice 1 (no grace notes, no chord members). */
  function editableUnits(measureEl) {
    var layer = editableLayer(measureEl);
    if (!layer) { return []; }
    var all = toArray(layer.querySelectorAll(UNIT_SELECTOR));
    var units = [];
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.getAttribute('data-grace')) { continue; }
      if (hasClass(el, 'note') && ancestorWithClass(el, 'chord', layer)) { continue; }
      if (ancestorWithClass(el, 'layer', measureEl) !== layer) { continue; }
      units.push(el);
    }
    return units;
  }

  /** The tapped unit for an event target: the chord when a chord note was tapped, else the note/rest. */
  function unitForTarget(target) {
    var el = target;
    var unit = null;
    while (el && el.nodeType === 1) {
      if (hasClass(el, 'note') || hasClass(el, 'rest') || hasClass(el, 'mRest') || hasClass(el, 'chord')) {
        unit = el;
        break;
      }
      el = el.parentNode;
    }
    if (!unit) { return null; }
    if (hasClass(unit, 'note')) {
      var chord = ancestorWithClass(unit, 'chord', closestWithClass(unit, 'layer'));
      if (chord) { unit = chord; }
    }
    return unit;
  }

  /** Where a unit sits: measure index (page order), printed number, order among editable units (-1 if not editable). */
  function locate(root, unit) {
    var measureEl = closestWithClass(unit, 'measure');
    if (!measureEl) { return null; }
    var measures = measureElements(root);
    var units = editableUnits(measureEl);
    return {
      measureIndex: measures.indexOf(measureEl),
      measureN: measureEl.getAttribute('data-n') || '',
      noteOrder: units.indexOf(unit),
      element: unit
    };
  }

  function unitAt(root, measureIndex, noteOrder) {
    var measures = measureElements(root);
    if (measureIndex < 0 || measureIndex >= measures.length) { return null; }
    var units = editableUnits(measures[measureIndex]);
    if (noteOrder < 0 || noteOrder >= units.length) { return null; }
    return units[noteOrder];
  }

  /** qstamp of a unit from the timemap model (a chord through its first note). */
  function qstampFor(model, unit) {
    if (!model || !unit) { return null; }
    var id = unit.id;
    if (hasClass(unit, 'chord')) {
      var first = unit.querySelector('g.note');
      if (first) { id = first.id; }
    }
    var q = model.noteStart[id];
    return (typeof q === 'number') ? q : null;
  }

  /** Grace note test that also sees grace chords: the note's own data-grace, or a chord above it with one. */
  function makeGraceTest(toolkit, root) {
    return function (id) {
      if (isGraceNote(toolkit, id)) { return true; }
      var el = root ? root.querySelector('[id="' + id + '"]') : null;
      if (!el) { return false; }
      if (el.getAttribute('data-grace')) { return true; }
      var chord = ancestorWithClass(el, 'chord', closestWithClass(el, 'layer'));
      return !!(chord && chord.getAttribute('data-grace'));
    };
  }

  function removeAll(root, selector) {
    var old = toArray(root.querySelectorAll(selector));
    for (var i = 0; i < old.length; i++) {
      if (old[i].parentNode) { old[i].parentNode.removeChild(old[i]); }
    }
  }

  /** Tints the measures at these indices and badges them. */
  function applyFlags(root, indices, doc) {
    var measures = measureElements(root);
    removeAll(root, 'rect.bar-flag, g.bar-badge');
    var i;
    for (i = 0; i < measures.length; i++) {
      measures[i].classList.remove(FLAGGED_CLASS);
    }
    for (i = 0; i < indices.length; i++) {
      var m = measures[indices[i]];
      if (!m) { continue; }
      m.classList.add(FLAGGED_CLASS);
      addFlagShapes(m, doc);
    }
  }

  function addFlagShapes(measureEl, doc) {
    var box = null;
    try {
      box = measureEl.getBBox();
    } catch (e) {
      box = null;
    }
    if (!box || !(box.width > 0) || !(box.height > 0)) { return; }
    var d = doc || document;
    var rect = d.createElementNS(SVG_NS, 'rect');
    rect.setAttribute('class', 'bar-flag');
    rect.setAttribute('x', String(box.x));
    rect.setAttribute('y', String(box.y));
    rect.setAttribute('width', String(box.width));
    rect.setAttribute('height', String(box.height));
    rect.setAttribute('rx', '40');
    measureEl.insertBefore(rect, measureEl.firstChild);

    var r = Math.max(90, Math.min(160, box.height * 0.11));
    var badge = d.createElementNS(SVG_NS, 'g');
    badge.setAttribute('class', 'bar-badge');
    var circle = d.createElementNS(SVG_NS, 'circle');
    circle.setAttribute('cx', String(box.x + r * 1.1));
    circle.setAttribute('cy', String(box.y + r * 0.2));
    circle.setAttribute('r', String(r));
    badge.appendChild(circle);
    var text = d.createElementNS(SVG_NS, 'text');
    text.setAttribute('x', String(box.x + r * 1.1));
    text.setAttribute('y', String(box.y + r * 0.2 + r * 0.5));
    text.setAttribute('font-size', String(r * 1.5));
    text.textContent = '!';
    badge.appendChild(text);
    measureEl.appendChild(badge);
  }

  function applySelection(root, selection) {
    var old = toArray(root.querySelectorAll('.' + SELECTED_CLASS));
    for (var i = 0; i < old.length; i++) {
      old[i].classList.remove(SELECTED_CLASS);
    }
    if (!selection) { return null; }
    var unit = unitAt(root, selection.measureIndex, selection.noteOrder);
    if (unit) { unit.classList.add(SELECTED_CLASS); }
    return unit;
  }

  var core = {
    DEFAULT_SCALE: DEFAULT_SCALE,
    makeOptions: makeOptions,
    decodeBase64Utf8: decodeBase64Utf8,
    renderAll: renderAll,
    buildModel: buildModel,
    findEntryIndex: findEntryIndex,
    soundingAt: soundingAt,
    sameIds: sameIds,
    measureElements: measureElements,
    editableLayer: editableLayer,
    editableUnits: editableUnits,
    unitForTarget: unitForTarget,
    locate: locate,
    unitAt: unitAt,
    qstampFor: qstampFor,
    makeGraceTest: makeGraceTest,
    applyFlags: applyFlags,
    applySelection: applySelection
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = core;
  }

  // ---------------------------------------------------------------------------
  // Browser glue
  // ---------------------------------------------------------------------------

  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return;
  }

  var state = {
    toolkit: null,
    ready: false,
    pending: null,
    xml: null,
    width: 0,
    model: null,
    selection: null,
    flags: [],
    highlighted: [],
    lastQ: null,
    resizeTimer: null
  };

  function post(message) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editor) {
        window.webkit.messageHandlers.editor.postMessage(message);
      }
    } catch (e) {
      // no native host (page opened in a desktop browser)
    }
  }

  function container() {
    return document.getElementById('score');
  }

  function viewportWidth() {
    var w = document.documentElement.clientWidth || window.innerWidth || 0;
    return Math.max(200, Math.round(w));
  }

  function scrollIntoViewIfNeeded(el) {
    var rect;
    try {
      rect = el.getBoundingClientRect();
    } catch (e) {
      return;
    }
    var viewH = window.innerHeight || document.documentElement.clientHeight || 0;
    if (!viewH) { return; }
    var margin = 24;
    if (rect.top >= margin && rect.bottom <= viewH - margin) { return; }
    var target = window.scrollY + rect.top - viewH * 0.33;
    if (target < 0) { target = 0; }
    try {
      window.scrollTo({ top: target, behavior: 'smooth' });
    } catch (e) {
      window.scrollTo(0, target);
    }
  }

  function setHighlight(ids) {
    var i, el;
    if (sameIds(ids, state.highlighted)) { return; }
    for (i = 0; i < state.highlighted.length; i++) {
      el = document.getElementById(state.highlighted[i]);
      if (el) { el.classList.remove(SOUNDING_CLASS); }
    }
    var first = null;
    for (i = 0; i < ids.length; i++) {
      el = document.getElementById(ids[i]);
      if (el) {
        el.classList.add(SOUNDING_CLASS);
        if (!first) { first = el; }
      }
    }
    state.highlighted = ids.slice();
    if (first) { scrollIntoViewIfNeeded(first); }
  }

  function onScoreClick(event) {
    var root = container();
    if (!root) { return; }
    var unit = unitForTarget(event.target);
    if (!unit) { return; }
    var where = locate(root, unit);
    if (!where) { return; }
    var q = qstampFor(state.model, unit);
    post({
      type: 'tapNote',
      measureIndex: where.measureIndex,
      measureN: where.measureN,
      noteOrder: where.noteOrder,
      qstamp: (q === null) ? 0 : q,
      id: unit.id || ''
    });
  }

  function reapplyDecorations(scrollToSelection) {
    var root = container();
    if (!root) { return; }
    applyFlags(root, state.flags, document);
    var unit = applySelection(root, state.selection);
    if (unit && scrollToSelection) { scrollIntoViewIfNeeded(unit); }
  }

  function doLoad(xml, widthPx) {
    var tk = state.toolkit;
    var root = container();
    if (!tk || !root) { return; }
    var width = widthPx > 0 ? widthPx : viewportWidth();
    state.xml = xml;
    state.width = width;
    var result;
    try {
      result = renderAll(tk, xml, width, DEFAULT_SCALE);
    } catch (e) {
      post({ type: 'error', message: String(e && e.message ? e.message : e) });
      return;
    }
    var scrollY = window.scrollY || 0;
    state.highlighted = [];
    root.innerHTML = result.svgs.join('');
    try {
      state.model = buildModel(tk, result.timemap, makeGraceTest(tk, root));
    } catch (e) {
      state.model = null;
      post({ type: 'error', message: 'timemap: ' + String(e && e.message ? e.message : e) });
      return;
    }
    reapplyDecorations(false);
    try {
      window.scrollTo(0, scrollY);
    } catch (e) {
      // ignore
    }
    var measures = [];
    var measureEls = measureElements(root);
    for (var i = 0; i < measureEls.length; i++) {
      var info = state.model.measures[i] || {};
      measures.push({
        index: i,
        n: measureEls[i].getAttribute('data-n') || info.n || '',
        qstamp: (typeof info.qstamp === 'number') ? info.qstamp : 0,
        count: editableUnits(measureEls[i]).length
      });
    }
    post({
      type: 'ready',
      pages: result.pages,
      measures: measures,
      totalQstamp: state.model.maxQstamp
    });
    if (state.lastQ !== null) {
      setHighlight(soundingAt(state.model, state.lastQ));
    }
  }

  function initToolkit() {
    if (typeof verovio === 'undefined' || !verovio || !verovio.module) {
      post({ type: 'error', message: 'Verovio is missing' });
      return;
    }
    var started = false;
    function start() {
      if (started) { return; }
      started = true;
      try {
        state.toolkit = new verovio.toolkit();
      } catch (e) {
        post({ type: 'error', message: 'Verovio could not start: ' + String(e && e.message ? e.message : e) });
        return;
      }
      state.ready = true;
      post({ type: 'init' });
      if (state.pending) {
        var p = state.pending;
        state.pending = null;
        doLoad(p.xml, p.width);
      }
    }
    verovio.module.onRuntimeInitialized = start;
    var attempts = 0;
    var timer = setInterval(function () {
      attempts += 1;
      if (started) { clearInterval(timer); return; }
      if (typeof verovio.module._vrvToolkit_constructor === 'function') {
        clearInterval(timer);
        start();
      } else if (attempts > 600) {
        clearInterval(timer);
        post({ type: 'error', message: 'Verovio did not start' });
      }
    }, 50);
  }

  window.editor = {
    load: function (base64MusicXML, widthPx) {
      var xml;
      try {
        xml = decodeBase64Utf8(base64MusicXML);
      } catch (e) {
        post({ type: 'error', message: 'Could not decode the file' });
        return;
      }
      if (state.ready) {
        doLoad(xml, widthPx);
      } else {
        state.pending = { xml: xml, width: widthPx };
      }
    },
    select: function (measureIndex, noteOrder) {
      var mi = Number(measureIndex);
      var no = Number(noteOrder);
      if (!isFinite(mi) || !isFinite(no) || mi < 0 || no < 0) {
        state.selection = null;
      } else {
        state.selection = { measureIndex: mi, noteOrder: no };
      }
      var root = container();
      if (!root || !state.model) { return; }
      var unit = applySelection(root, state.selection);
      if (unit) { scrollIntoViewIfNeeded(unit); }
    },
    flagBars: function (indices) {
      var list = [];
      if (indices && indices.length) {
        for (var i = 0; i < indices.length; i++) {
          var n = Number(indices[i]);
          if (isFinite(n) && n >= 0) { list.push(n); }
        }
      }
      if (sameInts(list, state.flags) && state.model) { return; }
      state.flags = list;
      var root = container();
      if (!root || !state.model) { return; }
      applyFlags(root, state.flags, document);
    },
    highlight: function (qstamp) {
      var q = Number(qstamp);
      if (!isFinite(q)) { return; }
      state.lastQ = q;
      if (!state.model) { return; }
      setHighlight(soundingAt(state.model, q));
    },
    clear: function () {
      state.lastQ = null;
      setHighlight([]);
    },
    isReady: function () {
      return state.ready;
    }
  };

  function boot() {
    var root = container();
    if (root) { root.addEventListener('click', onScoreClick); }
    initToolkit();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  window.addEventListener('resize', function () {
    if (!state.xml) { return; }
    if (state.resizeTimer) { clearTimeout(state.resizeTimer); }
    state.resizeTimer = setTimeout(function () {
      state.resizeTimer = null;
      var w = viewportWidth();
      if (w !== state.width) { doLoad(state.xml, w); }
    }, 250);
  });
})(this);
