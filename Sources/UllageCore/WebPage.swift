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
<title>Ullage</title>
<style>
  :root {
    --bg: #fbfbfa; --panel: #fff; --ink: #1a1a19; --dim: #78786f;
    --rule: #e4e4dd; --fill: #3f7d5c; --warn: #a8542a; --quiet: #9a9a90;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #17171a; --panel: #1f1f23; --ink: #ececea; --dim: #8b8b84;
      --rule: #2e2e33; --fill: #5aa37a; --warn: #d4824a; --quiet: #6a6a63;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.45 ui-sans-serif, -apple-system, system-ui, sans-serif;
    padding: max(16px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom));
    -webkit-font-smoothing: antialiased;
  }
  main { max-width: 640px; margin: 0 auto; }
  h1 {
    font-size: 11px; letter-spacing: .14em; text-transform: uppercase;
    color: var(--dim); font-weight: 600; margin: 0 0 14px;
  }
  h2 {
    font-size: 11px; letter-spacing: .14em; text-transform: uppercase;
    color: var(--dim); font-weight: 600; margin: 28px 0 10px;
  }
  .card {
    background: var(--panel); border: 1px solid var(--rule);
    border-radius: 14px; padding: 20px;
  }
  .pct {
    font-size: 64px; line-height: 1; font-weight: 600;
    letter-spacing: -.03em; font-variant-numeric: tabular-nums;
  }
  body.warn .pct, body.warn .fill { color: var(--warn); }
  body.warn .fill { background: var(--warn); }
  body.quiet .pct { color: var(--quiet); font-weight: 400; }
  .track {
    height: 8px; border-radius: 4px; background: var(--rule);
    margin: 16px 0 14px; overflow: hidden;
  }
  .fill {
    display: block; height: 100%; width: 0; background: var(--fill);
    border-radius: 4px; transition: width .4s ease;
  }
  .meta { color: var(--dim); font-size: 13px; }
  .meta strong { color: var(--ink); font-weight: 600; }
  .tokens { font-variant-numeric: tabular-nums; }
  ol { list-style: none; margin: 0; padding: 0; }
  li {
    display: grid; grid-template-columns: 1fr auto; gap: 2px 12px;
    padding: 11px 0; border-bottom: 1px solid var(--rule); align-items: baseline;
  }
  li:last-child { border-bottom: 0; }
  .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sub { grid-column: 1; color: var(--dim); font-size: 12px; }
  .share {
    grid-row: 1 / span 2; align-self: center; text-align: right;
    font-variant-numeric: tabular-nums; font-size: 17px;
  }
  .share.none { color: var(--quiet); font-size: 15px; }
  .share.warn { color: var(--warn); }
  #stale {
    margin: 14px 0 0; padding: 10px 12px; border-radius: 10px;
    background: var(--rule); color: var(--dim); font-size: 13px;
  }
  body.stale .card { opacity: .5; }
  footer { margin-top: 26px; color: var(--quiet); font-size: 12px; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<main>
  <h1>Ullage</h1>

  <section class="card">
    <div class="pct" id="pct">&#9678;</div>
    <div class="track"><span class="fill" id="fill"></span></div>
    <div class="meta" id="where"></div>
    <div class="meta tokens" id="tokens"></div>
  </section>

  <p id="stale" hidden></p>

  <h2>Sessions</h2>
  <ol id="sessions"></ol>

  <footer id="foot"></footer>
</main>
<script>
(function () {
  var el = function (id) { return document.getElementById(id); };
  var pctEl = el('pct'), fillEl = el('fill'), whereEl = el('where'),
      tokensEl = el('tokens'), staleEl = el('stale'), listEl = el('sessions'), footEl = el('foot');
  var timer = null, lastGood = null;

  function num(n) { return n == null ? '—' : n.toLocaleString('en-US'); }

  // Floored, exactly as MenuBarFormatter does it: 99.6% must not read as full
  // while there is still room in the window.
  function share(o) { return o == null ? null : Math.floor(o * 100); }

  // Same buckets as the CLI's relative(), so two views of one number agree.
  function ago(s) {
    if (s == null) return '';
    if (s < 90) return Math.round(s) + 's ago';
    if (s < 5400) return Math.round(s / 60) + ' min ago';
    if (s < 172800) return (s / 3600).toFixed(1) + ' hours ago';
    return (s / 86400).toFixed(1) + ' days ago';
  }

  function render(snap) {
    var live = snap.live, warn = snap.warningThreshold || 0.85;
    var p = share(live.occupancy);
    var quiet = p == null || live.status === 'idle' || live.status === 'empty';

    document.body.classList.toggle('warn', live.status === 'warning');
    document.body.classList.toggle('quiet', quiet);

    pctEl.textContent = quiet ? '◎' : p + '%';
    fillEl.style.width = quiet ? '0%' : Math.min(100, p) + '%';

    if (live.status === 'empty') {
      whereEl.textContent = 'Nothing ingested yet.';
      tokensEl.textContent = '';
    } else {
      var bits = [];
      if (live.project) bits.push('<strong>' + esc(live.project) + '</strong>');
      if (live.model) bits.push(esc(live.model));
      bits.push(ago(live.ageSeconds));
      whereEl.innerHTML = bits.join(' &middot; ');

      var line = num(live.contextTokens) + ' / ' + num(live.windowLimit) + ' tokens';
      // Say so when the window came from a lookup miss rather than the
      // transcript: an assumed denominator makes an assumed percentage.
      if (live.modelWindowIsAssumed) line += ' · window assumed';
      if (live.contextDelta != null) {
        line += ' · ' + (live.contextDelta >= 0 ? '+' : '') + num(live.contextDelta) + ' this turn';
      }
      tokensEl.textContent = line;
    }

    listEl.innerHTML = '';
    snap.sessions.forEach(function (s) {
      var p2 = share(s.occupancy);
      var li = document.createElement('li');
      li.innerHTML =
        '<span class="name">' + esc(s.project || '—') + '</span>' +
        '<span class="share' + (p2 == null ? ' none' : (s.occupancy >= warn ? ' warn' : '')) + '">' +
          (p2 == null ? '—' : p2 + '%') + '</span>' +
        '<span class="sub">' + esc(s.sessionId.slice(0, 8)) + ' · ' + s.calls + ' turns' +
          (s.agents ? ' · ' + s.agents + ' agents' : '') + ' · ' + ago(s.ageSeconds) + '</span>';
      listEl.appendChild(li);
    });

    footEl.textContent = 'updated ' + new Date().toLocaleTimeString();
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  // A number that cannot be refreshed is the browser's version of a stale menu
  // bar: dim the card and say why, rather than leaving a confident percentage
  // on screen that stopped being true some minutes ago.
  function setStale(message) {
    document.body.classList.toggle('stale', !!message);
    staleEl.hidden = !message;
    if (message) staleEl.textContent = message;
  }

  function tick() {
    fetch('state.json', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
      .then(function (snap) { lastGood = Date.now(); render(snap); setStale(null); })
      .catch(function () {
        var since = lastGood ? ago((Date.now() - lastGood) / 1000) : 'since loading';
        setStale('Not reachable — last update ' + since + '. Is the Mac awake?');
      });
  }

  function schedule() {
    clearInterval(timer);
    if (document.visibilityState === 'visible') { tick(); timer = setInterval(tick, 3000); }
  }

  document.addEventListener('visibilitychange', schedule);
  schedule();
})();
</script>
</body>
</html>
"""#
}
