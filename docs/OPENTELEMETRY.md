# Exporting to OpenTelemetry

Ullage reads local transcripts and keeps them in a local SQLite file. The OTLP
export is how that leaves the machine on purpose: one command, to any collector
that speaks OTLP/HTTP, so several machines and several harnesses aggregate in
one place.

```bash
ullage otlp --endpoint http://localhost:4318          # metrics + spans
ullage otlp --dry-run --days 1 | head -40             # see exactly what would go
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.com \
OTEL_EXPORTER_OTLP_HEADERS="api-key=…" ullage otlp    # the standard variables work
```

Nothing is sent unless you run this. There is no background exporter, no
telemetry about Ullage itself, and `--dry-run` prints the payloads instead of
sending them so you can read what would leave before it does. (The one other
thing that ever leaves the machine is a push notification, and only to a device
you have explicitly subscribed — see [`PHONE.md`](PHONE.md).)

## The one thing to get right

`gen_ai.usage.input_tokens` means **the whole prompt**. Claude's
`input_tokens` does not — it is the *uncached remainder*, which on a cached
session is a rounding error against the real prompt:

| | value |
|---|---|
| `message.usage.input_tokens` | 5 |
| `message.usage.cache_read_input_tokens` | 20,000 |
| `message.usage.cache_creation_input_tokens` | 1,200 |
| **prompt** | **21,205** |

So the export sends `gen_ai.usage.input_tokens = 21205`, and the three counters
travel separately under their own names. Exporting the raw `input_tokens` under
the standard name would understate every cached session by three orders of
magnitude — in someone else's dashboard, where nobody can see the mistake.

The counters are never summed into one number, here or anywhere else: a heavy
session is ~99% cache reads, so a single "total tokens" is a cache-read number
wearing a disguise.

## Metrics

Cumulative sums and point-in-time gauges, one data point per **stream** — a
session's main thread, or one of its subagents, because that is the only
grouping where a context window means anything.

| Metric | Type | Unit | What it is |
|---|---|---|---|
| `ullage.tokens` | sum | `{token}` | Tokens, split by `ullage.token.type`: `input`, `output`, `cache_read`, `cache_write` |
| `ullage.turns` | sum | `{turn}` | API calls recorded |
| `ullage.tool.calls` | sum | `{call}` | Tool invocations |
| `ullage.tool.result_tokens` | sum | `{token}` | Size of tool results — **estimated** from their length, and tagged `ullage.estimated=true` |
| `ullage.compactions` | sum | `{event}` | Times the window was compacted |
| `ullage.context.tokens` | gauge | `{token}` | The last prompt's size: what is in the window now |
| `ullage.context.window` | gauge | `{token}` | The window this stream runs in |
| `ullage.context.occupancy` | gauge | `1` | Prompt over window, 0–1 |

Sums are **cumulative**, covering everything on disk, so running the export
twice changes nothing a backend sees — no cursor, no double counting.

Every data point carries:

`gen_ai.system` (`anthropic`, `openai`, `cursor`), `gen_ai.request.model`,
`ullage.harness` (`claude-code`, `codex`, `cursor`), `ullage.project`,
`ullage.session_id`, `ullage.agent_id`, `ullage.agent_type`, `ullage.stream`
(`main` or `agent`), `ullage.confidence`.

## Traces

A session is a trace. Each turn is a span. Each subagent is a span under **the
turn that spawned it**, with its own turns under that — the tree is already on
disk, because the spawning tool call names the child exactly, and a trace is the
one format every backend can already draw it in.

```
session marketing-site            ← root span, first turn to last
├── chat claude-opus-5            ← a turn
├── chat claude-opus-5            ← the turn that spawned an agent
│   └── agent Audit the API surface
│       ├── chat claude-sonnet-4-5
│       └── chat claude-sonnet-4-5
└── chat claude-opus-5
```

Trace and span ids are derived from the ids already on disk (`sessionId`,
`message.id`, `agentId`), so re-exporting a session produces the same spans
rather than a second copy of the run. A compaction is an event on the span of
the stream that compacted.

Turn spans carry the `gen_ai.*` attributes above plus `ullage.context.tokens`,
`ullage.context.window`, `ullage.context.occupancy`, `ullage.context.delta` and
`ullage.turn`.

Spans are **not** idempotent the way cumulative metrics are, so they are sent
from wherever the last successful export to that endpoint finished. The cursor
is per endpoint, in the `otlp_cursor` table. `--days N` overrides it; `--all`
sends every span on disk.

## A harness that measures nothing

Cursor records no tokens and no window locally. Those rows export **activity
only** — `ullage.turns`, `ullage.tool.calls` — with `ullage.confidence =
unmeasured`, and no token counters, no window and no occupancy. A zero beside
three real numbers reads as a measurement, so it is not sent.

## Running it

Anything that speaks OTLP/HTTP works: the OpenTelemetry Collector, Grafana
Alloy, Honeycomb, Datadog, Jaeger (traces), Prometheus via the collector's
`prometheusremotewrite` exporter. A minimal collector config:

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug: { verbosity: detailed }
service:
  pipelines:
    metrics: { receivers: [otlp], exporters: [debug] }
    traces:  { receivers: [otlp], exporters: [debug] }
```

Payloads are split across requests (400 spans or 150 streams each, roughly a
megabyte) because collectors cap request bodies.

To keep a backend current, run it on a schedule — there is no daemon:

```bash
*/15 * * * * /usr/local/bin/ullage otlp --endpoint http://localhost:4318
```

## Questions worth asking of the exported data

- Which project burns the most cache reads?
  `sum by (ullage_project) (ullage_tokens{ullage_token_type="cache_read"})`
- Which sessions are close to compaction?
  `max by (ullage_session_id) (ullage_context_occupancy) > 0.85`
- Do subagents cost more than the thread that spawned them?
  `sum by (ullage_stream) (ullage_tokens{ullage_token_type="output"})`
- Which agent types are spawned most, and how full do they get?
  `avg by (ullage_agent_type) (ullage_context_occupancy)`

(Metric and attribute names are shown as a Prometheus backend renders them —
dots become underscores. In a backend that keeps dots, use the names above.)
