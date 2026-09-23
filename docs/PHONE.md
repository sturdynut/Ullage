# Reading the gauge from a phone

The menu bar only helps in front of the Mac. If you drive a session from
somewhere else — Claude Code's remote control, a laptop in another room — the
number you want is on a machine you are not looking at.

`ullage serve` answers that: the same gauge, as a web page.

```bash
ullage serve                 # http://127.0.0.1:7878
ullage serve --port 9000
ullage serve --no-watch      # the app is already running and ingesting
```

By default it tails transcripts as well as serving them, so it is useful with
the app closed. With the app running, both processes ingest — which is safe
(WAL, a 5s busy timeout, and every ingest is idempotent) but redundant, so
`--no-watch` is the tidier pairing.

## Getting to it from the phone

Ullage binds `127.0.0.1` and offers no flag to bind anything else. Put
[Tailscale](https://tailscale.com) in front instead:

```bash
tailscale serve --bg 7878
tailscale serve status            # prints the https://<machine>.<tailnet>.ts.net URL
tailscale serve --https=443 off   # take it down again
```

You may need to enable **HTTPS Certificates** for the tailnet once, in the admin
console under DNS. Tailscale then terminates TLS with a real Let's Encrypt
certificate for the machine's tailnet name and proxies to loopback.

Why this rather than `--bind 0.0.0.0`:

- The page carries project names, repository paths and session ids. That is not
  coffee-shop-Wi-Fi material.
- Exposure is granted and revoked outside Ullage, by a tool whose whole job is
  deciding who may reach what. Nobody can leave a flag switched on by accident.
- It is real HTTPS, which matters more than it looks: browser notifications and
  installable web apps need a secure context, and `http://` over a tailnet is
  not one. Anything built on top of this page needs the certificate to exist.

## What it shows

The live gauge is the newest main-thread turn that has a window — the same row
that drives the menu bar, filtered by the same query, so the two cannot disagree.
Below it, recent sessions with their own occupancy.

The display rules are the menu bar's, not a second copy:

- The percentage is floored, so 99.6% never reads as full while there is room.
- Amber arrives at the same threshold the menu bar uses, sent in the payload
  rather than hardcoded in the page.
- A session older than the idle threshold shows a glyph, not a number.
- A harness that reported no window shows a dash. Never `0%` — an unmeasured
  session is not an empty one.

If the page cannot reach the Mac — asleep, off the tailnet, `serve` stopped —
it dims and says when it last heard back, rather than leaving a stale percentage
on screen looking authoritative. A number that cannot be refreshed is the
browser's version of a stale menu bar.

## Endpoints

| Path | What |
|---|---|
| `/` | The page |
| `/state.json` | The live gauge and recent sessions (`ServeSnapshot`) |
| `/healthz` | `ok` |

`state.json` is the whole contract; the page is just one consumer of it, and a
shell script watching for 85% is a reasonable second.

## The host check

Requests are refused unless their `Host` header is a loopback name or ends in
`.ts.net`. This is not decoration. A loopback HTTP server with no host check can
be read by any web page you visit: the page resolves a name it controls to
`127.0.0.1`, and the browser then treats the response as same-origin. The
allowlist closes that, and still lets Tailscale's proxy through under the
tailnet name — an attacker cannot make a name in someone else's tailnet resolve
to your loopback.

## Alerts

Opening a page to look at a gauge is the wrong shape for what you actually want,
which is to be told at 85% and otherwise left alone.

1. Open the `https://…ts.net` URL on the phone **in Safari**.
2. Share → **Add to Home Screen**.
3. Open it from the Home Screen, not from Safari.
4. Tap **Enable alerts** and allow notifications.

Step 3 is the one people skip. iOS permits notifications only inside an
installed web app — in a plain Safari tab `Notification.requestPermission` does
not exist at all — so the page detects that case and says so rather than
offering a button that cannot work.

Check it with:

```bash
ullage push          # which devices are subscribed, and how the last send went
ullage push --test   # buzz them all
```

### When it fires

Once when a stream crosses 85%, once more at 95%, and then nothing until a
compaction drops it back below. That restraint is the whole design: a
notification on every turn from 85% to the end is one you learn to swipe away
without reading.

What never alerts:

- **Subagents.** A subagent's window is its own and is not the one about to run
  out on you.
- **Harnesses that report no window.** No occupancy, no percentage, no buzz.
- **Backfills.** Only rows newer than the idle threshold count, because
  re-reading a month of transcripts crosses 85% thousands of times and none of
  it is news.
- **Assumed windows.** A Claude model the lookup table does not know falls
  back to 200k and is flagged "assumed" on screen. A buzz cannot carry that flag
  in a way anyone reads, so it does not buzz; the gauge still shows it, flagged.

A rung counts as said only once a device has actually been told: a delivery
that fails is retried on the next pass, never swallowed. The state is persisted
in `push_alert`, so restarting `serve` does not re-announce a window it already
announced. Evaluation runs every five seconds against the database, so it works
the same with `--no-watch` while the app does the ingesting.

### What leaves the machine

This is the one part of Ullage that sends anything anywhere without you typing a
command, so it is worth being exact about.

Nothing is sent until a device subscribes; there is no default recipient. Once
one has, a crossing produces an HTTPS POST to that device's push service —
`web.push.apple.com` for an iPhone. The body is encrypted with a key derived
from the device's own keypair (RFC 8291), so the push service relays ciphertext
it cannot read. It does see that a message was sent, when, and roughly how big.

The project name is in that encrypted body. If that matters to you, do not
subscribe a device; the gauge page still works.

Delete a subscription by clearing the site data on the device, or delete the row:

```bash
sqlite3 ~/Library/Application\ Support/com.sturdynut.ullage/telemetry.db \
  "DELETE FROM push_subscription;"
```

### Rotating the identity

The VAPID keypair is generated on first use and stored in `push_key`. Deleting
it invalidates every existing subscription, so nothing rotates it automatically;
if you do delete it, every device has to tap Enable alerts again.

### Regenerating the icon

`WebIcon.swift` holds a 192x192 PNG as base64, quantised to 32 colours and
full-bleed on the mark's own background (iOS masks home-screen icons to a
squircle and would otherwise round the already-rounded corners twice). It is
embedded rather than shipped as a resource because `install-app.sh` copies one
executable into the `.app` and a `Bundle.module` lookup would find nothing
there. Regenerate it from `assets/branding/ullage-logo.png` with PIL, then
paste the base64 back in.
