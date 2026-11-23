import Foundation
import SwiftUI
import FirebaseCore
import FirebaseFirestore

/// A live head-to-head race: both players get the same hand and target. To win
/// you "lock in" (buzz) first, then have `lockWindow` seconds to prove the solve;
/// miss it and the floor passes to your opponent. Rooms are Firestore docs keyed
/// by a short join code.
@MainActor
final class MultiplayerService: ObservableObject, LiveMatchReporting {
    enum Phase: Equatable {
        case idle
        case connecting
        case waiting(code: String)
        case playing
        case error(String)
    }

    /// Chosen by the host when creating a room; joiners just inherit it.
    enum RoomMode: String {
        /// The original race: buzz "Krypto!" to grab the floor, then prove the
        /// solve within the room's lock window or cede it back.
        case buzzIn
        /// No buzzing, no lock, no miss penalty — everyone solves the same
        /// hand at their own pace, and the first valid submission wins.
        case firstToSolve
    }

    struct Opponent: Identifiable, Equatable {
        let id: String
        var name: String = "Opponent"
        var cardsLeft: Int = 5
        var elapsed: Int?          // set once this player has solved
        var score: Int = 0         // race wins this session
        var lastActiveAt: Date?    // last board touch, server time (see `touchActivity`)

        var presence: OpponentPresence {
            OpponentPresence(cardsLeft: cardsLeft, lastActiveAt: lastActiveAt, hasSolved: elapsed != nil)
        }
    }

    /// A hint one player asked for, shared to the whole room so everyone sees
    /// the same suggestion along with who requested it.
    struct SharedHint: Equatable, Identifiable {
        var id: String              // unique per request, so a re-request re-triggers the banner
        var requesterName: String   // "You" on the requester's device, otherwise their name
        var text: String
    }

    @Published var phase: Phase = .idle
    /// Everyone in the room other than me, in a stable display order.
    @Published var opponents: [Opponent] = []
    /// Every player in the room (including me) — drives the pre-game lobby roster.
    @Published var lobbyPlayers: [Opponent] = []
    /// The winning player's id for the current hand (nil until someone wins).
    @Published var winnerID: String?
    /// Convenience over `winnerID` for the many view sites that only care whether
    /// the local player won.
    var winnerIsMe: Bool? { winnerID.map { $0 == playerID } }
    @Published var puzzle: SharedPuzzle?
    /// The most recent hint requested by anyone in the room, cleared when a new hand is dealt.
    @Published var sharedHint: SharedHint?

    /// The player who has "locked in" and is proving their solution against the
    /// clock (nil when the floor is open and anyone may buzz). Winning requires
    /// holding this lock — you buzz first, then have `lockWindow` seconds to solve.
    @Published var lockHolder: String?
    /// Seconds left in the current lock-in window, shown to both the solver and
    /// (as a spectator countdown) their opponent.
    @Published var lockSecondsLeft = 0
    /// Seconds left on my own miss cooldown (0 when I'm free to buzz). Each
    /// player serves an independent `missCooldown`-second cooldown after letting
    /// a window lapse — stored per-player under `cooldowns/{playerID}` in the room
    /// doc — so both can be cooling down at once and the floor stays open throughout.
    @Published var cooldownSecondsLeft = 0
    /// The lock holder's solution steps, streamed live so their opponent watches
    /// the proof unfold (cleared when the floor opens or a new hand is dealt).
    @Published var opponentSteps: [String] = []
    /// The winner's completed solution, shown in the result popup on both devices.
    @Published var winningSolution: [String] = []
    /// The steps this device most recently broadcast, so the win transaction can
    /// record them as the solution.
    private var lastBroadcastSteps: [String] = []

    @Published var rematchRequestedBy: String?
    @Published var rematchAccepted: [String: Bool] = [:]

    /// The host's choice of race format for this room — read from the room doc,
    /// so it's the same on both devices. Defaults to the original buzz-in race
    /// for any room that predates this setting (shouldn't happen in practice,
    /// but a stale client or a partial write shouldn't leave this undefined).
    @Published private(set) var roomMode: RoomMode = .buzzIn
    /// This room's lock-in window, in seconds — the host's choice at creation,
    /// falling back to the remote-tuned default if the room doc omits it.
    /// Irrelevant in `.firstToSolve` rooms, which have no lock at all.
    @Published private(set) var roomLockWindowSeconds = Remote.shared.tuning.lockWindow
    /// Whether the host allowed hints for this room. Checked alongside the
    /// global `RemoteFlags.hintsEnabled` before the hint button does anything.
    @Published private(set) var roomHintsEnabled = true
    /// Whether the host allowed undo in this room. Rooms created by builds
    /// that predate the setting omit the field and read as allowed.
    @Published private(set) var roomUndosAllowed = true
    /// Max players allowed in this room — the host's choice at creation. A room
    /// above 2 opens into a lobby the host starts by hand; a 2-player room keeps
    /// the classic auto-start-on-join behaviour.
    @Published private(set) var maxPlayers = 2
    /// True on the device that created this room.
    @Published private(set) var isHost = false
    /// A room that holds more than two players — lobby + host-driven replay,
    /// and no per-player rematch handshake.
    var isCustomRoom: Bool { maxPlayers > 2 }

    /// The room's display name for a player id: "You" for the local player, their
    /// chosen name for anyone else, a neutral fallback otherwise.
    func displayName(for id: String?) -> String {
        guard let id else { return "A player" }
        if id == playerID { return "You" }
        return opponents.first { $0.id == id }?.name ?? "A player"
    }

    /// Length of a lock-in window, in seconds. Remote-tunable, so the race pace
    /// can be adjusted without a submission.
    ///
    /// Note that each client enforces its own window, so during a config rollout
    /// two players can briefly disagree by a second or two. That's tolerable for
    /// pacing values; don't move anything that decides a winner in here.
    static var lockWindow: Int { Remote.shared.tuning.lockWindow }
    /// How long, in seconds, a player must wait after letting a window lapse
    /// before they may buzz again. The floor stays open to the opponent throughout.
    static var missCooldown: Int { Remote.shared.tuning.missCooldown }
    private var lockTimer: Timer?
    private var cooldownTimer: Timer?

    /// True while I'm the one locked in and racing the clock.
    var iHoldLock: Bool { lockHolder == playerID }
    /// True while the opponent holds the floor (so my board should wait).
    var opponentHoldsLock: Bool { lockHolder != nil && lockHolder != playerID }
    /// Whether I'm allowed to hit "Krypto!" right now: mid-race, undecided, the
    /// floor is open, and I'm not serving a miss cooldown.
    var canLockIn: Bool { isRacing && winnerIsMe == nil && lockHolder == nil && cooldownSecondsLeft <= 0 }

    /// Race wins this session (across rematches/new games), reset when the room is left.
    @Published var myScore = 0
    /// Per-player race wins this session, keyed by playerID. Surfaced onto
    /// `myScore` and each `Opponent.score` in `apply(_:)`.
    private var scores: [String: Int] = [:]
    /// The playerID of the last winner we've already counted, so re-delivered
    /// snapshots (or the same winner twice) don't double-increment the score.
    private var scoredWinner: String?

    @AppStorage("playerID") private var storedPlayerID = UUID().uuidString

    /// The local player's display name, written into the room so the opponent
    /// can show it instead of a generic "Opponent" label. Set from the signed-in
    /// profile; falls back to a friendly default when playing anonymously.
    var myName: String = "Player"

    var roomCode: String?
    private var listener: ListenerRegistration?
    private var playerID: String { storedPlayerID }
    private var db: Firestore { Firestore.firestore() }

    /// The sole opponent's id in a 1-v-1 room. `nil` in a custom (3+) room, where
    /// there's no single opponent and replay is host-driven instead.
    private var soloOpponentID: String? { isCustomRoom ? nil : opponents.first?.id }

    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// True only once a race has actually started — unlike `isActive`, this
    /// is false while merely creating/waiting in a hosted room, so incoming
    /// friend challenges can still surface during that wait.
    var isRacing: Bool {
        if case .playing = phase { return true }
        return false
    }

    /// The rematch handshake only exists in a 1-v-1 room; a custom room replays
    /// via the host's "New Game" instead.

    /// True once no one has asked for a rematch yet — the "Rematch" button state.
    var canRequestRematch: Bool { !isCustomRoom && rematchRequestedBy == nil }

    /// True once I've asked and I'm waiting on the opponent's check/x.
    var isWaitingOnRematchResponse: Bool {
        guard !isCustomRoom else { return false }
        return rematchRequestedBy == playerID
            && !(soloOpponentID.map { rematchAccepted[$0] == true } ?? false)
    }

    /// True once the opponent has asked and it's my turn to accept/decline.
    var opponentWantsRematch: Bool {
        guard !isCustomRoom, let rematchRequestedBy, rematchRequestedBy != playerID else { return false }
        return rematchAccepted[playerID] != true
    }

    // MARK: - Room lifecycle

    /// `lockWindowSeconds` is ignored for a `.firstToSolve` room (there's no
    /// lock to time), but still stored so switching formats mid-room-history
    /// isn't a concern — it's simply unread in that mode. `nil` (rather than
    /// defaulting the parameter to `Remote.shared.tuning.lockWindow` directly)
    /// sidesteps evaluating that main-actor-isolated default in a nonisolated
    /// context.
    /// `maxPlayers` above 2 makes this a custom room: joiners land in a lobby and
    /// the host starts the match with `startGame()`.
    func createRoom(mode: RoomMode = .buzzIn, lockWindowSeconds: Int? = nil, hintsEnabled: Bool = true, undosAllowed: Bool = true, maxPlayers: Int = 2) async {
        phase = .connecting
        let code = Self.makeCode()
        let lockWindowSeconds = lockWindowSeconds ?? Remote.shared.tuning.lockWindow
        let capacity = min(6, max(2, maxPlayers))
        let (hand, target) = Krypto.deal()
        PuzzleStats.recordDealt(hand: hand, target: target)
        do {
            try await db.collection("rooms").document(code).setData([
                "hand": hand,
                "target": target,
                "round": 0,
                "host": playerID,
                "status": "waiting",
                "mode": mode.rawValue,
                "lockWindowSeconds": lockWindowSeconds,
                "hintsEnabled": hintsEnabled,
                "undosAllowed": undosAllowed,
                "maxPlayers": capacity,
                "createdAt": FieldValue.serverTimestamp(),
                "players": [playerID: ["cardsLeft": 5, "name": myName]],
            ])
            roomCode = code
            roomMode = mode
            roomLockWindowSeconds = lockWindowSeconds
            roomHintsEnabled = hintsEnabled
            roomUndosAllowed = undosAllowed
            self.maxPlayers = capacity
            isHost = true
            listen(to: code)
            phase = .waiting(code: code)
        } catch {
            phase = .error("Couldn't create room. Check your connection.")
        }
    }

    /// Host-only: takes a custom room out of the lobby and deals the first hand
    /// for everyone who's joined. The snapshot listener flips every client to
    /// `.playing`.
    func startGame() {
        guard isHost, let code = roomCode else { return }
        let (hand, target) = Krypto.deal()
        PuzzleStats.recordDealt(hand: hand, target: target)
        db.collection("rooms").document(code).updateData([
            "hand": hand,
            "target": target,
            "round": 0,
            "status": "playing",
            "winner": FieldValue.delete(),
            "hint": FieldValue.delete(),
            "lockedBy": FieldValue.delete(),
            "lockedAt": FieldValue.delete(),
            "cooldowns": FieldValue.delete(),
            "liveSteps": FieldValue.delete(),
            "solution": FieldValue.delete(),
        ])
    }

    func joinRoom(_ rawCode: String) async {
        let code = rawCode.uppercased().trimmingCharacters(in: .whitespaces)
        phase = .connecting
        let ref = db.collection("rooms").document(code)
        do {
            let snapshot = try await ref.getDocument()
            guard let data = snapshot.data(), data["status"] as? String == "waiting" else {
                phase = .error("Room \(code) not found or already started.")
                return
            }
            let capacity = data["maxPlayers"] as? Int ?? 2
            let players = data["players"] as? [String: Any] ?? [:]
            guard players[playerID] != nil || players.count < capacity else {
                phase = .error("Room \(code) is full.")
                return
            }
            var update: [String: Any] = ["players.\(playerID)": ["cardsLeft": 5, "name": myName]]
            // A 2-player room starts the instant the second player is in; a
            // custom room stays in the lobby until the host taps Start.
            if capacity <= 2 { update["status"] = "playing" }
            try await ref.updateData(update)
            roomCode = code
            maxPlayers = capacity
            isHost = (data["host"] as? String) == playerID
            listen(to: code)
            if capacity > 2 { phase = .waiting(code: code) }
        } catch {
            phase = .error("Couldn't join room. Check the code and try again.")
        }
    }

    /// Deals a fresh shared hand into the room immediately, for everyone.
    /// Unlike a rematch, this doesn't require the other players' acceptance —
    /// and in a custom room only the host may trigger it.
    func startNewGame() {
        guard let code = roomCode, !isCustomRoom || isHost else { return }
        let (hand, target) = Krypto.deal()
        PuzzleStats.recordDealt(hand: hand, target: target)
        var update: [String: Any] = [
            "hand": hand,
            "target": target,
            "round": FieldValue.increment(Int64(1)),
            "status": "playing",
            "winner": FieldValue.delete(),
            "hint": FieldValue.delete(),
            "lockedBy": FieldValue.delete(),
            "lockedAt": FieldValue.delete(),
            "cooldowns": FieldValue.delete(),
            "liveSteps": FieldValue.delete(),
            "solution": FieldValue.delete(),
            "rematchRequestedBy": FieldValue.delete(),
            "rematchAccepted": FieldValue.delete(),
            "players.\(playerID)": ["cardsLeft": 5, "name": myName],
        ]
        // Reset every other player we know about, so nobody carries a stale
        // card count or a lingering solve time into the new hand.
        for opp in opponents {
            update["players.\(opp.id)"] = ["cardsLeft": 5, "name": opp.name]
        }
        db.collection("rooms").document(code).updateData(update)
    }

    func leave() {
        listener?.remove()
        listener = nil
        if let code = roomCode {
            db.collection("rooms").document(code).delete()
        }
        roomCode = nil
        puzzle = nil
        winnerID = nil
        opponents = []
        lobbyPlayers = []
        isHost = false
        maxPlayers = 2
        sharedHint = nil
        resetLockState()
        rematchRequestedBy = nil
        rematchAccepted = [:]
        myScore = 0
        scores = [:]
        scoredWinner = nil
        phase = .idle
    }

    /// Clears local lock-in state and stops any running countdown.
    private func resetLockState() {
        stopLockCountdown()
        stopCooldown()
        lockHolder = nil
        lockSecondsLeft = 0
        opponentSteps = []
        winningSolution = []
        lastBroadcastSteps = []
    }

    // MARK: - Rematch

    /// Asks for a rematch (or, if the opponent already asked, accepts it).
    /// 1-v-1 only — a custom room replays through the host's `startNewGame()`.
    func requestRematch() {
        guard !isCustomRoom, let code = roomCode else { return }
        db.collection("rooms").document(code).updateData([
            "rematchRequestedBy": rematchRequestedBy ?? playerID,
            "rematchAccepted.\(playerID)": true,
        ])
    }

    func declineRematch() {
        guard let code = roomCode else { return }
        db.collection("rooms").document(code).updateData([
            "rematchRequestedBy": FieldValue.delete(),
            "rematchAccepted": FieldValue.delete(),
        ])
    }

    /// Only the original requester performs the reset, once both sides have accepted,
    /// so a simultaneous listener fire on both devices doesn't deal twice.
    private func maybeStartRematch() {
        guard !isCustomRoom, let code = roomCode, let opponentID = soloOpponentID,
              rematchRequestedBy == playerID,
              rematchAccepted[playerID] == true,
              rematchAccepted[opponentID] == true
        else { return }
        let (hand, target) = Krypto.deal()
        PuzzleStats.recordDealt(hand: hand, target: target)
        db.collection("rooms").document(code).updateData([
            "hand": hand,
            "target": target,
            "round": FieldValue.increment(Int64(1)),
            "status": "playing",
            "winner": FieldValue.delete(),
            "hint": FieldValue.delete(),
            "lockedBy": FieldValue.delete(),
            "lockedAt": FieldValue.delete(),
            "cooldowns": FieldValue.delete(),
            "liveSteps": FieldValue.delete(),
            "solution": FieldValue.delete(),
            "rematchRequestedBy": FieldValue.delete(),
            "rematchAccepted": FieldValue.delete(),
            "players.\(playerID)": ["cardsLeft": 5, "name": myName],
            "players.\(opponentID)": ["cardsLeft": 5, "name": opponents.first?.name ?? "Opponent"],
        ])
    }

    // MARK: - In-game reporting

    func updateProgress(cardsLeft: Int) {
        guard let code = roomCode else { return }
        lastHeartbeat = .now
        db.collection("rooms").document(code).updateData([
            "players.\(playerID).cardsLeft": cardsLeft,
            "players.\(playerID).lastActiveAt": FieldValue.serverTimestamp(),
        ])
    }

    private var lastHeartbeat: Date = .distantPast
    private static let heartbeatInterval: TimeInterval = 3

    /// Throttled heartbeat so the room can show who's actively playing.
    func touchActivity() {
        guard let code = roomCode, isRacing, winnerID == nil,
              Date.now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        lastHeartbeat = .now
        db.collection("rooms").document(code)
            .updateData(["players.\(playerID).lastActiveAt": FieldValue.serverTimestamp()])
    }

    /// Streams the lock holder's running solution to the room so their opponent
    /// can watch it live. Only the current holder writes.
    func updateLiveSteps(_ steps: [String]) {
        guard let code = roomCode, iHoldLock else { return }
        lastBroadcastSteps = steps
        db.collection("rooms").document(code).updateData(["liveSteps": steps])
    }

    /// Broadcasts a hint to the whole room. Everyone — including the requester —
    /// sees it surface through the snapshot listener, attributed to whoever asked.
    func requestHint(_ text: String) {
        guard let code = roomCode, roomHintsEnabled else { return }
        db.collection("rooms").document(code).updateData([
            "hint": ["id": UUID().uuidString, "by": playerID, "name": myName, "text": text],
        ])
    }

    func reportSolved(elapsed: Int) {
        guard let code = roomCode else { return }
        // Stop our own countdown right away: if the solve lands near the buzzer,
        // the win transaction below has to round-trip to Firestore, and a tick
        // that fires during that gap would call `expireLock()` and clear
        // `lockedBy` out from under us, silently losing a legitimate win.
        stopLockCountdown()
        let ref = db.collection("rooms").document(code)
        ref.updateData(["players.\(playerID).elapsed": elapsed])
        let puzzle = self.puzzle
        // In a buzz-in room a solve only counts while I hold the lock — you
        // must buzz first, and the transaction keeps that consistent if the
        // window lapses at the same moment. `.firstToSolve` has no lock at
        // all: anyone's solve counts, first transaction to land wins.
        let requireLock = roomMode == .buzzIn
        db.runTransaction { transaction, _ in
            let data = (try? transaction.getDocument(ref))?.data()
            guard data?["winner"] == nil else { return false }
            if requireLock {
                guard data?["lockedBy"] as? String == self.playerID else { return false }
            }
            transaction.updateData([
                "winner": self.playerID,
                "solution": self.lastBroadcastSteps,
                "lockedBy": FieldValue.delete(),
                "lockedAt": FieldValue.delete(),
                "cooldowns": FieldValue.delete(),
                "liveSteps": FieldValue.delete(),
            ], forDocument: ref)
            return true
        } completion: { result, _ in
            guard result as? Bool == true, let puzzle else { return }
            PuzzleStats.recordSolved(
                hand: puzzle.hand, target: puzzle.target, elapsedSeconds: elapsed, solverName: self.myName
            )
        }
    }

    // MARK: - Lock-in ("Krypto!" buzz)

    /// Attempts to grab the floor: first buzzer wins the lock and starts their
    /// `lockWindow`-second window to prove the solution. A no-op if the race is
    /// decided, someone already holds the lock, or I'm the one who just missed.
    func lockIn() {
        guard let code = roomCode else { return }
        let ref = db.collection("rooms").document(code)
        db.runTransaction { transaction, _ in
            let data = (try? transaction.getDocument(ref))?.data()
            if data?["winner"] != nil { return nil }
            if data?["lockedBy"] != nil { return nil }
            // I may re-buzz only once my own miss cooldown has elapsed. The
            // opponent's cooldown is independent and doesn't gate me.
            let cooldowns = data?["cooldowns"] as? [String: Any] ?? [:]
            if let mine = cooldowns[self.playerID] as? Timestamp,
               Date().timeIntervalSince(mine.dateValue()) < Double(Self.missCooldown) {
                return nil
            }
            transaction.updateData([
                "lockedBy": self.playerID,
                "lockedAt": FieldValue.serverTimestamp(),
                "cooldowns.\(self.playerID)": FieldValue.delete(),
                "liveSteps": FieldValue.delete(),
            ], forDocument: ref)
            return nil
        } completion: { _, _ in }
    }

    /// Called by the lock holder when their window lapses without a solve: cedes
    /// the floor and marks them as having missed, so the opponent gets a clean turn.
    private func expireLock() {
        guard let code = roomCode else { return }
        let ref = db.collection("rooms").document(code)
        db.runTransaction { transaction, _ in
            let data = (try? transaction.getDocument(ref))?.data()
            guard data?["lockedBy"] as? String == self.playerID, data?["winner"] == nil else { return nil }
            transaction.updateData([
                "lockedBy": FieldValue.delete(),
                "lockedAt": FieldValue.delete(),
                "cooldowns.\(self.playerID)": FieldValue.serverTimestamp(),
                "liveSteps": FieldValue.delete(),
            ], forDocument: ref)
            return nil
        } completion: { _, _ in }
    }

    /// Starts a fresh local countdown for the current lock window. Each device
    /// begins counting when it first learns of the lock; the holder is the one
    /// that actually cedes the floor on expiry, so spectator clock skew is cosmetic.
    private func startLockCountdown() {
        lockSecondsLeft = roomLockWindowSeconds
        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLock() }
        }
    }

    private func tickLock() {
        guard lockHolder != nil else { stopLockCountdown(); return }
        lockSecondsLeft -= 1
        if lockSecondsLeft <= 0 {
            stopLockCountdown()
            if iHoldLock { expireLock() }
        }
    }

    private func stopLockCountdown() {
        lockTimer?.invalidate()
        lockTimer = nil
    }

    /// Drives the local miss-cooldown countdown from my server `cooldowns`
    /// timestamp, so it stays accurate across reconnects and app suspensions
    /// (an idle repeating timer would drift or stall while backgrounded).
    private func startCooldown(since missedAt: Date) {
        let remaining = Double(Self.missCooldown) - Date().timeIntervalSince(missedAt)
        guard remaining > 0 else { stopCooldown(); return }
        cooldownSecondsLeft = Int(ceil(remaining))
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCooldown(since: missedAt) }
        }
    }

    private func tickCooldown(since missedAt: Date) {
        let remaining = Double(Self.missCooldown) - Date().timeIntervalSince(missedAt)
        if remaining <= 0 {
            stopCooldown()
        } else {
            cooldownSecondsLeft = Int(ceil(remaining))
        }
    }

    private func stopCooldown() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        cooldownSecondsLeft = 0
    }

    // MARK: - Listening

    /// Re-attaches the room listener to force a fresh read from the server.
    /// Call this when the app returns to the foreground: while the app is
    /// suspended (screen locked / backgrounded) iOS tears down Firestore's
    /// stream, and although the SDK normally recovers on its own, re-subscribing
    /// guarantees we immediately re-sync the current room state — the opponent's
    /// progress, a fresh hand, or a decided winner — instead of sitting on stale
    /// data. No-op when we're not in a room.
    func reconnect() {
        guard let roomCode, isActive else { return }
        listen(to: roomCode)
    }

    private func listen(to code: String) {
        listener?.remove()
        listener = db.collection("rooms").document(code)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let snapshot else { return }
                // The room doc going missing means the opponent left and tore
                // the room down; end the race locally instead of freezing on a
                // stale board (which is exactly what a mid-game disconnect used
                // to leave behind).
                guard snapshot.exists, let data = snapshot.data() else {
                    Task { @MainActor in self.handleRoomClosed() }
                    return
                }
                Task { @MainActor in self.apply(data) }
            }
    }

    /// The room disappeared out from under us (opponent left / ended it). Tear
    /// down our own listener and reset to idle so the player drops cleanly back
    /// to solo play rather than being stuck on a dead multiplayer board.
    private func handleRoomClosed() {
        guard isActive else { return }
        listener?.remove()
        listener = nil
        roomCode = nil
        puzzle = nil
        winnerID = nil
        opponents = []
        lobbyPlayers = []
        isHost = false
        maxPlayers = 2
        sharedHint = nil
        resetLockState()
        rematchRequestedBy = nil
        rematchAccepted = [:]
        myScore = 0
        scores = [:]
        scoredWinner = nil
        phase = .idle
    }

    private func apply(_ data: [String: Any]) {
        let status = data["status"] as? String
        let players = data["players"] as? [String: [String: Any]] ?? [:]

        roomMode = (data["mode"] as? String).flatMap(RoomMode.init) ?? .buzzIn
        roomLockWindowSeconds = data["lockWindowSeconds"] as? Int ?? Self.lockWindow
        roomHintsEnabled = data["hintsEnabled"] as? Bool ?? true
        roomUndosAllowed = data["undosAllowed"] as? Bool ?? true
        maxPlayers = data["maxPlayers"] as? Int ?? 2
        isHost = (data["host"] as? String) == playerID

        // Count a decided winner exactly once, whichever device we're on and
        // whoever won, then fan the running tally out onto every player.
        let winner = data["winner"] as? String
        if let winner {
            if winner != scoredWinner {
                scoredWinner = winner
                scores[winner, default: 0] += 1
            }
        } else {
            scoredWinner = nil
        }
        winnerID = winner
        myScore = scores[playerID, default: 0]

        func nameOf(_ entry: [String: Any]) -> String? {
            (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        lobbyPlayers = players.map { id, value in
            Opponent(
                id: id,
                name: id == playerID ? "You" : (nameOf(value) ?? "Player"),
                cardsLeft: value["cardsLeft"] as? Int ?? 5,
                elapsed: value["elapsed"] as? Int,
                score: scores[id, default: 0],
                lastActiveAt: (value["lastActiveAt"] as? Timestamp)?.dateValue()
            )
        }
        .sorted { ($0.id == playerID ? "" : $0.name, $0.id) < ($1.id == playerID ? "" : $1.name, $1.id) }
        opponents = lobbyPlayers.filter { $0.id != playerID }

        if status == "playing",
           let hand = data["hand"] as? [Int], let target = data["target"] as? Int {
            let fresh = SharedPuzzle(hand: hand, target: target, round: data["round"] as? Int ?? 0)
            if puzzle != fresh {
                puzzle = fresh
                phase = .playing
            }
        }

        if let hintData = data["hint"] as? [String: Any],
           let id = hintData["id"] as? String,
           let text = hintData["text"] as? String {
            let by = hintData["by"] as? String
            let requesterName = by == playerID
                ? "You"
                : (hintData["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? displayName(for: by)
            sharedHint = SharedHint(id: id, requesterName: requesterName, text: text)
        } else {
            sharedHint = nil
        }

        opponentSteps = data["liveSteps"] as? [String] ?? []
        winningSolution = data["solution"] as? [String] ?? []
        // Serve only my own cooldown, keyed by my player id; the opponent's entry
        // in the same map is driven independently on their device.
        let cooldowns = data["cooldowns"] as? [String: Any] ?? [:]
        if let mine = cooldowns[playerID] as? Timestamp {
            startCooldown(since: mine.dateValue())
        } else {
            stopCooldown()
        }
        let newHolder = data["lockedBy"] as? String
        if newHolder != lockHolder {
            lockHolder = newHolder
            // Each time the floor changes hands, (re)start this device's local
            // countdown; clear it once the floor is open again.
            if newHolder != nil { startLockCountdown() } else { stopLockCountdown() }
        }

        rematchRequestedBy = data["rematchRequestedBy"] as? String
        rematchAccepted = data["rematchAccepted"] as? [String: Bool] ?? [:]
        maybeStartRematch()
    }

    private static func makeCode() -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }
}
