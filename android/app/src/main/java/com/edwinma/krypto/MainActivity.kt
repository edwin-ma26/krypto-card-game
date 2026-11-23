package com.edwinma.krypto

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.lifecycle.compose.collectAsStateWithLifecycle

private enum class Screen { Home, Solo, Daily, SignIn, Profile }

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.light(Color.Transparent.toArgb(), Color.Transparent.toArgb()))
        val auth = AuthRepository(this)
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(
                background = KryptoTheme.background, surface = KryptoTheme.background,
                primary = KryptoTheme.button, onPrimary = Color.White, onBackground = KryptoTheme.inkDark, onSurface = KryptoTheme.inkDark,
            )) {
                var screen by rememberSaveable { mutableStateOf(Screen.Home) }
                var showHowToPlay by remember { mutableStateOf(false) }
                val user by auth.userFlow.collectAsStateWithLifecycle(initialValue = auth.currentUser)
                var displayName by remember { mutableStateOf<String?>(null) }
                // Keyed on the screen too: sign-up's auth change fires before the profile
                // doc exists, so the name is re-read when the player lands back on Home.
                LaunchedEffect(user?.uid, screen) {
                    displayName = user?.let { u -> auth.displayName(u.uid) ?: u.displayName ?: "Player" }
                }
                val solverName = displayName ?: "Player"
                val home = { screen = Screen.Home }
                val profile = { screen = Screen.Profile }
                BackHandler(enabled = screen != Screen.Home, onBack = home)

                Surface(color = KryptoTheme.background) {
                    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                        when (screen) {
                            Screen.Home -> HomeScreen(
                                onSolo = { screen = Screen.Solo }, onDaily = { screen = Screen.Daily },
                                onProfile = profile, onHowToPlay = { showHowToPlay = true },
                            )
                            Screen.Solo -> SoloScreen(solverName, onBack = home, onProfile = profile)
                            Screen.Daily -> DailyPuzzleScreen(solverName, signedIn = user != null, onBack = home, onProfile = profile)
                            Screen.SignIn -> SignInScreen(auth, onDone = home, onBack = home)
                            Screen.Profile -> ProfileScreen(
                                auth = auth, displayName = user?.let { solverName }, email = user?.email,
                                onSignIn = { screen = Screen.SignIn }, onSignOut = { auth.signOut(); screen = Screen.Home },
                                onDeleted = home, onBack = home,
                            )
                        }
                        if (showHowToPlay) HowToPlayDialog { showHowToPlay = false }
                    }
                }
            }
        }
    }
}
