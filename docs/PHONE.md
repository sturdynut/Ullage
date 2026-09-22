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

## Not here yet

Notifications. Seeing the gauge requires opening the page, which is the wrong
shape for "tell me when this session is nearly full". The route for that is an
installable web app plus Web Push, which is why the HTTPS above is load-bearing.
