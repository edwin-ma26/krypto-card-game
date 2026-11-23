import Foundation

/// Canonical outbound links for sharing/inviting. Kept in one place so the
/// App Store URL and referral-tagging rule can't drift between share buttons.
///
/// NOTE: the old shares pointed at `krypto-game-em26.web.app`, which currently
/// serves a Firebase "Site Not Found" 404 — so every invite landed on a dead
/// page. These go straight to the App Store listing instead. When a real
/// Universal Link / deferred-deep-link landing page exists, swap `store(ref:)`
/// to return that instead and keep the `?ref=` contract.
enum AppLinks {
    /// The public App Store listing for Krypto.
    static let appStore = "https://apps.apple.com/us/app/krypto-card-game/id6794679898"

    /// The App Store link tagged with a referral code, so we can (later) attribute
    /// installs to the inviter. Falls back to the plain listing when there's no code.
    static func store(ref code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return appStore }
        return "\(appStore)?ref=\(trimmed)"
    }
}
