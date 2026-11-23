import SwiftUI

/// The hand of cards laid out as a centred fan: three on top, two beneath.
/// As cards merge away the hand reflows 3-2 → 2-2 → 3 → 2 → 1, always
/// centred, and the board keeps its two-row height so nothing above or
/// below it moves. An optional footer (the revealed solution) sits under the
/// rows; the cards shrink to make room so the board stays the same height.
///
/// Cards are positioned explicitly rather than stacked in rows, so a card
/// that changes row between steps slides there instead of popping.
struct CardBoard<Footer: View>: View {
    /// How the hand is arranged.
    enum Layout {
        /// Three on top, two beneath, reflowing as cards merge away.
        case fan
        /// All five in one row, five slots wide, centred as the hand shrinks.
        /// Same-phone play shows one row per player.
        case row
    }

    let cards: [Card]
    var selected: Set<Card.ID> = []
    /// Height of a card while no footer is showing.
    let cardHeight: CGFloat
    var facing: Appearance.CardFacing = .oneWay
    var layout: Layout = .fan
    var spacing: CGFloat = 12
    /// Height reserved under the rows for `footer`; 0 hides it.
    var footerHeight: CGFloat = 0
    var onTap: (Card) -> Void = { _ in }
    /// Swipe-to-combine (opt-in via the `dragToCombine` setting): start
    /// dragging a card, and the general direction of the first stretch of
    /// the swipe picks the operator by quadrant (↖ +, ↗ −, ↙ ×, ↘ ÷, the
    /// operation row folded into a 2×2). Carry the card on to another and
    /// release to combine. Boards that don't pass this
    /// (previews, replays) stay tap-only.
    var onCombine: ((_ first: Card, _ second: Card, _ op: Operation) -> Void)? = nil
    /// An operator already picked on the operation row. A drop uses it when
    /// the swipe was too short to pick one.
    var preselectedOp: Operation? = nil
    @ViewBuilder var footer: () -> Footer

    @AppStorage(CardBoardSettings.dragToCombineKey) private var dragToCombine = false
    @State private var dragID: Card.ID?
    @State private var dragOffset: CGSize = .zero
    /// Operator latched from the opening direction of the current drag.
    @State private var dragOp: Operation?
    @State private var hoverID: Card.ID?
    /// A drag's touch-up also fires the card's tap button; taps right after a
    /// drag are ignored so the dropped card doesn't end up selected.
    @State private var lastDragEnd: Date = .distantPast

    /// How far the finger moves before the swipe direction is read. Long
    /// enough that the opening wobble of a drag doesn't decide it.
    private let latchDistance: CGFloat = 48
    /// Movement under this on release counts as a tap, not a swipe.
    private let tapSlop: CGFloat = 10

    private var dragEnabled: Bool { dragToCombine && onCombine != nil }

    /// The board's fixed height for a given card height.
    static func height(cardHeight: CGFloat, spacing: CGFloat = 12, layout: Layout = .fan) -> CGFloat {
        layout == .row ? cardHeight : 2 * cardHeight + spacing
    }

    /// Width of one card in a board `boardWidth` wide.
    static func cardWidth(boardWidth: CGFloat, spacing: CGFloat = 12, layout: Layout = .fan) -> CGFloat {
        layout == .row ? (boardWidth - 4 * spacing) / 5 : (boardWidth - 2 * spacing) / 3
    }

    /// Card height that fits `boardHeight`, e.g. the space an older
    /// three-row layout used, capped so narrow cards don't go tall and thin.
    static func cardHeight(fitting boardHeight: CGFloat, boardWidth: CGFloat, spacing: CGFloat = 12) -> CGFloat {
        let cardWidth = (boardWidth - 2 * spacing) / 3
        return min(cardWidth * 1.6, (boardHeight - spacing) / 2)
    }

    /// How many cards sit in each row for a hand of `count`.
    static func rowSizes(for count: Int, layout: Layout = .fan) -> [Int] {
        if layout == .row { return count > 0 ? [count] : [] }
        switch count {
        case 5: return [3, 2]
        case 4: return [2, 2]
        default: return count > 0 ? [count] : []
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let cardWidth = Self.cardWidth(boardWidth: width, spacing: spacing, layout: layout)
            let hasFooter = footerHeight > 0
            let rows: CGFloat = layout == .row ? 1 : 2
            let h = hasFooter ? cardHeight - (footerHeight + spacing) / rows : cardHeight
            let slots = Self.slots(count: cards.count, cardWidth: cardWidth, cardHeight: h, boardWidth: width, spacing: spacing, layout: layout)
            ZStack(alignment: .topLeading) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    let slot = slots[index]
                    let isDragging = dragID == card.id
                    CardView(card: card, isSelected: selected.contains(card.id) || hoverID == card.id, height: h, width: cardWidth, facing: facing) {
                        guard Date().timeIntervalSince(lastDragEnd) > 0.4 else { return }
                        onTap(card)
                    }
                    .frame(width: cardWidth, height: h)
                    .overlay(alignment: .topTrailing) {
                        if isDragging, let op = dragOp ?? preselectedOp {
                            operatorBadge(op, dimmed: dragOp == nil)
                                .offset(x: 10, y: -10)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .scaleEffect(isDragging ? 1.08 : 1)
                    .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 14, y: 8)
                    .position(x: slot.midX, y: slot.midY)
                    .offset(isDragging ? dragOffset : .zero)
                    .zIndex(isDragging ? 2 : 0)
                    .simultaneousGesture(dragEnabled ? dragGesture(for: card, slots: slots) : nil)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                // From touch-down until the swipe direction is read, a faint
                // compass around the card's home shows which way means what.
                if let dragID, dragOp == nil, let index = cards.firstIndex(where: { $0.id == dragID }),
                   let slot = slots[safe: index] {
                    operatorCompass(around: slot, cardWidth: cardWidth, boardSize: geo.size)
                        .zIndex(1)
                        .transition(.opacity)
                }
                if hasFooter {
                    footer()
                        .frame(width: width, height: footerHeight)
                        .position(x: width / 2, y: rows * (h + spacing) + footerHeight / 2)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "cardBoard")
            .animation(.easeOut(duration: 0.15), value: dragOp)
        }
        .frame(height: Self.height(cardHeight: cardHeight, spacing: spacing, layout: layout))
    }

    // MARK: - Swipe to combine

    private func dragGesture(for card: Card, slots: [CGRect]) -> some Gesture {
        // minimumDistance 0 so the compass shows on touch-down, while the
        // finger is still holding the card; a release without real movement
        // is left to the card's tap button.
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cardBoard"))
            .onChanged { value in
                if dragID == nil {
                    dragID = card.id
                    dragOp = nil
                    hoverID = nil
                }
                dragOffset = value.translation
                if dragOp == nil, let op = Self.operation(forFlick: value.translation, minimum: latchDistance) {
                    dragOp = op
                    Haptics.light()
                }
                let over = cardID(at: value.location, slots: slots, excluding: card.id)
                if over != hoverID {
                    hoverID = over
                    if over != nil { Haptics.light() }
                }
            }
            .onEnded { value in
                guard dragID == card.id else { return }
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < tapSlop {
                    // A press-and-release: the tap button handles it.
                    withAnimation(.spring(duration: 0.25)) {
                        dragID = nil; dragOffset = .zero; hoverID = nil; dragOp = nil
                    }
                    return
                }
                lastDragEnd = Date()
                let over = cardID(at: value.location, slots: slots, excluding: card.id)
                let op = dragOp ?? preselectedOp
                if let over, let op, let target = cards.first(where: { $0.id == over }) {
                    Haptics.medium()
                    withAnimation(.spring(duration: 0.3)) {
                        dragID = nil; dragOffset = .zero; hoverID = nil; dragOp = nil
                    }
                    onCombine?(card, target, op)
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
                        dragID = nil; dragOffset = .zero; hoverID = nil; dragOp = nil
                    }
                }
            }
    }

    private func cardID(at point: CGPoint, slots: [CGRect], excluding: Card.ID) -> Card.ID? {
        for (index, slot) in slots.enumerated() where index < cards.count {
            let card = cards[index]
            if card.id != excluding, slot.insetBy(dx: -spacing / 2, dy: -spacing / 2).contains(point) {
                return card.id
            }
        }
        return nil
    }

    /// The operator riding on the dragged card's corner.
    private func operatorBadge(_ op: Operation, dimmed: Bool) -> some View {
        Text(op.rawValue)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Theme.button.opacity(dimmed ? 0.55 : 1)).shadow(color: .black.opacity(0.18), radius: 6, y: 2))
    }

    /// Faint operator labels around the dragged card's home slot.
    private func operatorCompass(around slot: CGRect, cardWidth: CGFloat, boardSize: CGSize) -> some View {
        let radius = max(cardWidth * 0.62, 58)
        let margin = radius + 20
        let center = CGPoint(x: min(max(slot.midX, margin), boardSize.width - margin), y: slot.midY)
        return ForEach(Operation.allCases) { op in
            let dir = Self.direction(of: op)
            Text(op.rawValue)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.inkDark.opacity(0.35))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.7)))
                .position(x: center.x + dir.width * radius, y: center.y + dir.height * radius)
                .allowsHitTesting(false)
        }
    }

    /// ↖ +, ↗ −, ↙ ×, ↘ ÷: the operation row's order, folded into a 2×2.
    /// Unit vector in view coordinates.
    static func direction(of op: Operation) -> CGSize {
        let d: CGFloat = 0.7071
        switch op {
        case .add: return CGSize(width: -d, height: -d)
        case .subtract: return CGSize(width: d, height: -d)
        case .multiply: return CGSize(width: -d, height: d)
        case .divide: return CGSize(width: d, height: d)
        }
    }

    /// The operator a swipe points at, by quadrant, or nil for a tap /
    /// too-short move. Any up-and-left motion is +, however shallow, so
    /// there's no knife-edge between "left" and "up".
    static func operation(forFlick t: CGSize, minimum: CGFloat = 18) -> Operation? {
        guard hypot(t.width, t.height) >= minimum else { return nil }
        switch (t.width < 0, t.height < 0) {
        case (true, true): return .add
        case (false, true): return .subtract
        case (true, false): return .multiply
        case (false, false): return .divide
        }
    }

    /// Frame of each card's slot, in order, centred row by row.
    private static func slots(count: Int, cardWidth: CGFloat, cardHeight: CGFloat, boardWidth: CGFloat, spacing: CGFloat, layout: Layout) -> [CGRect] {
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for rowCount in rowSizes(for: count, layout: layout) {
            let rowWidth = CGFloat(rowCount) * cardWidth + CGFloat(rowCount - 1) * spacing
            var x = (boardWidth - rowWidth) / 2
            for _ in 0..<rowCount {
                frames.append(CGRect(x: x, y: y, width: cardWidth, height: cardHeight))
                x += cardWidth + spacing
            }
            y += cardHeight + spacing
        }
        return frames
    }
}

extension CardBoard where Footer == EmptyView {
    init(cards: [Card], selected: Set<Card.ID> = [], cardHeight: CGFloat,
         facing: Appearance.CardFacing = .oneWay, layout: Layout = .fan, spacing: CGFloat = 12,
         onTap: @escaping (Card) -> Void = { _ in },
         onCombine: ((Card, Card, Operation) -> Void)? = nil,
         preselectedOp: Operation? = nil) {
        self.cards = cards
        self.selected = selected
        self.cardHeight = cardHeight
        self.facing = facing
        self.layout = layout
        self.spacing = spacing
        self.footerHeight = 0
        self.onTap = onTap
        self.onCombine = onCombine
        self.preselectedOp = preselectedOp
        self.footer = { EmptyView() }
    }
}

enum CardBoardSettings {
    /// Opt-in: swipe a card diagonally toward an operator, release it on another card.
    static let dragToCombineKey = "dragToCombine"
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}
