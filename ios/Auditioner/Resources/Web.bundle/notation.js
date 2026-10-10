/*
 * Auditioner notation page: renders MusicXML with Verovio and follows playback.
 *
 * Native → JS:
 *   window.auditioner.load(base64MusicXML, widthPx)   render all pages, build the timemap
 *   window.auditioner.highlight(qstamp)               mark the notes sounding at qstamp (quarter notes)
 *   window.auditioner.clear()                         remove the highlight
 *
 * JS → native (webkit.messageHandlers.auditioner):
 *   {type:'init'}                                     toolkit ready, load() may be called
 *   {type:'ready', pages, measures:[{index,n,qstamp}], totalQstamp}
 *   {type:'tapNote', qstamp, id}
 *   {type:'error', message}
 *
 * The non-DOM logic lives in `core` so it can be tested in Node (see the scratch test).
 */
(function (global) {
  'use strict';

  var DEFAULT_SCALE = 40;
  var HIGHLIGHT_CLASS = 'is-sounding';

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
      svgViewBox: false
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

  /** Renders every page and returns the SVG strings plus the timemap (repeats NOT expanded). */
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
   * Builds the model used for highlighting and tapping from a Verovio timemap.
   * - entries: timemap entries in qstamp order, each with `sounding` (ids of notes/rests sounding from that qstamp)
   * - noteStart: id → qstamp of the note's start (grace notes do not steal the following note's start)
   * - measures: [{index, id, n, qstamp}]
   */
  function buildModel(toolkit, timemap) {
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

    // Grace notes: Verovio's timemap gives them time stolen from the next note. For "play from
    // here" we want the main note to start where it is written, i.e. at the grace note's qstamp.
    for (i = 0; i < entries.length; i++) {
      var onIds = entries[i].on;
      if (onIds.length === 0) { continue; }
      var allGrace = true;
      for (j = 0; j < onIds.length; j++) {
        if (!isGraceNote(toolkit, onIds[j])) { allGrace = false; break; }
      }
      if (!allGrace) { continue; }
      for (var m = i + 1; m < entries.length; m++) {
        var later = entries[m].on;
        if (later.length === 0) { continue; }
        var hasMain = false;
        for (j = 0; j < later.length; j++) {
          if (!isGraceNote(toolkit, later[j])) {
            hasMain = true;
            noteStart[later[j]] = entries[i].qstamp;
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

  /** Ids of the notes (and rests) sounding at q. */
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

  var core = {
    DEFAULT_SCALE: DEFAULT_SCALE,
    makeOptions: makeOptions,
    decodeBase64Utf8: decodeBase64Utf8,
    renderAll: renderAll,
    buildModel: buildModel,
    findEntryIndex: findEntryIndex,
    soundingAt: soundingAt,
    sameIds: sameIds
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
    highlighted: [],
    lastQ: null,
    resizeTimer: null
  };

  function post(message) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.auditioner) {
        window.webkit.messageHandlers.auditioner.postMessage(message);
      }
    } catch (e) {
      // ignore: no native host (e.g. opened in a desktop browser)
    }
  }

  function container() {
    return document.getElementById('score');
  }

  function viewportWidth() {
    var w = document.documentElement.clientWidth || window.innerWidth || 0;
    return Math.max(200, Math.round(w));
  }

  function setHighlight(ids) {
    var i, el;
    if (sameIds(ids, state.highlighted)) { return; }
    for (i = 0; i < state.highlighted.length; i++) {
      el = document.getElementById(state.highlighted[i]);
      if (el) { el.classList.remove(HIGHLIGHT_CLASS); }
    }
    var first = null;
    for (i = 0; i < ids.length; i++) {
      el = document.getElementById(ids[i]);
      if (el) {
        el.classList.add(HIGHLIGHT_CLASS);
        if (!first) { first = el; }
      }
    }
    state.highlighted = ids.slice();
    if (first) { scrollIntoViewIfNeeded(first); }
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

  function onScoreClick(event) {
    if (!state.model) { return; }
    var target = event.target;
    var g = null;
    if (target && typeof target.closest === 'function') {
      g = target.closest('g.note');
    }
    if (!g || !g.id) { return; }
    var q = state.model.noteStart[g.id];
    if (typeof q === 'undefined') { return; }
    post({ type: 'tapNote', qstamp: q, id: g.id });
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
    state.highlighted = [];
    root.innerHTML = result.svgs.join('');
    try {
      state.model = buildModel(tk, result.timemap);
    } catch (e) {
      state.model = null;
      post({ type: 'error', message: 'timemap: ' + String(e && e.message ? e.message : e) });
      return;
    }
    post({
      type: 'ready',
      pages: result.pages,
      measures: state.model.measures,
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
    // In case the runtime finished before this script ran.
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

  window.auditioner = {
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
