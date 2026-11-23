package com.edwinma.krypto

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.text.input.KeyboardType
import com.google.firebase.auth.FirebaseAuthRecentLoginRequiredException
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Minimal stand-in for the iOS profile hub: who you are, sign in / out, and
 *  Delete account (Google Play requires an in-app deletion path for any app
 *  that creates accounts). The delete flow mirrors ProfileView.swift: a
 *  confirmation first; email accounts then confirm their password (with a
 *  forgot-password escape hatch); Google accounts try the delete directly and
 *  only re-open the account picker if Firebase insists on a fresh sign-in. */
@Composable
fun ProfileScreen(
    auth: AuthRepository, displayName: String?, email: String?,
    onSignIn: () -> Unit, onSignOut: () -> Unit, onDeleted: () -> Unit, onBack: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    var askPassword by remember { mutableStateOf(false) }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun finishDelete() = scope.launch {
        error = null; note = null; deleting = true
        try {
            if (auth.hasPasswordProvider) {
                auth.reauthenticate(password)
                auth.deleteAccount()
            } else {
                try {
                    auth.deleteAccount()
                } catch (_: FirebaseAuthRecentLoginRequiredException) {
                    auth.reauthenticateWithGoogle()
                    auth.deleteAccount()
                }
            }
            onDeleted()
        } catch (e: Exception) {
            if (!e.isUserCancellation()) error = "Couldn't delete your account: ${e.authMessage()}"
        } finally {
            password = ""; deleting = false
        }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp)) { PillIconButton(Icons.Default.Close, contentDescription = "Close", onClick = onBack) }
        Spacer(Modifier.height(48.dp))
        Icon(Icons.Default.AccountCircle, null, tint = KryptoTheme.inkMuted, modifier = Modifier.size(72.dp))
        Spacer(Modifier.height(12.dp))
        if (displayName != null) {
            Text(displayName, style = rounded(28.sp, FontWeight.Black))
            email?.let { Text(it, style = rounded(14.sp, FontWeight.Medium, KryptoTheme.inkMuted)) }
            Spacer(Modifier.height(32.dp))
            PillButton("Sign out", Modifier.fillMaxWidth(), enabled = !deleting, onClick = onSignOut)
            Spacer(Modifier.weight(1f))
            error?.let { Text(it, style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.danger), textAlign = TextAlign.Center) }
            note?.let { Text(it, style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.inkMuted), textAlign = TextAlign.Center) }
            TextButton(onClick = { error = null; note = null; confirmDelete = true }, enabled = !deleting, modifier = Modifier.padding(bottom = 16.dp)) {
                if (deleting) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = KryptoTheme.danger)
                else Text("Delete account", style = rounded(14.sp, FontWeight.SemiBold, KryptoTheme.danger))
            }
        } else {
            Text("Not signed in", style = rounded(28.sp, FontWeight.Black))
            Text("Sign in to keep your daily streak and play friends.", style = rounded(14.sp, FontWeight.Medium, KryptoTheme.inkMuted), textAlign = TextAlign.Center)
            Spacer(Modifier.height(32.dp))
            PrimaryButton("Sign in", Modifier.fillMaxWidth(), onClick = onSignIn)
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            containerColor = KryptoTheme.background,
            title = { Text("Delete your account?", style = rounded(22.sp, FontWeight.Black)) },
            text = {
                Text(
                    "This permanently deletes your profile, friends, and Competition Mode progress. This can't be undone.",
                    style = rounded(15.sp, FontWeight.Medium, KryptoTheme.inkMuted),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    if (auth.hasPasswordProvider) askPassword = true else finishDelete()
                }) { Text("Delete account", style = rounded(16.sp, FontWeight.Bold, KryptoTheme.danger)) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel", style = rounded(16.sp, FontWeight.Bold)) } },
        )
    }

    if (askPassword) {
        AlertDialog(
            onDismissRequest = { askPassword = false; password = "" },
            containerColor = KryptoTheme.background,
            title = { Text("Confirm your password", style = rounded(22.sp, FontWeight.Black)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        "For your security, your current password is required to permanently delete your account.",
                        style = rounded(15.sp, FontWeight.Medium, KryptoTheme.inkMuted),
                    )
                    AuthField(password, { password = it }, "Password", KeyboardType.Password, secure = !showPassword) { showPassword = !showPassword }
                    TextButton(
                        onClick = {
                            askPassword = false; password = ""
                            scope.launch {
                                runCatching { auth.sendPasswordReset(email ?: "") }
                                    .onSuccess { note = "Reset email sent to $email. Set a new password, then try again." }
                                    .onFailure { error = it.authMessage() }
                            }
                        },
                        contentPadding = PaddingValues(0.dp),
                    ) { Text("Forgot password?", style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.inkMuted)) }
                }
            },
            confirmButton = {
                TextButton(onClick = { askPassword = false; finishDelete() }, enabled = password.isNotEmpty()) {
                    Text("Delete account", style = rounded(16.sp, FontWeight.Bold, KryptoTheme.danger))
                }
            },
            dismissButton = { TextButton(onClick = { askPassword = false; password = "" }) { Text("Cancel", style = rounded(16.sp, FontWeight.Bold)) } },
        )
    }
}

@Composable
fun HowToPlayDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = KryptoTheme.background,
        title = { Text("How to Play", style = rounded(22.sp, FontWeight.Black)) },
        text = {
            Text(
                "Use all five cards to make the target. Tap a card, an operation, then another card to combine them. Fractions are allowed. Hit the target with your last card to win.",
                style = rounded(15.sp, FontWeight.Medium, KryptoTheme.inkMuted),
            )
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Got it", style = rounded(16.sp, FontWeight.Bold)) } },
    )
}
