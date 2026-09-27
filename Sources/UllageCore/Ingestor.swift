import Foundation

public struct IngestStats: Equatable {
    public var filesScanned = 0
    public var filesSkipped = 0
    public var bytesRead = 0
    public var linesParsed = 0
    public var linesSkipped = 0
    public var malformedLines = 0
    public var callsUpserted = 0
    public var toolCallsUpserted = 0
    public var toolResultsMatched = 0
    public var toolResultsOrphaned = 0
    public var eventsInserted = 0
    public var sessionEnvSnapshots = 0
    /// Distinct subagents seen, and spawns joined back to the parent turn that
    /// asked for them. Counted once each, not once per turn.
    public var agentsSeen = 0
    public var agentSpawnsLinked = 0
    public var planLimitsSeen = 0
    /// A trailing partial line is normal — Claude Code is mid-write.
    public var partialTailBytes = 0
    public var restartedFromZero = 0

    public init() {}

    public static func + (lhs: IngestStats, rhs: IngestStats) -> IngestStats {
        var result = lhs
        result.filesScanned += rhs.filesScanned
        result.filesSkipped += rhs.filesSkipped
        result.bytesRead += rhs.bytesRead
        result.linesParsed += rhs.linesParsed
        result.linesSkipped += rhs.linesSkipped
        result.malformedLines += rhs.malformedLines
        result.callsUpserted += rhs.callsUpserted
        result.toolCallsUpserted += rhs.toolCallsUpserted
        result.toolResultsMatched += rhs.toolResultsMatched
        result.toolResultsOrphaned += rhs.toolResultsOrphaned
        result.eventsInserted += rhs.eventsInserted
        result.sessionEnvSnapshots += rhs.sessionEnvSnapshots
        result.agentsSeen += rhs.agentsSeen
        result.agentSpawnsLinked += rhs.agentSpawnsLinked
        result.planLimitsSeen += rhs.planLimitsSeen
        result.partialTailBytes += rhs.partialTailBytes
        result.restartedFromZero += rhs.restartedFromZero
        return result
    }
}

/// Reads transcript files forward from their stored cursor and writes rows.
///
/// Everything that needs to know about a *previous* line lives here rather than
/// in the parser: turn index, context delta, and the tool_result join.
public final class Ingestor {
    public let store: Store
    /// Log sink for lines we could not parse. Defaults to silence.
    public var onWarning: ((String) -> Void)?
    /// Captures the configuration a session ran under, on first sight of that
    /// session. Set to nil to ingest without touching the rest of the disk.
    public var environmentProvider: SessionEnvironmentProviding?

    /// Per-*stream* bookkeeping carried across files within one process.
    ///
    /// A stream is one context window: the main thread of a session, or one
    /// subagent of it. Subagent lines carry the parent's `sessionId`, so keying
    /// this by session alone would number four concurrent windows into one
    /// sequence and compute deltas between prompts that never followed each
    /// other.
    private struct StreamState {
        var nextTurnIndex: Int
        var contextByTurn: [Int: Int] = [:]
        /// Set when a compaction event is seen; nulls the delta of the next turn
        /// so the cliff does not read as a 180k-token drop.
        var compactionPending = false
    }

    private struct StreamKey: Hashable {
        var sessionId: String
        var agentId: String?
    }

    private var streams: [StreamKey: StreamState] = [:]
    /// Sessions this process has already considered for a snapshot, so the
    /// existence check is one query per session per run rather than per turn.
    private var snapshottedSessions = Set<String>()
    /// Agents already counted in this process, so a 60-turn subagent is one
    /// agent in the stats rather than sixty.
    private var seenAgents = Set<String>()

    public init(
        store: Store,
        environmentProvider: SessionEnvironmentProviding? = SessionEnvironmentProvider()
    ) {
        self.store = store
        self.environmentProvider = environmentProvider
    }

    // MARK: - Directory

    /// Recursively ingests every `.jsonl` under `url`, oldest file first so that
    /// turn indexes come out in wall-clock order.
    @discardableResult
    public func ingestDirectory(at url: URL) throws -> IngestStats {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return IngestStats()
        }

        var files: [(URL, Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            files.append((fileURL, values?.contentModificationDate ?? .distantPast))
        }
        files.sort { $0.1 < $1.1 }

        var total = IngestStats()
        for (fileURL, _) in files {
            do {
                total = total + (try ingestFile(at: fileURL))
            } catch {
                // One unreadable file must not abort a backfill.
                var stats = IngestStats()
                stats.filesSkipped = 1
                total = total + stats
                warn("skipping \(fileURL.path): \(error)")
            }
        }
        return total
    }

    // MARK: - File

    @discardableResult
    public func ingestFile(at url: URL) throws -> IngestStats {
        var stats = IngestStats()
        stats.filesScanned = 1

        let path = url.path
        let format = TranscriptFormat.detect(path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let stored = try store.cursor(forPath: path)
        var startOffset: UInt64 = 0
        if let stored {
            // New inode means the file was replaced; a size below the stored
            // offset means it was truncated. Either way, re-read from zero
            // rather than seeking into the middle of a different file.
            if stored.inode != inode || size < stored.byteOffset {
                startOffset = 0
                stats.restartedFromZero = 1
            } else {
                startOffset = stored.byteOffset
            }
        }

        if startOffset == size, stored != nil, stats.restartedFromZero == 0 {
            // Nothing appended since last time.
            try store.upsert(cursor: FileCursor(path: path, inode: inode, byteOffset: startOffset, size: size, mtime: mtime))
            return stats
        }

        // Codex usage lines are not self-contained; re-read the whole file when
        // it has changed so the parser sees session_meta and turn_context first.
        if format.reingestsWholeFile { startOffset = 0 }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if startOffset > 0 { try handle.seek(toOffset: startOffset) }

        let parser = format.makeParser()
        // Only a subagent transcript has one, and it is the one source of the
        // agent's name that outlives the parent's transcript.
        let agentMetadata = AgentMetadata.read(besideTranscript: path)

        let sessionFallback = url.deletingPathExtension().lastPathComponent
        var pending = Data()
        var consumed: UInt64 = 0
        var lastTimestamp: String?

        // Rows are staged and written in one transaction with the cursor: a
        // crash between the two would otherwise re-read or lose lines.
        var work: [ParsedLine] = []

        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineEnd = newlineIndex
                let line = pending[pending.startIndex..<lineEnd]
                let lineLength = pending.distance(from: pending.startIndex, to: lineEnd) + 1
                consumed += UInt64(lineLength)
                pending = pending[pending.index(after: newlineIndex)...]

                let trimmed = trimTrailingCR(Data(line))
                if trimmed.isEmpty {
                    stats.linesSkipped += 1
                    continue
                }

                let context = LineContext(
                    sourceFile: path,
                    fallbackSessionId: sessionFallback,
                    lastTimestamp: lastTimestamp,
                    fileModified: Timestamps.string(from: Date(timeIntervalSince1970: mtime))
                )
                guard let parsed = parser.parse(line: trimmed, context: context) else {
                    if (try? JSONSerialization.jsonObject(with: trimmed)) == nil {
                        stats.malformedLines += 1
                        warn("malformed JSON at \(path) byte \(startOffset + consumed)")
                    }
                    stats.linesSkipped += 1
                    continue
                }
                stats.linesParsed += 1
                if let ts = timestamp(of: parsed), !ts.isEmpty { lastTimestamp = ts }
                work.append(parsed)
            }
        }

        // Whatever is left has no newline: Claude Code is mid-write. Leave the
        // cursor before it so the line is re-read once it is complete.
        stats.partialTailBytes = pending.count
        stats.bytesRead = Int(consumed)

        let newOffset = startOffset + consumed
        try store.database.transaction {
            for parsed in work {
                try apply(parsed, to: &stats, metadata: agentMetadata)
            }
            try store.upsert(
                cursor: FileCursor(
                    path: path,
                    inode: inode,
                    byteOffset: newOffset,
                    // The file can grow between the stat and the read; recording
                    // the smaller size would look like a truncation next time.
                    size: max(size, newOffset),
                    mtime: mtime
                )
            )
        }
        return stats
    }

    // MARK: - Row application

    private func apply(
        _ parsed: ParsedLine,
        to stats: inout IngestStats,
        metadata: AgentMetadata? = nil
    ) throws {
        switch parsed {
        case .call(let parsedCall):
            var call = parsedCall.call
            let (turnIndex, delta) = try assignTurn(for: call)
            call.turnIndex = turnIndex
            call.contextDelta = delta
            try store.upsert(call: call)
            stats.callsUpserted += 1
            // The child's own side of the agent row: identity and span, known
            // even when the parent's transcript has already aged out.
            if let agentId = call.agentId {
                // Every turn, so the agent's last-seen time keeps up; counted
                // only the first time.
                try store.upsertAgent(fromCall: call, metadata: metadata)
                if seenAgents.insert(agentId).inserted { stats.agentsSeen += 1 }
            }
            // session_env is filesystem-derived Claude Code state (MCP servers,
            // skills, CLAUDE.md); it does not apply to other vendors.
            if parsedCall.call.vendor == Vendor.claudeCode,
               try snapshotEnvironmentIfNeeded(for: parsedCall) { stats.sessionEnvSnapshots += 1 }
            for toolCall in parsedCall.toolCalls {
                try store.upsert(toolCall: toolCall)
                stats.toolCallsUpserted += 1
            }
            for limit in parsedCall.planLimits {
                try store.upsert(planLimit: limit)
                stats.planLimitsSeen += 1
            }

        case .planLimits(let limits):
            for limit in limits {
                try store.upsert(planLimit: limit)
                stats.planLimitsSeen += 1
            }

        case .toolResults(let results):
            for result in results {
                // Written straight back by primary key, so a result that lands
                // in a later ingest run still finds its invocation. An
                // unmatched id is normal when a file is read from mid-stream.
                if try store.applyToolResult(result) {
                    stats.toolResultsMatched += 1
                } else {
                    stats.toolResultsOrphaned += 1
                }
                // An `Agent` result names the child it ran, which is the only
                // exact link between the parent's turn and the child's window.
                if let spawn = result.agent {
                    if try store.recordAgentSpawn(
                        toolUseId: result.toolUseId,
                        info: spawn,
                        sessionFallback: spawn.sessionId
                    ) { stats.agentSpawnsLinked += 1 }
                    if seenAgents.insert(spawn.agentId).inserted { stats.agentsSeen += 1 }
                }
            }

        case .event(let event):
            if try store.insert(event: event) { stats.eventsInserted += 1 }
            if event.kind == EventKind.compaction.rawValue {
                let key = StreamKey(sessionId: event.sessionId, agentId: event.agentId)
                streams[key, default: StreamState(nextTurnIndex: 0)].compactionPending = true
            }
        }
    }

    /// Nothing on disk records the configuration a session ran under, and that
    /// state leaves no history: if we do not capture it on first sight, the
    /// answer to "why was this session heavy?" is gone for good.
    private func snapshotEnvironmentIfNeeded(for parsed: ParsedCall) throws -> Bool {
        guard let environmentProvider else { return false }
        let sessionId = parsed.call.sessionId
        guard !snapshottedSessions.contains(sessionId) else { return false }
        snapshottedSessions.insert(sessionId)
        guard try !store.hasSessionEnv(sessionId: sessionId) else { return false }
        let snapshot = environmentProvider.snapshot(
            sessionId: sessionId,
            cwd: parsed.call.cwd,
            claudeVersion: parsed.claudeVersion
        )
        try store.upsert(sessionEnv: snapshot)
        return true
    }

    /// Turn index is ours, not the transcript's. It must be stable across
    /// re-ingests: a message id that already has one keeps it.
    private func assignTurn(for call: CallRow) throws -> (Int, Int?) {
        let key = StreamKey(sessionId: call.sessionId, agentId: call.agentId)
        var state = try streamState(for: key)
        defer { streams[key] = state }

        let turnIndex: Int
        if let existing = try store.turnIndex(forDedupeKey: call.dedupeKey) {
            // Trap 2: the same message.id reappears with a larger output count.
            // It is the same turn, so do not advance the counter.
            turnIndex = existing
        } else {
            turnIndex = state.nextTurnIndex
            state.nextTurnIndex = turnIndex + 1
        }
        state.contextByTurn[turnIndex] = call.contextTokens

        var delta: Int?
        if state.compactionPending {
            // Context falls off a cliff across a compaction boundary; a delta
            // there would be noise, and the `event` row is the real story.
            delta = nil
            state.compactionPending = false
        } else if turnIndex > 0 {
            var previous = state.contextByTurn[turnIndex - 1]
            if previous == nil {
                previous = try store.contextTokens(
                    sessionId: call.sessionId,
                    agentId: call.agentId,
                    turnIndex: turnIndex - 1
                )
            }
            delta = previous.map { call.contextTokens - $0 }
        } else {
            delta = nil
        }
        return (turnIndex, delta)
    }

    private func streamState(for key: StreamKey) throws -> StreamState {
        if let existing = streams[key] { return existing }
        // Resume numbering where the database left off so tailing an appended
        // file continues the sequence instead of restarting it.
        let next = (try store.maxTurnIndex(sessionId: key.sessionId, agentId: key.agentId))
            .map { $0 + 1 } ?? 0
        let state = StreamState(nextTurnIndex: next)
        streams[key] = state
        return state
    }

    private func timestamp(of parsed: ParsedLine) -> String? {
        switch parsed {
        case .call(let parsedCall): return parsedCall.call.ts
        case .event(let event): return event.ts
        case .planLimits(let limits): return limits.first?.observedAt
        case .toolResults: return nil
        }
    }

    private func trimTrailingCR(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }

    private func warn(_ message: String) {
        onWarning?(message)
    }
}
