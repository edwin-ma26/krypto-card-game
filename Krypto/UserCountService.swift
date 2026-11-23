import Foundation
import FirebaseFirestore

/// Global signup count, used to drive the countdown to Competition Mode's
/// launch. Deliberately its own service rather than part of `CompetitionService`
/// — the progress bar renders on the signed-out coming-soon screen, which has no
/// uid and none of the profile/referral machinery.
///
/// Reads via an aggregation query, which bills one document read per 1000 index
/// entries rather than one per user. That's negligible at the launch threshold,
/// but it does scale with the collection, so `refresh` no-ops once the target is
/// reached — past the goal the number stops mattering and there's no reason to
/// keep paying for it on every appearance.
@MainActor
final class UserCountService: ObservableObject {
    /// nil until the first successful load, so the UI can distinguish
    /// "still loading" from a genuine zero.
    @Published private(set) var count: Int?
    @Published private(set) var isLoading = false

    private let db = Firestore.firestore()
    private var lastFetched: Date?

    /// Minimum gap between server hits, so reopening the sheet repeatedly
    /// doesn't re-count each time.
    private static let refreshInterval: TimeInterval = 60

    func refresh(target: Int, force: Bool = false) async {
        if !force {
            if let count, count >= target { return }
            if let lastFetched, Date().timeIntervalSince(lastFetched) < Self.refreshInterval { return }
        }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await db.collection("users").count.getAggregation(source: .server)
            count = Int(truncating: snapshot.count)
            lastFetched = Date()
        } catch {
            // Non-fatal: keep the last known value (or nil) and let the UI show
            // its loading/unknown state rather than an error. The count is
            // decoration on a screen that already says "coming soon".
        }
    }
}
