import Foundation

/// The sidecar Claude Code writes next to every subagent transcript:
/// `agent-<agentId>.meta.json`, beside `agent-<agentId>.jsonl`.
///
/// Observed 2026-09-13 (Claude Code 2.1.x), four keys and nothing else:
///
/// ```json
/// {"agentType":"general-purpose","description":"Generate UI via claude CLI",
///  "toolUseId":"toolu_01WCf4AXqWoUx6DA3JJ4LVxN","spawnDepth":1}
/// ```
///
/// It is the better source for who an agent is, because it survives everything
/// the parent's transcript does not: a parent that has aged out of `~/.claude`,
/// a background agent whose result only ever said "launched", and a forked
/// session that replays the spawn under a different session id. The parent's
/// result line still supplies how the run *ended*, which the sidecar never says.
public struct AgentMetadata: Equatable {
    /// "Explore", "general-purpose", … the same string as `attributionAgent`.
    public var agentType: String?
    /// The description the spawning agent wrote. The name a human can read.
    public var label: String?
    /// The `tool_use` id of the `Agent` call that spawned this one, which is
    /// what places the agent in the tree.
    public var toolUseId: String?

    public init(agentType: String? = nil, label: String? = nil, toolUseId: String? = nil) {
        self.agentType = agentType
        self.label = label
        self.toolUseId = toolUseId
    }

    public var isEmpty: Bool { agentType == nil && label == nil && toolUseId == nil }

    /// `…/subagents/agent-<id>.jsonl` -> `…/subagents/agent-<id>.meta.json`.
    /// Nil for any path that is not a subagent transcript.
    public static func sidecarPath(forTranscript path: String) -> String? {
        guard Store.agentId(fromTranscriptPath: path) != nil else { return nil }
        return URL(fileURLWithPath: path).deletingPathExtension().path + ".meta.json"
    }

    /// Missing, unreadable and malformed all degrade to nil: the sidecar is a
    /// private format like the transcript, and ingestion never depends on it.
    public static func read(besideTranscript path: String) -> AgentMetadata? {
        guard let sidecar = sidecarPath(forTranscript: path),
              let data = FileManager.default.contents(atPath: sidecar),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let metadata = AgentMetadata(
            agentType: JSONAccess.string(root, "agentType"),
            label: JSONAccess.string(root, "description"),
            toolUseId: JSONAccess.string(root, "toolUseId")
        )
        return metadata.isEmpty ? nil : metadata
    }
}
