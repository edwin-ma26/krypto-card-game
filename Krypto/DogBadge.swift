import SwiftUI

/// The Founding Pup badge art, drawn in shapes rather than shipped as an image
/// asset — it stays crisp at any size, costs nothing in the bundle, and can
/// animate between its evolution stages.
///
/// Stages are additive: every mutation layers on top of the same base dog
/// rather than swapping in a different drawing, so the thing you earned is
/// visibly still the thing you earned, just increasingly wrong.
///
/// Colors come from `BadgeStage` rather than `Theme`. The palette is
/// remote-driven now, and a seasonal restyle that turned the dog green would be
/// a surprise; this is illustration, not chrome.
struct DogBadge: View {
    var size: CGFloat = 120
    /// Locked badges render as a silhouette with a paw print — the whole point
    /// is that you can't see what you're earning until you earn it.
    var isRevealed: Bool = true
    var stage: BadgeStage = .pup

    private static let muzzle = Color(red: 0.96, green: 0.90, blue: 0.80)
    private static let ink = Color(red: 0.22, green: 0.16, blue: 0.11)
    private static let tongue = Color(red: 0.93, green: 0.55, blue: 0.58)

    /// Everything is expressed as a fraction of `size` so the whole badge scales
    /// as one piece.
    private func u(_ fraction: CGFloat) -> CGFloat { size * fraction }

    var body: some View {
        ZStack {
            ring
            if isRevealed {
                dog.transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                mystery.transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: isRevealed)
        .animation(.spring(response: 0.6, dampingFraction: 0.55), value: stage)
    }

    // MARK: - Badge frame

    private var ring: some View {
        ZStack {
            if stage.isCosmic {
                // Sits behind the ring so the badge reads as emitting light
                // rather than having a second outline drawn around it.
                Circle()
                    .fill(stage.ringColors[1].opacity(0.5))
                    .blur(radius: u(0.08))
                    .scaleEffect(1.08)
            }
            Circle()
                .fill(
                    LinearGradient(
                        colors: isRevealed
                            ? stage.ringColors
                            : [Color(red: 0.72, green: 0.70, blue: 0.66), Color(red: 0.55, green: 0.53, blue: 0.49)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(stage.isCosmic ? Color(red: 0.12, green: 0.10, blue: 0.22) : Color(red: 0.99, green: 0.97, blue: 0.93))
                .padding(u(0.07))
        }
    }

    /// A paw print rather than a plain "?" — it gives away that there's a dog
    /// in here without giving away the dog, which is the tease we actually want.
    private var mystery: some View {
        Image(systemName: "pawprint.fill")
            .font(.system(size: u(0.34), weight: .bold))
            .foregroundStyle(Color(red: 0.62, green: 0.60, blue: 0.56))
    }

    // MARK: - Dog

    private var dog: some View {
        ZStack {
            if stage.isCosmic { starfield }
            if stage.hasAntennae {
                antenna(flipped: false)
                antenna(flipped: true)
            }
            if stage.isCosmic { halo }

            ear(flipped: false)
            ear(flipped: true)

            Ellipse()
                .fill(stage.fur)
                .frame(width: u(0.52), height: u(0.48))

            // Lighter blaze down the forehead, which is what stops the face
            // reading as a flat oval — and where the third eye opens.
            Ellipse()
                .fill(Self.muzzle.opacity(0.55))
                .frame(width: u(0.14), height: u(0.22))
                .offset(y: -u(0.10))

            if stage.hasThirdEye { thirdEye }
            if stage.hasCheekEyes {
                cheekEye(x: -u(0.21))
                cheekEye(x: u(0.21))
            }

            eye(x: -u(0.11))
            eye(x: u(0.11))

            Ellipse()
                .fill(Self.muzzle)
                .frame(width: u(0.28), height: u(0.20))
                .offset(y: u(0.11))

            tongueShape
            mouth

            Ellipse()
                .fill(Self.ink)
                .frame(width: u(0.11), height: u(0.08))
                .offset(y: u(0.055))
        }
        .offset(y: -u(0.01))
    }

    private func ear(flipped: Bool) -> some View {
        Ellipse()
            .fill(stage.furDark)
            .frame(width: u(0.19), height: u(0.32))
            .rotationEffect(.degrees(flipped ? 16 : -16))
            .offset(x: flipped ? u(0.24) : -u(0.24), y: u(0.03))
    }

    private func eye(x: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Self.ink)
                .frame(width: u(0.085), height: u(0.085))
            Circle()
                .fill(.white)
                .frame(width: u(0.03), height: u(0.03))
                .offset(x: -u(0.015), y: -u(0.018))
        }
        .offset(x: x, y: -u(0.055))
    }

    /// Vertical rather than round, so it reads as an extra eye that shouldn't
    /// be there instead of a third copy of the normal pair.
    private var thirdEye: some View {
        ZStack {
            Ellipse()
                .fill(.white)
                .frame(width: u(0.07), height: u(0.10))
            Ellipse()
                .fill(stage.isCosmic ? Color(red: 0.55, green: 0.85, blue: 0.95) : Color(red: 0.85, green: 0.62, blue: 0.25))
                .frame(width: u(0.05), height: u(0.075))
            Ellipse()
                .fill(Self.ink)
                .frame(width: u(0.022), height: u(0.06))
        }
        .offset(y: -u(0.135))
    }

    private func cheekEye(x: CGFloat) -> some View {
        ZStack {
            Circle().fill(.white).frame(width: u(0.055), height: u(0.055))
            Circle().fill(Self.ink).frame(width: u(0.028), height: u(0.028))
        }
        .offset(x: x, y: u(0.02))
    }

    private func antenna(flipped: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(stage.furDark)
                .frame(width: u(0.022), height: u(0.16))
                .offset(y: -u(0.30))
            Circle()
                .fill(stage.ringColors[0])
                .frame(width: u(0.07), height: u(0.07))
                .offset(y: -u(0.39))
        }
        .rotationEffect(.degrees(flipped ? 14 : -14), anchor: .bottom)
        .offset(x: flipped ? u(0.09) : -u(0.09), y: u(0.06))
    }

    private var halo: some View {
        Ellipse()
            .stroke(stage.ringColors[0], lineWidth: u(0.022))
            .frame(width: u(0.34), height: u(0.09))
            .offset(y: -u(0.335))
    }

    private var starfield: some View {
        ZStack {
            ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, star in
                Circle()
                    .fill(.white.opacity(star.opacity))
                    .frame(width: u(star.size), height: u(star.size))
                    .offset(x: u(star.x), y: u(star.y))
            }
        }
    }

    /// Fixed rather than random so the badge doesn't re-scatter its stars on
    /// every redraw.
    private static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (-0.28, -0.22, 0.020, 0.9), (0.30, -0.14, 0.016, 0.7), (-0.32, 0.12, 0.014, 0.6),
        (0.26, 0.24, 0.020, 0.8), (0.05, -0.34, 0.014, 0.7), (-0.14, 0.32, 0.016, 0.6),
    ]

    /// The classic two-arc dog mouth, drawn as one path so the curves stay
    /// symmetric about the nose.
    private var mouth: some View {
        Path { path in
            let cx = size / 2
            let top = size / 2 + u(0.095)
            path.move(to: CGPoint(x: cx, y: top))
            path.addQuadCurve(
                to: CGPoint(x: cx - u(0.075), y: top + u(0.045)),
                control: CGPoint(x: cx - u(0.055), y: top + u(0.055))
            )
            path.move(to: CGPoint(x: cx, y: top))
            path.addQuadCurve(
                to: CGPoint(x: cx + u(0.075), y: top + u(0.045)),
                control: CGPoint(x: cx + u(0.055), y: top + u(0.055))
            )
        }
        .stroke(Self.ink, style: StrokeStyle(lineWidth: u(0.018), lineCap: .round))
        .frame(width: size, height: size)
    }

    private var tongueShape: some View {
        Ellipse()
            .fill(Self.tongue)
            .frame(width: u(0.085), height: u(0.10))
            .offset(y: u(0.165))
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            DogBadge(size: 110, stage: .pup)
            DogBadge(size: 110, stage: .thirdEye)
        }
        HStack(spacing: 20) {
            DogBadge(size: 110, stage: .manyEyed)
            DogBadge(size: 110, stage: .cosmic)
        }
        DogBadge(size: 110, isRevealed: false)
    }
    .padding(30)
    .background(Color(red: 0.972, green: 0.965, blue: 0.945))
}
