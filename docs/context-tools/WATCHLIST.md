# Context Tools Watchlist

Weekly tracking of context-saving tools for AI coding agents.

| Tool | Kind | Harnesses | Repo/home | Latest version | Checked |
|---|---|---|---|---|---|
| rtk | outputFilter | Claude Code, Copilot CLI, Cursor | https://github.com/rtk-ai/rtk | v1.0.1 | 2026-11-02 |
| Tokenade | outputFilter | Claude Code, Copilot CLI, Cursor | https://github.com/pi-infected/tokenade | 2.0.1 | 2026-11-02 |
| caveman | replyStyle | Claude Code (plugin) | https://github.com/JuliusBrussee/caveman | v4.0.1 | 2026-10-19 |
| Headroom | onDemand | Claude Code, Cursor | https://github.com/headroomlabs-ai/headroom | 0.41.0 | 2026-10-19 |
| Serena | codeSearch | Claude Code | https://github.com/oraios/serena | 2.0.0 | 2026-10-19 |
| codegraph | codeSearch | Claude Code, Cline, Cursor | https://github.com/colbymchenry/codegraph | 1.6.2 | 2026-10-19 |
| claude-context | codeSearch | Claude Code | https://github.com/zilliztech/claude-context | 0.1.15 | 2026-10-19 |
| claude-mem | memory | Claude Code (plugin) | https://github.com/thedotmack/claude-mem | v14.0.1 | 2026-10-19 |

## New Candidates (First Check)

Kinds are the descriptor kinds in `docs/CONTEXT-TOOLS.md`. Latest version is the
GitHub release on the date checked.

| Tool | Kind | Harnesses | Repo/home | Latest | Status | Notes |
|---|---|---|---|---|---|---|
| Graphify | codeSearch | Claude Code, Cursor, Codex, Gemini | https://github.com/Graphify-Labs/graphify | v0.9.34 | candidate | Knowledge graph, symbol lookups; benchmark claims 50%+ reduction |
| mcptoon | onDemand | Claude Code, Cursor, Codex, Cline | https://github.com/activeing123/mcptoon | v0.8.34 | candidate | CLI tool, MCP schemas out of context; claims 99.2% discovery reduction |
| token-optimizer-mcp | onDemand | Claude Code, multiple CLI clients | https://github.com/ooples/token-optimizer-mcp | v5.1.1 | candidate | MCP server, claims 60-90% reduction |
| squeez | outputFilter | Claude Code, OpenCode, Copilot CLI, others | https://github.com/claudioemmanuel/squeez | v1.48.18 | candidate | Hook plus MCP server, claims up to 95% bash compression |
| winnow | outputFilter | Claude Code, generic | https://github.com/jpoindexter/winnow | no release (pushed 2026-07-09) | candidate | Recoverable compression, claims 40-95% |
| mcp-compressor | onDemand | Claude Code (MCP) | https://github.com/atlassian-labs/mcp-compressor | v0.38.0 | candidate | Schema compression proxy, claims 70-97% |
| context-firewall | onDemand | Claude Code, Cursor | https://github.com/alepha188838884/context-firewall | v0.4.0 | candidate | Wraps MCP servers, claims 60-95% output reduction |
| context-compress | outputFilter | Claude Code (MCP + hook) | https://github.com/Open330/context-compress | v2026.8.3 | candidate | Structural compression, claims 99.2% reduction |
| context-optimizer | — | Claude Code | https://github.com/egorfedorov/claude-context-optimizer | v5.0.2 | not a saver | Tracks usage and reports waste; shrinks nothing itself |
| context-compress (vidanov) | — | Claude Code, others | https://github.com/vidanov/context-compress | no release (pushed 2026-05-26) | stale | Same name as Open330's; compresses instruction files |
| ReCompress | — | Generic (research) | — | — | research | UC Berkeley hackathon prize, model-based |
| CtxGuard | — | Generic (research) | — | — | research | Governance gateway, Chinese docs |
| claude-code-hooks | — | Claude Code | — | — | research | Plugin marketplace, not itself a saver |
