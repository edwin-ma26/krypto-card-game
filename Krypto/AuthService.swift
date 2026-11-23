import Foundation
import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices
import CryptoKit
import GoogleSignIn
import GameKit
import FirebaseCore
import UIKit

/// Firebase's auth emails send from a shared no-reply domain, so they
/// frequently land in spam. Shown after any reset/verification email is sent.
let authSpamNote = "Don't see it? Check your spam or junk folder for an email from noreply@kryptopuzzle.com."

/// Firebase's raw error strings (e.g. "The supplied auth credential is
/// malformed or has expired") are meant for developers, not end users.
/// Translate the common ones into plain language before showing them.
/// Errors raised by our own username-reservation logic (see
/// `AuthService.reserveUsername`), kept in a dedicated domain so
/// `authErrorMessage` can hand their message straight through rather than
/// mistaking the code for a Firebase `AuthErrorCode`.
let usernameErrorDomain = "Krypto.Username"

func usernameTakenError() -> NSError {
    NSError(domain: usernameErrorDomain, code: 1, userInfo: [
        NSLocalizedDescriptionKey: "That username is already taken. Please choose another.",
    ])
}

func authErrorMessage(_ error: Error) -> String {
    if (error as NSError).domain == usernameErrorDomain {
        return error.localizedDescription
    }
    guard let code = AuthErrorCode(rawValue: (error as NSError).code) else {
        return error.localizedDescription
    }
    switch code {
    case .invalidEmail:
        return "That email address doesn't look valid."
    case .wrongPassword, .userNotFound, .invalidCredential:
        return "Incorrect email or password."
    case .emailAlreadyInUse:
        return "An account with that email already exists."
    case .weakPassword:
        return "Password should be at least 6 characters."
    case .userDisabled:
        return "This account has been disabled."
    case .tooManyRequests:
        return "Too many attempts. Please wait a bit and try again."
    case .networkError:
        return "Network error — check your connection and try again."
    case .requiresRecentLogin:
        return "For your security, please sign in again and retry."
    case .userMismatch:
        return "That's a different account. Choose the one you're signed in with."
    default:
        return error.localizedDescription
    }
}

@MainActor
final class AuthService: ObservableObject {
    @Published var user: FirebaseAuth.User?

    /// True only for a real account (email, Apple, Google). The anonymous
    /// session `ensureSignedIn` creates on launch doesn't count: multiplayer,
    /// ranked, and the profile all require an identifiable player.
    var isSignedIn: Bool {
        guard let user else { return false }
        return !user.isAnonymous
    }

    /// `isSignedIn`, held back until a provider sign-in has finished seeding
    /// the profile. Use for the signed-in / signed-out view switch.
    var showsSignedInUI: Bool { isSignedIn && !isFinishingProviderSignIn }

    /// Whether the account has an email/password credential. Profile UI that
    /// edits the email, changes the password, or nags about verification only
    /// applies to those accounts, not Apple / Google / Game Center ones.
    var hasPasswordProvider: Bool {
        user?.providerData.contains { $0.providerID == "password" } ?? false
    }

    /// Short label for the provider a social account signed in with, for the
    /// profile header when there's no email to show.
    var signInMethodLabel: String? {
        guard let ids = user?.providerData.map(\.providerID) else { return nil }
        if ids.contains("gc.apple.com") { return "Game Center" }
        if ids.contains("google.com") { return "Google" }
        if ids.contains("apple.com") { return "Apple" }
        return nil
    }
    @Published var isEmailVerified: Bool = false

    // Cached Firestore profile fields (display name, friend code, premium
    // status) shown by ProfileView. Keeping this on the service — rather
    // than in the view's local @State — lets the profile sheet render
    // instantly on repeat opens instead of re-fetching from Firestore
    // (and showing a blank/loading state) every single time it's presented.
    @Published var cachedDisplayName: String = ""
    @Published var cachedFriendCode: String = ""
    /// Set when a provider sign-in (Apple, Google, Game Center) has just
    /// minted a generated handle for a brand-new account, holding that
    /// handle. The owning screen presents `ChooseUsernameSheet` so the
    /// player can keep it with one tap or pick their own; email sign-up asks
    /// for a username up front, so it never sets this.
    @Published var pendingUsernamePrompt: String?
    /// True while an Apple / Google / Game Center sign-in has a Firebase
    /// session but is still seeding the profile (reading the user doc,
    /// reserving a handle, minting a friend code). The auth listener flips
    /// `isSignedIn` as soon as the session exists, which would swap the
    /// sign-in form for the profile hub a second or two before the username
    /// prompt is ready; screens gate on `showsSignedInUI` so the swap and the
    /// prompt land together.
    @Published private(set) var isFinishingProviderSignIn = false
    @Published var cachedIsPremium: Bool = false
    private var cachedProfileUid: String?

    /// True from the moment `signUp` creates the auth account until it has
    /// finished writing the profile. The auth listener fires as soon as the
    /// account exists, which swaps the profile sheet over to its signed-in
    /// view and starts `loadProfile` — against a `users/{uid}` doc that
    /// `reserveUsername` is still in the middle of writing. Without this flag
    /// that load sees no display name and "self-heals" a random handle,
    /// silently discarding the username the player just typed.
    private var isCreatingAccount = false

    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        // Firebase restores the persisted session synchronously, but the
        // state listener below only reports it on a later turn of the run
        // loop. Seed from `currentUser` now so views that read `user` in
        // their first `.task` (the daily puzzle, the profile sheet) don't
        // briefly see a signed-out state on cold launch.
        user = Auth.auth().currentUser
        isEmailVerified = user?.isEmailVerified ?? false
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.user = user
            self?.isEmailVerified = user?.isEmailVerified ?? false
        }
    }

    var hasCachedProfile: Bool { cachedProfileUid != nil }

    /// Loads the Firestore profile doc for `uid` and caches it. Skips the
    /// network round-trip entirely if we already have a cached profile for
    /// this uid, unless `forceRefresh` is set (e.g. after editing a field).
    func loadProfile(uid: String, forceRefresh: Bool = false) async {
        guard forceRefresh || cachedProfileUid != uid else { return }
        // An anonymous session has no identity to name. Without this guard the
        // self-heal below would mint a "player1234" handle for a signed-out
        // player, reserve it in `usernames`, and show it as if they had an
        // account. Signed-out players stay nameless; UI falls back to "Player".
        guard isSignedIn else { return }
        let data = try? await Firestore.firestore().collection("users").document(uid).getDocument().data()
        // The Firestore profile doc is only created once the user opens
        // Competition Mode, so before that, fall back to the username
        // entered at sign-up.
        let storedName = data?["displayName"] as? String
        if let storedName, !storedName.isEmpty {
            cachedDisplayName = storedName
        } else if cachedDisplayName.isEmpty {
            // No name in Firestore (doc not created yet) — fall back to the
            // auth profile name. Guard on the cache being empty so we never
            // clobber a name that sign-up set directly while this ran (the
            // auth-listener race described in `signUp`).
            cachedDisplayName = user?.displayName ?? ""
        }
        cachedFriendCode = data?["referralCode"] as? String ?? ""
        cachedIsPremium = data?["isPremium"] as? Bool ?? false
        cachedProfileUid = uid

        // Self-heal a nameless profile. A `users/{uid}` doc can exist without a
        // `displayName` — e.g. `saveFCMToken` creates one with only an fcmToken
        // for a user who signed in but never finished profile creation. Such an
        // account shows up as "Player" in other people's friends lists. Backfill
        // a name so every account is always identifiable: reuse whatever name we
        // resolved above, or mint a unique handle when there's none anywhere.
        //
        // Skipped mid-sign-up: the doc legitimately has no name yet because
        // `reserveUsername` hasn't landed, and healing it here would overwrite
        // the player's chosen username with a generated one.
        if (storedName ?? "").isEmpty && !isCreatingAccount {
            if !cachedDisplayName.isEmpty {
                try? await Firestore.firestore().collection("users").document(uid)
                    .setData(["displayName": cachedDisplayName], merge: true)
            } else {
                try? await ensureProfile(uid: uid, email: user?.email ?? "", suggestedName: user?.displayName)
            }
        }

        await ensureFriendCode(uid: uid)

        // Email changes only take effect once the user confirms the link
        // Firebase sends to the new address, so keep Firestore in sync here.
        if let authEmail = user?.email, let storedEmail = data?["email"] as? String, authEmail != storedEmail {
            try? await Firestore.firestore().collection("users").document(uid).updateData(["email": authEmail])
        }
    }

    /// Mints this account's referral code if it doesn't have one, caching it.
    ///
    /// Codes used to be minted only by Competition Mode's profile creation,
    /// which is locked until launch — so every account created in the meantime
    /// has none, and its invites go out with nothing to attribute them by.
    /// Called from all three paths that can finish establishing a profile,
    /// because each sets `cachedProfileUid` and would otherwise short-circuit
    /// `loadProfile` before it got here. Idempotent, so existing accounts are
    /// backfilled on their next sign-in and no migration script is needed.
    private func ensureFriendCode(uid: String) async {
        guard cachedFriendCode.isEmpty else { return }
        cachedFriendCode = await CompetitionService.ensureReferralCode(uid: uid) ?? ""
    }

    /// The name shown to multiplayer opponents: the signed-in display name, or a
    /// generic fallback. Never falls back to the email prefix — `loadProfile`'s
    /// self-heal hasn't necessarily finished by the time a room is created/joined,
    /// and leaking even part of an email to a stranger opponent is worse than a
    /// placeholder name.
    var multiplayerName: String {
        guard isSignedIn else { return "Player" }
        let cached = cachedDisplayName.trimmingCharacters(in: .whitespaces)
        return cached.isEmpty ? "Player" : cached
    }

    func updateCachedDisplayName(_ name: String) {
        cachedDisplayName = name
    }

    func updateCachedIsPremium(_ isPremium: Bool) {
        cachedIsPremium = isPremium
    }

    /// Stores this device's push token on the signed-in user's profile doc
    /// so Cloud Functions can look it up to send friend-request/accept pushes.
    func saveFCMToken(_ token: String) {
        guard let uid = user?.uid else { return }
        Task {
            try? await Firestore.firestore().collection("users").document(uid)
                .setData(["fcmToken": token], merge: true)
        }
    }

    func clearProfileCache() {
        cachedProfileUid = nil
        cachedDisplayName = ""
        cachedFriendCode = ""
        cachedIsPremium = false
    }

    deinit {
        if let handle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    func signUp(email: String, password: String, username: String) async throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreatingAccount = true
        defer { isCreatingAccount = false }
        try await createOrLinkEmailAccount(email: email, password: password)
        guard let uid = Auth.auth().currentUser?.uid else { return }

        // Reserve the username before doing anything else. Firebase already
        // created the account by this point, so if the name is taken we tear
        // that account back down — otherwise the email would be stuck
        // "registered" against a half-made account the user can't complete.
        do {
            try await reserveUsername(username, uid: uid, email: email)
        } catch {
            try? await Auth.auth().currentUser?.delete()
            try? Auth.auth().signOut()
            throw error
        }

        let changeRequest = Auth.auth().currentUser?.createProfileChangeRequest()
        changeRequest?.displayName = username
        try? await changeRequest?.commitChanges()
        // The auth state listener fires as soon as createUser succeeds, before
        // the display name commit above resolves. That can race with
        // loadProfile (triggered by the new uid) caching an empty name, with
        // nothing to refresh it afterward. Set the cache directly here so
        // sign-up always ends with the right name regardless of that race.
        cachedDisplayName = username
        cachedProfileUid = uid
        await ensureFriendCode(uid: uid)
        try? await Auth.auth().currentUser?.sendEmailVerification()
    }

    /// Claims `username` (case-insensitively) for `uid` in a single
    /// transaction, writing both the reservation doc under `usernames/` and
    /// the user's own profile doc. Throws `usernameTakenError()` if another
    /// account already holds the name. The transaction is what makes the
    /// check-then-claim atomic: two people racing for the same name can't both
    /// win, because Firestore aborts and retries on a conflicting write.
    private func reserveUsername(_ username: String, uid: String, email: String) async throws {
        guard !username.isEmpty else {
            throw NSError(domain: usernameErrorDomain, code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Please enter a username.",
            ])
        }
        let key = username.lowercased()
        let db = Firestore.firestore()
        try await db.runTransaction { transaction, errorPointer -> Any? in
            let nameRef = db.collection("usernames").document(key)
            let existing: DocumentSnapshot
            do {
                existing = try transaction.getDocument(nameRef)
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
            if existing.exists, existing.data()?["uid"] as? String != uid {
                errorPointer?.pointee = usernameTakenError()
                return nil
            }
            transaction.setData(["uid": uid, "displayName": username], forDocument: nameRef)
            // Write the profile doc so the account is findable by username
            // (Friends) regardless of whether Competition Mode's own
            // profile-creation path ever runs for this user.
            transaction.setData([
                "displayName": username,
                "email": email,
            ], forDocument: db.collection("users").document(uid), merge: true)
            return nil
        }
    }

    /// Changes the signed-in user's username, moving the `usernames/`
    /// reservation from the old name to the new one and updating the profile
    /// doc — all atomically, so the rename can't leave a dangling reservation
    /// or collide with someone taking the new name at the same moment. Throws
    /// `usernameTakenError()` if the new name belongs to another account.
    func changeUsername(to rawName: String) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            throw NSError(domain: usernameErrorDomain, code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Please enter a username.",
            ])
        }
        let newKey = newName.lowercased()
        let db = Firestore.firestore()
        try await db.runTransaction { transaction, errorPointer -> Any? in
            let userRef = db.collection("users").document(uid)
            let newRef = db.collection("usernames").document(newKey)
            // All reads must precede all writes in a Firestore transaction.
            let userSnap: DocumentSnapshot
            let newSnap: DocumentSnapshot
            do {
                userSnap = try transaction.getDocument(userRef)
                newSnap = try transaction.getDocument(newRef)
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
            if newSnap.exists, newSnap.data()?["uid"] as? String != uid {
                errorPointer?.pointee = usernameTakenError()
                return nil
            }
            let oldName = userSnap.data()?["displayName"] as? String ?? ""
            let oldKey = oldName.lowercased()
            if !oldKey.isEmpty, oldKey != newKey {
                transaction.deleteDocument(db.collection("usernames").document(oldKey))
            }
            transaction.setData(["uid": uid, "displayName": newName], forDocument: newRef)
            transaction.updateData(["displayName": newName], forDocument: userRef)
            return nil
        }
        cachedDisplayName = newName
    }

    /// Re-sends the verification link to the signed-in user's current email.
    func sendEmailVerification() async throws {
        guard let currentUser = Auth.auth().currentUser else { return }
        try await currentUser.sendEmailVerification()
    }

    /// Firebase doesn't push verification status changes, so callers need to
    /// reload the user (e.g. when a screen appears) to pick up a fresh value.
    func refreshEmailVerificationStatus() async {
        try? await Auth.auth().currentUser?.reload()
        isEmailVerified = Auth.auth().currentUser?.isEmailVerified ?? false
    }

    func sendPasswordReset(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    func signIn(email: String, password: String) async throws {
        // If they're mid-anonymous-session this replaces it with the real
        // account (uid changes). The anonymous uid — and its unused referral
        // code — is simply abandoned; there's nothing to migrate because a
        // pre-existing real account already has its own code and records.
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    // MARK: - Anonymous session

    /// Guarantees there is always a Firebase session — anonymous until the
    /// player creates a real account. This is what gives a not-yet-signed-up
    /// sharer a stable uid, so `ensureReferralCode` has something to mint a
    /// code against and an invite actually carries a redeemable code. When they
    /// later sign up, `signUp` / `completeAppleSignIn` link the new credential
    /// onto this same uid, so the referral code, `referrals` records and
    /// Founding Pup badge all carry over untouched.
    ///
    /// No-ops once any session exists, so it's safe to call on every launch.
    /// Requires Anonymous sign-in to be enabled in the Firebase console
    /// (Authentication → Sign-in method).
    func ensureSignedIn() async {
        guard Auth.auth().currentUser == nil else { return }
        do {
            let result = try await Auth.auth().signInAnonymously()
            cachedFriendCode = await CompetitionService.ensureReferralCode(uid: result.user.uid) ?? ""
        } catch {
            // Non-fatal: the app still runs signed-out, invites just won't
            // carry a code until a session is established on a later launch.
        }
    }

    /// Creates a fresh email/password account, or — when the player is in an
    /// anonymous session — upgrades that session in place so its uid (and
    /// everything keyed to it) is kept. Falls back to a normal create when the
    /// anonymous link can't be used (email already registered, or this session
    /// was already upgraded on another device).
    private func createOrLinkEmailAccount(email: String, password: String) async throws {
        if let current = Auth.auth().currentUser, current.isAnonymous {
            do {
                try await current.link(with: EmailAuthProvider.credential(withEmail: email, password: password))
                return
            } catch {
                guard let code = AuthErrorCode(rawValue: (error as NSError).code),
                      code == .emailAlreadyInUse || code == .credentialAlreadyInUse || code == .providerAlreadyLinked
                else { throw error }
                // Fall through: abandon the anonymous uid and create/join the
                // account the normal way. A duplicate-email create re-throws
                // `.emailAlreadyInUse`, which is the right thing to show.
            }
        }
        try await Auth.auth().createUser(withEmail: email, password: password)
    }

    /// Like `Auth.signIn(with:)`, but upgrades an anonymous session in place
    /// when there is one, so the pre-sign-up uid (and its referral code /
    /// `referrals` / badge) is preserved. If the Apple identity already exists
    /// as its own user, falls back to a plain sign-in with whatever credential
    /// Firebase hands back.
    private func signInOrLink(with credential: AuthCredential) async throws -> AuthDataResult {
        if let current = Auth.auth().currentUser, current.isAnonymous {
            do {
                return try await current.link(with: credential)
            } catch {
                let nsError = error as NSError
                guard let code = AuthErrorCode(rawValue: nsError.code),
                      code == .credentialAlreadyInUse || code == .emailAlreadyInUse
                else { throw error }
                let updated = nsError.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential
                return try await Auth.auth().signIn(with: updated ?? credential)
            }
        }
        return try await Auth.auth().signIn(with: credential)
    }

    // MARK: - Sign in with Apple

    /// The raw nonce for the in-flight Apple request. Apple signs a SHA-256 hash
    /// of it; Firebase needs the raw value back to verify the returned token.
    private var currentAppleNonce: String?

    /// Configures the Apple ID request (scopes + hashed nonce). Wire this to
    /// `SignInWithAppleButton`'s `onRequest`.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Exchanges the Apple authorization for a Firebase session, creating a
    /// profile + generated username the first time. Wire this to the button's
    /// `onCompletion` success case.
    func completeAppleSignIn(_ authorization: ASAuthorization) async throws {
        guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let nonce = currentAppleNonce,
              let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8)
        else {
            throw NSError(domain: usernameErrorDomain, code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't complete Sign in with Apple. Please try again.",
            ])
        }
        currentAppleNonce = nil
        let credential = OAuthProvider.appleCredential(withIDToken: idToken,
                                                       rawNonce: nonce,
                                                       fullName: appleCredential.fullName)
        isFinishingProviderSignIn = true
        defer { isFinishingProviderSignIn = false }
        let result = try await signInOrLink(with: credential)
        // Apple only returns name/email on the very first authorization, so we
        // must seed the profile now if this is a brand-new account.
        try await finishProviderSignIn(uid: result.user.uid,
                                       email: result.user.email ?? appleCredential.email ?? "",
                                       suggestedName: appleCredential.fullName?.givenName)
    }

    // MARK: - Sign in with Google

    /// Runs the Google sign-in sheet over `presenting`, then exchanges the
    /// resulting ID token for a Firebase session via `signInOrLink`, so an
    /// anonymous session is upgraded in place just like the Apple path.
    /// Throws `GIDSignInError.canceled` when the user dismisses the sheet.
    func signInWithGoogle(presenting: UIViewController) async throws {
        let (credential, googleUser) = try await requestGoogleCredential(presenting: presenting)
        isFinishingProviderSignIn = true
        defer { isFinishingProviderSignIn = false }
        let authResult = try await signInOrLink(with: credential)
        try await finishProviderSignIn(uid: authResult.user.uid,
                                       email: authResult.user.email ?? googleUser.profile?.email ?? "",
                                       suggestedName: googleUser.profile?.givenName)
    }

    /// Runs the Google sheet and returns a Firebase credential for the chosen
    /// account, shared by first sign-in and by re-authentication.
    private func requestGoogleCredential(presenting: UIViewController) async throws -> (AuthCredential, GIDGoogleUser) {
        // The SDK raises an ObjC exception (hard crash) if it has no client ID
        // when the sheet is requested, so configure it from Firebase's options
        // right before use rather than relying on an Info.plist key.
        if GIDSignIn.sharedInstance.configuration == nil {
            guard let clientID = FirebaseApp.app()?.options.clientID else {
                throw NSError(domain: usernameErrorDomain, code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Google sign-in isn't configured for this build.",
                ])
            }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
        guard let idToken = result.user.idToken?.tokenString else {
            throw NSError(domain: usernameErrorDomain, code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't complete Google sign-in. Please try again.",
            ])
        }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                       accessToken: result.user.accessToken.tokenString)
        return (credential, result.user)
    }

    // MARK: - Sign in with Game Center

    /// Authenticates the device's Game Center player (presenting Apple's
    /// sign-in UI over `presenting` if needed), then exchanges that for a
    /// Firebase session via `signInOrLink`. Requires the Game Center
    /// capability and the provider enabled in the Firebase console.
    func signInWithGameCenter(presenting: UIViewController) async throws {
        let player = GKLocalPlayer.local
        if !player.isAuthenticated {
            let notSignedIn = NSError(domain: usernameErrorDomain, code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Game Center isn't signed in on this device. Sign in under Settings › Game Center, then try again.",
            ])
            let timedOut = NSError(domain: usernameErrorDomain, code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Game Center didn't respond. Check that you're signed in under Settings › Game Center, then try again.",
            ])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // GameKit may call this handler more than once (once with a
                // view controller to show, again with the result), and on some
                // devices never at all, so resume exactly once and time out
                // unless Apple's own sign-in UI is up and waiting on the user.
                let gate = OnceGate(continuation)
                var presentedUI = false
                player.authenticateHandler = { viewController, error in
                    if let viewController {
                        presentedUI = true
                        presenting.present(viewController, animated: true)
                        return
                    }
                    if let error {
                        // GameKit's "not authenticated" wording is for
                        // developers; tell the player what to actually do.
                        let nsError = error as NSError
                        let isNotSignedIn = nsError.domain == GKErrorDomain
                            && nsError.code == GKError.notAuthenticated.rawValue
                        gate.finish(.failure(isNotSignedIn ? notSignedIn : error))
                    } else if player.isAuthenticated {
                        gate.finish(.success(()))
                    } else {
                        gate.finish(.failure(notSignedIn))
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if !presentedUI { gate.finish(.failure(timedOut)) }
                }
            }
        }
        let credential = try await GameCenterAuthProvider.getCredential()
        isFinishingProviderSignIn = true
        defer { isFinishingProviderSignIn = false }
        let result = try await signInOrLink(with: credential)
        try await finishProviderSignIn(uid: result.user.uid,
                                       email: result.user.email ?? "",
                                       suggestedName: player.alias)
    }

    /// Resumes a continuation at most once, from whichever caller gets there
    /// first (GameKit's handler or the timeout task).
    private final class OnceGate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Error>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    /// Ensures a signed-in user has a Firestore profile + reserved username,
    /// generating a unique one when there isn't a name yet (the Apple path,
    /// where the user never typed one).
    /// Returns true when it had to mint a handle, i.e. this is a new (or
    /// never-named) account rather than a returning one.
    @discardableResult
    private func ensureProfile(uid: String, email: String, suggestedName: String?) async throws -> Bool {
        let db = Firestore.firestore()
        let existing = try? await db.collection("users").document(uid).getDocument().data()
        if let name = existing?["displayName"] as? String, !name.isEmpty {
            cachedDisplayName = name
            cachedProfileUid = uid
            await ensureFriendCode(uid: uid)
            return false
        }
        let base = (suggestedName ?? "player").lowercased().filter { $0.isLetter || $0.isNumber }
        let baseName = base.isEmpty ? "player" : String(base.prefix(12))
        // Reserve a random, unique handle. Retry on the rare collision.
        for _ in 0..<10 {
            let candidate = "\(baseName)\(Int.random(in: 1000...9999))"
            do {
                try await reserveUsername(candidate, uid: uid, email: email)
                let changeRequest = Auth.auth().currentUser?.createProfileChangeRequest()
                changeRequest?.displayName = candidate
                try? await changeRequest?.commitChanges()
                cachedDisplayName = candidate
                cachedProfileUid = uid
                await ensureFriendCode(uid: uid)
                return true
            } catch let error as NSError where error.domain == usernameErrorDomain && error.code == 1 {
                continue // handle taken — try another
            }
        }
        return false
    }

    /// Shared tail of the provider sign-ins: seed the profile, and if that
    /// minted a handle, queue the username prompt with it as the suggestion.
    private func finishProviderSignIn(uid: String, email: String, suggestedName: String?) async throws {
        if try await ensureProfile(uid: uid, email: email, suggestedName: suggestedName) {
            pendingUsernamePrompt = cachedDisplayName
        }
    }

    /// A cryptographically-random nonce string, per Apple's Sign in with Apple + Firebase guidance.
    private static func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                return random
            }
            for random in randoms where remaining > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signOut() throws {
        try Auth.auth().signOut()
        clearProfileCache()
    }

    /// Firebase requires a "recent" sign-in before it will let you change
    /// the email or password on an account. Re-authenticating with the
    /// current password lets us do that without forcing a full sign-out.
    func reauthenticate(currentPassword: String) async throws {
        guard let currentUser = Auth.auth().currentUser, let email = currentUser.email else { return }
        let credential = EmailAuthProvider.credential(withEmail: email, password: currentPassword)
        try await currentUser.reauthenticate(with: credential)
    }

    // MARK: - Re-authentication for sensitive actions

    /// How the signed-in account proves it's really them before a sensitive
    /// action (delete account, change password/email). Firebase insists on a
    /// recent sign-in for those, and only password accounts have a password
    /// to type; everyone else re-runs their provider's sheet.
    enum ReauthMethod { case password, apple, google, gameCenter }

    var reauthMethod: ReauthMethod {
        let ids = user?.providerData.map(\.providerID) ?? []
        if ids.contains("password") { return .password }
        if ids.contains("apple.com") { return .apple }
        if ids.contains("google.com") { return .google }
        if ids.contains("gc.apple.com") { return .gameCenter }
        return .password
    }

    /// Emails a password-reset link to the signed-in account's own address,
    /// for a player who is signed in but can't remember their password when a
    /// sensitive action asks for it. Returns the address it went to.
    @discardableResult
    func sendPasswordResetToCurrentUser() async throws -> String {
        guard let email = Auth.auth().currentUser?.email, !email.isEmpty else {
            throw NSError(domain: usernameErrorDomain, code: 8, userInfo: [
                NSLocalizedDescriptionKey: "This account has no email address to send a reset link to.",
            ])
        }
        try await Auth.auth().sendPasswordReset(withEmail: email)
        return email
    }

    /// Re-authenticates a social account by running its own provider's sheet
    /// over `presenting`. Does nothing for password accounts; those use
    /// `reauthenticate(currentPassword:)`. Throws the provider's cancellation
    /// error when the user backs out; see `isUserCancellation(_:)`.
    func reauthenticateWithProvider(presenting: UIViewController) async throws {
        guard let currentUser = Auth.auth().currentUser else { return }
        switch reauthMethod {
        case .password:
            return
        case .apple:
            let (credential, authorizationCode) = try await requestAppleCredential(presenting: presenting)
            try await currentUser.reauthenticate(with: credential)
            // App Store guideline 5.1.1(v): deleting an account must also
            // revoke its Sign in with Apple token. The authorization code
            // only comes from a fresh authorization, which is why the Apple
            // sheet always runs before a delete. Best-effort: Apple's
            // revoke endpoint hiccuping shouldn't strand the deletion.
            if let authorizationCode {
                try? await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
            }
        case .google:
            let (credential, _) = try await requestGoogleCredential(presenting: presenting)
            try await currentUser.reauthenticate(with: credential)
        case .gameCenter:
            guard GKLocalPlayer.local.isAuthenticated else {
                throw NSError(domain: usernameErrorDomain, code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Game Center isn't signed in on this device. Sign in under Settings › Game Center, then try again.",
                ])
            }
            let credential = try await GameCenterAuthProvider.getCredential()
            try await currentUser.reauthenticate(with: credential)
        }
    }

    /// True when `error` is the user dismissing an Apple, Google or Game
    /// Center sheet rather than something that went wrong.
    static func isUserCancellation(_ error: Error) -> Bool {
        if (error as? ASAuthorizationError)?.code == .canceled { return true }
        let nsError = error as NSError
        if nsError.domain == kGIDSignInErrorDomain, nsError.code == GIDSignInError.canceled.rawValue { return true }
        if nsError.domain == GKErrorDomain, nsError.code == GKError.cancelled.rawValue { return true }
        return false
    }

    /// Keeps the in-flight Apple authorization's delegate alive; the
    /// controller only holds it weakly.
    private var appleReauthCoordinator: AppleAuthorizationCoordinator?

    /// Runs the Sign in with Apple sheet programmatically (no SwiftUI button)
    /// and returns a Firebase credential for the result, plus Apple's
    /// one-time authorization code (needed to revoke the token on delete).
    private func requestAppleCredential(presenting: UIViewController) async throws -> (AuthCredential, authorizationCode: String?) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        prepareAppleRequest(request)
        let anchor = presenting.view.window ?? ASPresentationAnchor()
        let authorization: ASAuthorization = try await withCheckedThrowingContinuation { continuation in
            let coordinator = AppleAuthorizationCoordinator(continuation: continuation, anchor: anchor)
            appleReauthCoordinator = coordinator
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator
            controller.performRequests()
        }
        appleReauthCoordinator = nil
        guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let nonce = currentAppleNonce,
              let tokenData = appleCredential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8)
        else {
            throw NSError(domain: usernameErrorDomain, code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't complete Sign in with Apple. Please try again.",
            ])
        }
        currentAppleNonce = nil
        let authorizationCode = appleCredential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        return (OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: nonce, fullName: nil), authorizationCode)
    }

    /// Bridges `ASAuthorizationController`'s delegate callbacks to async/await.
    private final class AppleAuthorizationCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        private var continuation: CheckedContinuation<ASAuthorization, Error>?
        private let anchor: ASPresentationAnchor

        init(continuation: CheckedContinuation<ASAuthorization, Error>, anchor: ASPresentationAnchor) {
            self.continuation = continuation
            self.anchor = anchor
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            continuation?.resume(returning: authorization)
            continuation = nil
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    /// Sends a verification link to the new address; the email only changes
    /// once the user confirms it there (required by Firebase's email-change
    /// policy — a direct `updateEmail` call is rejected on most projects).
    func updateEmail(_ newEmail: String, currentPassword: String) async throws {
        guard let currentUser = Auth.auth().currentUser else { return }
        try await reauthenticate(currentPassword: currentPassword)
        try await currentUser.sendEmailVerification(beforeUpdatingEmail: newEmail)
    }

    func updatePassword(_ newPassword: String, currentPassword: String) async throws {
        guard let currentUser = Auth.auth().currentUser else { return }
        try await reauthenticate(currentPassword: currentPassword)
        try await currentUser.updatePassword(to: newPassword)
    }

    func deleteAccount() async throws {
        guard let currentUser = Auth.auth().currentUser else { return }
        try await currentUser.delete()
        clearProfileCache()
        await Self.eraseLocalPlayerData()
    }

    /// Posted after an account is deleted and this device's local play data
    /// has been wiped, so live services (solo rating) reload their defaults.
    static let accountDeletedNotification = Notification.Name("KryptoAccountDeleted")

    /// Wipes the device-side stats after an account deletion: the Stats
    /// history file and the solo rating / win counters in UserDefaults. The
    /// server side is handled by the `onUserDeleted` function; without this
    /// the Stats page kept showing the deleted account's history from the
    /// local mirror, which reads as the delete not having worked. Sign-out
    /// deliberately leaves these alone (the player may sign back in).
    @MainActor
    private static func eraseLocalPlayerData() {
        StatsLog.shared.eraseLocalHistory()
        let defaults = UserDefaults.standard
        for key in ["soloRating", "soloTier", "soloPuzzlesCompleted", "gamesWon", "bestTime", "totalSolveTime"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: accountDeletedNotification, object: nil)
    }
}
