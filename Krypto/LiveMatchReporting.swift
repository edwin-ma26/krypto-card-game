import Foundation

/// Lets `GameViewModel` report progress to whichever live opponent service
/// is driving the current match — a casual room code or a ranked queue.
@MainActor
protocol LiveMatchReporting: AnyObject {
    func updateProgress(cardsLeft: Int)
    func reportSolved(elapsed: Int)
    /// Broadcasts the running solution steps so an opponent can watch a lock-in
    /// solve live. No-op by default — only the casual lock-in race uses it.
    func updateLiveSteps(_ steps: [String])
    /// Called on every board touch (card or operator tap). Services throttle
    /// this into an occasional heartbeat so the opponent sees the player is
    /// still there. No-op by default.
    func touchActivity()
}

extension LiveMatchReporting {
    func updateLiveSteps(_ steps: [String]) {}
    func touchActivity() {}
}
