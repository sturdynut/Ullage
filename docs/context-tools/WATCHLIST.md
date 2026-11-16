# Context Tools Watchlist

Weekly tracking of context-saving tools for AI coding agents.

| Tool | Kind | Harnesses | Repo/home | Latest version | Checked |
|---|---|---|---|---|---|
| rtk | outputFilter | Claude Code, Copilot CLI, Cursor | https://github.com/rtk-ai/rtk | v0.47.0 (2026-09-01) | 2026-11-16 |
| Tokenade | outputFilter | Claude Code, Copilot CLI, Cursor | https://github.com/pi-infected/tokenade | 2.0.1+ | 2026-11-16 |
| caveman | replyStyle | Claude Code (plugin) | https://github.com/JuliusBrussee/caveman | v4.0.1+ | 2026-11-16 |
| Headroom | onDemand | Claude Code, Cursor | https://github.com/headroomlabs-ai/headroom | 0.41.0+ | 2026-11-16 |
| Serena | codeSearch | Claude Code | https://github.com/oraios/serena | 2.0.0+ | 2026-11-16 |
| codegraph | codeSearch | Claude Code, Cline, Cursor | https://github.com/colbymchenry/codegraph | 1.6.2+ | 2026-11-16 |
| claude-context | codeSearch | Claude Code | https://github.com/zilliztech/claude-context | 0.1.15+ | 2026-11-16 |
| claude-mem | memory | Claude Code (plugin) | https://github.com/thedotmack/claude-mem | v15.15.2+ | 2026-11-16 |

## New Candidates (First Check)

Kinds are the descriptor kinds in `docs/CONTEXT-TOOLS.md`. Latest version is the
GitHub release on the date checked.

| Tool | Kind | Harnesses | Repo/home | Latest | Status | Notes |
|---|---|---|---|---|---|---|
| code-context-engine | codeSearch | Claude Code | https://github.com/elara-labs/code-context-engine | 0.4.24+ | candidate | MCP server with semantic search, May-June 2026 releases |
| claude-token-saver | codeSearch | Claude Code, Cursor, Copilot CLI | https://github.com/awesomo913/Claude-Token-Saver | Jun 2026 | candidate | Function/class selector, production-ready 9.0/10 |
| claude-context-guard | onDemand | Claude Code | https://github.com/AntonioBlago/claude-context-guard | unconfirmed | candidate | Hook + skill, warns on context expense, Oct 2026 usage data |
| claude-token-policy | outputFilter | Claude Code | https://github.com/aniteshdharam/claude-token-policy | unconfirmed | candidate | Plugin with policy enforcement and census script |
| context-handoff | onDemand | Claude Code | https://github.com/YauhenBichel/context-handoff | unconfirmed | candidate | Plugin, meters turns, writes handoff notes after /clear |
| token-optimizer-mcp | onDemand | Claude Code, multiple CLI clients | https://github.com/ooples/token-optimizer-mcp | v7.5.1 | candidate | MCP server, claims 60-90% reduction |
| squeez | outputFilter | Claude Code, OpenCode, Copilot CLI, others | https://github.com/claudioemmanuel/squeez | v1.48.18 | candidate | Hook plus MCP server, claims up to 95% bash compression |
| winnow | outputFilter | Claude Code, generic | https://github.com/jpoindexter/winnow | no release (pushed 2026-07-09) | candidate | Recoverable compression, claims 40-95% |
| mcp-compressor | onDemand | Claude Code (MCP) | https://github.com/atlassian-labs/mcp-compressor | v0.38.0+ | candidate | Schema compression proxy, claims 70-97% |
| context-firewall | onDemand | Claude Code, Cursor | https://github.com/alepha188838884/context-firewall | v0.4.0 | candidate | Wraps MCP servers, claims 60-95% output reduction |
| context-compress | outputFilter | Claude Code (MCP + hook) | https://github.com/Open330/context-compress | v2026.8.3 | candidate | Structural compression, claims 99.2% reduction |
| context-optimizer | — | Claude Code | https://github.com/egorfedorov/claude-context-optimizer | v5.0.2+ | not a saver | Tracks usage and reports waste; shrinks nothing itself |
| context-compress (vidanov) | — | Claude Code, others | https://github.com/vidanov/context-compress | no release (pushed 2026-05-26) | stale | Same name as Open330's; compresses instruction files |
| token-compressor | — | Claude Code | https://github.com/base76-research-lab/token-compressor | v0.1.1 | research | PyPI MCP server, semantic compression 40-60%, unverified claims |
| ReCompress | — | Generic (research) | — | — | research | UC Berkeley hackathon prize, model-based |
| CtxGuard | — | Generic (research) | — | — | research | Governance gateway, Chinese docs |
| claude-code-hooks | — | Claude Code | — | — | research | Plugin marketplace, not itself a saver |
