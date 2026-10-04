import Foundation

/// The context tools Ullage knows out of the box. Each is data: adding a tool
/// here, or as a JSON file in `~/.config/ullage/tools/`, needs no other code.
/// Every command below is the tool's own documented one, checked against its
/// docs and recorded with the source in `docs/OBSERVED-FORMAT.md`.
public enum BuiltinTools {
    public static let all: [ToolDescriptor] = [rtk, tokenade, caveman, headroom, serena, codegraph, claudeContext, claudeMem]

    public static let rtk = ToolDescriptor(
        id: "rtk", name: "rtk", kind: .outputFilter, shrinks: "Bash output",
        about: "Rewrites common commands so their output is shorter before the model reads it.",
        // A word, not a substring: "rtk" inside another word is not rtk.
        detect: .init(hookCommand: [#"(^|[\s/"'])rtk([\s\-_."']|$)"#]),
        claims: .init(reader: "rtk-history", source: "rtk's own estimate (bytes ÷ 4)", how: "rtk counts bytes ÷ 4"),
        install: .init(
            binary: "rtk", package: "rtk",
            packages: [
                .init(manager: "brew", command: "brew install rtk"),
                .init(manager: "script", command: "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh", needs: "curl"),
            ],
            setup: [.init(command: "rtk init -g", purpose: "Add rtk's hook to Claude Code", needs: "rtk")],
            teardown: [.init(command: "rtk init -g --uninstall", purpose: "Remove rtk's hook and RTK.md from Claude Code", needs: "rtk", when: "binary")]
        )
    )

    public static let tokenade = ToolDescriptor(
        id: "tokenade", name: "Tokenade", kind: .outputFilter, shrinks: "Bash and Read output, MCP tool lists",
        about: "Filters command output and file reads, and hides MCP tools a session doesn't use.",
        detect: .init(hookCommand: ["tokenade"], mcpServer: ["tokenade"]),
        claims: .init(reader: "tokenade-gain", source: "Tokenade's own ledger; its method is not stated", how: "Tokenade doesn't say how"),
        install: .init(
            binary: "tokenade", package: "@tokenade/cli",
            packages: [.init(manager: "npm", command: "npm install -g @tokenade/cli")],
            setup: [
                .init(command: "tokenade install", purpose: "Add Tokenade's hooks and MCP server", needs: "tokenade"),
                .init(command: "tokenade login", purpose: "Sign in to a free Tokenade account (opens a browser)", interactive: true, needs: "tokenade"),
            ],
            teardown: [.init(command: "tokenade uninstall", purpose: "Remove Tokenade's hooks, MCP server and shell aliases", needs: "tokenade", when: "binary")],
            notes: ["Tokenade needs an account and sends usage totals to its dashboard."]
        )
    )

    public static let caveman = ToolDescriptor(
        id: "caveman", name: "caveman", kind: .replyStyle, shrinks: "the model's replies",
        about: "Makes the model's replies shorter.",
        detect: .init(hookCommand: ["caveman"], plugin: ["^caveman@"], skill: ["^caveman($|[:-])"]),
        claims: nil,
        install: .init(
            setup: [
                .init(command: "claude plugin marketplace add JuliusBrussee/caveman", purpose: "Add caveman's marketplace", needs: "claude"),
                .init(command: "claude plugin install caveman@caveman", purpose: "Install the caveman plugin", needs: "claude"),
            ],
            teardown: [
                .init(command: "claude plugin uninstall caveman@caveman", purpose: "Uninstall the caveman plugin", needs: "claude"),
                .init(command: "claude plugin marketplace remove caveman", purpose: "Remove caveman's marketplace", needs: "claude"),
            ]
        )
    )

    public static let headroom = ToolDescriptor(
        id: "headroom", name: "Headroom", kind: .onDemand, shrinks: "tool output, when called",
        about: "Compresses content when the model asks it to, as an MCP server.",
        detect: .init(hookCommand: ["headroom"], mcpServer: ["headroom"]),
        claims: nil,
        install: .init(
            binary: "headroom", package: "headroom-ai",
            packages: [
                .init(manager: "uv", command: "uv tool install --python 3.13 \"headroom-ai[mcp]\""),
                .init(manager: "pipx", command: "pipx install \"headroom-ai[mcp]\""),
            ],
            setup: [.init(command: "claude mcp add --scope user headroom -- headroom mcp serve",
                          purpose: "Register Headroom's MCP server with Claude Code", needs: "claude")],
            teardown: [.init(command: "claude mcp remove --scope user headroom",
                             purpose: "Unregister Headroom's MCP server from Claude Code", needs: "claude")]
        )
    )

    public static let serena = ToolDescriptor(
        id: "serena", name: "Serena", kind: .codeSearch, shrinks: "whole-file reads, with symbol lookups",
        about: "Lets the model find and edit code by symbol through a language server, instead of reading whole files.",
        detect: .init(mcpServer: ["^serena$"]),
        claims: nil,
        install: .init(
            binary: "serena", package: "serena-agent",
            packages: [.init(manager: "uv", command: "uv tool install -p 3.13 serena-agent")],
            setup: [.init(command: "claude mcp add --scope user serena -- serena start-mcp-server --context claude-code --project-from-cwd",
                          purpose: "Register Serena's MCP server with Claude Code, for every project", needs: "claude")],
            teardown: [.init(command: "claude mcp remove --scope user serena",
                             purpose: "Unregister Serena's MCP server from Claude Code", needs: "claude")],
            notes: ["Serena opens a dashboard in your browser when it starts; turn that off in ~/.serena/serena_config.yml."]
        )
    )

    public static let codegraph = ToolDescriptor(
        id: "codegraph", name: "codegraph", kind: .codeSearch, shrinks: "file reads, with a code graph",
        about: "Indexes code into a graph the model can query for symbols, callers and impact, instead of reading files.",
        // Its installer also teaches agents the `codegraph` command, run in Bash.
        detect: .init(mcpServer: ["^codegraph$"], bash: ["^codegraph$"]),
        claims: nil,
        install: .init(
            binary: "codegraph", package: "@colbymchenry/codegraph",
            packages: [
                .init(manager: "npm", command: "npm install -g @colbymchenry/codegraph"),
                .init(manager: "script", command: "curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh", needs: "curl"),
            ],
            setup: [.init(command: "codegraph install --target=claude --yes", purpose: "Register codegraph with Claude Code", needs: "codegraph")],
            teardown: [.init(command: "codegraph uninstall --keep-cli", purpose: "Remove codegraph from Claude Code", needs: "codegraph", when: "binary")],
            notes: ["codegraph sends anonymous usage telemetry by default; `codegraph telemetry off` stops it.",
                    "Index a project with `codegraph init` in its folder."]
        )
    )

    public static let claudeContext = ToolDescriptor(
        id: "claude-context", name: "claude-context", kind: .codeSearch, shrinks: "file reads, with semantic search",
        about: "Semantic code search over an index of your codebase, as an MCP server.",
        detect: .init(mcpServer: ["^claude-context$"]),
        claims: nil,
        install: .init(
            setup: [.init(command: "claude mcp add --scope user claude-context -e OPENAI_API_KEY=$OPENAI_API_KEY -e MILVUS_ADDRESS=$MILVUS_ADDRESS -e MILVUS_TOKEN=$MILVUS_TOKEN -- npx @zilliz/claude-context-mcp@latest",
                          purpose: "Register claude-context with Claude Code (needs your OpenAI and Zilliz keys set in the shell)",
                          interactive: true, needs: "claude")],
            teardown: [.init(command: "claude mcp remove --scope user claude-context",
                             purpose: "Unregister claude-context from Claude Code", needs: "claude")],
            notes: ["By default claude-context sends your code to OpenAI to embed it and stores the vectors in Zilliz Cloud. Ollama with a local Milvus keeps it on your Mac."]
        )
    )

    public static let claudeMem = ToolDescriptor(
        id: "claude-mem", name: "claude-mem", kind: .memory, shrinks: "re-explaining past sessions",
        about: "Records what each session did and injects a summary of relevant past work into new sessions.",
        detect: .init(hookCommand: ["claude-mem"], mcpServer: ["claude-mem"], plugin: ["^claude-mem@"]),
        claims: nil,
        install: .init(
            setup: [
                .init(command: "claude plugin marketplace add thedotmack/claude-mem", purpose: "Add claude-mem's marketplace", needs: "claude"),
                .init(command: "claude plugin install claude-mem@thedotmack", purpose: "Install the claude-mem plugin", needs: "claude"),
            ],
            teardown: [.init(command: "npx claude-mem uninstall", purpose: "Remove claude-mem's plugin, hooks and cache", needs: "npx")],
            notes: ["claude-mem needs Node 20+ and Bun. It keeps its memory in ~/.claude-mem."]
        )
    )
}
