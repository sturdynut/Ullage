# Harnesses Ullage does not read

| Harness | Why |
|---|---|
| **Kiro** | Closed-source VS Code fork. Its agent state sits in an undocumented extension `globalStorage`, so no writer code can be checked against it, and no token or window fields are documented. |
| **Continue** | `~/.continue/sessions/<id>.json` holds conversation content. Its only token counts are dev-data `tokensGenerated` events (`promptTokens`, `generatedTokens`; `packages/config-yaml/src/schemas/data/tokensGenerated`), which carry no session id, cache split or window, so they can't be tied to a session's context. |
| **Windsurf** | Subscription IDE: usage is metered server-side, and local storage holds conversation state only. |
| **Warp** | Agent conversations are stored and metered by Warp's service, with no local per-turn token log. |
| **Gemini Code Assist, Amazon Q (IDE)** | Cloud-metered, with nothing local beyond conversation content. |
| **Any cloud or web session** | Nothing is on disk. |

The rule from `CLAUDE.md` holds: local-first CLI agents write usage because they
need it offline, while subscription-metered IDEs keep it on their servers. A
harness can move off this list when its local files are shown to carry per-turn
prompt tokens.
