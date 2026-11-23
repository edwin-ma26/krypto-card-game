import Foundation
import FirebaseFirestore

/// Elo-based matchmaking. Joining just creates a ticket in `matchmakingQueue`
/// and listens for it to flip to "matched" — the `onQueueJoin` Cloud Function
/// (functions/src/index.ts) is the sole authority that pairs waiting tickets,
/// deals the shared hand, and creates the match, all inside a server-side
/// Firestore transaction. The client never attempts to claim an opponent
/// itself, so there's no client-driven polling and no double-claim race.
@MainActor
final class RankedService: ObservableObject, LiveMatchReporting {
    /// One instance for the whole app. Ranked UI lives behind full-screen
    /// covers that come and go, but a finished match's rematch negotiation
    /// has to outlive them: the opponent may ask for a rematch after this
    /// player has already backed out to the menu, and the banner that
    /// surfaces that request (see `RematchBanner`) is drawn on every screen.
    static let shared = RankedService()

    enum Phase: Equatable {
        case idle
        case searching
        case matched
        case error(String)
    }

    struct OpponentState: Equatable {
        var cardsLeft = 5
        /// Server timestamp of the opponent's last board touch (see `touchActivity`).
        var lastActiveAt: Date?
        var hasSolved = false
    }

    /// How the match screen renders the opponent's live state. Bots don't
    /// heartbeat, so they read as engaged until they finish.
    var opponentPresence: OpponentPresence {
        OpponentPresence(
            cardsLeft: opponent.cardsLeft,
            lastActiveAt: opponent.lastActiveAt,
            alwaysActive: opponentIsBot,
            hasSolved: opponent.hasSolved
        )
    }
    private var lastHeartbeat: Date = .distantPast
    private static let heartbeatInterval: TimeInterval = 3
    #if DEBUG
    /// Set by `startDemoMatch()`: no match doc exists, so solving and
    /// leaving resolve locally instead of through Firestore.
    var isDemoMatch = false
    var demoTask: Task<Void, Never>?
    #endif

    @Published var phase: Phase = .idle
    @Published var opponent = OpponentState()
    @Published var winnerIsMe: Bool?
    @Published var puzzle: (hand: [Int], target: Int)?
    @Published var eloDelta: Int?
    @Published var newElo: Int?
    @Published var estimatedWaitSeconds: Int?
    /// Opponent's rating as recorded on the match doc — shown on the
    /// "opponent found" interstitial (names are never shown in ranked).
    @Published var opponentElo: Int?
    /// Opponent's display name as denormalised onto the match doc by the
    /// matcher (`nameA`/`nameB`), so no extra profile read is needed.
    @Published var opponentName: String?
    /// Set when a match ended by someone leaving rather than solving: the
    /// uid of whoever forfeited, so the result screen can say so.
    @Published var forfeitedBy: String?
    /// True while the current search was started by "Rematch", so the
    /// searching popup can word itself accordingly.
    @Published var isRematchSearch = false

    /// Where a human-vs-human rematch negotiation stands, driven by the
    /// `rematchRequestedBy` / `rematchResponse` fields on the finished match
    /// doc (both players keep listening to it while the result card is up).
    /// Bot rematches skip all this — the bot "accepts" server-side.
    enum RematchState: Equatable {
        case none
        /// We asked; waiting on the opponent (auto-expires, see `rematchTimeoutSeconds`).
        case waitingForOpponent
        case declined
        case noResponse
        /// The opponent asked us.
        case incoming
    }
    @Published private(set) var rematchState: RematchState = .none
    private static let rematchTimeoutSeconds: UInt64 = 30
    /// Requests older than this are ignored even if their fields are still on
    /// the doc — the requester clears them after `rematchTimeoutSeconds`, but
    /// a force-quit mid-wait would otherwise leave a banner up for good.
    private static let rematchRequestMaxAge: TimeInterval = 45
    /// How long after leaving a finished human match we keep listening for a
    /// late rematch request before letting the match go for good.
    private static let postMatchListenSeconds: UInt64 = 10 * 60
    private var rematchTimeoutTask: Task<Void, Never>?
    private var postMatchExpiryTask: Task<Void, Never>?
    private var hasStartedRematchQueue = false

    /// True while we've left the result card but still listen to the finished
    /// match for a rematch request from the opponent (see `leave()`).
    @Published private(set) var isListeningAfterMatch = false
    /// Set when the player accepts a rematch from a banner outside the
    /// Competition screen. `HomeView` watches it and presents Competition,
    /// where the searching popup and the new match take over.
    @Published var wantsCompetitionScreen = false

    /// An opponent's rematch request we can act on from a banner: it's
    /// pending, and the result card that would otherwise show it is closed.
    var hasIncomingRematchBanner: Bool {
        rematchState == .incoming && phase != .matched
    }

    /// Badge for the player's current (post-result, if any) rating; `nil`
    /// while the player is still placing or their rank is not yet revealed.
    var myStanding: TierStanding? {
        guard myTier != nil else { return nil }
        return Remote.shared.tiers.standing(rating: newElo ?? myElo, held: myTier)
    }

    /// Line under the result while there is no badge: how far through
    /// placement the player is, or that the rank is waiting on a referral.
    var placementNote: String? {
        guard myTier == nil else { return nil }
        let total = Remote.shared.tiers.placementMatches
        if matchesPlayed < total {
            return "Placement match \(matchesPlayed) of \(total)"
        }
        return "Placement complete \u{2014} reveal your rank in Competition Mode"
    }

    /// Opponent's badge. Their held tier isn't on the match doc, so this is
    /// the plain band for their rating.
    var opponentStanding: TierStanding? {
        opponentElo.map { Remote.shared.tiers.standing(rating: $0, held: nil) }
    }

    private let db = Firestore.firestore()
    private var queueListener: ListenerRegistration?
    private var matchListener: ListenerRegistration?
    private var estimateTimer: Timer?
    private var hasAppliedEloUpdate = false

    private var uid = ""
    /// The player's rating going into this match. `newElo` supersedes it once
    /// a result is applied, so the match screen shows `newElo ?? myElo`.
    @Published private(set) var myElo = 1200
    /// Tier the player was last shown (`users/{uid}.rankedTier`); see
    /// `RatingTiers` for why it's held separately from the rating.
    @Published private(set) var myTier: Int?
    /// Promotion / demotion from the match just finished, if any.
    @Published private(set) var lastTierChange: TierChange?
    /// Rated matches finished (`users/{uid}.rankedMatches`), counting the
    /// one just played once its result is applied.
    @Published private(set) var matchesPlayed = 0
    /// Whether finishing placement may write and show a tier. False while
    /// the referral gate sits between placement and the reveal; the hub
    /// writes the tier later once the gate is met.
    private var canRevealTier = true
    private var matchId: String?
    /// This player's solve time in the current match, for the stats log.
    private var mySolveSeconds: Int?
    private var eloA = 1200
    private var eloB = 1200
    private var playerA = ""
    private var playerB = ""
    private var opponentUid = ""
    private var opponentIsBot = false

    /// Ratings within this many points of ours count as a "nearby" opponent
    /// when estimating wait time (the matcher itself has no such cutoff —
    /// it always pairs with whoever's closest — this is just for display).
    private let nearbyEloWindow = 150

    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    var errorMessage: String? {
        if case .error(let message) = phase { return message }
        return nil
    }

    // MARK: - Queue

    /// Who a re-queue would like to face again. The matcher treats it as a
    /// preference, not a guarantee: a bot rematch is honoured after a short
    /// wait, a human rematch only if that person is also waiting — otherwise
    /// the normal nearest-rating search applies.
    struct RematchHint {
        let opponentUid: String
        let isBot: Bool
    }

    func joinQueue(uid: String, elo: Int, heldTier: Int? = nil, matchesPlayed: Int? = nil,
                   canRevealTier: Bool? = nil, rematch: RematchHint? = nil) {
        self.uid = uid
        myElo = elo
        myTier = heldTier ?? myTier
        if let matchesPlayed { self.matchesPlayed = matchesPlayed }
        if let canRevealTier { self.canRevealTier = canRevealTier }
        lastTierChange = nil
        matchId = nil
        hasAppliedEloUpdate = false
        eloDelta = nil
        newElo = nil
        winnerIsMe = nil
        mySolveSeconds = nil
        puzzle = nil
        opponent = OpponentState()
        opponentElo = nil
        opponentName = nil
        forfeitedBy = nil
        estimatedWaitSeconds = nil
        isRematchSearch = rematch != nil
        rematchState = .none
        rematchTimeoutTask?.cancel()
        rematchTimeoutTask = nil
        hasStartedRematchQueue = false
        stopPostMatchListening()
        matchListener?.remove()
        matchListener = nil
        phase = .searching

        var ticket: [String: Any] = [
            "elo": elo,
            "joinedAt": FieldValue.serverTimestamp(),
            "status": "waiting",
        ]
        if let rematch {
            ticket[rematch.isBot ? "rematchBot" : "rematchWith"] = rematch.opponentUid
        }
        let ref = db.collection("matchmakingQueue").document(uid)
        queueListener?.remove()

        Task { @MainActor in
            // A previous session can leave this player's ticket behind in the
            // "matched" state (force-quit mid-match, old build). Security
            // rules only allow *creating* a waiting ticket, never updating
            // one, so writing over that leftover is silently rejected — and
            // the listener below would then see the stale ticket and drop
            // the player straight into a months-old match. Clear it first.
            try? await ref.delete()
            do {
                try await ref.setData(ticket)
            } catch {
                phase = .error("Couldn't join the queue. Check your connection and try again.")
                return
            }
            guard phase == .searching else { return } // Cancelled while the write was in flight.

            queueListener = ref.addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let data = snapshot?.data() else { return }
                if data["status"] as? String == "matched", let matchId = data["matchId"] as? String {
                    self.attachToMatch(matchId)
                }
            }

            refreshEstimatedWait()
            estimateTimer?.invalidate()
            estimateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshEstimatedWait() }
            }
        }
    }

    func cancelQueue() {
        queueListener?.remove()
        estimateTimer?.invalidate()
        estimateTimer = nil
        if !uid.isEmpty {
            db.collection("matchmakingQueue").document(uid).delete()
        }
        estimatedWaitSeconds = nil
        isRematchSearch = false
        phase = .idle
    }

    /// Rough ETA from how many other players are currently waiting and how
    /// close their ratings are to ours — more nearby-rated players in the
    /// pool means the next join is likelier to be a fast, well-matched pair.
    ///
    /// Polled on a 5s timer via count-aggregation queries rather than a live
    /// listener on the whole waiting pool: a listener there means every
    /// join/leave fans out to every other searching client's device (O(N²)
    /// across N simultaneous searchers), where a `.count()` aggregation query
    /// only ever costs ~1 read regardless of how many tickets match, and this
    /// value only needs to be roughly fresh, not instantaneous.
    private func refreshEstimatedWait() {
        guard !uid.isEmpty else { return }
        Task {
            let waiting = db.collection("matchmakingQueue").whereField("status", isEqualTo: "waiting")
            let nearbyQuery = waiting
                .whereField("elo", isGreaterThanOrEqualTo: myElo - nearbyEloWindow)
                .whereField("elo", isLessThanOrEqualTo: myElo + nearbyEloWindow)
            guard let nearbyCount = try? await nearbyQuery.count.getAggregation(source: .server).count.intValue,
                  let totalCount = try? await waiting.count.getAggregation(source: .server).count.intValue
            else { return }

            // Both counts include this ticket itself (status == "waiting"
            // and trivially within its own nearby window).
            let nearby = max(0, nearbyCount - 1)
            let far = max(0, totalCount - nearbyCount)

            let strength = Double(nearby) + Double(far) * 0.35
            let humanEstimate = max(5, min(Int((90.0 / (1.0 + strength)).rounded()), 90))

            // With bots on, nobody waits longer than the bot fallback (which
            // the server jitters around this centre), so the estimate is
            // whichever comes first: a nearby human or the bot stepping in.
            let flags = Remote.shared.flags
            estimatedWaitSeconds = flags.rankedBotsEnabled
                ? min(humanEstimate, flags.rankedBotWaitSeconds)
                : humanEstimate
        }
    }

    // MARK: - Match

    private func attachToMatch(_ id: String) {
        guard matchId != id else { return }
        matchId = id
        queueListener?.remove()
        estimateTimer?.invalidate()
        estimateTimer = nil
        // phase flips to .matched once `apply` has the puzzle, not before —
        // otherwise the match UI can appear and fall back to a default deal
        // before the real shared hand/target arrives over the listener.

        let ref = db.collection("rankedMatches").document(id)
        matchListener?.remove()
        matchListener = ref.addSnapshotListener { [weak self] snapshot, _ in
            guard let self, let data = snapshot?.data() else { return }
            self.apply(data)
        }
    }

    private func apply(_ data: [String: Any]) {
        guard let playerA = data["playerA"] as? String,
              let playerB = data["playerB"] as? String
        else { return }
        self.playerA = playerA
        self.playerB = playerB
        eloA = data["eloA"] as? Int ?? 1200
        eloB = data["eloB"] as? Int ?? 1200

        opponentUid = playerA == uid ? playerB : playerA
        opponentIsBot = data["isBot"] as? Bool ?? false
        opponentElo = playerA == uid ? eloB : eloA
        opponentName = (playerA == uid ? data["nameB"] : data["nameA"]) as? String
        let cardsLeft = data["cardsLeft"] as? [String: Int] ?? [:]
        opponent.cardsLeft = cardsLeft[opponentUid] ?? 5
        let lastActive = data["lastActiveAt"] as? [String: Timestamp] ?? [:]
        opponent.lastActiveAt = lastActive[opponentUid]?.dateValue()
        opponent.hasSolved = (data["winner"] as? String) == opponentUid
        forfeitedBy = data["forfeitedBy"] as? String

        if puzzle == nil, let hand = data["hand"] as? [Int], let target = data["target"] as? Int {
            puzzle = (hand, target)
            phase = .matched
        }

        if let winner = data["winner"] as? String {
            winnerIsMe = winner == uid
            applyEloIfNeeded(winner: winner)
        }

        applyRematchFields(data)
    }

    // MARK: - Rematch negotiation (human opponents)

    private func applyRematchFields(_ data: [String: Any]) {
        let requestedBy = data["rematchRequestedBy"] as? String
        let response = data["rematchResponse"] as? String
        guard let requestedBy, !requestedBy.isEmpty else {
            // Request withdrawn (or never made). An incoming prompt we were
            // showing goes away; our own states are owned locally.
            if rematchState == .incoming { rematchState = .none }
            return
        }

        if requestedBy == uid {
            switch response {
            case "accepted":
                startRematchQueueIfNeeded()
            case "declined":
                rematchTimeoutTask?.cancel()
                if rematchState == .waitingForOpponent { rematchState = .declined }
            default:
                break
            }
        } else if response == nil {
            if let at = (data["rematchRequestedAt"] as? Timestamp)?.dateValue(),
               Date().timeIntervalSince(at) > Self.rematchRequestMaxAge {
                // Stale: the requester never cleared it (force-quit, lost
                // connection). Don't offer a rematch nobody is waiting for.
                if rematchState == .incoming { rematchState = .none }
                return
            }
            // Mutual offers: if we were already waiting on our own request
            // (which theirs has since overwritten), both sides want it, so
            // treat it as accepted straight away — same as chess sites do.
            if rematchState == .waitingForOpponent {
                rematchState = .incoming
                acceptRematch()
            } else {
                rematchState = .incoming
            }
        } else if response == "accepted" {
            // We accepted (possibly from another snapshot ordering); make
            // sure we actually went to the queue.
            startRematchQueueIfNeeded()
        }
    }

    /// Both sides land here once a human rematch is agreed: leave the
    /// finished match and queue with a "same opponent" hint. The matcher
    /// pairs whoever arrives second with the one already waiting.
    private func startRematchQueueIfNeeded() {
        guard !hasStartedRematchQueue else { return }
        hasStartedRematchQueue = true
        rematchTimeoutTask?.cancel()
        let hint = RematchHint(opponentUid: opponentUid, isBot: false)
        let rating = newElo ?? myElo
        matchListener?.remove()
        matchListener = nil
        joinQueue(uid: uid, elo: rating, heldTier: myTier, rematch: hint)
    }

    /// Withdraws our pending request (Cancel on the waiting card, or
    /// leaving). Safe to call when nothing is pending.
    func cancelRematchRequest() {
        rematchTimeoutTask?.cancel()
        rematchTimeoutTask = nil
        guard let matchId, rematchState == .waitingForOpponent else { return }
        rematchState = .none
        db.collection("rankedMatches").document(matchId).updateData([
            "rematchRequestedBy": FieldValue.delete(),
            "rematchRequestedAt": FieldValue.delete(),
        ])
    }

    func acceptRematch() {
        guard let matchId, rematchState == .incoming else { return }
        rematchState = .none
        db.collection("rankedMatches").document(matchId).updateData(["rematchResponse": "accepted"])
        startRematchQueueIfNeeded()
    }

    func declineRematch() {
        guard let matchId, rematchState == .incoming else { return }
        rematchState = .none
        db.collection("rankedMatches").document(matchId).updateData(["rematchResponse": "declined"])
    }

    /// Concedes the match: the opponent is recorded as the winner (with
    /// `forfeitedBy` so both result screens can say why) unless someone has
    /// already won. Elo is settled exactly as for any other loss.
    func forfeit() {
        #if DEBUG
        if isDemoMatch { demoTask?.cancel(); winnerIsMe = false; return }
        #endif
        guard let matchId, !opponentUid.isEmpty else { return }
        let ref = db.collection("rankedMatches").document(matchId)
        let myUid = uid
        let opponent = opponentUid
        db.runTransaction { transaction, _ in
            let snapshot = try? transaction.getDocument(ref)
            guard snapshot?.data()?["winner"] == nil else { return false }
            transaction.updateData(
                ["winner": opponent, "status": "finished", "forfeitedBy": myUid],
                forDocument: ref
            )
            return true
        } completion: { _, _ in }
    }

    /// Leaves the finished match and re-queues for whoever's next, using the
    /// just-updated rating so the new ticket is placed correctly.
    func requestNewGame() {
        let rating = newElo ?? myElo
        matchListener?.remove()
        matchListener = nil
        joinQueue(uid: uid, elo: rating, heldTier: myTier)
    }

    /// Leaves the finished match and re-queues, asking to face the same
    /// opponent again (see `RematchHint`). Uses the just-updated rating so
    /// the new ticket is placed correctly.
    func requestRematch() {
        guard !opponentIsBot else {
            // Bots don't need asking — the matcher plays the same bot after a
            // short, jittered "accepting" pause.
            let hint = RematchHint(opponentUid: opponentUid, isBot: true)
            let rating = newElo ?? myElo
            matchListener?.remove()
            matchListener = nil
            joinQueue(uid: uid, elo: rating, heldTier: myTier, rematch: hint)
            return
        }
        // Tapping Rematch while they've already asked is an acceptance.
        if rematchState == .incoming {
            acceptRematch()
            return
        }
        guard let matchId, rematchState == .none else { return }
        rematchState = .waitingForOpponent
        db.collection("rankedMatches").document(matchId).updateData([
            "rematchRequestedBy": uid,
            "rematchRequestedAt": FieldValue.serverTimestamp(),
            "rematchResponse": FieldValue.delete(),
        ])
        rematchTimeoutTask?.cancel()
        rematchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.rematchTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.rematchState == .waitingForOpponent else { return }
            self.rematchState = .noResponse
            try? await self.db.collection("rankedMatches").document(matchId).updateData([
                "rematchRequestedBy": FieldValue.delete(),
                "rematchRequestedAt": FieldValue.delete(),
            ])
        }
    }

    private func applyEloIfNeeded(winner: String) {
        guard !hasAppliedEloUpdate else { return }
        hasAppliedEloUpdate = true

        let myRating = playerA == uid ? eloA : eloB
        let oppRating = playerA == uid ? eloB : eloA
        let score: Double = winner == uid ? 1 : 0
        let expected = 1.0 / (1.0 + pow(10, Double(oppRating - myRating) / 400.0))
        let delta = Int((32.0 * (score - expected)).rounded())
        let updated = max(100, myRating + delta)

        eloDelta = updated - myRating
        newElo = updated

        let tiers = Remote.shared.tiers
        matchesPlayed += 1
        var write: [String: Any] = ["elo": updated, "rankedMatches": FieldValue.increment(Int64(1))]
        if let heldBefore = myTier {
            // Already badged: promotions are immediate, demotions wait for
            // the margin (see `RatingTiers`).
            let before = tiers.standing(rating: myRating, held: heldBefore)
            let held = tiers.heldTier(for: updated, held: heldBefore)
            myTier = held
            let after = tiers.standing(rating: updated, held: held)
            if after.tierIndex != before.tierIndex {
                lastTierChange = after.tierIndex > before.tierIndex ? .promoted(after) : .demoted(after)
            }
            write["rankedTier"] = held
        } else if matchesPlayed >= tiers.placementMatches, canRevealTier {
            // Placement just finished: the first badge is the plain band of
            // the settled rating, with nothing held over from the 1200 start.
            let held = tiers.rawTier(for: updated)
            myTier = held
            lastTierChange = .placed(tiers.standing(rating: updated, held: held))
            write["rankedTier"] = held
        }
        // Otherwise still placing (or the reveal is gated): no tier yet.

        db.collection("users").document(uid).updateData(write)
        if let matchId {
            let won = winner == uid
            StatsLog.shared.recordRanked(
                matchId: matchId, won: won, seconds: won ? mySolveSeconds : nil,
                ratingAfter: updated, delta: updated - myRating
            )
        }
    }

    // MARK: - LiveMatchReporting

    func updateProgress(cardsLeft: Int) {
        guard let matchId else { return }
        lastHeartbeat = .now
        db.collection("rankedMatches").document(matchId)
            .updateData(["cardsLeft.\(uid)": cardsLeft, "lastActiveAt.\(uid)": FieldValue.serverTimestamp()])
    }

    /// Throttled heartbeat: one write every few seconds while the player is
    /// tapping around, none while they're staring at the board or away.
    func touchActivity() {
        guard let matchId, winnerIsMe == nil,
              Date.now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval else { return }
        lastHeartbeat = .now
        db.collection("rankedMatches").document(matchId)
            .updateData(["lastActiveAt.\(uid)": FieldValue.serverTimestamp()])
    }

    func reportSolved(elapsed: Int) {
        #if DEBUG
        if isDemoMatch { demoTask?.cancel(); winnerIsMe = true; return }
        #endif
        guard let matchId else { return }
        mySolveSeconds = elapsed
        let ref = db.collection("rankedMatches").document(matchId)
        let myUid = uid
        let puzzle = self.puzzle
        db.runTransaction { transaction, _ in
            let snapshot = try? transaction.getDocument(ref)
            guard snapshot?.data()?["winner"] == nil else { return false }
            transaction.updateData(["winner": myUid, "status": "finished"], forDocument: ref)
            return true
        } completion: { result, _ in
            guard result as? Bool == true, let puzzle else { return }
            PuzzleStats.recordSolved(
                hand: puzzle.hand, target: puzzle.target, elapsedSeconds: elapsed, solverName: myUid
            )
        }
    }

    func leave() {
        #if DEBUG
        if isDemoMatch { demoTask?.cancel(); isDemoMatch = false }
        #endif
        // Walking away withdraws our own request so the other player's card
        // updates promptly instead of waiting out the timeout. An incoming
        // request is *not* declined: it, and any later one, now shows as a
        // banner wherever the player goes (see `keepListeningAfterMatch`).
        if rematchState == .waitingForOpponent { cancelRematchRequest() }
        rematchTimeoutTask?.cancel()
        rematchTimeoutTask = nil
        hasStartedRematchQueue = false
        queueListener?.remove()
        matchListener?.remove()
        matchListener = nil
        estimateTimer?.invalidate()
        estimateTimer = nil
        if !uid.isEmpty {
            db.collection("matchmakingQueue").document(uid).delete()
        }
        let finishedHumanMatch = matchId != nil && winnerIsMe != nil && !opponentIsBot
        puzzle = nil
        winnerIsMe = nil
        opponentElo = nil
        forfeitedBy = nil
        estimatedWaitSeconds = nil
        isRematchSearch = false
        phase = .idle
        if finishedHumanMatch {
            keepListeningAfterMatch()
        } else {
            rematchState = .none
            matchId = nil
            opponentName = nil
        }
    }

    /// Keeps a narrow listener on the finished match — rematch fields only,
    /// never the puzzle/winner (which would re-present the match) — so the
    /// opponent's request reaches this player on any screen. Drops out on
    /// the next queue join, on sign-out, or after `postMatchListenSeconds`.
    private func keepListeningAfterMatch() {
        guard let matchId else { return }
        isListeningAfterMatch = true
        let ref = db.collection("rankedMatches").document(matchId)
        matchListener = ref.addSnapshotListener { [weak self] snapshot, _ in
            guard let self, let data = snapshot?.data() else { return }
            self.applyRematchFields(data)
        }
        postMatchExpiryTask?.cancel()
        postMatchExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.postMatchListenSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.stopPostMatchListening()
        }
    }

    /// Ends the post-match listen (if any). Declines an open request if asked
    /// to, so the opponent isn't left waiting out their timeout.
    func stopPostMatchListening(declining: Bool = false) {
        postMatchExpiryTask?.cancel()
        postMatchExpiryTask = nil
        guard isListeningAfterMatch else { return }
        if declining, rematchState == .incoming { declineRematch() }
        isListeningAfterMatch = false
        matchListener?.remove()
        matchListener = nil
        rematchState = .none
        matchId = nil
        opponentName = nil
    }

    /// Full reset on sign-out: nothing of the last match should survive a
    /// change of account.
    func reset() {
        leave()
        stopPostMatchListening()
        wantsCompetitionScreen = false
        uid = ""
    }
}
