import SwiftUI
import Combine

@MainActor
final class GameViewModel: ObservableObject {
    @Published var cards: [Card] = []
    @Published var target: Fraction = Fraction(0)
    @Published var selectedCardID: UUID?
    @Published var selectedOp: Operation?
    @Published var elapsed: Int = 0
    @Published var isSolved = false
    @Published var hint: String?
    /// Human-readable log of the operations performed so far (e.g. "17 − 11 = 6"),
    /// kept in lockstep with `history`. Broadcast during a race so an opponent can
    /// watch the solve live, and shown as the winning solution afterwards.
    @Published var steps: [String] = []
    /// Slot-based record of the merges so far (see `ReplayMove`), kept in
    /// lockstep with `history`/`steps`, so a finished solve can be replayed.
    @Published private(set) var replayMoves: [ReplayMove] = []

    @AppStorage("gamesWon") var gamesWon = 0
    @AppStorage("bestTime") var bestTime = 0
    @AppStorage("totalSolveTime") var totalSolveTime = 0

    var averageTime: Int { gamesWon > 0 ? totalSolveTime / gamesWon : 0 }

    /// Set while a live race is running (casual room or ranked match); progress and solves are reported to it.
    weak var multiplayer: LiveMatchReporting?

    /// Set by the Single Player board only. While set (and no race is running)
    /// each dealt puzzle is rated: a target time is shown, a solve or give-up
    /// moves the rating, and an unfinished puzzle survives a relaunch.
    weak var soloRating: SoloRatingService?
    /// What the player is up against on the current rated puzzle — the
    /// device estimate at deal time, refined once the stats fetch returns.
    @Published private(set) var puzzleModel: SoloRating.PuzzleModel?
    /// True once the player chose Show Solution; the puzzle is over and
    /// `revealedSolution` holds the steps.
    @Published private(set) var gaveUp = false
    @Published private(set) var revealedSolution: [String] = []
    /// Rating change applied by the puzzle that just ended, for the result card.
    @Published private(set) var ratingDelta: Int?
    /// Set when a relaunch found a rated puzzle that was on screen when the
    /// process died (the player swiped the app away): the points it cost,
    /// shown as a brief notice over the fresh deal.
    @Published var abandonedNotice: Int?
    private var statsFetch: Task<Void, Never>?
    private var pausedAt: Date?

    /// True while the board is a post-game review: the original hand is
    /// back on the table next to a revealed solution so the player can work
    /// through it. Nothing is live — no clock, no progress or solve reports
    /// to a match, no stats, no rating. Cleared by the next real deal.
    @Published private(set) var isReviewing = false

    var isRatedSolo: Bool { soloRating != nil && multiplayer == nil && !isReviewing }
    /// Solved or given up — either way the clock has stopped.
    var isOver: Bool { isSolved || gaveUp }

    /// Break-even time for the current rating on this puzzle, or nil until
    /// the puzzle is rated.
    var targetSeconds: Int? {
        guard let puzzleModel, let soloRating else { return nil }
        return SoloRating.targetSeconds(rating: soloRating.rating, model: puzzleModel)
    }

    /// Attribution passed to `PuzzleStats.recordSolved` for a non-multiplayer
    /// solve. Plain solo play leaves this as "solo" (no per-player identity to
    /// attach); the daily puzzle overrides it to the signed-in uid so a
    /// fastest-solve record can actually be attributed to someone.
    var solverIdentity = "solo"

    /// The hand/target as originally dealt, kept alongside `cards` (which
    /// shrinks as operations combine cards) so a solve can still be attributed
    /// to the right puzzle combo for `PuzzleStats`.
    private var dealtHand: [Int] = []
    private var dealtTarget: Int = 0
    private var dealtColors: [Int] = []
    /// Which dealt slot (0–4) each card id came from. A merged card keeps the
    /// second card's id, so this never needs updating after the deal.
    private var slotByCardID: [UUID: Int] = [:]

    /// The finished solve as a replayable record, or nil until it's solved.
    var solveReplay: SolveReplay? {
        guard isSolved else { return nil }
        return SolveReplay(hand: dealtHand, target: dealtTarget, colors: dealtColors, moves: replayMoves)
    }

    private var history: [[Card]] = []
    private var timerCancellable: AnyCancellable?
    /// True while the clock is frozen (app backgrounded, or a sheet/overlay is
    /// covering the board). Paused time is excluded from `elapsed`.
    private var isPaused = false
    /// When the current game started, used to derive `elapsed` from the wall
    /// clock. A repeating `Timer` doesn't fire while the app is suspended
    /// (screen locked / backgrounded), so counting ticks would undercount the
    /// real time — reading it from a stored start date keeps the clock (and the
    /// solve time we report in a race) accurate across a lock/unlock.
    private var startDate: Date?

    /// `dealsOwnPuzzle` is false for views that immediately hand this instance
    /// a specific hand+target via `startShared` (a ranked match, the daily
    /// puzzle) — dealing here first would still be visible for a single frame
    /// and, worse, would call `PuzzleStats.recordDealt` for a puzzle that's
    /// discarded before anyone ever sees or plays it.
    init(dealsOwnPuzzle: Bool = true) {
        if dealsOwnPuzzle { newGame() }
    }

    var timeString: String {
        String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    func newGame() {
        let (hand, targetValue) = Krypto.deal()
        // Only the solo path deals here — a multiplayer room's host records its
        // own deal once for the whole room, and `startShared` (used by every
        // participant, including the host's own board) would otherwise double-count it.
        PuzzleStats.recordDealt(hand: hand, target: targetValue)
        start(hand: hand, target: targetValue)
        beginRatedPuzzleIfNeeded()
    }

    // MARK: - Rated solo play

    /// Picks up where a rated puzzle was left. Two cases:
    /// - *Parked*: the player backed out to Home mid-puzzle (`park()`), so it
    ///   resumes with time away credited at the reduced pause rate.
    /// - *Not parked*: the process died with the puzzle on screen — the
    ///   player swiped the app away (or, indistinguishably, iOS evicted it).
    ///   That counts as an abandon: the give-up cost is charged, the shared
    ///   stats get the abandon, and the caller deals a fresh puzzle.
    /// Returns true only when a puzzle was resumed.
    func resumeSavedSoloGame() -> Bool {
        guard isRatedSolo, let saved = SoloProgress.load() else { return false }
        if saved.parked {
            let away = Date().timeIntervalSince(saved.pausedAt)
            start(hand: saved.hand, target: saved.target, resumeElapsed: saved.elapsed + Self.pauseCredit(for: away))
            beginRatedPuzzleIfNeeded()
            return true
        }
        SoloProgress.clear()
        soloRating?.recordAbandonment(cost: saved.giveUpCost)
        PuzzleStats.recordAbandoned(hand: saved.hand, target: saved.target)
        abandonedNotice = saved.giveUpCost
        return false
    }

    /// Call when the board leaves the screen with a rated puzzle still
    /// running (back to Home). Marks the save resumable so the next visit
    /// continues it rather than treating it as a swipe-out.
    func park() {
        guard isRatedSolo, !isOver, startDate != nil else { return }
        syncElapsed()
        saveProgress(parked: true)
    }

    private func saveProgress(parked: Bool) {
        let cost = puzzleModel.map { SoloRating.giveUpCost(model: $0) } ?? 15
        SoloProgress(hand: dealtHand, target: dealtTarget, elapsed: elapsed, pausedAt: Date(),
                     giveUpCost: cost, parked: parked).save()
    }

    private func beginRatedPuzzleIfNeeded() {
        guard isRatedSolo else { return }
        let hand = dealtHand, target = dealtTarget
        let estimate = Krypto.estimateSolveSeconds(hand: hand, target: target)
        puzzleModel = SoloRating.PuzzleModel(estimateSeconds: estimate, summary: nil)
        saveProgress(parked: false)
        statsFetch = Task { [weak self] in
            let summary = await PuzzleStats.fetch(hand: hand, target: target)
            guard let self, !Task.isCancelled, self.dealtHand == hand, self.dealtTarget == target else { return }
            self.puzzleModel = SoloRating.PuzzleModel(estimateSeconds: estimate, summary: summary)
            // Re-save so a swipe-out charges the refined cost, not the estimate's.
            if !self.isOver { self.saveProgress(parked: false) }
        }
    }

    /// Ends the puzzle as a loss and reveals one solution. Costs
    /// `SoloRating.giveUpCost` for the current puzzle; recorded on the shared
    /// stats as an abandon so the time distribution can account for it.
    func giveUp() {
        guard !isOver else { return }
        if let startDate, !isPaused { elapsed = max(0, Int(Date().timeIntervalSince(startDate))) }
        timerCancellable?.cancel()
        timerCancellable = nil
        gaveUp = true
        hint = nil
        selectedCardID = nil
        selectedOp = nil
        let hand = dealtHand.map { Fraction($0) }
        revealedSolution = (Krypto.solve(hand, target: target) ?? []).map {
            "\($0.a) \($0.op.rawValue) \($0.b) = \($0.result)"
        }
        if let puzzleModel, let soloRating {
            soloRating.recordGiveUp(model: puzzleModel)
            ratingDelta = soloRating.lastDelta
        }
        if isRatedSolo {
            StatsLog.shared.recordSolo(seconds: nil, ratingAfter: soloRating?.rating, delta: ratingDelta)
        }
        PuzzleStats.recordAbandoned(hand: dealtHand, target: dealtTarget)
        SoloProgress.clear()
    }

    /// Paused time counts at a third, capped, so stepping away isn't free
    /// thinking time but a phone call isn't a loss either.
    private static func pauseCredit(for interval: TimeInterval) -> Int {
        min(300, max(0, Int(interval / 3)))
    }

    /// `resumeElapsed` restarts the clock already advanced by that many
    /// seconds — used when returning to a puzzle (e.g. the daily puzzle,
    /// reopened later the same day) whose solve time was saved off when the
    /// player last left it, so the time spent away isn't counted twice and
    /// isn't lost either.
    func startShared(hand: [Int], target: Int, resumeElapsed: Int = 0) {
        start(hand: hand, target: target, resumeElapsed: resumeElapsed)
    }

    /// Puts the original hand back for a post-game walk-through (see
    /// `isReviewing`). The displayed time stays frozen at whatever it was.
    func startReview(hand: [Int], target: Int) {
        let frozen = elapsed
        start(hand: hand, target: target)
        timerCancellable?.cancel()
        timerCancellable = nil
        startDate = nil
        elapsed = frozen
        isReviewing = true
    }

    private func start(hand: [Int], target targetValue: Int, resumeElapsed: Int = 0) {
        dealtHand = hand
        dealtTarget = targetValue
        let colors = Array(0..<5).shuffled()
        cards = zip(hand, colors).map { Card(value: Fraction($0), colorIndex: $1) }
        dealtColors = Array(colors.prefix(hand.count))
        slotByCardID = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1.id, $0) })
        target = Fraction(targetValue)
        history = []
        steps = []
        replayMoves = []
        selectedCardID = nil
        selectedOp = nil
        hint = nil
        isSolved = false
        gaveUp = false
        revealedSolution = []
        ratingDelta = nil
        puzzleModel = nil
        statsFetch?.cancel()
        statsFetch = nil
        pausedAt = nil
        elapsed = resumeElapsed
        isPaused = false
        isReviewing = false
        startDate = Date().addingTimeInterval(-Double(resumeElapsed))
        startTimer()
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.syncElapsed()
            }
    }

    /// Freezes the clock — e.g. when the app backgrounds or a popup covers the
    /// board — capturing the time elapsed so far. Safe to call redundantly.
    func pause() {
        guard !isPaused, !isOver, startDate != nil else { return }
        syncElapsed()
        timerCancellable?.cancel()
        timerCancellable = nil
        isPaused = true
        pausedAt = Date()
        if isRatedSolo {
            // Backgrounding is the last chance to write before iOS may kill
            // the process, so the unfinished puzzle is saved here.
            saveProgress(parked: false)
        }
    }

    /// Resumes a paused clock, rebasing `startDate` so the paused interval isn't
    /// counted. No-op if we weren't paused or the game is already over.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        guard !isOver, startDate != nil else { return }
        if isRatedSolo, let pausedAt {
            elapsed += Self.pauseCredit(for: Date().timeIntervalSince(pausedAt))
        }
        pausedAt = nil
        startDate = Date().addingTimeInterval(-Double(elapsed))
        startTimer()
    }

    /// Recomputes `elapsed` from the wall clock. Called on each timer tick and
    /// whenever the app returns to the foreground, so the displayed time (and
    /// the solve time reported to a race) reflects real time even if the app
    /// was suspended and the timer stopped firing.
    func syncElapsed() {
        guard !isPaused, !isOver, let startDate else { return }
        elapsed = max(0, Int(Date().timeIntervalSince(startDate)))
        // A kill straight from the foreground never reaches `pause()`, so a
        // rated puzzle also checkpoints its clock every few seconds.
        if isRatedSolo, elapsed % 5 == 0 { saveProgress(parked: false) }
    }

    func tapCard(_ card: Card) {
        hint = nil
        guard !isSolved else { return }
        if !isReviewing { multiplayer?.touchActivity() }
        if selectedCardID == card.id {
            selectedCardID = nil
            selectedOp = nil
            return
        }
        guard let firstID = selectedCardID, let op = selectedOp else {
            selectedCardID = card.id
            return
        }
        combine(firstID: firstID, secondID: card.id, op: op)
    }

    /// Drag-to-combine: `first` was dropped on `second` and `op` picked from
    /// the flick ring. Same move as tap–op–tap; the result lands on `second`.
    func combine(first: Card, second: Card, op: Operation) {
        hint = nil
        guard !isSolved, first.id != second.id else { return }
        combine(firstID: first.id, secondID: second.id, op: op)
    }

    private func combine(firstID: Card.ID, secondID: Card.ID, op: Operation) {
        guard let firstIndex = cards.firstIndex(where: { $0.id == firstID }),
              let secondIndex = cards.firstIndex(where: { $0.id == secondID })
        else { return }
        guard let result = op.apply(cards[firstIndex].value, cards[secondIndex].value) else {
            // Division by zero: keep the op, just bounce the selection.
            return
        }
        let step = "\(cards[firstIndex].value) \(op.rawValue) \(cards[secondIndex].value) = \(result)"
        history.append(cards)
        steps.append(step)
        if let firstSlot = slotByCardID[cards[firstIndex].id],
           let secondSlot = slotByCardID[cards[secondIndex].id] {
            replayMoves.append(ReplayMove(first: firstSlot, op: op.rawValue, second: secondSlot))
        }
        cards[secondIndex].value = result
        let resultID = cards[secondIndex].id
        cards.remove(at: firstIndex)
        // Keep the result selected so the next operation chains off it.
        selectedCardID = cards.count > 1 ? resultID : nil
        selectedOp = nil
        if !isReviewing {
            multiplayer?.updateProgress(cardsLeft: cards.count)
            multiplayer?.updateLiveSteps(steps)
        }
        checkWin()
    }

    func tapOperation(_ op: Operation) {
        hint = nil
        guard !isSolved, selectedCardID != nil else { return }
        if !isReviewing { multiplayer?.touchActivity() }
        selectedOp = selectedOp == op ? nil : op
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        if !steps.isEmpty { steps.removeLast() }
        if !replayMoves.isEmpty { replayMoves.removeLast() }
        cards = previous
        selectedCardID = nil
        selectedOp = nil
        hint = nil
        isSolved = false
        if !isReviewing {
            multiplayer?.updateProgress(cardsLeft: cards.count)
            multiplayer?.updateLiveSteps(steps)
        }
    }

    var canUndo: Bool { !history.isEmpty }

    func showHint() {
        guard !isSolved else { return }
        hint = hintText()
    }

    /// The next-step hint for the current board, computed without mutating state
    /// so it can be broadcast to a multiplayer room as well as shown locally.
    func hintText() -> String {
        if let steps = Krypto.solve(cards.map(\.value), target: target), let first = steps.first {
            return "Try \(first.a) \(first.op.rawValue) \(first.b) = \(first.result)"
        } else {
            return "No solution from here — undo a step"
        }
    }

    private func checkWin() {
        guard cards.count == 1, cards[0].value == target else { return }
        // Reaching the target in a review is just the board matching the
        // solution: no win, no time, no stats, nothing reported.
        if isReviewing { isSolved = true; return }
        // Capture the exact solve time before freezing the clock, rather than
        // relying on the last 1-second tick. The fractional value feeds the
        // rating; the display and stats keep whole seconds.
        let preciseElapsed = startDate.map { max(0, Date().timeIntervalSince($0)) } ?? Double(elapsed)
        if startDate != nil { elapsed = Int(preciseElapsed) }
        isSolved = true
        gamesWon += 1
        totalSolveTime += elapsed
        if bestTime == 0 || elapsed < bestTime { bestTime = elapsed }
        if let multiplayer {
            // A race can have a player complete the cards without holding the
            // lock (e.g. after losing it); that's not a real solve for stats
            // purposes, so the live-match service records it itself, only once
            // a win is actually confirmed server-side.
            multiplayer.reportSolved(elapsed: elapsed)
        } else {
            PuzzleStats.recordSolved(
                hand: dealtHand, target: dealtTarget, elapsedSeconds: elapsed, solverName: solverIdentity
            )
            if let puzzleModel, let soloRating, ratingDelta == nil {
                soloRating.recordSolve(seconds: preciseElapsed, model: puzzleModel)
                ratingDelta = soloRating.lastDelta
            }
            if isRatedSolo {
                StatsLog.shared.recordSolo(seconds: elapsed, ratingAfter: soloRating?.rating, delta: ratingDelta)
            }
            if isRatedSolo { SoloProgress.clear() }
        }
    }
}

/// A rated Single Player puzzle left unfinished, persisted so walking away
/// from it is never free. `parked` distinguishes a deliberate back-to-Home
/// (resumable; only the deal and clock are kept, partial combines reset)
/// from a process death with the puzzle on screen (charged as an abandon —
/// see `GameViewModel.resumeSavedSoloGame`). `giveUpCost` is captured at
/// save time so the charge needs no network on relaunch.
struct SoloProgress {
    let hand: [Int]
    let target: Int
    let elapsed: Int
    let pausedAt: Date
    let giveUpCost: Int
    let parked: Bool

    private static let key = "solo.inProgress"

    func save() {
        UserDefaults.standard.set(
            ["hand": hand, "target": target, "elapsed": elapsed, "pausedAt": pausedAt.timeIntervalSince1970,
             "giveUpCost": giveUpCost, "parked": parked],
            forKey: Self.key
        )
    }

    static func load() -> SoloProgress? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let hand = dict["hand"] as? [Int], hand.count == 5,
              let target = dict["target"] as? Int,
              let elapsed = dict["elapsed"] as? Int,
              let pausedAt = dict["pausedAt"] as? Double else { return nil }
        return SoloProgress(
            hand: hand, target: target, elapsed: elapsed, pausedAt: Date(timeIntervalSince1970: pausedAt),
            giveUpCost: dict["giveUpCost"] as? Int ?? 15,
            // Saves from before `parked` existed were always resumable.
            parked: dict["parked"] as? Bool ?? true
        )
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
