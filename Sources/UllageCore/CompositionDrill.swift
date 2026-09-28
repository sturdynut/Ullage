import Foundation

/// The composition as a tree you can walk: the window, its four segments, and
/// under Tool results every tool — MCP tools grouped by their server — and
/// under the Baseline the CLAUDE.md estimate carved out of it.
///
/// `CompositionTreemap` is the popover's one-glance picture and folds anything
/// thin into "N more". This is the other half: nothing folds, because a level
/// is drawn across the whole explorer window and anything too small for a
/// label is still a tile you can hover, and a row in the table beside it.
public struct CompositionNode: Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The unshortened name (`mcp__github__pull_request_read`).
    public var fullName: String
    /// The top-level segment this belongs to, which decides its colour.
    public var segment: String
    public var tokens: Int
    public var calls: Int?
    public var isEstimate: Bool
    public var detail: String?
    public var children: [CompositionNode]

    public var canDrill: Bool { !children.isEmpty }

    /// The window: four segments, in their fixed order, zero-sized ones left out.
    public static func tree(_ composition: ContextComposition) -> CompositionNode {
        CompositionNode(
            id: "window",
            name: "Context window",
            fullName: "Context window",
            segment: "",
            tokens: composition.contextTokens,
            calls: nil,
            isEstimate: false,
            detail: nil,
            children: composition.segments.filter { $0.tokens > 0 }.map { segment($0, composition) }
        )
    }

    static func segment(_ segment: ContextComposition.Segment, _ composition: ContextComposition) -> CompositionNode {
        var children: [CompositionNode] = []
        switch segment.name {
        case ContextComposition.toolResultsName:
            children = tools(composition.tools.filter { $0.resultTokens > 0 })
        case ContextComposition.baselineName:
            // The same parts the treemap splits the baseline into, and on the
            // same condition: only where the estimate is smaller than what it
            // is carved out of.
            children = CompositionTreemap.parts(of: segment, in: composition).map {
                CompositionNode(id: segment.name + "/" + $0.id, name: $0.name, fullName: $0.fullName,
                                segment: segment.name, tokens: $0.tokens, calls: nil,
                                isEstimate: true, detail: $0.detail, children: [])
            }
        default:
            break
        }
        return CompositionNode(
            id: segment.name,
            name: segment.name,
            fullName: segment.name,
            segment: segment.name,
            tokens: segment.tokens,
            calls: children.isEmpty ? nil : children.reduce(0) { $0 + ($1.calls ?? 0) },
            isEstimate: ContextComposition.isEstimate(segment: segment.name),
            detail: nil,
            children: children
        )
    }

    /// Built-in tools stand alone; MCP tools gather under their server, which
    /// is itself a tile you can open. A server with one tool is not a group.
    static func tools(_ tools: [ContextComposition.ToolShare]) -> [CompositionNode] {
        let segment = ContextComposition.toolResultsName
        func leaf(_ tool: ContextComposition.ToolShare, name: String) -> CompositionNode {
            CompositionNode(id: segment + "/" + tool.name, name: name, fullName: tool.name, segment: segment,
                            tokens: tool.resultTokens, calls: tool.calls, isEstimate: true,
                            detail: tool.server.map { "MCP server " + $0 },
                            children: targets(tool, parent: segment + "/" + tool.name))
        }
        var nodes: [CompositionNode] = []
        var servers: [String: [ContextComposition.ToolShare]] = [:]
        var serverOrder: [String] = []
        for tool in tools {
            if let server = mcpServer(tool) {
                if servers[server] == nil { serverOrder.append(server) }
                servers[server, default: []].append(tool)
            } else {
                nodes.append(leaf(tool, name: tool.name))
            }
        }
        for server in serverOrder {
            let members = servers[server] ?? []
            if members.count == 1, let only = members.first {
                nodes.append(leaf(only, name: CompositionTreemap.shortToolName(only.name)))
                continue
            }
            let prefix = "mcp__" + server + "__"
            nodes.append(CompositionNode(
                id: segment + "/mcp:" + server,
                name: server,
                fullName: "MCP server " + server,
                segment: segment,
                tokens: members.reduce(0) { $0 + $1.resultTokens },
                calls: members.reduce(0) { $0 + $1.calls },
                isEstimate: true,
                detail: "\(members.count) tools",
                children: members.map { tool in
                    let short = tool.name.hasPrefix(prefix)
                        ? String(tool.name.dropFirst(prefix.count)).replacingOccurrences(of: "_", with: " ")
                        : tool.name
                    return leaf(tool, name: short)
                }.sorted { $0.tokens > $1.tokens }
            ))
        }
        return nodes.sorted { $0.tokens > $1.tokens }
    }

    /// What a tool was called on. Nothing to open when every call had the same
    /// target, or none — a level of one tile says nothing the tool did not.
    static func targets(_ tool: ContextComposition.ToolShare, parent: String) -> [CompositionNode] {
        let isFile = ToolTargets.fileTools.contains(tool.name)
        func node(_ target: ContextComposition.TargetShare, parent: String) -> CompositionNode {
            let id = parent + "/" + target.name
            var detail = "\(target.calls) call\(target.calls == 1 ? "" : "s")"
            if target.errors > 0 { detail += " · \(target.errors) failed" }
            return CompositionNode(
                id: id,
                name: isFile ? ToolTargets.shortPath(target.name) : target.name,
                fullName: target.name,
                segment: ContextComposition.toolResultsName,
                tokens: target.resultTokens,
                calls: target.calls,
                isEstimate: true,
                detail: detail,
                children: target.members.map { node($0, parent: id) }
            )
        }
        let nodes = tool.targets.map { node($0, parent: parent) }
        if nodes.count == 1, nodes[0].children.isEmpty { return [] }
        if nodes.allSatisfy({ $0.fullName == ToolTargets.noTarget }) { return [] }
        return nodes
    }

    /// The recorded server, or the one spelled in an `mcp__server__tool` name.
    static func mcpServer(_ tool: ContextComposition.ToolShare) -> String? {
        if let server = tool.server, !server.isEmpty { return server }
        guard tool.name.hasPrefix("mcp__") else { return nil }
        let pieces = tool.name.dropFirst("mcp__".count).components(separatedBy: "__")
        return pieces.count >= 2 && !pieces[0].isEmpty ? pieces[0] : nil
    }

    /// The node at the end of a path of child ids, or as far as the path
    /// still leads — a turn can make a tool vanish from under an open level.
    public func descend(_ path: [String]) -> (node: CompositionNode, path: [String]) {
        var node = self
        var reached: [String] = []
        for id in path {
            guard let child = node.children.first(where: { $0.id == id }) else { break }
            node = child
            reached.append(id)
        }
        return (node, reached)
    }
}

// MARK: - Squarified layout

extension CompositionTreemap {
    public struct Placed: Equatable, Identifiable {
        public var node: CompositionNode
        public var rect: Rect
        public var label: Label
        public var shade: Int
        public var id: String { node.id }
    }

    /// Squarified (Bruls, Huizing & van Wijk): rows of tiles kept as close to
    /// square as the sizes allow, largest first, so a level of forty tools
    /// reads as tiles rather than slivers. Order is by size, which holds still
    /// between turns because tool totals only grow within a window.
    public static func squarify(
        _ nodes: [CompositionNode],
        width: Double,
        height: Double,
        gap: Double = partGap,
        metrics: Metrics = Metrics(),
        weight: (CompositionNode) -> Int = { $0.tokens },
        value: (CompositionNode) -> String = { ($0.isEstimate ? "≈" : "") + TokenFormat.compact($0.tokens) }
    ) -> [Placed] {
        let items = nodes.filter { weight($0) > 0 }.sorted { weight($0) > weight($1) }
        let total = Double(items.reduce(0) { $0 + weight($1) })
        guard width > 0, height > 0, total > 0 else { return [] }
        let scale = width * height / total
        var areas = items.map { Double(weight($0)) * scale }
        var rects: [Rect] = []
        var free = Rect(x: 0, y: 0, width: width, height: height)

        func worst(_ row: [Double], side: Double) -> Double {
            let sum = row.reduce(0, +)
            guard sum > 0, side > 0, let big = row.max(), let small = row.min(), small > 0 else { return .infinity }
            return max(side * side * big / (sum * sum), (sum * sum) / (side * side * small))
        }

        while !areas.isEmpty {
            let side = min(free.width, free.height)
            var row = [areas.removeFirst()]
            while let next = areas.first, worst(row + [next], side: side) <= worst(row, side: side) {
                row.append(areas.removeFirst())
            }
            let sum = row.reduce(0, +)
            if free.width >= free.height {
                // A column down the left edge.
                let columnWidth = free.height > 0 ? sum / free.height : 0
                var y = free.y
                for area in row {
                    let h = columnWidth > 0 ? area / columnWidth : 0
                    rects.append(Rect(x: free.x, y: y, width: columnWidth, height: h))
                    y += h
                }
                free = Rect(x: free.x + columnWidth, y: free.y, width: max(0, free.width - columnWidth), height: free.height)
            } else {
                // A row across the top edge.
                let rowHeight = free.width > 0 ? sum / free.width : 0
                var x = free.x
                for area in row {
                    let w = rowHeight > 0 ? area / rowHeight : 0
                    rects.append(Rect(x: x, y: free.y, width: w, height: rowHeight))
                    x += w
                }
                free = Rect(x: free.x, y: free.y + rowHeight, width: free.width, height: max(0, free.height - rowHeight))
            }
        }

        return zip(items, rects).map { node, rect in
            // The gap is taken from each tile's right and bottom edge, except
            // where the tile meets the edge of the map.
            let inset = Rect(
                x: rect.x,
                y: rect.y,
                width: max(1, rect.maxX >= width - 0.5 ? rect.width : rect.width - gap),
                height: max(1, rect.maxY >= height - 0.5 ? rect.height : rect.height - gap)
            )
            return Placed(
                node: node,
                rect: inset,
                label: label(name: node.name, values: [value(node)], rect: inset, metrics: metrics),
                shade: node.id == node.segment ? 0 : shade(for: node.id)
            )
        }
    }
}
