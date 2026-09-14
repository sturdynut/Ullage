#if os(macOS)
import SwiftUI
import UllageCore

/// How full the window is, as one thick bar across the header.
///
/// A ring was tried first and failed the common case: most sessions live below
/// 20%, where an arc is a stub on an empty circle and the threshold mark reads
/// as a stray tick. A bar is legible at 7% and at 97%, and it rhymes with the
/// composition bar below it — the same width meaning the same window.
///
/// The 85% mark is drawn on the track so "how close am I" is spatial rather
/// than a comparison against a number you have to remember. The peak is drawn
/// only when it is somewhere the fill is not: on a growing session the peak is
/// the current value, and a mark on top of the fill's own edge says nothing.
struct OccupancyBar: View {
    /// Nil when the harness reported no window: an empty track, never a guess.
    let occupancy: Double?
    var peak: Double?
    var height: CGFloat = 10

    private var isWarning: Bool { (occupancy ?? 0) >= MenuBarFormatter.warningThreshold }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                // Quarter graduations. Most sessions live under 20%, where a
                // bare rail is a stub against an empty void and reads as broken;
                // marked, the same reading is a position on a known scale.
                ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                    mark(at: width * fraction, color: Color.primary.opacity(0.10))
                }

                if let occupancy {
                    Capsule()
                        .fill(isWarning ? Color.orange : Color.accentColor)
                        .frame(width: max(3, width * min(1, occupancy)))

                    if let peak, peak > occupancy + 0.02, peak <= 1 {
                        mark(at: width * peak, color: Color.primary.opacity(0.35))
                            .help("Peak: \(MenuBarFormatter.percentage(peak))")
                    }
                    mark(at: width * MenuBarFormatter.warningThreshold, color: Color.orange.opacity(0.45))
                        .help("\(Int(MenuBarFormatter.warningThreshold * 100))% — compaction territory")
                }
            }
        }
        .frame(height: height)
    }

    private func mark(at x: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 1.5, height: height)
            .offset(x: x - 0.75)
    }
}
#endif
