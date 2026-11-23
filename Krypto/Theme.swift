import SwiftUI

/// The app palette. These now forward to `Remote.shared.palette`, so colors can
/// be restyled from the Firebase console without a new build; the values below
/// fall back to the exact shipped literals in `Remote.Palette.fallback` when
/// nothing has been fetched. Reads are cheap — the remote payload is parsed once
/// per activation, not per access.
///
/// `@MainActor` because the palette snapshot lives on `Remote`; every use of
/// `Theme` is from a SwiftUI view, which is already main-actor isolated.
@MainActor
enum Theme {
    static var background: Color { Remote.shared.palette.background }
    static var pill: Color { Remote.shared.palette.pill }
    /// Fixed light grey for code-entry fields (room codes, friend codes) — deliberately
    /// not a system-adaptive color, since the rest of the palette here is fixed too and
    /// mixing an adaptive grey with Theme.inkDark text goes unreadable in dark mode.
    static var codeField: Color { Remote.shared.palette.codeField }
    /// Darker neutral grey for code text itself (room codes, friend codes) — used on
    /// Theme.pill so the code reads as clearly grey rather than the ink-dark brown used elsewhere.
    static var codeText: Color { Remote.shared.palette.codeText }
    static var inkDark: Color { Remote.shared.palette.inkDark }
    static var inkMuted: Color { Remote.shared.palette.inkMuted }
    static var button: Color { Remote.shared.palette.button }
    static var accent: Color { Remote.shared.palette.accent }

    static var cardColors: [Color] { Remote.shared.palette.cardColors }
}
