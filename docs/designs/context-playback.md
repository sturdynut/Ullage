# Context playback

Approved direction: a synchronized native playback workspace, with Ullage's
existing compact overview as the entry point. The user approved this direction
and delegated implementation decisions to the orchestrator on 2026-10-15.

## User experience

Open a session's Session page to follow its recorded requests and activity in
the playback workspace.
Select a step to inspect its usage, calls, results, and the context contents
that its source actually recorded. Selecting an older step pauses following;
incoming activity must not move that selection. An explicit live control
returns to the newest step. Each subagent remains its own context stream.
The track can interleave activity from the session's streams, with each step
labelled as main-thread or agent activity; an inspected step never combines
their context usage into one window.
The stream picker can narrow that track to the main thread or one agent.

The overview stays small. Detailed text belongs in the inspector, behind
disclosures where useful. A timeline entry is not itself proof that an exact
model-request snapshot exists.

[Native fixture preview](../screenshots/playback.png): the actual playback
workspace and inspector, rendered with synthetic events. This checks layout;
it is not a live recording or an end-to-end folder-picker check.

## Evidence and privacy

- Show source and availability beside inspected contents. A transcript is
  partial evidence of a conversation, not a complete model request.
- Show captured request contents only when the recorded linkage identifies
  the corresponding request. Preserve stated redactions and display limits.
- Missing, unsupported, malformed, deleted, or oversized source material must
  produce a clear availability message, never invented contents or a zero.
- Keep request bodies in their existing user-managed files. Load detail on
  demand; do not copy bodies into SQLite, `state.json`, the phone page, or OTLP.
  If source files disappear, their contents become unavailable for playback.
- Select a request-recording directory explicitly with the native folder
  picker. Do not search arbitrary directories for capture bodies.
- Treat source files and capture indexes as untrusted input. A capture index
  cannot authorize reading arbitrary paths outside its capture directory,
  including through a symlink.
- Do not enable capture, edit agent configuration, install an agent extension,
  or upload playback contents as part of this feature.

## Implementation boundaries

Reuse session discovery, ingestion, stored usage, session/agent selection, and
the native sidebar. Keep playback parsing and selection rules in Core where
possible. Load files and query SQLite off the main actor; discard asynchronous
results belonging to an old session or selected step. Bound file, line, entry, and
display sizes and communicate those limits in the inspector.

The initial reader supports Claude Code and Codex transcript activity. Other
harnesses retain their existing usage views and show that playback contents
are unavailable. The reader caps inspected lines and request bodies at 16 MiB,
reads at most 64 MiB across sources in a refresh, and retains a rolling history of
up to 10,000 steps / 64 MiB of event text. The native inspector previews up to
48,000 characters and offers the original source in Finder. These are explicit
inspection limits, not changes to the source recordings.

No new distribution channel is needed: playback ships in the existing native
app through the existing build, test, and packaging pipeline. The phone page
and CLI retain their current scope.

## Acceptance checks

1. A synthetic session opens a populated playback track and inspector without
   reading a user's real transcripts or database.
2. Recorded tool calls/results and usage are inspectable; absent contents say
   why they are absent. Transcript contents never carry an exact-request claim.
3. Captured request fixtures join only to the request they identify. Invalid
   paths, traversal, symlink escapes, and missing or malformed files are handled.
4. Appending activity while an old step is selected preserves that selection;
   returning live selects the newest step. Switching session or selecting an
   agent's step cannot display another stream's delayed load.
5. Loading, empty, unavailable, and error states remain usable. The playback
   controls have keyboard and accessibility labels.
6. Bounded parsing and detail loading leave the main UI responsive. Raw bodies
   are absent from persisted state and existing server/export payloads.
7. Run focused fixture tests, the full XCTest suite, SwiftLint, and existing
   coverage/install checks. Record live vendor-format validation separately
   from fixture evidence; a passing fixture is not a live capture check.

## Deferred work

Cross-agent skill, plugin, and hook management; selective manual compaction;
LLM summaries; reusable context packets and their provenance; replay editing;
and automatic capture setup are outside this implementation. The selected
interaction leaves room for them without adding their controls now.

## Validation evidence

The implementation was reviewed against synthetic transcripts and request
indexes, including split streamed blocks, malformed and missing files,
counter overflow, path traversal, symlink escapes, special files, source
replacement, and rolling-history limits. App tests exercise selection and
asynchronous result isolation. The full suite passed 465 tests with no failures;
Core line coverage was 89.80%, above the required 85%. Strict SwiftLint and
the 12 Python coverage/install checks passed.

The checked-in preview renders the real native workspace with synthetic data.
A separate native harness using `NSApplication.run` also verified the actual
`MainWindow` Session page, window visibility, actor-backed source loading, and
the expected synthetic marker in the inspector's `NSTextView`. This validates
the native loading path beyond the layout fixture.

The native folder-picker interaction remains unverified. No user capture was
enabled and no live vendor request recording was inspected; synthetic evidence
does not establish live recorder-format compatibility.

## Next real-world validation

Use playback during one ordinary coding session, pause on a surprising step,
and check whether the inspector explains what happened without requiring a
second tool. Compare one user-enabled request capture against the vendor's
recorded source before claiming live request-format compatibility.
