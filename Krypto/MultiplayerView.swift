import SwiftUI

struct MultiplayerView: View {
    @ObservedObject var service: MultiplayerService
    @ObservedObject var auth: AuthService
    @ObservedObject var friends: FriendsService
    @Environment(\.dismiss) private var dismiss
    @State private var joinCode = ""
    @FocusState private var codeFieldFocused: Bool
    // Room settings, chosen by the host before creating — a joiner just
    // inherits whatever's already on the room doc, so these only matter here.
    @State private var roomMode: MultiplayerService.RoomMode = .firstToSolve
    @State private var lockWindowSeconds = 9
    @State private var hintsEnabled = true
    @State private var undosAllowed = true
    @State private var playerCount = 2
    @State private var showJoin = false
    @State private var showSamePhone = false
    /// Called when a match starts. The sheet form (over a board) dismisses
    /// itself instead; `MultiplayerHubView` passes this to open the board.
    var onMatchStarted: (() -> Void)? = nil

    /// Online rooms, or two players on this one phone. Remembered per device
    /// since it's about how the phone gets used, not the account.
    enum Surface: String, CaseIterable, Identifiable {
        case online, samePhone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .online: "Online"
            case .samePhone: "Same phone"
            }
        }
    }
    @AppStorage("multiplayer.surface") private var surfaceRaw = Surface.online.rawValue
    private var surface: Surface { Surface(rawValue: surfaceRaw) ?? .online }

    private let lockWindowChoices = [5, 9, 15]

    var body: some View {
        Group {
            // Online play needs an account (rooms, names, challenges). A match
            // on one phone needs nothing from the server, so it stays open to
            // signed-out players — the picker is reachable in both states.
            // Same header and picker position as `menuScreen`, so switching
            // tabs while signed out doesn't move the picker.
            if surface == .online, !auth.showsSignedInUI {
                VStack(spacing: 0) {
                    VStack(spacing: 24) {
                        header
                        surfacePicker
                    }
                    .padding(.horizontal, 28)
                    AuthSignInView(
                        auth: auth,
                        icon: "person.2.fill",
                        subtitle: "Sign in to race friends, create rooms, and send challenges.",
                        showsHeader: false
                    )
                }
            } else {
                menuScreen
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        .onChange(of: service.phase) { _, phase in
            guard phase == .playing else { return }
            if let onMatchStarted { onMatchStarted() } else { dismiss() }
        }
        .fullScreenCover(isPresented: $showSamePhone) {
            SamePhoneView(settings: .init(
                lockWindowSeconds: lockWindowSeconds, hintsEnabled: hintsEnabled, undosAllowed: undosAllowed
            ))
        }
    }

    private var surfacePicker: some View {
        Picker("Where to play", selection: $surfaceRaw) {
            ForEach(Surface.allCases) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Icon, title and tagline. Shared with the signed-out Online screen so
    /// the picker under it sits at the same height on both tabs.
    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.inkDark)
            Text("Multiplayer")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            if case .idle = service.phase {
                Text("Race a friend on the same hand.")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.top, 20)
    }

    private var menuScreen: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                switch service.phase {
                case .idle, .error:
                    surfacePicker
                    switch surface {
                    case .online:
                        menu
                        friendsSection
                    case .samePhone:
                        samePhoneMenu
                    }
                case .connecting:
                    ProgressView()
                        .padding(.vertical, 40)
                case .waiting(let code):
                    waitingRoom(code: code)
                case .playing:
                    EmptyView()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    private var menu: some View {
        VStack(spacing: 22) {
            if case .error(let message) = service.phase {
                Text(message)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            modeCards
            settingsList

            VStack(spacing: 12) {
                Button {
                    service.myName = auth.multiplayerName
                    Task {
                        await service.createRoom(
                            mode: roomMode, lockWindowSeconds: lockWindowSeconds,
                            hintsEnabled: hintsEnabled, undosAllowed: undosAllowed, maxPlayers: playerCount
                        )
                    }
                } label: {
                    Label("Create Room", systemImage: "plus.circle.fill")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Theme.button, in: RoundedRectangle(cornerRadius: 20))
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showJoin.toggle() }
                    codeFieldFocused = showJoin
                } label: {
                    Label("Join with Code", systemImage: "qrcode")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.inkDark)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Theme.inkMuted.opacity(0.35), lineWidth: 1.5)
                        )
                }

                if showJoin {
                    joinRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Same phone

    /// Setup for a match on this phone. Buzz to Answer is the only mode: two
    /// people can't race on one set of cards, so the first to see it buzzes
    /// and gets the floor. Players are fixed at two (one per end of the phone).
    private var samePhoneMenu: some View {
        VStack(spacing: 22) {
            HStack(spacing: 16) {
                samePhonePreview
                Text("Lay the phone flat between you. The numbers face both players, and each of you buzzes from your own end.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            )

            samePhoneSettings

            Button { showSamePhone = true } label: {
                Label("Start Game", systemImage: "play.fill")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    /// Two tiny rows of cards, the top one upside down: each player reads
    /// their own row.
    private var samePhonePreview: some View {
        VStack(spacing: 6) {
            previewRow.rotationEffect(.degrees(180))
            previewRow
        }
        .frame(width: 104)
    }

    private var previewRow: some View {
        HStack(spacing: 5) {
            ForEach(Array(["6", "12", "3"].enumerated()), id: \.offset) { index, value in
                CardFace(text: value, isWhole: true, height: 36, width: 30, facing: .oneWay)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Theme.cardColors[index % max(Theme.cardColors.count, 1)])
                    )
            }
        }
    }

    private var samePhoneSettings: some View {
        VStack(spacing: 0) {
            settingsRow(icon: "bolt.fill", title: "Buzz to Answer") {
                Text("2 players")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.pill, in: Capsule())
            }
            Divider()
            settingsRow(icon: "clock", title: "Solve window") {
                lockWindowPicker
            }
            Divider()
            settingsRow(icon: "arrow.uturn.backward", title: "Undos allowed") {
                Toggle("", isOn: $undosAllowed).labelsHidden().tint(Theme.button)
            }
            Divider()
            settingsRow(icon: "lightbulb", title: "Hints") {
                Toggle("", isOn: $hintsEnabled).labelsHidden().tint(Theme.button)
            }
        }
    }

    private var lockWindowPicker: some View {
        HStack(spacing: 2) {
            ForEach(lockWindowChoices, id: \.self) { seconds in
                let selected = lockWindowSeconds == seconds
                Button { lockWindowSeconds = seconds } label: {
                    Text("\(seconds)s")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(selected ? .white : Theme.inkDark)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selected ? Theme.button : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.pill, in: Capsule())
    }

    // MARK: - Mode cards

    private var modeCards: some View {
        HStack(spacing: 14) {
            modeCard(
                .firstToSolve, icon: "clock", tint: Theme.inkDark,
                title: "First to Submit", subtitle: "Fastest correct answer wins"
            )
            modeCard(
                .buzzIn, icon: "bolt.fill", tint: Theme.accent,
                title: "Buzz to Answer", subtitle: "First to buzz gets a chance to solve."
            )
        }
    }

    private func modeCard(
        _ mode: MultiplayerService.RoomMode, icon: String, tint: Color, title: String, subtitle: String
    ) -> some View {
        let selected = roomMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { roomMode = mode }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(height: 44)
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                ZStack {
                    Circle()
                        .stroke(selected ? Theme.button : Theme.inkMuted.opacity(0.35), lineWidth: 2.5)
                        .frame(width: 26, height: 26)
                    if selected {
                        Circle().fill(Theme.button).frame(width: 26, height: 26)
                        Circle().fill(.white).frame(width: 9, height: 9)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(selected ? Theme.pill : .white)
                    .shadow(color: .black.opacity(selected ? 0.04 : 0.06), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(selected ? Theme.accent.opacity(0.9) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings rows (host only, applied when creating)

    private var settingsList: some View {
        VStack(spacing: 0) {
            settingsRow(icon: "person.2", title: "Players") {
                HStack(spacing: 0) {
                    stepperButton("minus", enabled: playerCount > 2) { playerCount -= 1 }
                    Text("\(playerCount)")
                        .font(.system(.headline, design: .rounded, weight: .heavy))
                        .foregroundStyle(Theme.inkDark)
                        .frame(width: 34)
                        .monospacedDigit()
                    stepperButton("plus", enabled: playerCount < 6) { playerCount += 1 }
                }
                .padding(4)
                .background(Theme.pill, in: Capsule())
            }
            if playerCount > 2 {
                Text("Everyone joins a lobby with the code — you start the game when they're all in.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }
            Divider()
            if roomMode == .buzzIn {
                settingsRow(icon: "clock", title: "Solve window") {
                    lockWindowPicker
                }
                Divider()
            }
            settingsRow(icon: "arrow.uturn.backward", title: "Undos allowed") {
                Toggle("", isOn: $undosAllowed).labelsHidden().tint(Theme.button)
            }
            Divider()
            settingsRow(icon: "lightbulb", title: "Hints") {
                Toggle("", isOn: $hintsEnabled).labelsHidden().tint(Theme.button)
            }
        }
    }

    private func settingsRow<Trailing: View>(icon: String, title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.inkDark)
                .frame(width: 26)
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkDark)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            trailing()
                .fixedSize()
        }
        .padding(.vertical, 14)
    }

    private func stepperButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? Theme.inkDark : Theme.inkMuted.opacity(0.4))
                .frame(width: 32, height: 32)
        }
        .disabled(!enabled)
    }

    // MARK: - Join with code

    private var joinRow: some View {
        HStack(spacing: 10) {
            ZStack {
                if joinCode.isEmpty {
                    Text("XXXX")
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                        .foregroundStyle(Theme.codeText.opacity(0.6))
                }
                TextField("", text: $joinCode)
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.codeText)
                    .tint(Theme.codeText)
                    .focused($codeFieldFocused)
                    .onChange(of: joinCode) { _, value in
                        joinCode = String(value.prefix(4)).uppercased()
                    }
            }
            .frame(height: 56)
            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 18))

            Button {
                service.myName = auth.multiplayerName
                Task { await service.joinRoom(joinCode) }
            } label: {
                Text("Join")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 100, height: 56)
                    .background(
                        joinCode.count == 4 ? Theme.button : Theme.button.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
            }
            .disabled(joinCode.count != 4)
        }
    }

    // MARK: - Challenge a friend

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.vertical, 4)

            Text("CHALLENGE A FRIEND")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Theme.inkMuted)

            if friends.friends.isEmpty {
                Text("Add friends from your profile to challenge them here.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            } else {
                VStack(spacing: 8) {
                    ForEach(friends.friends) { friend in
                        HStack {
                            Text(friend.displayName)
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .foregroundStyle(Theme.inkDark)
                            Spacer()
                            Button("Challenge") {
                                Task { await challenge(friend) }
                            }
                            .font(.system(.footnote, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Theme.button, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.codeField, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func challenge(_ friend: Friend) async {
        guard let uid = auth.user?.uid else { return }
        // Resolve the challenger's name once and use it for both the room (so the
        // opponent sees it in-game) and the challenge push — never a placeholder.
        let myName = auth.multiplayerName
        service.myName = myName
        await service.createRoom(mode: roomMode, lockWindowSeconds: lockWindowSeconds, hintsEnabled: hintsEnabled, undosAllowed: undosAllowed)
        guard let code = service.roomCode else { return }
        await friends.sendChallenge(to: friend.id, roomCode: code, myUid: uid, myName: myName)
    }

    private func waitingRoom(code: String) -> some View {
        VStack(spacing: 18) {
            Text("Share this code")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)

            Text(code)
                .font(.system(size: 54, weight: .heavy, design: .monospaced))
                .kerning(10)
                .foregroundStyle(Theme.inkDark)
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                )

            if service.isCustomRoom {
                lobbyRoster
                if service.isHost {
                    Button {
                        service.startGame()
                    } label: {
                        Text("Start Game")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                service.lobbyPlayers.count >= 2 ? Theme.button : Theme.button.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 18)
                            )
                    }
                    .disabled(service.lobbyPlayers.count < 2)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for the host to start…")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for opponent…")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                }
            }

            Button(service.isCustomRoom && !service.isHost ? "Leave" : "Cancel") {
                service.leave()
            }
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(Theme.inkMuted)
        }
    }

    private var lobbyRoster: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PLAYERS \(service.lobbyPlayers.count)/\(service.maxPlayers)")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Theme.inkMuted)
            ForEach(service.lobbyPlayers) { player in
                HStack(spacing: 8) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(player.name)
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkDark)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
    }
}
