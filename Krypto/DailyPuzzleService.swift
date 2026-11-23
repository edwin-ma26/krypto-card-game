import Foundation
import FirebaseFirestore

/// Drives the daily-puzzle screen: fetches the day's shared hand+target —
/// dealt server-side, once for the whole world, by the `generateDailyPuzzle`
/// scheduled Cloud Function at UTC midnight (see functions/src/dailyPuzzle.ts)
/// — and, for signed-in players, tracks their completion streak.
///
/// Anyone can play today's puzzle; only a signed-in player's solve is
/// persisted into a streak (the "daily puzzle available to everyone, streak
/// requires an account" call). The puzzle's own "dealt"/"solved" telemetry
/// still flows through `PuzzleStats` like every other mode — that happens
/// via the shared `GameViewModel` this service's puzzle is handed to, not
/// from here, so this type only owns the streak side of things.
@MainActor
final class DailyPuzzleService: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case error(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var hand: [Int] = []
    @Published private(set) var target: Int = 0
    @Published private(set) var isCompletedToday = false
    @Published private(set) var streak = 0
    @Published private(set) var longestStreak = 0
    /// "Compare against others" numbers for today's puzzle — how many people
    /// have solved it, the average time, and the fastest on record. Fetched
    /// up front in `load`, before the player even starts, so the result
    /// screen has it ready instantly instead of waiting on a fetch; refreshed
    /// again via `refreshComparisonStats()` once this player's own solve has
    /// been recorded, so it also reflects their just-finished solve.
    @Published private(set) var comparisonStats: PuzzleStats.Summary?
    /// This player's own solve time for today, if they've completed it —
    /// persisted (for signed-in players) so it's still there if they reopen
    /// the screen later today, not just in the moment right after solving.
    @Published private(set) var mySolveSeconds: Int?
    /// Friends who have completed *today's* puzzle, unsorted — only those
    /// with `dailyLastCompletedDate == dateKey` are included, so a friend who
    /// hasn't played today (or played a previous day) is simply absent rather
    /// than shown with a stale time.
    @Published private(set) var friendsLeaderboard: [FriendResult] = []

    struct FriendResult: Identifiable, Equatable {
        let id: String
        let displayName: String
        let solveSeconds: Int
    }

    private(set) var dateKey = ""
    private static let inProgressDateDefaultsKey = "dailyPuzzleInProgressDate"
    private static let inProgressElapsedDefaultsKey = "dailyPuzzleInProgressElapsed"
    /// The last-completed date as of the most recent load/record, kept
    /// locally so `recordCompletion` can compute (and show) the new streak
    /// immediately instead of waiting on a network round-trip.
    private var lastCompletedDate: String?
    private var db: Firestore { Firestore.firestore() }

    /// Today's date key in UTC — the same boundary the server uses to decide
    /// which `dailyPuzzles/{date}` doc is "today" for every player worldwide.
    static func todayKeyUTC(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Loads today's puzzle and, if signed in, this player's current streak.
    /// The day's doc is dealt server-side at UTC midnight; if a read lands in
    /// the rare few-second gap before that's run, retry briefly rather than
    /// surfacing an error for what's usually just scheduler jitter.
    func load(uid: String?) async {
        phase = .loading
        let today = Self.todayKeyUTC()
        dateKey = today

        var attempt = 0
        while true {
            if let data = try? await db.collection("dailyPuzzles").document(today).getDocument().data(),
               let dealtHand = data["hand"] as? [Int], let dealtTarget = data["target"] as? Int {
                hand = dealtHand
                target = dealtTarget
                break
            }
            attempt += 1
            guard attempt < 4 else {
                phase = .error("Today's puzzle isn't ready yet — try again in a moment.")
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        if let uid {
            await loadStreak(uid: uid)
        } else {
            // No account (and no anonymous session): fall back to the local
            // record so a relaunch doesn't offer today's puzzle again.
            isCompletedToday = localCompletedDate == dateKey
            mySolveSeconds = isCompletedToday ? localSolveSeconds : nil
        }
        comparisonStats = await PuzzleStats.fetch(hand: hand, target: target)
        phase = .ready
    }

    private func loadStreak(uid: String) async {
        let data = try? await db.collection("users").document(uid).getDocument().data()
        streak = data?["dailyStreak"] as? Int ?? 0
        longestStreak = data?["dailyLongestStreak"] as? Int ?? 0
        lastCompletedDate = data?["dailyLastCompletedDate"] as? String
        isCompletedToday = lastCompletedDate == dateKey
        mySolveSeconds = isCompletedToday ? data?["dailyLastSolveSeconds"] as? Int : nil
    }

    /// Records a signed-in player's solve of today's puzzle into their streak.
    /// Strict rule: completing yesterday's (UTC) puzzle extends the streak by
    /// one; any bigger gap resets it to 1. `streak`/`longestStreak` are
    /// updated optimistically, synchronously, before the transaction even
    /// starts — otherwise the result screen would show the *previous* streak
    /// for as long as the round-trip takes, which reads as "it didn't count".
    /// A transaction (rather than a plain update) keeps the persisted value
    /// correct if this somehow got called twice — the second call sees its
    /// own first write and no-ops instead of double-counting.
    func recordCompletion(uid: String?, elapsedSeconds: Int) async {
        guard !isCompletedToday else { return }
        isCompletedToday = true
        mySolveSeconds = elapsedSeconds
        clearSavedProgress()
        saveLocalCompletion(elapsedSeconds: elapsedSeconds)
        guard let uid else { return }

        let today = dateKey
        let yesterday = Self.dayBefore(today)
        let optimisticStreak = lastCompletedDate == yesterday ? streak + 1 : 1
        streak = optimisticStreak
        longestStreak = max(longestStreak, optimisticStreak)
        lastCompletedDate = today

        let ref = db.collection("users").document(uid)
        try? await db.runTransaction { transaction, _ in
            let data = (try? transaction.getDocument(ref))?.data() ?? [:]
            let lastCompleted = data["dailyLastCompletedDate"] as? String
            guard lastCompleted != today else { return nil }
            let previousStreak = data["dailyStreak"] as? Int ?? 0
            let longest = data["dailyLongestStreak"] as? Int ?? 0
            let newStreak = lastCompleted == yesterday ? previousStreak + 1 : 1
            transaction.setData([
                "dailyStreak": newStreak,
                "dailyLongestStreak": max(longest, newStreak),
                "dailyLastCompletedDate": today,
                "dailyLastSolveSeconds": elapsedSeconds,
            ], forDocument: ref, merge: true)
            return nil
        }
        // Reconciles with the server's value in case the optimistic guess
        // above was wrong (e.g. another device already recorded today).
        await loadStreak(uid: uid)
    }

    /// Re-fetches `comparisonStats` after this player's own solve has been
    /// recorded, so Avg/Fastest (and the "faster than N%" line) reflect it
    /// instead of the pre-solve snapshot `load()` fetched up front.
    func refreshComparisonStats() async {
        comparisonStats = await PuzzleStats.fetch(hand: hand, target: target)
    }

    /// Looks up which of `friendUids` have completed today's puzzle and their
    /// times, for the friends leaderboard. Batched the same way as
    /// `FriendsService.fetchProfiles` — a document-ID `in` query caps at 30
    /// values, so a large friends list is a handful of concurrent queries
    /// rather than one round-trip per friend.
    func loadFriendsLeaderboard(friendUids: [String]) async {
        let ids = friendUids.filter { !$0.isEmpty && !$0.contains("/") }
        guard !ids.isEmpty else {
            friendsLeaderboard = []
            return
        }
        let batches = stride(from: 0, to: ids.count, by: 30).map {
            Array(ids[$0..<min($0 + 30, ids.count)])
        }
        let today = dateKey
        let db = self.db
        friendsLeaderboard = await withTaskGroup(of: [FriendResult].self) { group in
            for batch in batches {
                group.addTask {
                    guard let snapshot = try? await db.collection("users")
                        .whereField(FieldPath.documentID(), in: batch)
                        .getDocuments()
                    else { return [] }
                    return snapshot.documents.compactMap { document -> FriendResult? in
                        let data = document.data()
                        guard data["dailyLastCompletedDate"] as? String == today,
                              let seconds = data["dailyLastSolveSeconds"] as? Int
                        else { return nil }
                        return FriendResult(
                            id: document.documentID,
                            displayName: data["displayName"] as? String ?? "Player",
                            solveSeconds: seconds
                        )
                    }
                }
            }
            var all: [FriendResult] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }

    /// Elapsed seconds saved from a previous session of *today's* puzzle, if
    /// any — lets leaving mid-solve and reopening the puzzle later the same
    /// day resume the clock instead of restarting it. `nil` for a different
    /// day's leftover value, so a stale save never bleeds into a new puzzle.
    var savedElapsedSeconds: Int? {
        guard UserDefaults.standard.string(forKey: Self.inProgressDateDefaultsKey) == dateKey else { return nil }
        return UserDefaults.standard.object(forKey: Self.inProgressElapsedDefaultsKey) as? Int
    }

    func saveProgress(elapsedSeconds: Int) {
        UserDefaults.standard.set(dateKey, forKey: Self.inProgressDateDefaultsKey)
        UserDefaults.standard.set(elapsedSeconds, forKey: Self.inProgressElapsedDefaultsKey)
    }

    private static let completedDateDefaultsKey = "dailyPuzzle.completed.date"
    private static let completedSecondsDefaultsKey = "dailyPuzzle.completed.seconds"

    /// Device-local record of the last completed daily, for players with no
    /// account. Signed-in players use the Firestore profile instead.
    private var localCompletedDate: String? {
        UserDefaults.standard.string(forKey: Self.completedDateDefaultsKey)
    }
    private var localSolveSeconds: Int? {
        UserDefaults.standard.object(forKey: Self.completedSecondsDefaultsKey) as? Int
    }
    private func saveLocalCompletion(elapsedSeconds: Int) {
        UserDefaults.standard.set(dateKey, forKey: Self.completedDateDefaultsKey)
        UserDefaults.standard.set(elapsedSeconds, forKey: Self.completedSecondsDefaultsKey)
    }

    private static let solveReplayDateDefaultsKey = "dailyPuzzle.solveReplay.date"
    private static let solveReplayDefaultsKey = "dailyPuzzle.solveReplay"

    /// The recorded solve of *today's* puzzle, so "View Puzzle" can replay it
    /// even after the app is relaunched later the same day. Nil for any other
    /// day's leftover.
    var savedSolveReplay: SolveReplay? {
        guard UserDefaults.standard.string(forKey: Self.solveReplayDateDefaultsKey) == dateKey,
              let data = UserDefaults.standard.data(forKey: Self.solveReplayDefaultsKey)
        else { return nil }
        return try? JSONDecoder().decode(SolveReplay.self, from: data)
    }

    func saveSolveReplay(_ replay: SolveReplay?) {
        guard let replay, let data = try? JSONEncoder().encode(replay) else { return }
        UserDefaults.standard.set(dateKey, forKey: Self.solveReplayDateDefaultsKey)
        UserDefaults.standard.set(data, forKey: Self.solveReplayDefaultsKey)
    }

    func clearSavedProgress() {
        UserDefaults.standard.removeObject(forKey: Self.inProgressDateDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.inProgressElapsedDefaultsKey)
    }

    private static func dayBefore(_ key: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = formatter.date(from: key),
              let prior = calendar.date(byAdding: .day, value: -1, to: date)
        else { return key }
        return formatter.string(from: prior)
    }
}
