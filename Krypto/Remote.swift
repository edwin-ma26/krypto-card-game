import SwiftUI
import FirebaseRemoteConfig

/// Server-driven configuration, so palette tweaks, feature kill-switches and
/// game tuning can ship from the Firebase console instead of an App Store
/// submission.
///
/// Every value has a baked-in fallback matching what the app shipped with, so a
/// cold launch with no network behaves exactly as it did before Remote Config
/// existed. Fetched values are parsed into plain Swift structs once per
/// activation rather than read through Firebase on every access — SwiftUI
/// evaluates `Theme.background` and friends many times per frame, and a
/// dictionary lookup plus a hex parse per read would show up.
@MainActor
final class Remote: ObservableObject {
    static let shared = Remote()

    /// Bumped whenever newly fetched values are activated. Views that need to
    /// restyle mid-session can observe it; most don't need to, since the launch
    /// fetch lands behind the splash, before the first paint.
    @Published private(set) var generation = 0

    private(set) var palette = Palette.fallback
    private(set) var flags = Flags.fallback
    private(set) var tuning = Tuning.fallback
    /// Tier bands over the solo and ranked ratings (see `RatingTiers`).
    private(set) var tiers = RatingTiers.fallback

    private let config = RemoteConfig.remoteConfig()

    private init() {
        let settings = RemoteConfigSettings()
        // Firebase throttles to one fetch every 12h by default, which makes
        // console changes untestable while developing.
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 3600
        #endif
        config.configSettings = settings
        config.setDefaults(Self.bakedInDefaults)
        // Firebase persists the last activated payload, so this picks up the
        // previous launch's config immediately rather than showing shipped
        // defaults for as long as the network round-trip takes.
        apply()
    }

    /// Fetches and activates the latest config. Failures are deliberately
    /// silent: offline, throttled, or a malformed payload all just leave the
    /// previously activated values (or the shipped fallbacks) in force.
    func refresh() async {
        _ = try? await config.fetchAndActivate()
        apply()
    }

    private func apply() {
        palette = Palette(json: config[Key.palette.rawValue].jsonValue as? [String: Any])
        flags = Flags(
            multiplayerEnabled: config[Key.multiplayerEnabled.rawValue].boolValue,
            competitionEnabled: config[Key.competitionEnabled.rawValue].boolValue,
            hintsEnabled: config[Key.hintsEnabled.rawValue].boolValue,
            dailyPuzzleEnabled: config[Key.dailyPuzzleEnabled.rawValue].boolValue,
            minSupportedBuild: config[Key.minSupportedBuild.rawValue].numberValue.intValue,
            updateMessage: config[Key.updateMessage.rawValue].stringValue,
            latestRecommendedBuild: config[Key.latestRecommendedBuild.rawValue].numberValue.intValue,
            softUpdateMessage: config[Key.softUpdateMessage.rawValue].stringValue,
            // Guarded against 0: a blank console field would otherwise parse as
            // zero and instantly "reach" the goal, launching Competition Mode
            // for everyone by accident.
            competitionUnlockThreshold: max(1, config[Key.unlockThreshold.rawValue].numberValue.intValue),
            competitionForceUnlock: config[Key.forceUnlock.rawValue].boolValue,
            rankedReferralsRequired: max(0, config[Key.rankedReferralsRequired.rawValue].numberValue.intValue),
            rankedReferralGateSince: Flags.parseDay(config[Key.rankedReferralGateSince.rawValue].stringValue),
            rankedGateAfterPlacement: config[Key.rankedGateAfterPlacement.rawValue].boolValue,
            rankedBotsEnabled: config[Key.rankedBotsEnabled.rawValue].boolValue,
            rankedBotWaitSeconds: max(5, config[Key.rankedBotWaitSeconds.rawValue].numberValue.intValue)
        )
        tuning = Tuning(
            // Clamped so a fat-fingered console entry (or an empty string, which
            // parses as 0) can't hand out a zero-second lock window and wedge a
            // live race for everyone who fetched it.
            lockWindow: clamp(config[Key.lockWindow.rawValue].numberValue.intValue, 3...60, Tuning.fallback.lockWindow),
            missCooldown: clamp(config[Key.missCooldown.rawValue].numberValue.intValue, 0...120, Tuning.fallback.missCooldown)
        )
        tiers = RatingTiers(json: config[Key.ratingTiers.rawValue].jsonValue as? [String: Any])
        generation += 1
    }

    private func clamp(_ value: Int, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
        range.contains(value) ? value : fallback
    }

    /// This build's `CFBundleVersion`, or 0 if it can't be read.
    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// True when the console has marked this build too old to keep running.
    /// Drives the non-dismissible `UpdateRequiredView`.
    var requiresUpdate: Bool {
        currentBuild < flags.minSupportedBuild
    }

    /// True when a newer build is recommended but this one still runs — the
    /// trigger for the dismissible soft-update nudge. Suppressed while
    /// `requiresUpdate` is true so the hard gate always wins.
    var recommendsUpdate: Bool {
        !requiresUpdate
            && flags.latestRecommendedBuild > 0
            && currentBuild < flags.latestRecommendedBuild
    }

    // MARK: - Keys

    private enum Key: String {
        case palette = "theme_palette"
        case multiplayerEnabled = "multiplayer_enabled"
        case competitionEnabled = "competition_enabled"
        case hintsEnabled = "hints_enabled"
        case dailyPuzzleEnabled = "daily_puzzle_enabled"
        case minSupportedBuild = "min_supported_build"
        case updateMessage = "update_message"
        case latestRecommendedBuild = "latest_recommended_build"
        case softUpdateMessage = "soft_update_message"
        case lockWindow = "multiplayer_lock_window"
        case missCooldown = "multiplayer_miss_cooldown"
        case unlockThreshold = "competition_unlock_threshold"
        case forceUnlock = "competition_force_unlock"
        case rankedReferralsRequired = "ranked_referrals_required"
        case rankedReferralGateSince = "ranked_referral_gate_since"
        case rankedGateAfterPlacement = "ranked_referral_gate_after_placement"
        case rankedBotsEnabled = "ranked_bots_enabled"
        case rankedBotWaitSeconds = "ranked_bot_wait_seconds"
        case ratingTiers = "rating_tiers"
    }

    /// Registered with Firebase so `config[key]` always returns something sane
    /// before the first fetch completes. These mirror `Flags.fallback` and
    /// `Tuning.fallback`; the palette defaults to `{}`, meaning "override
    /// nothing", which leaves `Palette.fallback`'s exact shipped colors intact.
    private static let bakedInDefaults: [String: NSObject] = [
        Key.palette.rawValue: "{}" as NSString,
        Key.multiplayerEnabled.rawValue: Flags.fallback.multiplayerEnabled as NSNumber,
        Key.competitionEnabled.rawValue: Flags.fallback.competitionEnabled as NSNumber,
        Key.hintsEnabled.rawValue: Flags.fallback.hintsEnabled as NSNumber,
        Key.dailyPuzzleEnabled.rawValue: Flags.fallback.dailyPuzzleEnabled as NSNumber,
        Key.minSupportedBuild.rawValue: Flags.fallback.minSupportedBuild as NSNumber,
        Key.updateMessage.rawValue: Flags.fallback.updateMessage as NSString,
        Key.latestRecommendedBuild.rawValue: Flags.fallback.latestRecommendedBuild as NSNumber,
        Key.softUpdateMessage.rawValue: Flags.fallback.softUpdateMessage as NSString,
        Key.lockWindow.rawValue: Tuning.fallback.lockWindow as NSNumber,
        Key.missCooldown.rawValue: Tuning.fallback.missCooldown as NSNumber,
        Key.unlockThreshold.rawValue: Flags.fallback.competitionUnlockThreshold as NSNumber,
        Key.forceUnlock.rawValue: Flags.fallback.competitionForceUnlock as NSNumber,
        Key.rankedReferralsRequired.rawValue: Flags.fallback.rankedReferralsRequired as NSNumber,
        Key.rankedReferralGateSince.rawValue: Flags.fallbackGateSinceString as NSString,
        Key.rankedGateAfterPlacement.rawValue: Flags.fallback.rankedGateAfterPlacement as NSNumber,
        Key.rankedBotsEnabled.rawValue: Flags.fallback.rankedBotsEnabled as NSNumber,
        Key.rankedBotWaitSeconds.rawValue: Flags.fallback.rankedBotWaitSeconds as NSNumber,
        // `{}` = keep `RatingTiers.fallback` wholesale.
        Key.ratingTiers.rawValue: "{}" as NSString,
    ]
}

// MARK: - Payloads

extension Remote {
    struct Flags {
        /// Day the referral gate came in (see `rankedReferralGateSince`).
        static let fallbackGateSinceString = "2026-11-18"
        /// "yyyy-MM-dd" in UTC → start of that day; nil if it doesn't parse.
        static func parseDay(_ string: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: string.trimmingCharacters(in: .whitespaces))
        }

        var multiplayerEnabled: Bool
        var competitionEnabled: Bool
        var hintsEnabled: Bool
        /// Depends on the `generateDailyPuzzle` scheduled Cloud Function
        /// actually being deployed — defaulted to true for local testing,
        /// but flip this back to false (or set `daily_puzzle_enabled=false`
        /// in the console) if it ships before that backend is live, so the
        /// entry point doesn't lead to a permanently broken "not ready" state.
        var dailyPuzzleEnabled: Bool
        /// Builds below this are blocked at launch. 0 disables the gate.
        var minSupportedBuild: Int
        var updateMessage: String
        /// Builds below this get a dismissible "update available" nudge. 0
        /// disables it. Should stay at or above `minSupportedBuild`.
        var latestRecommendedBuild: Int
        var softUpdateMessage: String
        /// Signups needed before Competition Mode opens to everyone.
        var competitionUnlockThreshold: Int
        /// Opens Competition Mode regardless of the signup count — the manual
        /// override for launching early, or for re-locking after launch without
        /// having to move the threshold around.
        var competitionForceUnlock: Bool
        /// Per-player gate on top of the global unlock: how many friends a
        /// player must have referred before Ranked opens for *them*. 0 turns
        /// the gate off. Tunable live from the console.
        var rankedReferralsRequired: Int
        /// Accounts created before this UTC day are exempt from the referral
        /// gate — it's meant for *new* players, not a wall dropped in front of
        /// people who already had Ranked. `nil` (blank/unparseable) gates
        /// everyone.
        var rankedReferralGateSince: Date?
        /// Where the referral gate sits relative to placement. `true`: anyone
        /// may play their placement matches, and the gate applies when the
        /// rank is ready to be revealed — the badge and further Ranked play
        /// wait for the referral. `false`: the gate stands in front of the
        /// first match, as it did before placement existed.
        var rankedGateAfterPlacement: Bool
        /// Mirrors the server's bot-fallback knobs (functions/src/ranked.ts
        /// reads the same keys) so the searching popup's wait estimate can
        /// be capped at "a bot will step in by then". The client doesn't
        /// act on these otherwise — the server decides when a bot plays.
        var rankedBotsEnabled: Bool
        var rankedBotWaitSeconds: Int

        static let fallback = Flags(
            multiplayerEnabled: true,
            competitionEnabled: true,
            hintsEnabled: true,
            dailyPuzzleEnabled: true,
            minSupportedBuild: 0,
            updateMessage: "",
            latestRecommendedBuild: 0,
            softUpdateMessage: "",
            competitionUnlockThreshold: 1000,
            competitionForceUnlock: false,
            rankedReferralsRequired: 1,
            rankedReferralGateSince: Flags.parseDay(Flags.fallbackGateSinceString),
            rankedGateAfterPlacement: true,
            rankedBotsEnabled: false,
            rankedBotWaitSeconds: 12
        )
    }

    struct Tuning {
        var lockWindow: Int
        var missCooldown: Int

        static let fallback = Tuning(lockWindow: 7, missCooldown: 14)
    }

    /// The app palette. `fallback` holds the exact `Color` literals the app
    /// shipped with — not hex round-trips of them — so with no config fetched
    /// the rendering is bit-identical to before.
    struct Palette {
        var background: Color
        var pill: Color
        var codeField: Color
        var codeText: Color
        var inkDark: Color
        var inkMuted: Color
        var button: Color
        var accent: Color
        var cardColors: [Color]

        static let fallback = Palette(
            background: Color(red: 0.972, green: 0.965, blue: 0.945),
            pill: Color(red: 0.941, green: 0.925, blue: 0.886),
            codeField: Color(red: 0.82, green: 0.82, blue: 0.82),
            codeText: Color(red: 0.25, green: 0.25, blue: 0.25),
            inkDark: Color(red: 0.29, green: 0.23, blue: 0.16),
            inkMuted: Color(red: 0.55, green: 0.50, blue: 0.42),
            button: Color(red: 0.36, green: 0.29, blue: 0.19),
            accent: Color(red: 0.85, green: 0.65, blue: 0.25),
            cardColors: [
                Color(red: 0.91, green: 0.84, blue: 0.64),  // sand
                Color(red: 0.78, green: 0.85, blue: 0.72),  // sage
                Color(red: 0.87, green: 0.75, blue: 0.60),  // tan
                Color(red: 0.83, green: 0.81, blue: 0.77),  // stone
                Color(red: 0.88, green: 0.78, blue: 0.74),  // clay
            ]
        )

        /// Overrides only the keys actually present and parseable, so a partial
        /// or half-typo'd console payload restyles what it can and leaves the
        /// rest shipped rather than falling back wholesale.
        init(json: [String: Any]?) {
            self = .fallback
            guard let json else { return }

            func hex(_ key: String) -> Color? {
                guard let raw = json[key] as? String else { return nil }
                return Color(hex: raw)
            }

            background = hex("background") ?? background
            pill = hex("pill") ?? pill
            codeField = hex("codeField") ?? codeField
            codeText = hex("codeText") ?? codeText
            inkDark = hex("inkDark") ?? inkDark
            inkMuted = hex("inkMuted") ?? inkMuted
            button = hex("button") ?? button
            accent = hex("accent") ?? accent

            // Card colors are indexed by `Card.colorIndex`, which the game
            // engine generates against the shipped count, so a short remote
            // array would crash on lookup. Take it only if it's complete.
            if let raw = json["cardColors"] as? [String] {
                let parsed = raw.compactMap { Color(hex: $0) }
                if parsed.count == raw.count && parsed.count >= cardColors.count {
                    cardColors = parsed
                }
            }
        }

        private init(
            background: Color, pill: Color, codeField: Color, codeText: Color,
            inkDark: Color, inkMuted: Color, button: Color, accent: Color,
            cardColors: [Color]
        ) {
            self.background = background
            self.pill = pill
            self.codeField = codeField
            self.codeText = codeText
            self.inkDark = inkDark
            self.inkMuted = inkMuted
            self.button = button
            self.accent = accent
            self.cardColors = cardColors
        }
    }
}

extension Color {
    /// Parses `#RRGGBB` / `#RRGGBBAA` (and the same without the `#`).
    init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6 || raw.count == 8,
              let value = UInt64(raw, radix: 16) else { return nil }

        let hasAlpha = raw.count == 8
        let shift = hasAlpha ? 8 : 0
        self.init(
            .sRGB,
            red: Double((value >> (16 + shift)) & 0xFF) / 255,
            green: Double((value >> (8 + shift)) & 0xFF) / 255,
            blue: Double((value >> shift) & 0xFF) / 255,
            opacity: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }
}
