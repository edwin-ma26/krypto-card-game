package com.edwinma.krypto

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.FirebaseException
import com.google.firebase.auth.AuthCredential
import com.google.firebase.auth.EmailAuthProvider
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import com.google.firebase.auth.userProfileChangeRequest
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class UsernameTakenException : Exception("That username is taken.")

/** Account flows ported from Krypto/AuthService.swift: email sign-in/sign-up with a
 *  reserved unique username, Google sign-in, profile + referral-code bootstrap. */
class AuthRepository(private val context: Context) {
    private val auth = FirebaseAuth.getInstance()
    private val db = FirebaseFirestore.getInstance()

    val currentUser: FirebaseUser? get() = auth.currentUser

    val userFlow: Flow<FirebaseUser?> = callbackFlow {
        val listener = FirebaseAuth.AuthStateListener { trySend(it.currentUser) }
        auth.addAuthStateListener(listener)
        awaitClose { auth.removeAuthStateListener(listener) }
    }

    data class EmailStatus(val exists: Boolean, val providers: List<String>)

    /** Asks the `checkEmail` Cloud Function whether an account exists (see functions/src/auth.ts). */
    suspend fun checkEmail(email: String): EmailStatus = withContext(Dispatchers.IO) {
        val conn = URL("https://us-central1-krypto-game-em26.cloudfunctions.net/checkEmail").openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/json")
        conn.doOutput = true
        conn.outputStream.use { it.write(JSONObject().put("email", email.trim().lowercase()).toString().toByteArray()) }
        if (conn.responseCode != 200) error("Couldn't check that email (HTTP ${conn.responseCode}).")
        val json = JSONObject(conn.inputStream.bufferedReader().readText())
        val providers = json.optJSONArray("providers")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
        EmailStatus(json.optBoolean("exists"), providers)
    }

    suspend fun signIn(email: String, password: String) {
        auth.signInWithEmailAndPassword(email.trim(), password).await()
        currentUser?.let { ensureReferralCode(it.uid) }
    }

    /** Creates the account, then reserves the username. If the name is taken the
     *  half-made account is torn down so the email isn't left stuck. */
    suspend fun signUp(email: String, password: String, username: String) {
        val name = username.trim()
        require(name.isNotEmpty()) { "Please enter a username." }
        auth.createUserWithEmailAndPassword(email.trim(), password).await()
        val user = currentUser ?: return
        try {
            reserveUsername(name, user.uid, email.trim())
        } catch (e: Exception) {
            runCatching { user.delete().await() }
            auth.signOut()
            throw e
        }
        runCatching { user.updateProfile(userProfileChangeRequest { displayName = name }).await() }
        ensureReferralCode(user.uid)
        runCatching { user.sendEmailVerification().await() }
    }

    suspend fun signInWithGoogle() {
        val (firebaseCredential, google) = googleCredential()
        val user = auth.signInWithCredential(firebaseCredential).await().user ?: error("Google sign-in failed.")
        ensureProfile(user.uid, user.email ?: google.id, google.givenName)
    }

    /** Runs the Google account picker and returns the Firebase credential for the
     *  chosen account (plus the raw Google credential for its profile fields). */
    private suspend fun googleCredential(): Pair<AuthCredential, GoogleIdTokenCredential> {
        val webClientId = context.getString(context.resources.getIdentifier("default_web_client_id", "string", context.packageName))
        val option = GetGoogleIdOption.Builder()
            .setFilterByAuthorizedAccounts(false)
            .setServerClientId(webClientId)
            .build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val result = CredentialManager.create(context).getCredential(context, request)
        val google = GoogleIdTokenCredential.createFrom(result.credential.data)
        return GoogleAuthProvider.getCredential(google.idToken, null) to google
    }

    /** True when the account can sign in with a password (so deletion asks for it). */
    val hasPasswordProvider: Boolean
        get() = currentUser?.providerData?.any { it.providerId == EmailAuthProvider.PROVIDER_ID } == true

    /** Proves it's still the account holder before a sensitive change (delete). */
    suspend fun reauthenticate(password: String) {
        val user = currentUser ?: error("Not signed in.")
        val email = user.email ?: error("This account has no email.")
        user.reauthenticate(EmailAuthProvider.getCredential(email, password)).await()
    }

    /** Google accounts re-prove themselves through the account picker. Picking a
     *  different Google account than the one signed in is rejected by Firebase. */
    suspend fun reauthenticateWithGoogle() {
        val user = currentUser ?: error("Not signed in.")
        val (credential, _) = googleCredential()
        user.reauthenticate(credential).await()
    }

    /** Deletes the Auth user. Everything server-side (profile doc, username,
     *  referral code, friends' lists) is cleaned up by the `onUserDeleted`
     *  Cloud Function (functions/src/accountDeletion.ts); this only has to wipe
     *  the device's local play data, as iOS does, so a deleted account's stats
     *  don't linger on screen as if the delete hadn't worked. Sign-out leaves
     *  them alone on purpose. Throws FirebaseAuthRecentLoginRequiredException
     *  when Firebase wants a fresh re-authentication first. */
    suspend fun deleteAccount() {
        val user = currentUser ?: return
        user.delete().await()
        for (store in listOf("solo", "dailyPuzzle")) {
            context.getSharedPreferences(store, Context.MODE_PRIVATE).edit().clear().apply()
        }
    }

    /** Emails a password-reset link; works signed out (sign-in screen) or signed in. */
    suspend fun sendPasswordReset(email: String) {
        auth.sendPasswordResetEmail(email.trim()).await()
    }

    fun signOut() = auth.signOut()

    suspend fun displayName(uid: String): String? =
        runCatching { db.collection("users").document(uid).get().await().getString("displayName") }.getOrNull()

    /** Claims `username` case-insensitively for `uid` and writes the profile doc, atomically. */
    private suspend fun reserveUsername(username: String, uid: String, email: String) {
        val nameRef = db.collection("usernames").document(username.lowercase())
        val userRef = db.collection("users").document(uid)
        try {
            db.runTransaction { tx ->
                val existing = tx.get(nameRef)
                if (existing.exists() && existing.getString("uid") != uid) throw UsernameTakenException()
                tx.set(nameRef, mapOf("uid" to uid, "displayName" to username))
                tx.set(userRef, mapOf("displayName" to username, "email" to email), SetOptions.merge())
                null
            }.await()
        } catch (e: FirebaseException) {
            if (e.cause is UsernameTakenException) throw UsernameTakenException() else throw e
        }
    }

    /** Google accounts get a random unique handle like `edwin4821` if they have no profile yet. */
    private suspend fun ensureProfile(uid: String, email: String, suggestedName: String?) {
        val existing = displayName(uid)
        if (!existing.isNullOrEmpty()) { ensureReferralCode(uid); return }
        val base = (suggestedName ?: "player").lowercase().filter { it.isLetterOrDigit() }.ifEmpty { "player" }.take(12)
        repeat(10) {
            val candidate = "$base${(1000..9999).random()}"
            try {
                reserveUsername(candidate, uid, email)
                runCatching { currentUser?.updateProfile(userProfileChangeRequest { displayName = candidate })?.await() }
                ensureReferralCode(uid)
                return
            } catch (_: UsernameTakenException) { /* try another */ }
        }
    }

    private val codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    /** Mints the account's 6-char referral code if missing; `referralCodes/{code}` is
     *  create-only by rules, so a collision just fails and we try again. */
    private suspend fun ensureReferralCode(uid: String) {
        val ref = db.collection("users").document(uid)
        val existing = runCatching { ref.get().await().getString("referralCode") }.getOrNull()
        if (!existing.isNullOrEmpty()) return
        repeat(8) {
            val code = (1..6).map { codeAlphabet.random() }.joinToString("")
            val ok = runCatching { db.collection("referralCodes").document(code).set(mapOf("uid" to uid)).await() }.isSuccess
            if (ok) { runCatching { ref.set(mapOf("referralCode" to code), SetOptions.merge()).await() }; return }
        }
    }
}

/** The player backed out of the Google account picker: not an error to show. */
fun Throwable.isUserCancellation(): Boolean = this is androidx.credentials.exceptions.GetCredentialCancellationException

/** Human-readable text for Firebase auth failures. */
fun Throwable.authMessage(): String = when (this) {
    is UsernameTakenException -> message ?: "That username is taken."
    is com.google.firebase.auth.FirebaseAuthInvalidCredentialsException -> "Wrong password. Try again."
    is com.google.firebase.auth.FirebaseAuthUserCollisionException -> "An account already exists for that email."
    is com.google.firebase.auth.FirebaseAuthWeakPasswordException -> "Password needs at least 6 characters."
    is com.google.firebase.auth.FirebaseAuthRecentLoginRequiredException -> "Please sign in again to confirm it's you."
    is androidx.credentials.exceptions.GetCredentialCancellationException -> "Sign-in cancelled."
    is androidx.credentials.exceptions.NoCredentialException -> "No Google account on this device."
    else -> message ?: "Something went wrong."
}
