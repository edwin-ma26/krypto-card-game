import Foundation
import FirebaseAuth
import FirebaseFirestore

/// One finished puzzle, as the Stats page sees it: a solo deal (solved or
/// given up), today's daily, or a ranked match.
struct SolveRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case solo, daily, ranked
    }

    let id: String
    let kind: Kind
    let at: Date
    /// Time to solve. `nil` when the puzzle wasn't solved by this player — a
    /// solo give-up, or a ranked match the opponent finished first.
    let seconds: Int?
    /// Solo rating / ranked Elo after this result, when the mode is rated.
    let ratingAfter: Int?
    let delta: Int?
    /// Ranked only.
    let won: Bool?

    var solved: Bool { seconds != nil }
}

/// The player's own history of finished puzzles, kept on the device and
/// mirrored under `users/{uid}/solves` once signed in so Stats follow the
/// account across devices.
///
/// Everything the Stats page charts comes from here. Solo and daily puzzles
/// log themselves as they finish; ranked matches do too, and are additionally
/// back-filled once from `rankedMatches`, which has every match ever played
/// (new or old build), keyed by the match id so the two sources never double
/// count.
///
/// Signing in listens on Firebase Auth directly rather than being wired
/// through each screen, so a solve recorded while signed out is pushed to
/// the account the moment one exists.
@MainActor
final class StatsLog: ObservableObject {
    static let shared = StatsLog()

    @Published private(set) var records: [SolveRecord] = []
    @Published private(set) var isLoading = false

    private var uid: String?
    /// Records written locally but not yet confirmed on the server for the
    /// current account. Flushed on sign-in and retried on the next record.
    private var pendingMirror: Set<String> = []
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var bindTask: Task<Void, Never>?
    private let db = Firestore.firestore()

    private static let maxRecords = 3000

    private struct Disk: Codable {
        var records: [SolveRecord]
        var pendingMirror: [String]
    }

    private init() {
        load()
        #if DEBUG
        if DemoStats.isEnabled {
            records = Self.demoRecords()
            return // In-memory only: nothing saved, nothing mirrored.
        }
        #endif
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.bind(uid: user?.uid) }
        }
    }

    // MARK: Recording

    func record(_ record: SolveRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
            if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
        }
        pendingMirror.insert(record.id)
        save()
        flushPending()
    }

    func recordSolo(seconds: Int?, ratingAfter: Int?, delta: Int?) {
        record(SolveRecord(id: UUID().uuidString, kind: .solo, at: Date(), seconds: seconds,
                           ratingAfter: ratingAfter, delta: delta, won: nil))
    }

    /// Keyed by the day so a daily solved on two devices stays one record.
    func recordDaily(dateKey: String, seconds: Int) {
        record(SolveRecord(id: "daily-\(dateKey)", kind: .daily, at: Date(), seconds: seconds,
                           ratingAfter: nil, delta: nil, won: nil))
    }

    /// Keyed by the match so the `rankedMatches` back-fill can't duplicate it.
    func recordRanked(matchId: String, won: Bool, seconds: Int?, ratingAfter: Int, delta: Int) {
        record(SolveRecord(id: "ranked-\(matchId)", kind: .ranked, at: Date(), seconds: seconds,
                           ratingAfter: ratingAfter, delta: delta, won: won))
    }

    /// Forgets everything on this device. Used when the account is deleted;
    /// the server copy is removed separately by the `onUserDeleted` function.
    func eraseLocalHistory() {
        bindTask?.cancel()
        records = []
        pendingMirror = []
        save()
    }

    func records(of kind: SolveRecord.Kind) -> [SolveRecord] {
        records.filter { $0.kind == kind }.sorted { $0.at < $1.at }
    }

    // MARK: Account sync

    private func bind(uid: String?) {
        guard uid != self.uid else { return }
        self.uid = uid
        bindTask?.cancel()
        guard let uid else { return }
        // Everything recorded so far belongs to whoever just signed in.
        pendingMirror.formUnion(records.map(\.id))
        save()
        bindTask = Task { [weak self] in
            guard let self else { return }
            isLoading = true
            await pullFromServer(uid: uid)
            await backfillRankedIfNeeded(uid: uid)
            flushPending()
            isLoading = false
        }
    }

    /// Pulls the account's history (another device, or a reinstall) and
    /// merges it with what's on this device.
    private func pullFromServer(uid: String) async {
        guard let snapshot = try? await db.collection("users").document(uid).collection("solves")
            .order(by: "at", descending: true).limit(to: 1500).getDocuments()
        else { return }
        guard !Task.isCancelled, self.uid == uid else { return }
        var merged = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for document in snapshot.documents {
            guard let record = Self.parse(id: document.documentID, data: document.data()) else { continue }
            merged[record.id] = record
            pendingMirror.remove(record.id)
        }
        records = merged.values.sorted { $0.at < $1.at }
        save()
    }

    /// Old ranked matches (played before this log existed) come from the
    /// match documents themselves. Rating after each one is reconstructed with
    /// the same K=32 step `RankedService` applied at the time.
    private func backfillRankedIfNeeded(uid: String) async {
        let flag = "statsLog.rankedBackfilled.\(uid)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        var imported: [SolveRecord] = []
        for side in ["playerA", "playerB"] {
            guard let snapshot = try? await db.collection("rankedMatches")
                .whereField(side, isEqualTo: uid)
                .order(by: "createdAt")
                .limit(to: 300)
                .getDocuments()
            else { return } // Missing index or offline: try again next launch.
            for document in snapshot.documents {
                let data = document.data()
                guard let winner = data["winner"] as? String,
                      let playerA = data["playerA"] as? String,
                      let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
                else { continue }
                let mine = playerA == uid ? data["eloA"] as? Int ?? 1200 : data["eloB"] as? Int ?? 1200
                let theirs = playerA == uid ? data["eloB"] as? Int ?? 1200 : data["eloA"] as? Int ?? 1200
                let won = winner == uid
                let expected = 1.0 / (1.0 + pow(10, Double(theirs - mine) / 400.0))
                let delta = Int((32.0 * ((won ? 1.0 : 0.0) - expected)).rounded())
                imported.append(SolveRecord(
                    id: "ranked-\(document.documentID)", kind: .ranked, at: createdAt,
                    seconds: nil, ratingAfter: max(100, mine + delta), delta: delta, won: won
                ))
            }
        }
        guard !Task.isCancelled, self.uid == uid else { return }
        let known = Set(records.map(\.id))
        for record in imported where !known.contains(record.id) {
            records.append(record)
            pendingMirror.insert(record.id)
        }
        records.sort { $0.at < $1.at }
        save()
        UserDefaults.standard.set(true, forKey: flag)
    }

    private func flushPending() {
        guard let uid, !pendingMirror.isEmpty else { return }
        let collection = db.collection("users").document(uid).collection("solves")
        for id in pendingMirror {
            guard let record = records.first(where: { $0.id == id }) else {
                pendingMirror.remove(id)
                continue
            }
            collection.document(id).setData(Self.fields(for: record)) { [weak self] error in
                guard let self else { return }
                Task { @MainActor in
                    if let error {
                        print("StatsLog mirror failed: \(error.localizedDescription)")
                    } else {
                        self.pendingMirror.remove(id)
                        self.save()
                    }
                }
            }
        }
    }

    private static func fields(for record: SolveRecord) -> [String: Any] {
        var fields: [String: Any] = [
            "kind": record.kind.rawValue,
            "at": Timestamp(date: record.at),
        ]
        if let seconds = record.seconds { fields["seconds"] = seconds }
        if let rating = record.ratingAfter { fields["ratingAfter"] = rating }
        if let delta = record.delta { fields["delta"] = delta }
        if let won = record.won { fields["won"] = won }
        return fields
    }

    private static func parse(id: String, data: [String: Any]) -> SolveRecord? {
        guard let kindRaw = data["kind"] as? String, let kind = SolveRecord.Kind(rawValue: kindRaw),
              let at = (data["at"] as? Timestamp)?.dateValue()
        else { return nil }
        return SolveRecord(
            id: id, kind: kind, at: at,
            seconds: data["seconds"] as? Int,
            ratingAfter: data["ratingAfter"] as? Int,
            delta: data["delta"] as? Int,
            won: data["won"] as? Bool
        )
    }

    // MARK: Disk

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stats-log.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let disk = try? JSONDecoder().decode(Disk.self, from: data)
        else { return }
        records = disk.records.sorted { $0.at < $1.at }
        pendingMirror = Set(disk.pendingMirror)
    }

    private func save() {
        let disk = Disk(records: records, pendingMirror: Array(pendingMirror))
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

#if DEBUG
extension StatsLog {
    /// A plausible month of play for eyeballing the Stats page layout
    /// (`KRYPTO_DEMO_STATS=1`), without needing a signed-in account.
    static func demoRecords() -> [SolveRecord] {
        var generator = SystemRandomNumberGenerator()
        var out: [SolveRecord] = []
        let now = Date()
        var solo = 1200, elo = 1200
        for i in 0..<60 {
            let at = now.addingTimeInterval(-Double(60 - i) * 9_000 - Double.random(in: 0...3000, using: &generator))
            let gaveUp = i % 13 == 7
            let seconds = gaveUp ? nil : max(12, Int(110 - Double(i) * 1.1 + Double.random(in: -35...45, using: &generator)))
            let delta = gaveUp ? -Int.random(in: 6...14, using: &generator) : Int.random(in: -8...14, using: &generator)
            solo += delta
            out.append(SolveRecord(id: "demo-solo-\(i)", kind: .solo, at: at, seconds: seconds, ratingAfter: solo, delta: delta, won: nil))
        }
        for day in 0..<24 where day % 5 != 3 {
            let at = now.addingTimeInterval(-Double(day) * 86_400)
            out.append(SolveRecord(id: "daily-\(DailyPuzzleService.todayKeyUTC(at))", kind: .daily, at: at,
                                   seconds: Int.random(in: 40...260, using: &generator), ratingAfter: nil, delta: nil, won: nil))
        }
        for i in 0..<18 {
            let at = now.addingTimeInterval(-Double(18 - i) * 40_000)
            let won = Double.random(in: 0...1, using: &generator) < 0.55
            let delta = won ? Int.random(in: 8...18, using: &generator) : -Int.random(in: 8...18, using: &generator)
            elo += delta
            out.append(SolveRecord(id: "ranked-demo-\(i)", kind: .ranked, at: at,
                                   seconds: won ? Int.random(in: 25...140, using: &generator) : nil,
                                   ratingAfter: elo, delta: delta, won: won))
        }
        return out.sorted { $0.at < $1.at }
    }
}
#endif
