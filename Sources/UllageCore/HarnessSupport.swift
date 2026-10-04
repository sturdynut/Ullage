import Foundation

/// What one harness can't tell Ullage, in plain words, so a page says
/// "Gemini CLI doesn't record cache writes" instead of showing an empty
/// section or a zero that looks measured. Built from `HarnessCapabilities`,
/// never from which harness it is.
public struct HarnessSupport: Equatable {
    public enum Feature: String, CaseIterable, Codable {
        case gauge, everyCall, cacheSplit, model, context, agents, compaction, effort, planLimits, contextTools
    }

    public struct Row: Equatable, Codable {
        public var feature: Feature
        public var label: String
        public var available: Bool
        /// Why not, or how partially; nil when fully available.
        public var detail: String?
    }

    public let harnessName: String
    public let capabilities: HarnessCapabilities

    public init(harness: Harness) {
        harnessName = harness.name
        capabilities = harness.capabilities
    }

    /// A stored vendor; an unknown one (a newer database) is treated as Claude.
    public init(vendor: String?) {
        self.init(harness: Harness.named(vendor) ?? .claudeCode)
    }

    public var rows: [Row] {
        let c = capabilities, name = harnessName
        func row(_ f: Feature, _ label: String, _ ok: Bool, _ why: String?) -> Row {
            Row(feature: f, label: label, available: ok, detail: ok ? nil : why)
        }
        var rows: [Row] = []
        let gaugeWhy: String
        switch (c.occupancy, c.window) {
        case (.none, _): gaugeWhy = "\(name) doesn't record token counts on your Mac"
        case (.approximate, _): gaugeWhy = "\(name) only writes rounded token counts, so there's no exact gauge"
        case (_, .none): gaugeWhy = "\(name) doesn't record the context window"
        default: gaugeWhy = ""
        }
        rows.append(row(.gauge, "Context gauge", c.hasGauge, gaugeWhy))
        let everyCall: String? = {
            switch c.occupancy {
            case .everyCall: return nil
            case .perRequest: return "One reading per request, not per model call, so the chart has fewer points"
            case .latestOnly: return "Only the latest turn is kept, so there's no history to chart"
            case .approximate, .none: return "No per-call history"
            }
        }()
        rows.append(Row(feature: .everyCall, label: "Every model call", available: everyCall == nil, detail: everyCall))
        rows.append(row(.cacheSplit, "Cache reads and writes", c.cacheSplit,
                        "\(name) doesn't report cache use separately, so cache rebuilds can't be found"))
        rows.append(row(.model, "Model", c.model, "\(name) doesn't record which model ran"))
        rows.append(row(.context, "What's in the context", c.toolResults,
                        "\(name) doesn't record tool result sizes, so Context can't break the window down"))
        rows.append(row(.agents, "Subagents", c.subagents, "\(name) has no separate subagent windows on disk"))
        rows.append(row(.compaction, "Compaction", c.compaction, "\(name) doesn't mark when it compacts"))
        rows.append(row(.effort, "Reasoning effort", c.effort, "\(name) doesn't record the effort setting"))
        rows.append(row(.planLimits, "Plan limits", c.planLimits, "\(name)'s plan limits aren't on disk"))
        rows.append(row(.contextTools, "Context tools", c.contextTools,
                        "Context tools are detected from Claude Code's hooks and settings"))
        return rows
    }

    /// Only what's missing or partial, for a "Not recorded by …" list.
    public var gaps: [Row] { rows.filter { !$0.available || $0.detail != nil } }

    public func gap(_ feature: Feature) -> String? {
        rows.first { $0.feature == feature && !$0.available }?.detail
    }

    /// Shown where the gauge would be when this harness can't have one.
    public var gaugeNotice: String? {
        capabilities.hasGauge ? nil : gap(.gauge).map { $0 + ". Showing activity only." }
    }

    /// One line for the Session page's header: "Gemini CLI · no cache writes".
    public var title: String { "What \(harnessName) records" }
}
