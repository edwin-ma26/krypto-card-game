package com.edwinma.krypto

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

private enum class Step { Email, Password, Create }

/** Email-first sign-in (ported from Krypto/EmailSignInFlow.swift) plus Google. */
@Composable
fun SignInScreen(auth: AuthRepository, onDone: () -> Unit, onBack: () -> Unit) {
    var step by remember { mutableStateOf(Step.Email) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var username by remember { mutableStateOf("") }
    var providers by remember { mutableStateOf<List<String>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var info by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun run(block: suspend () -> Unit) {
        error = null; info = null; busy = true
        scope.launch {
            runCatching { block() }.onFailure { error = it.authMessage() }
            busy = false
        }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
            PillIconButton(Icons.Default.ChevronLeft, contentDescription = "Back") { if (step == Step.Email) onBack() else { step = Step.Email; error = null } }
        }
        Spacer(Modifier.height(6.dp))
        Icon(
            when (step) { Step.Email -> Icons.Default.Email; Step.Password -> Icons.Default.Lock; Step.Create -> Icons.Default.PersonAdd },
            null, tint = KryptoTheme.accent, modifier = Modifier.size(40.dp),
        )
        Text(
            when (step) { Step.Email -> "What's your email?"; Step.Password -> "Welcome back"; Step.Create -> "Create your account" },
            style = rounded(24.sp, FontWeight.Black),
        )
        Text(
            when (step) {
                Step.Email -> "We'll check whether you already have an account."
                Step.Password -> "Enter your password to sign in."
                Step.Create -> "Pick a username. It's how friends will find you."
            },
            style = rounded(13.sp, FontWeight.Medium, KryptoTheme.inkMuted), textAlign = TextAlign.Center,
        )
        if (step != Step.Email) {
            Row(Modifier.background(Color.White, CircleShape).padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Default.Email, null, tint = KryptoTheme.inkMuted, modifier = Modifier.size(14.dp))
                Text(email, style = rounded(14.sp, FontWeight.SemiBold, KryptoTheme.inkMuted), maxLines = 1)
            }
        }

        when (step) {
            Step.Email -> {
                AuthField(email, { email = it }, "Email", KeyboardType.Email)
                PrimaryButton("Continue", Modifier.fillMaxWidth(), enabled = !busy && email.contains("@")) {
                    run {
                        val status = auth.checkEmail(email)
                        providers = status.providers
                        step = if (status.exists) Step.Password else Step.Create
                    }
                }
                Text("or", style = rounded(13.sp, FontWeight.Medium, KryptoTheme.inkMuted))
                OutlinedButton(
                    onClick = { run { auth.signInWithGoogle(); onDone() } }, enabled = !busy,
                    modifier = Modifier.fillMaxWidth().height(56.dp), shape = RoundedCornerShape(18.dp),
                    colors = ButtonDefaults.outlinedButtonColors(containerColor = Color.White, contentColor = KryptoTheme.inkDark),
                ) { Text("Continue with Google", style = rounded(18.sp, FontWeight.Bold)) }
            }
            Step.Password -> {
                if ("password" !in providers && providers.isNotEmpty()) {
                    Text("You signed up with ${providers.joinToString { it.removeSuffix(".com") }}. Use that button instead.", style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.accent), textAlign = TextAlign.Center)
                }
                AuthField(password, { password = it }, "Password", KeyboardType.Password, secure = !showPassword) { showPassword = !showPassword }
                PrimaryButton("Sign in", Modifier.fillMaxWidth(), enabled = !busy && password.isNotEmpty()) { run { auth.signIn(email, password); onDone() } }
                TextButton(
                    onClick = { run { auth.sendPasswordReset(email); info = "Password reset email sent to $email. Check your spam folder if it doesn't show up." } },
                    enabled = !busy,
                ) { Text("Forgot password?", style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.inkMuted)) }
            }
            Step.Create -> {
                AuthField(username, { username = it }, "Username", KeyboardType.Text)
                AuthField(password, { password = it }, "Password", KeyboardType.Password, secure = !showPassword) { showPassword = !showPassword }
                PrimaryButton("Create account", Modifier.fillMaxWidth(), enabled = !busy && username.isNotBlank() && password.length >= 6) {
                    run { auth.signUp(email, password, username); onDone() }
                }
            }
        }
        error?.let { Text(it, style = rounded(13.sp, FontWeight.SemiBold, Color(0xBFCC3333)), textAlign = TextAlign.Center) }
        info?.let { Text(it, style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.inkMuted), textAlign = TextAlign.Center) }
        if (busy) CircularProgressIndicator(color = KryptoTheme.accent)
    }
}

@Composable
fun AuthField(value: String, onChange: (String) -> Unit, label: String, type: KeyboardType, secure: Boolean = false, onToggleSecure: (() -> Unit)? = null) {
    TextField(
        value, onChange, placeholder = { Text(label, style = rounded(16.sp, FontWeight.Medium, KryptoTheme.inkMuted)) }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = type),
        visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
        textStyle = rounded(16.sp, FontWeight.Medium),
        trailingIcon = onToggleSecure?.let { { IconButton(onClick = it) { Icon(if (secure) Icons.Default.Visibility else Icons.Default.VisibilityOff, null, tint = KryptoTheme.inkMuted) } } },
        shape = RoundedCornerShape(16.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = KryptoTheme.pill, unfocusedContainerColor = KryptoTheme.pill,
            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
            cursorColor = KryptoTheme.inkDark, focusedTextColor = KryptoTheme.inkDark, unfocusedTextColor = KryptoTheme.inkDark,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}
