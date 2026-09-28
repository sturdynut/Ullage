#if os(macOS)
import SwiftUI

/// A small caption on a hairline that runs to the edge of the popover.
///
/// The popover is six stacked blocks that used to be separated by nothing but
/// one repeated gap value, so an answer, a control, a chart and a field dump
/// all read as one column. Naming each block is what turns it back into
/// sections — and because two of these blocks change subject when an agent is
/// selected, the caption is also where that scope is stated, right on top of
/// the numbers it governs rather than in a header two blocks away.
///
/// Left-aligned, unlike the menu-bar apps this borrows from: everything under
/// it is a left-aligned reading column, and a centred caption would introduce a
/// second alignment axis for nothing.
struct SectionRule<Trailing: View>: View {
    let title: String
    /// The agent whose numbers follow, when it is not the session's own.
    var scope: String?
    /// When set, the hairline is drawn as these proportions instead — how a
    /// collapsed section keeps its chart without spending a second row on it.
    var shares: [RuleShare]? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .fixedSize()
            if let scope {
                Text("·")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
                Text(scope)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(scope)
            }
            if let shares, !shares.isEmpty {
                proportions(shares)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            trailing()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One segment of a rule drawn as proportions.
struct RuleShare {
    var color: Color
    var weight: Double
}

extension SectionRule {
    /// The same fixed order and colours as the chart it stands in for, as
    /// thin as a rule can be and still be read: 3pt.
    func proportions(_ shares: [RuleShare]) -> some View {
        let total = shares.reduce(0) { $0 + max(0, $1.weight) }
        return GeometryReader { geometry in
            let gap: CGFloat = 1
            let usable = max(0, geometry.size.width - gap * CGFloat(max(shares.count - 1, 0)))
            HStack(spacing: gap) {
                ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                    Rectangle()
                        .fill(share.color)
                        .frame(width: total > 0 ? usable * CGFloat(max(0, share.weight)) / CGFloat(total) : 0)
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// A `SectionRule` that is also the section's toggle: the whole rule is the
/// target and a chevron at its end says which way it is. Collapsed sections
/// show a one-glance summary; expanded, everything.
struct CollapsibleSectionRule<Trailing: View>: View {
    let title: String
    var scope: String?
    @Binding var isExpanded: Bool
    var help: (collapse: String, expand: String) = ("Collapse", "Expand")
    /// Drawn in place of the hairline while collapsed; see `SectionRule.shares`.
    var shares: [RuleShare]? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            // Only the caption, hairline and chevron toggle; trailing items
            // sit outside so a button among them gets its own clicks.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                SectionRule(title: title, scope: scope, shares: isExpanded ? nil : shares) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? help.collapse : help.expand)
            trailing()
                .fixedSize()
        }
    }
}

extension CollapsibleSectionRule {
    init(_ title: String, scope: String? = nil, isExpanded: Binding<Bool>,
         help: (collapse: String, expand: String) = ("Collapse", "Expand"),
         shares: [RuleShare]? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, scope: scope, isExpanded: isExpanded, help: help, shares: shares, trailing: trailing)
    }
}

extension CollapsibleSectionRule where Trailing == EmptyView {
    init(_ title: String, scope: String? = nil, isExpanded: Binding<Bool>,
         help: (collapse: String, expand: String) = ("Collapse", "Expand")) {
        self.init(title: title, scope: scope, isExpanded: isExpanded, help: help) { EmptyView() }
    }
}

extension SectionRule where Trailing == EmptyView {
    init(_ title: String, scope: String? = nil) {
        self.init(title: title, scope: scope) { EmptyView() }
    }
}

extension SectionRule {
    init(_ title: String, scope: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, scope: scope, trailing: trailing)
    }
}
#endif
