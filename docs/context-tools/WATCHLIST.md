# Context Tools Watchlist

Weekly tracking of context-saving tools for AI coding agents.

| Tool | Kind | Harnesses | Repo/home | Latest version | Checked |
|---|---|---|---|---|---|
| rtk | outputFilter | Claude Code, Copilot CLI, Cursor | https://github.com/rtk-ai/rtk | v1.2.0 | 2026-11-09 |
| Tokenade | outputFilter | Claude Code, Copilot CLI, Cursor | https://github.com/pi-infected/tokenade | v2.0.9 | 2026-11-09 |
| caveman | replyStyle | Claude Code (plugin) | https://github.com/JuliusBrussee/caveman | v4.1.0 | 2026-11-09 |
| Headroom | onDemand | Claude Code, Cursor | https://github.com/headroomlabs-ai/headroom | 0.43.1 | 2026-11-09 |
| Serena | codeSearch | Claude Code | https://github.com/oraios/serena | v2.1.0 | 2026-11-09 |
| codegraph | codeSearch | Claude Code, Cline, Cursor | https://github.com/colbymchenry/codegraph | 1.6.2 | 2026-11-09 |
| claude-context | codeSearch | Claude Code | https://github.com/zilliztech/claude-context | 0.1.15 | 2026-11-09 |
| claude-mem | memory | Claude Code (plugin) | https://github.com/thedotmack/claude-mem | v15.13.0 | 2026-11-09 |

## New Candidates (First Check)

Kinds are the descriptor kinds in `docs/CONTEXT-TOOLS.md`. Latest version is the
GitHub release on the date checked.

| Tool | Kind | Harnesses | Repo/home | Latest | Status | Notes |
|---|---|---|---|---|---|---|
| token-optimizer-mcp | onDemand | Claude Code, multiple CLI clients | https://github.com/ooples/token-optimizer-mcp | v7.9.0 | candidate | MCP server, claims 60-90% reduction |
| squeez | outputFilter | Claude Code, OpenCode, Copilot CLI, others | https://github.com/claudioemmanuel/squeez | v1.49.2 | candidate | Hook plus MCP server, claims up to 95% bash compression |
| winnow | outputFilter | Claude Code, generic | https://github.com/jpoindexter/winnow | no release (pushed 2026-07-09) | candidate | Recoverable compression, claims 40-95% |
| mcp-compressor | onDemand | Claude Code (MCP) | https://github.com/atlassian-labs/mcp-compressor | v0.40.0 | candidate | Schema compression proxy, claims 70-97% |
| context-firewall | onDemand | Claude Code, Cursor | https://github.com/alepha188838884/context-firewall | v0.4.0 | candidate | Wraps MCP servers, claims 60-95% output reduction |
| context-compress | outputFilter | Claude Code (MCP + hook) | https://github.com/Open330/context-compress | v2026.8.3 | candidate | Structural compression, claims 99.2% reduction |
| honest-done | outputFilter | Claude Code | https://github.com/moelsaka01/honest-done | no release (pushed 2026-11-09) | candidate | Stop hook, blocks premature 'All done!' signals |
| teyla | onDemand | Claude Code, Codex, Cursor, Grok, Hermes | https://github.com/zaitsew/teyla | no release (pushed 2026-11-09) | candidate | Token optimization + memory control, unified hooks |
| trimtok | onDemand | Claude Code, Cursor, Codex, Gemini, others | https://github.com/Stxyu-p/trimtok | no release (pushed 2026-11-09) | candidate | Universal compressor, 88.3% reduction via AST |
| context-pruner-mcp | onDemand | Claude Code (MCP) | https://github.com/Zn0w/context-pruner-mcp | no release (pushed 2026-11-01) | candidate | Tool output compression, 50-80% reduction |
| lean-ctx | Multi-tool | Cursor, Claude Code, Copilot, 20+ | https://github.com/yvgude/lean-ctx | v3.5.0 | candidate | MCP + shell hook in Rust, 61-62 MCP tools |
| PindeX | codeSearch | Claude Code (MCP) | https://github.com/phash/PindeX | unconfirmed | candidate | SQLite-based code indexer, 70-80% reduction |
| context-optimizer | — | Claude Code | https://github.com/egorfedorov/claude-context-optimizer | v5.0.2 | not a saver | Tracks usage and reports waste; shrinks nothing itself |
| context-compress (vidanov) | — | Claude Code, others | https://github.com/vidanov/context-compress | no release (pushed 2026-05-26) | stale | Same name as Open330's; compresses instruction files |
| ReCompress | — | Generic (research) | — | — | research | UC Berkeley hackathon prize, model-based |
| CtxGuard | — | Generic (research) | — | — | research | Governance gateway, Chinese docs |
| claude-code-hooks | — | Claude Code | — | — | research | Plugin marketplace, not itself a saver |
