import Foundation

/// The one page `ullage serve` hands out.
///
/// A string constant rather than a file on disk: the CLI and the app both serve
/// it, neither has a resource bundle to read from, and a menu bar utility should
/// not gain an asset pipeline to draw one bar.
///
/// No frameworks, no CDN, no fonts to fetch — partly because the page has to
/// render on a phone over a tailnet with the Mac asleep behind it, and partly
/// because a page that loads nothing is a page that can leak nothing.
public enum WebPage {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#13181d">
<link rel="manifest" href="manifest.webmanifest">
<link rel="apple-touch-icon" href="icon.png">
<title>Ullage</title>
<style>
  :root {
    --bg: #fbfbfa; --panel: #fff; --ink: #1a1a19; --dim: #6b6b63; --faint: #8f8f86;
    --rule: #e4e4dd; --fill: #2f6fd0; --warn: #b5541c; --quiet: #9a9a90; --accent: #2f6fd0;
    --c-baseline: #8e8e93; --c-tools: #1f9ab0; --c-output: #a347d1; --c-other: #a2845e;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #17171a; --panel: #1f1f23; --ink: #ececea; --dim: #a3a39b; --faint: #85857e;
      --rule: #2e2e33; --fill: #4a90f0; --warn: #f0954d; --quiet: #6a6a63; --accent: #5a9cf5;
      --c-baseline: #98989d; --c-tools: #40c8e0; --c-output: #bf5af2; --c-other: #ac8e68;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.45 ui-sans-serif, -apple-system, system-ui, sans-serif;
    padding: max(14px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom));
    -webkit-font-smoothing: antialiased; -webkit-tap-highlight-color: transparent;
  }
  main { max-width: 640px; margin: 0 auto; }
  .num { font-variant-numeric: tabular-nums; }
  .top { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
  .brand { font-size: 11px; letter-spacing: .14em; text-transform: uppercase; color: var(--dim); font-weight: 600; flex: 1; }
  select {
    font: inherit; font-size: 13px; color: var(--ink); background: var(--panel);
    border: 1px solid var(--rule); border-radius: 8px; padding: 6px 8px; max-width: 62%;
  }
  .card { background: var(--panel); border: 1px solid var(--rule); border-radius: 14px; padding: 16px; }
  .head { display: flex; gap: 12px; align-items: flex-start; }
  .who { flex: 1; min-width: 0; }
  .who .name { font-weight: 650; font-size: 17px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .who .line { color: var(--dim); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; direction: rtl; text-align: left; }
  .who .line.ltr { direction: ltr; }
  .badge { font-size: 11px; color: var(--warn); border: 1px solid var(--warn); border-radius: 99px; padding: 0 6px; margin-left: 6px; }
  .left { text-align: right; white-space: nowrap; }
  .left b { font-size: 26px; font-weight: 650; letter-spacing: -.02em; }
  .left span { color: var(--dim); font-size: 13px; margin-left: 3px; }
  body.warn .left b { color: var(--warn); }
  body.quiet .left b { color: var(--quiet); }
  .track { position: relative; height: 8px; border-radius: 4px; background: var(--rule); margin: 12px 0 8px; overflow: hidden; }
  .fill { display: block; height: 100%; width: 0; background: var(--fill); border-radius: 4px; transition: width .4s ease; }
  body.warn .fill { background: var(--warn); }
  .tick { position: absolute; top: 0; bottom: 0; width: 2px; background: var(--bg); opacity: .9; }
  .tick.peak { background: var(--warn); opacity: .7; }
  .exact { display: flex; justify-content: space-between; color: var(--dim); font-size: 13px; }
  .exact span:last-child { color: var(--faint); }
  .remote {
    display: inline-block; margin-bottom: 12px; font-size: 14px; font-weight: 600; color: var(--accent);
    text-decoration: none; padding: 8px 12px; border: 1px solid var(--rule); border-radius: 9px;
  }
  .chart { margin-top: 12px; }
  .chart svg { display: block; width: 100%; height: 96px; touch-action: pan-y; }
  .caption { color: var(--faint); font-size: 12px; margin-top: 4px; min-height: 17px; }
  details { border-top: 1px solid var(--rule); padding: 10px 0; }
  details:first-of-type { border-top: 0; }
  summary { list-style: none; cursor: pointer; }
  summary::-webkit-details-marker { display: none; }
  .rule { display: flex; align-items: center; gap: 8px; }
  .rule .t { font-size: 11px; letter-spacing: .12em; text-transform: uppercase; color: var(--dim); font-weight: 650; white-space: nowrap; }
  .rule .ln { flex: 1; height: 1px; background: var(--rule); }
  .rule .ln.shares { height: 3px; border-radius: 2px; display: flex; gap: 1px; overflow: hidden; background: none; }
  /* Open, the section draws the bar large in its body; the title goes back
     to a plain rule, as the popover's does. */
  details[open] .rule .ln.shares { height: 1px; background: var(--rule); }
  details[open] .rule .ln.shares i { display: none; }
  .rule .chev { color: var(--faint); font-size: 12px; transition: transform .15s; }
  details[open] .rule .chev { transform: rotate(90deg); }
  .readout { margin-top: 6px; font-size: 13px; color: var(--dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  details[open] > summary .readout { display: none; }
  .readout b { color: var(--ink); font-weight: 500; }
  .readout .w, .readout .w b { color: var(--warn); }
  .readout .m b { color: var(--faint); }
  .readout .sep { color: var(--faint); }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 4px; margin-right: 4px; vertical-align: 0; }
  .body { margin-top: 10px; }
  .grp { margin-top: 12px; }
  .grp:first-child { margin-top: 0; }
  .grp h3 { font-size: 12px; font-weight: 600; color: var(--dim); margin: 0 0 4px; }
  .row { display: grid; grid-template-columns: 1fr auto; gap: 0 12px; padding: 5px 0; font-size: 14px; align-items: baseline; }
  .row .l { min-width: 0; overflow-wrap: anywhere; }
  .row .v { text-align: right; font-variant-numeric: tabular-nums; }
  .row .d { grid-column: 1 / span 2; color: var(--faint); font-size: 12px; }
  .row.w .v, .row.w .l { color: var(--warn); }
  .row.m .v, .row.m .l { color: var(--faint); }
  .row .bar { grid-column: 1 / span 2; height: 4px; border-radius: 2px; background: var(--rule); margin-top: 4px; overflow: hidden; }
  .row .bar i { display: block; height: 100%; background: var(--fill); }
  .row.w .bar i { background: var(--warn); }
  .warning { color: var(--warn); font-size: 13px; margin: 0 0 8px; }
  .bigbar { display: flex; gap: 2px; height: 22px; border-radius: 6px; overflow: hidden; margin-bottom: 12px; }
  .saver { padding: 10px 0; border-bottom: 1px solid var(--rule); }
  .saver:last-of-type { border-bottom: 0; }
  .saver .top1 { display: flex; align-items: center; gap: 10px; }
  .saver .nm { font-weight: 650; flex: 1; }
  .saver .mt { font-weight: 650; font-variant-numeric: tabular-nums; }
  .saver .mt.w { color: var(--warn); }
  .saver .mc { color: var(--dim); font-size: 12px; }
  .saver .sub { padding-left: 54px; font-size: 13px; color: var(--dim); }
  .saver .note { padding-left: 54px; font-size: 12px; color: var(--faint); }
  .saver .pend { padding-left: 54px; font-size: 13px; color: var(--accent); font-weight: 600; }
  .switch {
    position: relative; width: 44px; height: 26px; border-radius: 13px; border: 0; padding: 0;
    background: var(--rule); flex: none; cursor: pointer; transition: background .15s;
  }
  .switch::after {
    content: ''; position: absolute; top: 3px; left: 3px; width: 20px; height: 20px;
    border-radius: 10px; background: #fff; transition: transform .15s; box-shadow: 0 1px 2px rgba(0,0,0,.25);
  }
  .switch[aria-checked="true"] { background: #34c759; }
  .switch[aria-checked="true"]::after { transform: translateX(18px); }
  .linkbtn { font: inherit; font-size: 13px; color: var(--accent); background: none; border: 0; padding: 6px 4px; cursor: pointer; }
  .more { width: 44px; flex: none; }
  .legend { font-size: 12px; color: var(--dim); margin-top: 8px; }
  h2 { font-size: 11px; letter-spacing: .14em; text-transform: uppercase; color: var(--dim); font-weight: 600; margin: 24px 0 8px; }
  ol { list-style: none; margin: 0; padding: 0; }
  li {
    display: grid; grid-template-columns: 1fr auto; gap: 2px 12px; padding: 11px 0;
    border-bottom: 1px solid var(--rule); align-items: baseline; cursor: pointer;
  }
  li:last-child { border-bottom: 0; }
  li.on .name { color: var(--accent); }
  .name { grid-column: 1; grid-row: 1; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
  /* Right-aligned so a long path loses its start, not the folder you know. */
  .path {
    grid-column: 1; grid-row: 2; color: var(--dim); font-size: 12px; min-width: 0;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; direction: rtl; text-align: left;
  }
  .sub2 { grid-column: 1; grid-row: 3; color: var(--faint); font-size: 12px; }
  .share { grid-column: 2; grid-row: 1 / span 3; align-self: center; text-align: right; font-variant-numeric: tabular-nums; font-size: 17px; }
  .share.none { color: var(--quiet); font-size: 15px; }
  .share.warn { color: var(--warn); }
  #stale { margin: 12px 0 0; padding: 10px 12px; border-radius: 10px; background: var(--rule); color: var(--dim); font-size: 13px; }
  body.stale .card { opacity: .5; }
  #alerts {
    margin-top: 14px; padding: 13px 15px; border: 1px solid var(--rule); border-radius: 12px;
    display: flex; gap: 12px; align-items: center; justify-content: space-between; font-size: 13px; color: var(--dim);
  }
  #alerts button, dialog .go {
    font: inherit; font-weight: 600; color: var(--bg); background: var(--ink); border: 0;
    border-radius: 8px; padding: 9px 14px; cursor: pointer; flex: none; -webkit-appearance: none;
  }
  #alerts button:disabled { opacity: .45; cursor: default; }
  dialog {
    border: 1px solid var(--rule); border-radius: 14px; background: var(--panel); color: var(--ink);
    padding: 18px; width: min(92vw, 520px);
  }
  dialog::backdrop { background: rgba(0,0,0,.4); }
  dialog h4 { margin: 0 0 10px; font-size: 17px; }
  dialog ol li { display: block; cursor: default; padding: 8px 0; }
  dialog code { display: block; font-size: 12px; color: var(--dim); overflow-wrap: anywhere; margin-top: 2px; }
  dialog p { font-size: 13px; color: var(--dim); margin: 8px 0; }
  dialog .acts { display: flex; gap: 10px; justify-content: flex-end; margin-top: 14px; }
  dialog .cancel { font: inherit; background: none; border: 1px solid var(--rule); color: var(--ink); border-radius: 8px; padding: 9px 14px; }
  dialog .go.danger { background: var(--warn); }
  footer { margin-top: 26px; color: var(--quiet); font-size: 12px; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<main>
  <div class="top">
    <div class="brand">Ullage</div>
    <select id="picker" aria-label="Session"></select>
  </div>

  <section class="card" id="card">
    <div class="head">
      <div class="who">
        <div class="name" id="project">—</div>
        <div class="line" id="path"></div>
        <div class="line ltr" id="model"></div>
      </div>
      <div class="left"><b class="num" id="headroom">—</b><span id="leftword">left</span></div>
    </div>
    <div class="track" id="track"><span class="fill" id="fill"></span></div>
    <div class="exact num"><span id="exact"></span><span id="used"></span></div>
    <div class="chart" id="chartbox" hidden>
      <svg id="chart" viewBox="0 0 320 96" preserveAspectRatio="none" aria-label="Context per turn"></svg>
      <div class="caption num" id="caption"></div>
    </div>
    <div id="sections"></div>
  </section>

  <p id="stale" hidden></p>

  <div id="alerts" hidden>
    <span id="alerts-text"></span>
    <button id="alerts-button" hidden></button>
  </div>

  <h2>Sessions</h2>
  <ol id="sessions"></ol>

  <footer>
    <a class="remote" id="remote" hidden target="_blank" rel="noopener">Open in Claude ↗</a>
    <div id="foot"></div>
  </footer>
</main>

<dialog id="confirm">
  <h4 id="cf-title"></h4>
  <div id="cf-body"></div>
  <div class="acts">
    <button class="cancel" id="cf-cancel" value="cancel">Cancel</button>
    <button class="go" id="cf-go" value="go">Run</button>
  </div>
</dialog>

<script>
(function () {
  var el = function (id) { return document.getElementById(id); };
  var timer = null, lastGood = null, lastJSON = '', snapshot = null;
  var chosen = null;
  try { chosen = localStorage.getItem('ullage.session'); } catch (e) {}

  function num(n) { return n == null ? '—' : n.toLocaleString('en-US'); }
  function share(o) { return o == null ? null : Math.floor(o * 100); }
  function ago(s) {
    if (s == null) return '';
    if (s < 90) return Math.round(s) + 's ago';
    if (s < 5400) return Math.round(s / 60) + ' min ago';
    if (s < 172800) return (s / 3600).toFixed(1) + ' hours ago';
    return (s / 86400).toFixed(1) + ' days ago';
  }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function compact(t) {
    if (t >= 1e6) return (t / 1e6).toFixed(1) + 'M';
    if (t >= 1e4) return Math.floor(t / 1000) + 'k';
    if (t >= 1e3) return (t / 1000).toFixed(1) + 'k';
    return String(t);
  }

  // ---- One collapsed line, drawn the way ReadoutLine draws it ------------
  function readoutLine(items, dots) {
    return items.map(function (r, i) {
      var dot = dots && dots[i] ? '<span class="dot" style="background:var(--c-' + dots[i] + ')"></span>' : '';
      var cls = r.isWarning ? 'w' : (r.isMuted ? 'm' : '');
      return (i ? '<span class="sep"> · </span>' : '') + '<span class="' + cls + '">' + dot + esc(r.label) +
        (r.value != null ? ' <b>' + esc(r.value) + '</b>' : '') + '</span>';
    }).join('');
  }

  // ---- Chart: the popover's line, its 85% rule, compactions, rebuilds ----
  function drawChart(chart, warn) {
    var box = el('chartbox'), svg = el('chart');
    if (!chart || chart.points.length < 2) { box.hidden = true; return; }
    box.hidden = false;
    var W = 320, H = 96, pts = chart.points;
    var first = pts[0][0], last = pts[pts.length - 1][0];
    var peak = Math.max.apply(null, pts.map(function (p) { return p[1]; }));
    var top = chart.windowLimit || peak || 1;
    var x = function (t) { return last === first ? 0 : (t - first) / (last - first) * W; };
    var y = function (v) { return H - 4 - (v / top) * (H - 8); };
    var line = pts.map(function (p, i) { return (i ? 'L' : 'M') + x(p[0]).toFixed(1) + ' ' + y(p[1]).toFixed(1); }).join(' ');
    var parts = [];
    parts.push('<path d="' + line + ' L' + W + ' ' + H + ' L0 ' + H + ' Z" fill="var(--fill)" opacity=".12"/>');
    if (chart.windowLimit) {
      var wy = y(chart.windowLimit * warn).toFixed(1);
      parts.push('<line x1="0" x2="' + W + '" y1="' + wy + '" y2="' + wy + '" stroke="var(--warn)" stroke-dasharray="2 4" opacity=".5" vector-effect="non-scaling-stroke"/>');
    }
    chart.compactions.forEach(function (t) {
      var cx = x(t).toFixed(1);
      parts.push('<line x1="' + cx + '" x2="' + cx + '" y1="0" y2="' + H + '" stroke="var(--faint)" stroke-dasharray="3 3" vector-effect="non-scaling-stroke"/>');
    });
    parts.push('<path d="' + line + '" fill="none" stroke="var(--fill)" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round"/>');
    chart.rebuilds.forEach(function (r) {
      var cx = x(r.turn), cy = y(r.contextTokens);
      parts.push('<path d="M' + (cx - 4) + ' ' + (cy + 3) + ' L' + cx + ' ' + (cy - 4) + ' L' + (cx + 4) + ' ' + (cy + 3) + ' Z" fill="' +
        (r.avoidable ? 'var(--warn)' : 'var(--faint)') + '"/>');
    });
    svg.innerHTML = parts.join('');
    el('caption').textContent = chart.caption || '';

    // Touch to read a turn, the popover's hover readout.
    svg.onpointermove = svg.onpointerdown = function (ev) {
      var rect = svg.getBoundingClientRect();
      var t = first + (ev.clientX - rect.left) / rect.width * (last - first);
      var near = pts.reduce(function (a, p) { return Math.abs(p[0] - t) < Math.abs(a[0] - t) ? p : a; }, pts[0]);
      var text = 'Turn ' + near[0] + ' · ' + num(near[1]) + ' tokens';
      if (chart.compactions.indexOf(near[0]) >= 0) text += ' · compacted before this turn';
      chart.rebuilds.forEach(function (r) {
        if (r.turn === near[0]) text += ' · re-cached ' + compact(r.cacheWrite) + ': ' + r.cause + (r.detail ? ', ' + r.detail : '');
      });
      el('caption').textContent = text;
    };
    svg.onpointerleave = function () { el('caption').textContent = chart.caption || ''; };
  }

  // ---- Sections ----------------------------------------------------------
  function isOpen(id) { try { return localStorage.getItem('ullage.open.' + id) === '1'; } catch (e) { return false; } }
  function remember(id, open) { try { localStorage.setItem('ullage.open.' + id, open ? '1' : '0'); } catch (e) {} }

  function rows(list) {
    return list.map(function (r) {
      var cls = 'row' + (r.warning ? ' w' : '') + (r.muted ? ' m' : '');
      var pad = r.depth ? ' style="padding-left:' + (r.depth * 14) + 'px"' : '';
      return '<div class="' + cls + '"' + pad + '><span class="l">' + esc(r.label) + '</span><span class="v">' + esc(r.value || '') + '</span>' +
        (r.detail ? '<span class="d">' + esc(r.detail) + '</span>' : '') +
        (r.bar != null ? '<span class="bar"><i style="width:' + Math.min(100, r.bar * 100).toFixed(1) + '%"></i></span>' : '') +
        '</div>';
    }).join('');
  }

  function sharesBar(shares, cls) {
    var total = shares.reduce(function (a, s) { return a + Math.max(0, s.tokens); }, 0) || 1;
    return '<span class="' + cls + '">' + shares.map(function (s) {
      return '<i style="flex:' + Math.max(0, s.tokens) / total + ';background:var(--c-' + s.key + ')"></i>';
    }).join('') + '</span>';
  }

  function saverBlock(s) {
    var control = s.canSwitch
      ? '<button class="switch" role="switch" aria-checked="' + (s.switchState === 'on') + '" aria-label="' + esc(s.name) +
        ' enabled" data-saver="' + s.id + '" data-action="' + (s.switchState === 'on' ? 'off' : 'on') + '"></button>'
      : '<button class="linkbtn more" data-plan="' + s.id + '" data-kind="install">' + (s.isInstalled ? 'Set up' : 'Install') + '</button>';
    return '<div class="saver"><div class="top1">' + control +
      '<span class="nm">' + esc(s.name) + '</span>' +
      '<span class="mt' + (s.metricWarning ? ' w' : '') + '">' + esc(s.metric) + '</span>' +
      (s.metricCaption ? '<span class="mc">' + esc(s.metricCaption) + '</span>' : '') +
      (s.isInstalled ? '<button class="linkbtn" data-plan="' + s.id + '" data-kind="uninstall" aria-label="Uninstall ' + esc(s.name) + '">⋯</button>' : '') +
      '</div>' +
      (s.pending ? '<div class="pend">' + esc(s.pending) +
        (s.canUndo ? ' <button class="linkbtn" data-saver="' + s.id + '" data-action="undo">Undo</button>' : '') + '</div>' : '') +
      '<div class="sub">' + esc(s.line) + '</div>' +
      (s.note ? '<div class="note">' + esc(s.note) + '</div>' : '') +
      '</div>';
  }

  function sectionHTML(sec) {
    var collapsedRule = sec.shares ? sharesBar(sec.shares, 'ln shares') : '<span class="ln"></span>';
    var body = '';
    if (sec.warning) body += '<p class="warning">' + esc(sec.warning) + '</p>';
    if (sec.shares) body += sharesBar(sec.shares, 'bigbar');
    if (sec.savers) body += sec.savers.map(saverBlock).join('');
    (sec.groups || []).forEach(function (g) {
      body += '<div class="grp">' + (g.heading ? '<h3>' + esc(g.heading) + '</h3>' : '') + rows(g.rows) + '</div>';
    });
    if (sec.installable && sec.installable.length) {
      body += '<div class="grp"><h3>Not installed</h3>' + sec.installable.map(function (i) {
        return '<div class="row"><span class="l">' + esc(i.name) + ' <span style="color:var(--faint)">— shrinks ' + esc(i.shrinks) +
          '</span></span><span class="v"><button class="linkbtn" data-plan="' + i.id + '" data-kind="install">Install…</button></span></div>';
      }).join('') + '</div>';
    }
    (sec.legend || []).forEach(function (line) { body += '<p class="legend">' + esc(line) + '</p>'; });
    return '<details data-id="' + sec.id + '"' + (isOpen(sec.id) ? ' open' : '') + '>' +
      '<summary><div class="rule"><span class="t">' + esc(sec.title) + '</span>' + collapsedRule + '<span class="chev">›</span></div>' +
      '<div class="readout num">' + readoutLine(sec.summary, sec.dots) + '</div></summary>' +
      '<div class="body">' + body + '</div></details>';
  }

  function render(snap) {
    snapshot = snap;
    var d = snap.detail, warn = snap.warningThreshold || 0.85;
    var quiet = !d || d.status === 'idle' || d.status === 'empty';
    document.body.classList.toggle('warn', !!d && d.occupancy != null && d.occupancy >= warn);
    document.body.classList.toggle('quiet', quiet);

    // Picker: follow the latest, or hold one session still.
    var picker = el('picker');
    picker.innerHTML = '<option value="">Latest session</option>' + snap.sessions.map(function (s) {
      return '<option value="' + esc(s.sessionId) + '"' + (chosen === s.sessionId ? ' selected' : '') + '>' +
        esc((s.project || '—') + ' · ' + s.sessionId.slice(0, 8)) + '</option>';
    }).join('');

    if (!d) {
      el('project').textContent = 'No sessions ingested yet';
      el('path').textContent = ''; el('model').textContent = '';
      el('headroom').textContent = '—'; el('fill').style.width = '0%';
      el('exact').textContent = ''; el('used').textContent = '';
      el('sections').innerHTML = ''; el('chartbox').hidden = true; el('remote').hidden = true;
    } else {
      el('project').textContent = d.project || '—';
      // Right-aligned so a long path loses its start, not its end; the marks
      // keep the browser from reordering '~/' to the far side.
      el('path').textContent = d.path ? '\u200E' + d.path + '\u200E' : '';
      el('model').innerHTML = esc(d.modelLine || '') + (d.modelWindowIsAssumed ? '<span class="badge">window assumed</span>' : '') +
        (d.isLatest ? '' : ' · <span style="color:var(--accent)">not the latest</span>');
      el('headroom').textContent = d.headroom;
      el('leftword').hidden = d.headroom === '—';
      var p = share(d.occupancy);
      el('fill').style.width = p == null ? '0%' : Math.min(100, p) + '%';
      var track = el('track');
      track.querySelectorAll('.tick').forEach(function (t) { t.remove(); });
      var w = document.createElement('span'); w.className = 'tick'; w.style.left = (warn * 100) + '%'; track.appendChild(w);
      if (d.peakOccupancy != null && d.peakOccupancy > (d.occupancy || 0) + 0.005) {
        var k = document.createElement('span'); k.className = 'tick peak';
        k.style.left = Math.min(99.5, d.peakOccupancy * 100) + '%'; track.appendChild(k);
      }
      el('exact').textContent = d.exactLine;
      el('used').textContent = d.usedLine || '';
      var remote = el('remote');
      remote.hidden = !d.remoteURL;
      if (d.remoteURL) remote.href = d.remoteURL;
      drawChart(d.chart, warn);
      el('sections').innerHTML = d.sections.map(sectionHTML).join('');
      el('sections').querySelectorAll('details').forEach(function (det) {
        det.addEventListener('toggle', function () { remember(det.dataset.id, det.open); });
      });
    }

    var list = el('sessions');
    list.innerHTML = '';
    snap.sessions.forEach(function (s) {
      var p2 = share(s.occupancy);
      var li = document.createElement('li');
      if (d && s.sessionId === d.sessionId) li.className = 'on';
      li.innerHTML =
        '<span class="name">' + esc(s.project || '—') + '</span>' +
        '<span class="share' + (p2 == null ? ' none' : (s.occupancy >= warn ? ' warn' : '')) + '">' + (p2 == null ? '—' : p2 + '%') + '</span>' +
        (s.path ? '<span class="path">\u200E' + esc(s.path) + '\u200E</span>' : '') +
        '<span class="sub2">' + esc(s.sessionId.slice(0, 8)) + ' · ' + s.calls + ' turns' +
          (s.agents ? ' · ' + s.agents + ' agents' : '') + ' · ' + ago(s.ageSeconds) + '</span>';
      li.onclick = function () { choose(s.sessionId); window.scrollTo({ top: 0, behavior: 'smooth' }); };
      list.appendChild(li);
    });
    el('foot').textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  function choose(id) {
    chosen = id || null;
    try { if (chosen) localStorage.setItem('ullage.session', chosen); else localStorage.removeItem('ullage.session'); } catch (e) {}
    lastJSON = '';
    tick();
  }
  el('picker').addEventListener('change', function (e) { choose(e.target.value); });

  // ---- Token saver actions: switches, Undo, install, uninstall ------------
  // Every change goes through POST /savers, which only accepts this page's
  // own origin plus the X-Ullage header.
  function act(saver, action) {
    return fetch('savers', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Ullage': '1' },
      body: JSON.stringify({ saver: saver, action: action })
    }).then(function (r) {
      return r.text().then(function (t) { if (!r.ok) throw new Error(t.trim()); });
    }).then(function () { lastJSON = ''; tick(); })
      .catch(function (e) { alert(e.message || 'Could not change it.'); });
  }

  function confirmPlan(saver, kind) {
    fetch('savers/plan?saver=' + encodeURIComponent(saver) + '&action=' + kind, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then(function (plan) {
        var dlg = el('confirm'), go = el('cf-go'), cancel = el('cf-cancel');
        var uninstall = kind === 'uninstall';
        el('cf-title').textContent = (uninstall ? 'Uninstall ' : 'Install ') + plan.saver + '?';
        var html = '';
        if (plan.missing.length) html += '<p>Needs ' + esc(plan.missing.join(' and ')) + ', which isn’t on the Mac.</p>';
        if (plan.steps.length) {
          html += '<ol>' + plan.steps.map(function (s, i) {
            return '<li>' + (i + 1) + '. ' + esc(s.purpose) + (s.interactive ? ' <b>(needs you at the Mac)</b>' : '') +
              '<code>$ ' + esc(s.command) + '</code></li>';
          }).join('') + '</ol>';
          html += '<p>These are ' + esc(plan.saver) + '’s own commands. They run in a Terminal window on the Mac, and this page shows how it went.</p>';
        }
        if (plan.needsPerson) html += '<p><b>Part of this needs someone at the Mac</b> (a sign-in or a prompt), so start it from the menu bar there.</p>';
        plan.notes.forEach(function (n) { html += '<p>' + esc(n) + '</p>'; });
        el('cf-body').innerHTML = html;
        var runnable = plan.runnable && !plan.needsPerson;
        go.hidden = !runnable;
        go.textContent = uninstall ? 'Uninstall on the Mac' : 'Install on the Mac';
        go.classList.toggle('danger', uninstall);
        cancel.textContent = runnable ? 'Cancel' : 'OK';
        go.onclick = function () { dlg.close(); act(saver, kind); };
        cancel.onclick = function () { dlg.close(); };
        dlg.showModal();
        // Nothing that removes anything is the default: Cancel holds focus.
        (uninstall || !runnable ? cancel : go).focus();
      })
      .catch(function (e) { alert(e.message || 'Could not load the plan.'); });
  }

  el('sections').addEventListener('click', function (e) {
    var b = e.target.closest('button');
    if (!b) return;
    e.preventDefault(); e.stopPropagation();
    if (b.dataset.plan) { confirmPlan(b.dataset.plan, b.dataset.kind); return; }
    if (b.dataset.saver) { act(b.dataset.saver, b.dataset.action); }
  });

  // ---- Polling -----------------------------------------------------------
  function setStale(message) {
    document.body.classList.toggle('stale', !!message);
    el('stale').hidden = !message;
    if (message) el('stale').textContent = message;
  }

  function tick() {
    var url = 'state.json' + (chosen ? '?session=' + encodeURIComponent(chosen) : '');
    fetch(url, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.text(); })
      .then(function (text) {
        lastGood = Date.now(); setStale(null);
        // Redrawn only when something changed, so an open section, a scroll
        // position or a finger on the chart is not reset every few seconds.
        var body = text.replace(/"(generatedAt|ageSeconds)":[^,}]*/g, '');
        if (body === lastJSON) return;
        lastJSON = body;
        var snap = JSON.parse(text);
        if (chosen && snap.detail && snap.detail.sessionId !== chosen) { chosen = null; }
        render(snap);
      })
      .catch(function () {
        var since = lastGood ? ago((Date.now() - lastGood) / 1000) : 'since loading';
        setStale('Not reachable — last update ' + since + '. Is the Mac awake?');
      });
  }

  function schedule() {
    clearInterval(timer);
    if (document.visibilityState === 'visible') { tick(); timer = setInterval(tick, 4000); }
  }
  document.addEventListener('visibilitychange', schedule);
  schedule();

  // ---- Alerts -------------------------------------------------------------
  // Web Push, so the phone is told at 85% with this page closed and in a
  // pocket. iOS only allows any of this inside a web app installed to the home
  // screen — in a plain Safari tab Notification.requestPermission does not even
  // exist — so the first thing this does is work out which of those it is in,
  // and say so rather than failing silently.

  var alertsBox = el('alerts'), alertsText = el('alerts-text'), alertsButton = el('alerts-button');

  function installed() {
    return window.navigator.standalone === true ||
      (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches);
  }

  function isApple() { return /iPad|iPhone|iPod/.test(navigator.userAgent); }

  function say(text, action, handler) {
    alertsBox.hidden = false;
    alertsText.textContent = text;
    alertsButton.hidden = !action;
    alertsButton.disabled = false;
    if (action) { alertsButton.textContent = action; alertsButton.onclick = handler; }
  }

  function keyBytes(base64url) {
    var padded = (base64url + '==='.slice((base64url.length + 3) % 4))
      .replace(/-/g, '+').replace(/_/g, '/');
    var raw = atob(padded), bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i); }
    return bytes;
  }

  function enable() {
    alertsButton.disabled = true;
    alertsText.textContent = 'Asking…';
    navigator.serviceWorker.register('sw.js')
      .then(function (reg) {
        return Notification.requestPermission().then(function (permission) {
          if (permission !== 'granted') { throw new Error('Permission denied.'); }
          return fetch('push-key.json').then(function (r) { return r.json(); })
            .then(function (conf) {
              return reg.pushManager.subscribe({
                userVisibleOnly: true,
                applicationServerKey: keyBytes(conf.publicKey)
              });
            });
        });
      })
      .then(function (sub) {
        return fetch('subscribe', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(sub)
        });
      })
      .then(function (r) {
        if (!r.ok) { throw new Error('Server refused the subscription.'); }
        say('Alerts on for this device.');
      })
      .catch(function (e) { say(e.message || 'Could not enable alerts.', 'Try again', enable); });
  }

  function initAlerts() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
      // On iOS this is what a plain Safari tab looks like, and the fix is not
      // obvious unless someone says it.
      if (isApple() && !installed()) {
        say('For alerts, add this page to your Home Screen, then open it from there.');
      } else {
        say('This browser cannot do push notifications.');
      }
      return;
    }
    if (Notification.permission === 'denied') {
      say('Notifications are blocked for this site in browser settings.');
      return;
    }
    navigator.serviceWorker.getRegistration().then(function (reg) {
      if (!reg) { say('Get told when a window fills up.', 'Enable alerts', enable); return; }
      reg.pushManager.getSubscription().then(function (sub) {
        if (sub && Notification.permission === 'granted') { say('Alerts on for this device.'); }
        else { say('Get told when a window fills up.', 'Enable alerts', enable); }
      });
    });
  }

  initAlerts();
})();
</script>
</body>
</html>
"""#

    public static let manifest = #"""
{
  "name": "Ullage",
  "short_name": "Ullage",
  "start_url": ".",
  "scope": ".",
  "display": "standalone",
  "background_color": "#13181d",
  "theme_color": "#13181d",
  "icons": [
    { "src": "icon.png", "sizes": "192x192", "type": "image/png", "purpose": "any" }
  ]
}
"""#

    /// The service worker. Its only real job is to exist when a push arrives —
    /// the page is closed by then, and this is the only thing left running.
    ///
    /// No caching: the whole point of the page is a number that is true now, and
    /// a cached gauge is worse than no gauge. The `fetch` listener is here
    /// because some browsers will not treat a worker without one as installable,
    /// and it deliberately does nothing.
    public static let serviceWorker = #"""
self.addEventListener('install', function (event) { self.skipWaiting(); });
self.addEventListener('activate', function (event) { event.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function (event) { /* network only, on purpose */ });

self.addEventListener('push', function (event) {
  var data = {};
  try { data = event.data ? event.data.json() : {}; }
  catch (e) { data = { title: 'Ullage', body: event.data ? event.data.text() : '' }; }

  event.waitUntil(self.registration.showNotification(data.title || 'Ullage', {
    body: data.body || '',
    icon: 'icon.png',
    badge: 'icon.png',
    // One tag per stream, so a session that climbs past 85% and then 95%
    // replaces its own notification instead of stacking two. You want the
    // current number, not a history of it.
    tag: data.tag || 'ullage',
    renotify: true,
    data: { url: data.url || '.' }
  }));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (windows) {
      for (var i = 0; i < windows.length; i++) {
        if ('focus' in windows[i]) { return windows[i].focus(); }
      }
      if (self.clients.openWindow) { return self.clients.openWindow(event.notification.data.url); }
    })
  );
});
"""#
}
