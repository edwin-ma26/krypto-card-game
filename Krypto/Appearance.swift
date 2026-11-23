import SwiftUI

/// How the board is drawn for the people around the phone. Not a user
/// setting: every mode knows how its phone is held. Solo, Daily, Ranked and
/// online Multiplayer are one phone per player (`.oneWay`); Same-phone
/// Multiplayer lays the phone flat between two players (`.twoWay`).
enum Appearance {
    /// Which way the numbers on cards (and the target) face.
    enum CardFacing: Equatable {
        /// One number in the middle of each card — a phone held by one player.
        case oneWay
        /// The number in both halves of the card, the bottom copy upside
        /// down, so two players sitting across a table both read it the
        /// right way up.
        case twoWay
    }
}

/// A playing card's face: the value centred, or once in each half with the
/// bottom copy rotated for the player across the table.
struct CardFace: View {
    let text: String
    let isWhole: Bool
    let height: CGFloat
    /// The card's width when known. Narrow cards (three to a row) size their
    /// number from the width so two digits keep their margins.
    var width: CGFloat? = nil
    let facing: Appearance.CardFacing

    /// The dimension the type scales from: the height, unless the card is
    /// narrow enough that the width is the tighter constraint.
    private var unit: CGFloat { min(height, (width ?? .infinity) * 1.25) }

    var body: some View {
        switch facing {
        case .oneWay:
            Text(text)
                .font(.system(size: isWhole ? unit * 0.43 : unit * 0.28, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.inkDark)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        case .twoWay:
            // One copy in each half of the card: the top half upright, the
            // bottom half upside down for the player across the table.
            VStack(spacing: height * 0.14) {
                halfLabel
                halfLabel.rotationEffect(.degrees(180))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, height * 0.08)
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
    }

    private var halfLabel: some View {
        Text(text)
            .font(.system(size: isWhole ? unit * 0.36 : unit * 0.22, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.inkDark)
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .orientationMark(if: Appearance.needsOrientationMark(text), thickness: max(2, height * 0.035))
            .frame(maxWidth: .infinity)
    }
}

extension Appearance {
    /// 6 and 9 read as each other upside down, so in two-direction mode they
    /// get the playing-card convention: a short line under the digit.
    static func needsOrientationMark(_ text: String) -> Bool {
        text == "6" || text == "9"
    }
}

private extension View {
    /// A short underline hugging the glyph, drawn only when `condition` holds.
    func orientationMark(if condition: Bool, thickness: CGFloat) -> some View {
        overlay(alignment: .bottom) {
            if condition {
                Capsule()
                    .fill(Theme.inkDark)
                    .frame(height: thickness)
                    .padding(.horizontal, thickness)
                    .offset(y: thickness * 0.5)
            }
        }
    }
}

/// The "Target" badge above the board, shared by every mode. In two-way
/// facing the number is shown twice, the second copy upside down.
struct TargetCard: View {
    let value: String
    var facing: Appearance.CardFacing = .oneWay

    var body: some View {
        VStack(spacing: 6) {
            Text("Target")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .textCase(.uppercase)
                .kerning(1.5)
                .foregroundStyle(Theme.inkMuted)
            HStack(spacing: 28) {
                number
                if facing == .twoWay {
                    number.rotationEffect(.degrees(180))
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            )
        }
    }

    private var number: some View {
        Text(value)
            .font(.system(size: 56, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.inkDark)
            .orientationMark(if: facing == .twoWay && Appearance.needsOrientationMark(value), thickness: 3)
    }
}
