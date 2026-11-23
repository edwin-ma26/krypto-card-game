import SwiftUI

/// The revealed solution as a full-width strip under the two card rows:
/// the optional header (e.g. Solo's rating change) on one line, then the
/// steps two to a row so four steps fit in the height of about one card.
struct SolutionStrip: View {
    let steps: [String]
    var header: String? = nil
    var headerColor: Color = .red.opacity(0.85)

    /// Fixed so the board can reserve the room before the strip appears.
    static let height: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(.caption, design: .rounded, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(headerColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .leading),
                                GridItem(.flexible(), spacing: 12, alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text(step)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .foregroundStyle(Theme.inkDark)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Theme.pill))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Solution: " + steps.joined(separator: ", "))
    }
}
