import SwiftUI

/// Shown once after a provider sign-in creates a new account (see
/// `AuthService.pendingUsernamePrompt`). The field is prefilled with the
/// generated handle, so keeping it is a single tap; typing a new one moves
/// the reservation via `changeUsername`. Swiping the sheet away keeps the
/// generated handle too, so there is no way to end up nameless.
struct ChooseUsernameSheet: View {
    @ObservedObject var auth: AuthService
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var suggestion: String { auth.pendingUsernamePrompt ?? "" }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUnchanged: Bool { trimmed == suggestion }
    private var canContinue: Bool { !trimmed.isEmpty && !isSaving }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accent)
                .padding(.top, 28)
            Text("Choose your username")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            Text("This is how friends find you and how you appear to opponents. You can change it later in your profile.")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                Text("Username")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(Color(.darkGray))
                    .padding(.leading, 4)
                TextField("Username", text: $name)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
                    .authFieldStyle()
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            AuthPrimaryButton(title: isUnchanged ? "Keep This Name" : "Continue", isBusy: isSaving, enabled: canContinue) {
                Task { await save() }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            name = suggestion
            focused = true
        }
    }

    private func save() async {
        guard canContinue else { return }
        if isUnchanged {
            auth.pendingUsernamePrompt = nil
            return
        }
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.changeUsername(to: trimmed)
            auth.pendingUsernamePrompt = nil
        } catch {
            errorMessage = authErrorMessage(error)
        }
    }
}

extension View {
    /// Presents `ChooseUsernameSheet` whenever `auth` has a pending prompt.
    /// Attach to the screen that owns the `AuthService` a provider sign-in
    /// ran through (the Profile sheet, Competition Mode).
    func chooseUsernamePrompt(auth: AuthService) -> some View {
        sheet(isPresented: Binding(
            get: { auth.pendingUsernamePrompt != nil },
            set: { if !$0 { auth.pendingUsernamePrompt = nil } }
        )) {
            ChooseUsernameSheet(auth: auth)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.background)
        }
    }
}
