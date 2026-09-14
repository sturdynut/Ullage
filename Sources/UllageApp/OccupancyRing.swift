#if os(macOS)
import SwiftUI
import UllageCore

/// The headline instrument: how full the window is, as an arc, with the room
/// left written inside it.
///
/// A number cannot say "close to the edge" without the reader remembering what
/// the edge is, so the threshold is a tick on the track and the peak is another
/// — the same scale, the same instrument, no second gauge invented to fill a
/// slot. A window nobody reported draws an empty track rather than a guess.
struct OccupancyRing: View {
    /// Nil when the harness reported no window: no arc, no ticks.
    let occupancy: Double?
    /// The highest this stream has been, as a fraction of the same window.
    var peak: Double?
    /// Written inside the ring — the room left, which is what the app is named
    /// for and what the menu bar cannot show.
    let center: String
    var caption: String?
    var diameter: CGFloat = 62
    var lineWidth: CGFloat = 6

    private var isWarning: Bool { (occupancy ?? 0) >= MenuBarFormatter.warningThreshold }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)

            if let occupancy {
                Circle()
                    .trim(from: 0, to: min(1, max(0.004, occupancy)))
                    .stroke(
                        isWarning ? Color.orange : Color.accentColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                tick(at: MenuBarFormatter.warningThreshold, color: .orange.opacity(0.75))
                // Only worth drawing when it is somewhere the arc is not: on a
                // growing session the peak *is* the current value.
                if let peak, peak > occupancy + 0.02 {
                    tick(at: min(1, peak), color: Color.primary.opacity(0.35))
                }
            }

            VStack(spacing: -1) {
                Text(center)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(occupancy == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                if let caption {
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func tick(at fraction: Double, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 1.5, height: lineWidth + 3)
            .offset(y: -(diameter - lineWidth) / 2)
            .rotationEffect(.degrees(360 * fraction))
    }
}
#endif
