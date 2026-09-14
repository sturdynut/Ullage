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
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            trailing()
        }
        .frame(maxWidth: .infinity)
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
