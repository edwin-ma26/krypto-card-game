import SwiftUI
import Combine

/// A two-player buzz-in match on one phone laid flat between the players.
/// Owns a `GameViewModel` for the board and runs the buzz / lock-window /
/// miss-cooldown rules locally — the same rules `MultiplayerService` runs
/// through Firestore for an online room, minus the room. Nothing here touches
/// the network or the solo stats: the board reports solves to this object
/// (via `LiveMatchReporting`) instead of recording them as solo play.
@MainActor
final class SamePhoneMatch: ObservableObject, LiveMatchReporting {
    /// Which end of the phone a player sits at. `near` is the player holding
    /// the phone the normal way up (the bottom of the screen); `far` is the
    /// player across the table, who reads everything rotated 180°.
    enum Player: CaseIterable, Equatable {
        case near, far

        var title: String {
            switch self {
            case .near: "Player 1"
            case .far: "Player 2"
            }
        }

        var other: Player { self == .near ? .far : .near }
    }

    enum Floor: Equatable {
        /// Nobody has buzzed; the cards are visible but locked.
        case open
        /// `player` buzzed and is solving against the clock.
        case locked(Player)
        /// `player` solved it; the round is over until `nextRound()`.
        case won(Player)
    }

    struct Settings: Equatable {
        var lockWindowSeconds = 9
        var hintsEnabled = true
        var undosAllowed = true
    }

    let settings: Settings
    let game = GameViewModel(dealsOwnPuzzle: false)

    @Published private(set) var floor: Floor = .open
    @Published private(set) var lockSecondsLeft = 0
    @Published private(set) var scores: [Player: Int] = [.near: 0, .far: 0]
    /// Seconds each player must still wait after letting a lock window lapse.
    @Published private(set) var cooldowns: [Player: Int] = [:]
    /// The steps of the winning solve, for the result card.
    @Published private(set) var winningSolution: [String] = []
    @Published private(set) var winningTime = 0
    /// A hint that was shown this round, attributed to who asked for it.
    @Published private(set) var sharedHint: (player: Player, text: String)?

    private var ticker: AnyCancellable?
    private var hand: [Int] = []
    private var target = 0

    private static var missCooldown: Int { MultiplayerService.missCooldown }

    init(settings: Settings) {
        self.settings = settings
        game.multiplayer = self
        deal()
    }

    // MARK: - Rounds

    var lockHolder: Player? {
        if case .locked(let player) = floor { return player }
        return nil
    }

    var winner: Player? {
        if case .won(let player) = floor { return player }
        return nil
    }

    /// Deals a fresh hand and reopens the floor. Scores carry over.
    func nextRound() {
        deal()
    }

    private func deal() {
        stopTicker()
        let dealt = Krypto.deal()
        hand = dealt.hand
        target = dealt.target
        floor = .open
        lockSecondsLeft = 0
        cooldowns = [:]
        winningSolution = []
        winningTime = 0
        sharedHint = nil
        resetBoard()
    }

    /// Every buzz is a fresh attempt from the dealt hand, as in an online room.
    private func resetBoard() {
        game.startShared(hand: hand, target: target)
    }

    // MARK: - Buzzing

    func canBuzz(_ player: Player) -> Bool {
        floor == .open && (cooldowns[player] ?? 0) == 0
    }

    func buzz(_ player: Player) {
        guard canBuzz(player) else { return }
        floor = .locked(player)
        lockSecondsLeft = settings.lockWindowSeconds
        sharedHint = nil
        resetBoard()
        startTicker()
    }

    /// The lock holder's window lapsed without a solve: the floor reopens and
    /// they sit out a short cooldown so the other player gets a clean look.
    private func expireLock() {
        guard let player = lockHolder else { return }
        floor = .open
        lockSecondsLeft = 0
        if Self.missCooldown > 0 {
            cooldowns[player] = Self.missCooldown
        }
        resetBoard()
        if cooldowns.isEmpty { stopTicker() }
    }

    // MARK: - Hints

    func requestHint(from player: Player) {
        guard settings.hintsEnabled, winner == nil else { return }
        sharedHint = (player, game.hintText())
    }

    // MARK: - Clock

    private func startTicker() {
        ticker?.cancel()
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        if lockHolder != nil {
            lockSecondsLeft -= 1
            if lockSecondsLeft <= 0 { expireLock() }
        }
        for (player, left) in cooldowns {
            if left <= 1 { cooldowns[player] = nil } else { cooldowns[player] = left - 1 }
        }
        if lockHolder == nil, cooldowns.isEmpty { stopTicker() }
    }

    // MARK: - LiveMatchReporting

    func updateProgress(cardsLeft: Int) {}

    /// The board hit the target. Only counts for whoever holds the lock; a
    /// solve with the floor open can't happen since the board is disabled then.
    func reportSolved(elapsed: Int) {
        guard let player = lockHolder else { return }
        stopTicker()
        floor = .won(player)
        lockSecondsLeft = 0
        cooldowns = [:]
        scores[player, default: 0] += 1
        winningSolution = game.steps
        winningTime = elapsed
    }
}
