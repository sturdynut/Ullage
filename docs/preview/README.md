# Menu bar preview

`menu-bar-preview.html` is a design reference, not a screenshot: an HTML
rendering of what `MenuBarExtra` puts in the menu bar, drawn on a machine that
cannot compile the SwiftUI. Open it in a browser.

It shows the four states the code produces — live, over the 85% warning
threshold, idle after 30 minutes, and nothing ingested — with the titles taken
from `MenuBarFormatter` and the menu rows from `MenuContent`, in order.

The occupancy chart at the bottom is **not** part of the app. Charts are a §2
non-goal for v1; it exists to show that the schema already holds everything a
later time-series view needs. Its numbers are real ingested rows: a synthetic
48-turn session was parsed and stored by the collector, and the series was read
back out of the `call` and `event` tables:

```sql
SELECT turn_index, ts, context_tokens, window_limit, context_delta FROM call ORDER BY turn_index;
SELECT ts, kind, detail FROM event ORDER BY ts;
```

`sample-series.json` is that export, and the same rows are inlined in the HTML
so the page stands alone. The compaction cliff in it — 87% to 14% between two
adjacent turns, with `context_delta` NULL across the boundary — is the argument
for the `event` table in one picture.
