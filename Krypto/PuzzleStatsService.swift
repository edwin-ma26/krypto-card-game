import Foundation
import FirebaseFirestore

/// Aggregate telemetry for a distinct puzzle (a canonical hand+target combo),
/// pooled across every mode — solo, casual multiplayer rooms, and ranked all
/// report into the same `puzzleStats/{id}` doc, since a combo's difficulty is
/// intrinsic to the hand and target, not the mode it was dealt in.
///
/// This is deliberately just a counters/aggregates store, not a solution
/// cache: `Krypto.solve` is cheap enough to recompute on demand, so there's
/// nothing here worth denormalizing yet. It exists to back a difficulty
/// rating and "X% of players solved it" messaging for the (future) daily
/// puzzle, and the streak feature that sits on top of it.
///
/// Each puzzle is dealt by exactly one party — the solo player, whichever
/// device hosts a casual room, or the `onQueueJoin` Cloud Function for ranked
/// — so `recordDealt` is called once per deal, not once per participant.
/// `recordSolved`, by contrast, should only be called once a win is actually
/// confirmed (e.g. after a room's lock-in transaction commits `winner`), not
/// from every keystroke that happens to complete a hand — a casual race can
/// have a player finish the cards without holding the lock, which isn't a
/// real solve for stats purposes.
enum PuzzleStats {
    /// A read of the aggregate as of one fetch — used to show "compare
    /// against others" messaging (e.g. on the daily puzzle's result screen),
    /// not kept live/observed.
    struct Summary {
        let timesDealt: Int
        let timesSolved: Int
        /// `nil` when nobody has solved it yet (`timesSolved == 0`).
        let averageSolveSeconds: Int?
        let fastestSolveSeconds: Int?
        let fastestSolveBy: String?
        /// Difficulty-based estimate computed once, server-side, when this
        /// puzzle is dealt (see `functions/src/krypto.ts`'s
        /// `estimateSolveSeconds` — fewer solution paths imply a harder,
        /// slower puzzle). `nil` for puzzles dealt outside the daily-puzzle
        /// path, which don't get one. Only `targetSeconds` should be shown to
        /// players; this is the raw ingredient it blends with the real average.
        let estimatedSolveSeconds: Int?
        /// Bucket index (see `PuzzleStats.bucket`) -> number of solves that
        /// landed in it. Kept private: callers go through `percentile`
        /// rather than reasoning about bucket indices themselves.
        private let solveTimeBuckets: [Int: Int]

        init(
            timesDealt: Int, timesSolved: Int, averageSolveSeconds: Int?,
            fastestSolveSeconds: Int?, fastestSolveBy: String?, estimatedSolveSeconds: Int?,
            solveTimeBuckets: [Int: Int]
        ) {
            self.timesDealt = timesDealt
            self.timesSolved = timesSolved
            self.averageSolveSeconds = averageSolveSeconds
            self.fastestSolveSeconds = fastestSolveSeconds
            self.fastestSolveBy = fastestSolveBy
            self.estimatedSolveSeconds = estimatedSolveSeconds
            self.solveTimeBuckets = solveTimeBuckets
        }

        /// "Beat the clock" target shown to players — a shrinkage blend of the
        /// difficulty-based estimate and the real average, weighted by how
        /// many real solves back the average up. With few or no solves yet
        /// (the common case early in a daily puzzle's day) this leans almost
        /// entirely on the estimate; past a few dozen solves it's effectively
        /// just the true average. Avoids both the cold-start problem (no
        /// average exists yet) and a jarring jump if the target just switched
        /// from "estimate" to "average" at some fixed threshold.
        var targetSeconds: Int? {
            guard let estimatedSolveSeconds else { return averageSolveSeconds }
            guard let averageSolveSeconds, timesSolved > 0 else { return estimatedSolveSeconds }
            let priorWeight = 20.0
            let realWeight = Double(timesSolved) / (Double(timesSolved) + priorWeight)
            let blended = realWeight * Double(averageSolveSeconds) + (1 - realWeight) * Double(estimatedSolveSeconds)
            return Int(blended.rounded())
        }

        /// Solve counts per bucket, index 0..<`PuzzleStats.bucketCount` (the
        /// last one is the 10-minute+ overflow), zero-filled — the shape the
        /// result screen's chart draws directly.
        var histogram: [Int] {
            (0..<PuzzleStats.bucketCount).map { solveTimeBuckets[$0] ?? 0 }
        }

        /// Estimated percentile rank (1–100) for a solve of `elapsedSeconds`,
        /// among everyone reflected in this snapshot — "faster than N% of
        /// solvers". `nil` if nobody else had solved it yet as of this fetch.
        ///
        /// Approximated from the bucket histogram rather than an exact rank,
        /// since individual solve times aren't retained: a solve tied in the
        /// same bucket as others is credited as beating half of them, which
        /// is the standard way to estimate a percentile from grouped data
        /// without pretending to a precision the buckets don't actually have.
        func percentile(forElapsedSeconds elapsedSeconds: Int) -> Int? {
            guard timesSolved > 0 else { return nil }
            let myBucket = PuzzleStats.bucket(forSeconds: elapsedSeconds)
            let slower = solveTimeBuckets.filter { $0.key > myBucket }.values.reduce(0, +)
            let tied = solveTimeBuckets[myBucket] ?? 0
            let beaten = Double(slower) + Double(tied) / 2
            return max(1, min(100, Int((beaten / Double(timesSolved) * 100).rounded())))
        }
    }

    /// Deterministic doc id for a hand+target, independent of deal order or
    /// card colors — `[5,1,3,2,4]`/15 and `[1,2,3,4,5]`/15 are the same puzzle.
    static func id(hand: [Int], target: Int) -> String {
        (hand.sorted().map(String.init) + ["t\(target)"]).joined(separator: "-")
    }

    /// Groups solve times into 10-second buckets (0, 10, 20, … ) with
    /// everything at or past 10 minutes folded into one overflow bucket, so
    /// the histogram stays a fixed size regardless of how slow a solve is.
    /// (Until Nov 2026 the overflow started at 120s — index 12 — so docs
    /// written by older builds read that bucket as "120–129s" here, a small
    /// misplacement on the chart's tail rather than anything visible as a
    /// wrong number.)
    static let bucketSeconds = 10
    static let bucketCount = 61
    /// Field holding the 10-minute-range histogram. Builds before Nov 2026
    /// wrote `solveTimeBuckets` with a 120s overflow (and, worse, as literal
    /// dotted keys — see `recordSolved`); keeping the new scheme under its own
    /// name means the chart never mixes the two meanings of "bucket 12".
    static let bucketsField = "solveTimeBucketsV2"
    static func bucket(forSeconds seconds: Int) -> Int {
        min(max(seconds, 0) / bucketSeconds, bucketCount - 1)
    }

    private static var db: Firestore { Firestore.firestore() }

    /// Client writes land on one of these shard docs under the puzzle,
    /// `puzzleStats/{id}/shards/{0…shardCount-1}`, picked at random per write,
    /// rather than on the puzzle doc itself. Firestore sustains roughly one
    /// write per second per document; the daily puzzle is one document that
    /// every player hits in the same few hours, and a contended transaction
    /// retries a handful of times then fails — silently, as far as the player
    /// is concerned — so solves fell out of the stats exactly when the game
    /// was busiest. Eight shards lift the ceiling to ~8 writes/s per puzzle,
    /// and `fetch` sums them back together (plus whatever older builds and
    /// the ranked Cloud Function still write to the main doc). Mirrored in
    /// the Android client's `PuzzleStatsRepository.kt`.
    static let shardCount = 8
    private static func shardRef(hand: [Int], target: Int) -> DocumentReference {
        db.collection("puzzleStats").document(id(hand: hand, target: target))
            .collection("shards").document(String(Int.random(in: 0..<shardCount)))
    }

    /// Records one deal of this puzzle. Safe to call blindly — `increment`
    /// initializes a missing field to the increment amount, so the same call
    /// creates the shard doc on the first deal and just bumps the counter after.
    static func recordDealt(hand: [Int], target: Int) {
        shardRef(hand: hand, target: target).setData([
            "timesDealt": FieldValue.increment(Int64(1)),
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    /// Records one confirmed solve. `totalSolveTimeMs`/`timesSolved` together
    /// give an average; `fastestSolveTimeMs` is only ever lowered, via a
    /// transaction so two near-simultaneous record-breaking solves (in
    /// different rooms, since a single race only has one winner) can't race
    /// each other into an inconsistent doc. Each shard keeps its own fastest;
    /// `fetch` takes the minimum across them.
    static func recordSolved(hand: [Int], target: Int, elapsedSeconds: Int, solverName: String) {
        let elapsedMs = Int64(elapsedSeconds) * 1000
        let bucketKey = String(bucket(forSeconds: elapsedSeconds))
        let ref = shardRef(hand: hand, target: target)
        db.runTransaction { transaction, _ in
            let data = (try? transaction.getDocument(ref))?.data()
            let currentFastest = data?["fastestSolveTimeMs"] as? Int64
            // The bucket bump is a nested dictionary, not a dotted "a.b" string
            // key: in a merge-set the SDK treats a dotted key as a literal
            // top-level field name (dot notation is only parsed by
            // `updateData`), which both hid the histogram from `fetch` and
            // tripped the `puzzleStats` rules' field allowlist, so every
            // solve write was silently denied.
            var update: [String: Any] = [
                "timesSolved": FieldValue.increment(Int64(1)),
                "totalSolveTimeMs": FieldValue.increment(elapsedMs),
                bucketsField: [bucketKey: FieldValue.increment(Int64(1))],
                "updatedAt": FieldValue.serverTimestamp(),
            ]
            if currentFastest == nil || elapsedMs < currentFastest! {
                update["fastestSolveTimeMs"] = elapsedMs
                update["fastestSolveBy"] = solverName
            }
            transaction.setData(update, forDocument: ref, merge: true)
            return nil
        } completion: { _, error in
            // Telemetry only, so nothing to surface to the player — but a
            // rules denial here went unnoticed for months when this swallowed
            // the error, so at least leave a trace in the console.
            if let error { print("PuzzleStats.recordSolved failed: \(error.localizedDescription)") }
        }
    }

    /// Records a Single Player give-up. Kept separate from `timesSolved` so
    /// the solve-time average stays an average of finishes; readers can treat
    /// abandons as solves censored at the cap when fitting the distribution.
    static func recordAbandoned(hand: [Int], target: Int) {
        shardRef(hand: hand, target: target).setData([
            "timesAbandoned": FieldValue.increment(Int64(1)),
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true) { error in
            if let error { print("PuzzleStats.recordAbandoned failed: \(error.localizedDescription)") }
        }
    }

    /// Reads back the current aggregate for a puzzle, e.g. to show "N players
    /// solved this" against the player's own result: the main doc (what older
    /// builds and the ranked Cloud Function write, plus the server-side
    /// difficulty estimate) summed with every shard. `nil` if neither exists
    /// yet (shouldn't happen for a puzzle the caller just played, but a read
    /// racing the very first `recordDealt` write is possible) or a read fails.
    static func fetch(hand: [Int], target: Int) async -> Summary? {
        let ref = db.collection("puzzleStats").document(id(hand: hand, target: target))
        async let mainRead = try? ref.getDocument()
        async let shardsRead = try? ref.collection("shards").getDocuments()
        guard let main = await mainRead, let shards = await shardsRead else { return nil }
        var parts: [[String: Any]] = shards.documents.map { $0.data() }
        if let data = main.data() { parts.insert(data, at: 0) }
        guard !parts.isEmpty else { return nil }

        var timesDealt = 0, timesSolved = 0, totalMs = 0
        var fastestMs: Int?, fastestBy: String?
        var buckets: [Int: Int] = [:]
        for data in parts {
            timesDealt += data["timesDealt"] as? Int ?? 0
            timesSolved += data["timesSolved"] as? Int ?? 0
            totalMs += data["totalSolveTimeMs"] as? Int ?? 0
            if let ms = data["fastestSolveTimeMs"] as? Int, ms < (fastestMs ?? .max) {
                fastestMs = ms
                fastestBy = data["fastestSolveBy"] as? String
            }
            for (index, count) in histogram(in: data) { buckets[index, default: 0] += count }
        }
        return Summary(
            timesDealt: timesDealt,
            timesSolved: timesSolved,
            averageSolveSeconds: timesSolved > 0 ? (totalMs / timesSolved) / 1000 : nil,
            fastestSolveSeconds: fastestMs.map { $0 / 1000 },
            fastestSolveBy: fastestBy,
            // Only ever on the main doc, written by `publishDailyPuzzle`.
            estimatedSolveSeconds: main.data()?["estimatedSolveSeconds"] as? Int,
            solveTimeBuckets: buckets
        )
    }

    /// One doc's histogram. The current scheme feeds the chart/percentile.
    /// Until a doc has any `solveTimeBucketsV2` data, fall back to the legacy
    /// `solveTimeBuckets` histogram — both the nested map and the literal
    /// "solveTimeBuckets.N" top-level keys older builds wrote (see
    /// `recordSolved`). Legacy buckets 0–11 mean the same 10s ranges; only
    /// legacy 12 (the old "≥120s" overflow) lands slightly off, at 120–129s.
    /// Without this fallback every puzzle recorded before the rename had an
    /// empty histogram and the chart silently vanished.
    private static func histogram(in data: [String: Any]) -> [Int: Int] {
        var buckets: [Int: Int] = [:]
        for (key, value) in data[bucketsField] as? [String: Any] ?? [:] {
            if let index = Int(key), let count = value as? Int { buckets[index] = count }
        }
        if buckets.isEmpty {
            for (key, value) in data["solveTimeBuckets"] as? [String: Any] ?? [:] {
                if let index = Int(key), let count = value as? Int { buckets[index, default: 0] += count }
            }
            for (key, value) in data where key.hasPrefix("solveTimeBuckets.") {
                if let index = Int(key.dropFirst("solveTimeBuckets.".count)), let count = value as? Int {
                    buckets[index, default: 0] += count
                }
            }
        }
        return buckets
    }
}
