# Context tools

Ullage tracks third-party tools that keep the context window small. Each is a
**descriptor**: data that says how to recognise the tool, what kind it is, and
how to install and switch it. Nothing downstream names a specific tool, so
adding one never means touching the report, the panel, the window, the phone
page or the CLI.

Built-in descriptors live in `Sources/UllageCore/BuiltinTools.swift`. Add your
own as one JSON file per tool in `~/.config/ullage/tools/` (or
`$XDG_CONFIG_HOME/ullage/tools`, or `$ULLAGE_TOOLS_DIR`). A file whose `id`
matches a built-in replaces it. `ullage tools` lists what loaded and why any
file was skipped. A broken file is reported, never fatal.

## Kinds

The kind decides what Ullage can honestly say about a tool:

| Kind | Example | What the row shows |
|---|---|---|
| `outputFilter` | rtk, Tokenade | Rewrites from hook runs; savings only as the tool's own claim, marked ≈ |
| `replyStyle` | caveman | Measured reply length with it on vs off, in this folder. A comparison, not a saving |
| `onDemand` | Headroom | MCP calls, or **idle** when loaded and never called |
| `codeSearch` | Serena, codegraph, claude-context | Lookups (MCP calls or Bash runs) and ≈ size of what they returned |
| `memory` | claude-mem | ≈ size of what its hooks injected at session start (a length estimate) |

## Descriptor

```json
{
  "id": "mytool",
  "name": "My Tool",
  "kind": "codeSearch",
  "shrinks": "file reads, with symbol lookups",
  "about": "One sentence on what it does.",
  "detect": {
    "mcpServer": ["^mytool$"],
    "hookCommand": ["mytool"],
    "plugin": ["^mytool@"],
    "skill": ["^mytool($|:)"],
    "bash": ["^mytool$"]
  },
  "install": {
    "binary": "mytool",
    "package": "mytool",
    "packages": [{ "manager": "brew", "command": "brew install mytool" }],
    "setup": [{ "command": "claude mcp add --scope user mytool -- mytool serve",
                "purpose": "Register it with Claude Code", "needs": "claude" }],
    "teardown": [{ "command": "claude mcp remove --scope user mytool",
                   "purpose": "Unregister it", "needs": "claude" }],
    "notes": ["Anything a person should know before installing."]
  }
}
```

- **`detect`** patterns are case-insensitive regular expressions. `mcpServer`
  matches the server part of `mcp__<server>__<tool>`; `hookCommand` the command
  Claude Code records for each hook run; `plugin` an `enabledPlugins` key;
  `skill` a Skill target or slash command; `bash` the program a Bash call runs.
  Every list is optional.
- **`install`** is optional. Without it the tool is still detected and measured;
  Ullage just won't offer to install it. `packages` are tried in order, and the
  first whose manager (or `needs`) exists on the Mac is used. A `teardown` step
  with `"when": "binary"` runs only when the binary is present.
- **`claims`** (built-ins only for now) names a ledger reader in
  `SaverLedgers.readers`, for tools that keep their own record of savings.
  Reading a new ledger format is the one thing that needs Swift.

Commands run in Terminal, after Ullage shows them, and only when you ask.
