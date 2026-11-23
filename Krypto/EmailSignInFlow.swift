import SwiftUI
import FirebaseAuth

/// The "Continue with email" path: one email field first, then — after a
/// server-side lookup (functions/src/auth.ts `checkEmail`) — either a
/// password page for an existing account or a short create-account page
/// for a new one. Replaces the old combined log-in / sign-up form, so the
/// provider buttons stay the headline and the email route costs one line.
///
/// Presented as a sheet with its own `NavigationStack`, so it works the
/// same from the profile sheet, Multiplayer and Competition regardless of
/// what navigation (if any) the host view sits in.
struct EmailSignInFlow: View {
    @ObservedObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss
    /// Prefilled next time, so a returning player taps Continue and types a
    /// password rather than re-entering their address.
    @AppStorage("lastSignInEmail") private var lastEmail = ""

    @State private var path: [Step] = []
    @State private var email = ""
    @State private var isChecking = false
    @State private var lookupError: String?
    @FocusState private var emailFocused: Bool

    enum Step: Hashable {
        case password(String)
        case create(String)
        /// The address has an account, but not a password one (Apple /
        /// Google / Game Center) — point them back at that button.
        case providerOnly(String, [String])
    }

    var body: some View {
        NavigationStack(path: $path) {
            emailPage
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .password(let address):
                        PasswordPage(auth: auth, email: address)
                    case .create(let address):
                        CreateAccountPage(auth: auth, email: address)
                    case .providerOnly(let address, let providers):
                        ProviderOnlyPage(email: address, providers: providers) { dismiss() }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
        .onAppear {
            if email.isEmpty { email = lastEmail }
            emailFocused = true
        }
    }

    private var emailPage: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                Text("What's your email?")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                Text("We'll check whether you already have an account.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($emailFocused)
                    .onSubmit { Task { await continueWithEmail() } }
                    .authFieldStyle()

                if let lookupError {
                    Text(lookupError)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                }

                AuthPrimaryButton(title: "Continue", isBusy: isChecking, enabled: Self.looksLikeEmail(email)) {
                    Task { await continueWithEmail() }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func continueWithEmail() async {
        lookupError = nil
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeEmail(address) else {
            lookupError = "That email address doesn't look valid."
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let result = try await EmailLookup.check(address)
            lastEmail = address
            if !result.exists {
                path.append(.create(address))
            } else if result.providers.contains("password") {
                path.append(.password(address))
            } else {
                path.append(.providerOnly(address, result.providers))
            }
        } catch {
            lookupError = "Couldn't check that email. Check your connection and try again."
        }
    }

    static func looksLikeEmail(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !trimmed.contains(" ")
    }
}

// MARK: - Lookup

enum EmailLookup {
    struct Result: Decodable {
        let exists: Bool
        let providers: [String]
    }

    /// `checkEmail` Cloud Function (functions/src/auth.ts).
    private static let endpoint = URL(string: "https://us-central1-krypto-game-em26.cloudfunctions.net/checkEmail")!

    static func check(_ email: String) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    /// "Apple", "Google", … for the provider ids Firebase reports.
    static func label(for providerId: String) -> String {
        switch providerId {
        case "apple.com": return "Apple"
        case "google.com": return "Google"
        case "gc.apple.com": return "Game Center"
        case "password": return "email"
        default: return providerId
        }
    }
}

// MARK: - Password (existing account)

private struct PasswordPage: View {
    @ObservedObject var auth: AuthService
    let email: String
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var resetMessage: String?
    @State private var isSendingReset = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                Text("Welcome back")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                AuthEmailPill(email: email)

                AuthPasswordField(title: "Password", text: $password, show: $showPassword, contentType: .password)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { Task { await logIn() } }

                HStack {
                    Spacer()
                    Button {
                        Task { await sendReset() }
                    } label: {
                        if isSendingReset {
                            ProgressView().tint(Theme.inkMuted)
                        } else {
                            Text("Forgot password?")
                        }
                    }
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .disabled(isSendingReset)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                if let resetMessage {
                    Text(resetMessage)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                }

                AuthPrimaryButton(title: "Log In", isBusy: isSubmitting, enabled: !password.isEmpty) {
                    Task { await logIn() }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationTitle("Log in")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func logIn() async {
        guard !password.isEmpty else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await auth.signIn(email: email, password: password)
        } catch {
            errorMessage = authErrorMessage(error)
        }
    }

    private func sendReset() async {
        isSendingReset = true
        resetMessage = nil
        defer { isSendingReset = false }
        do {
            try await auth.sendPasswordReset(email: email)
            resetMessage = "Password reset email sent to \(email). \(authSpamNote)"
        } catch {
            resetMessage = "Couldn't send reset email: \(authErrorMessage(error))"
        }
    }
}

// MARK: - Create account (new email)

private struct CreateAccountPage: View {
    @ObservedObject var auth: AuthService
    let email: String
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var friendCode = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var usernameFocused: Bool

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 6 && !isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                Text("Create your account")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                AuthEmailPill(email: email)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Username")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(Color(.darkGray))
                        .padding(.leading, 4)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($usernameFocused)
                        .authFieldStyle()
                }

                VStack(alignment: .leading, spacing: 6) {
                    AuthPasswordField(title: "Password", text: $password, show: $showPassword, contentType: .newPassword)
                    if !password.isEmpty && password.count < 6 {
                        Text("Password must be at least 6 characters.")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.75))
                            .padding(.leading, 4)
                    }
                }

                ReferralCodeField(code: $friendCode)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                        .multilineTextAlignment(.center)
                }

                AuthPrimaryButton(title: "Create Account", isBusy: isSubmitting, enabled: canSubmit) {
                    Task { await signUp() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Sign up")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { usernameFocused = true }
    }

    private func signUp() async {
        guard canSubmit else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        // Check the code before creating anything: once sign-up succeeds the
        // auth listener dismisses this flow, so a "bad code" message raised
        // afterwards would flash past unread.
        let code = friendCode.trimmingCharacters(in: .whitespaces)
        if !code.isEmpty {
            guard await CompetitionService.referrerUid(forCode: code) != nil else {
                errorMessage = "That friend code doesn't exist. Check it, or clear the field to continue without one."
                return
            }
        }
        do {
            try await auth.signUp(email: email, password: password, username: username.trimmingCharacters(in: .whitespaces))
            if !code.isEmpty, let uid = Auth.auth().currentUser?.uid {
                // Best-effort: the account exists by now, so a failed credit
                // must not read as a sign-up failure.
                if let referrerUid = try? await CompetitionService.redeem(code: code, uid: uid) {
                    // Shown by whichever screen is on top once this form is
                    // gone (see `ReferralThanks`).
                    await ReferralThanks.shared.post(referrerUid: referrerUid, myUid: uid)
                }
            }
        } catch {
            errorMessage = authErrorMessage(error)
        }
    }
}

// MARK: - Account exists via a provider

private struct ProviderOnlyPage: View {
    let email: String
    let providers: [String]
    let done: () -> Void

    private var providerNames: String {
        let names = providers.map(EmailLookup.label(for:)).filter { $0 != "email" }
        switch names.count {
        case 0: return "another sign-in method"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " or " + names.last!
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)
                Text("You signed up with \(providerNames)")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Theme.inkDark)
                    .multilineTextAlignment(.center)
                AuthEmailPill(email: email)
                Text("This address doesn't have a password. Use the \(providerNames) button to sign in.")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                AuthPrimaryButton(title: "Back to sign-in options", isBusy: false, enabled: true, action: done)
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared pieces

private struct AuthEmailPill: View {
    let email: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .font(.system(size: 13, weight: .semibold))
            Text(email)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white, in: Capsule())
    }
}

private struct AuthPasswordField: View {
    let title: String
    @Binding var text: String
    @Binding var show: Bool
    var contentType: UITextContentType = .password

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color(.darkGray))
                .padding(.leading, 4)
            HStack {
                Group {
                    if show {
                        TextField(title, text: $text)
                    } else {
                        SecureField(title, text: $text)
                    }
                }
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button { show.toggle() } label: {
                    Image(systemName: show ? "eye.slash" : "eye")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
                .accessibilityLabel(show ? "Hide password" : "Show password")
            }
            .authFieldStyle()
        }
    }
}

struct AuthPrimaryButton: View {
    let title: String
    let isBusy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy { ProgressView().tint(.white) }
                Text(title).opacity(isBusy ? 0 : 1)
            }
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(enabled ? Theme.button : Theme.button.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
        }
        .disabled(!enabled || isBusy)
    }
}

extension View {
    func authFieldStyle() -> some View {
        self
            .foregroundStyle(Theme.inkDark)
            .tint(Theme.inkDark)
            .padding()
            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))
    }
}
