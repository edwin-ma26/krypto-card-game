package com.edwinma.krypto

import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

/** Single Player: deal, solve, deal again. Local best/won only for now —
 *  the beat-the-clock rating (Krypto/SoloRating.swift) is not ported yet. */
@Composable
fun SoloScreen(solverName: String, onBack: () -> Unit, onProfile: () -> Unit, game: GameViewModel = viewModel()) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("solo", Context.MODE_PRIVATE) }
    var won by remember { mutableIntStateOf(prefs.getInt("won", 0)) }
    var best by remember { mutableIntStateOf(prefs.getInt("best", 0)) }
    var hand by remember { mutableStateOf<List<Int>>(emptyList()) }
    var target by remember { mutableIntStateOf(0) }
    var showResult by remember { mutableStateOf(false) }

    fun deal() {
        val (h, t) = KryptoEngine.deal()
        hand = h; target = t; showResult = false
        PuzzleStatsRepository.recordDealt(h, t)
        game.startShared(h, t)
    }

    LaunchedEffect(Unit) {
        game.onSolved = { seconds ->
            PuzzleStatsRepository.recordSolved(hand, target, seconds, solverName)
            won += 1
            if (best == 0 || seconds < best) best = seconds
            prefs.edit().putInt("won", won).putInt("best", best).apply()
            showResult = true
        }
        if (game.cards.isEmpty()) deal()
    }

    Box(Modifier.fillMaxSize()) {
        GameBoard(
            game,
            topBar = {
                PillIconButton(Icons.Default.ChevronLeft, contentDescription = "Home", onClick = onBack)
                PillLabel(game.timeString, Icons.Default.Schedule)
                Spacer(Modifier.weight(1f))
                PillIconButton(Icons.Default.Lightbulb, tint = KryptoTheme.accent, contentDescription = "Hint", onClick = game::showHint)
                PillIconButton(Icons.Default.AccountCircle, contentDescription = "Profile", onClick = onProfile)
            },
            bottomRow = {
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    PillButton("Undo", Modifier.weight(1f), enabled = game.canUndo && !game.isSolved, icon = Icons.AutoMirrored.Filled.Undo, onClick = game::undo)
                    PrimaryButton(if (game.isSolved) "Next Puzzle" else "New Puzzle", Modifier.weight(1f), height = 58,
                        icon = if (game.isSolved) Icons.AutoMirrored.Filled.ArrowForward else Icons.Default.Refresh, onClick = ::deal)
                }
            },
        )
        if (showResult) {
            ResultOverlay {
                Text("🎉", fontSize = 56.sp)
                Text("Krypto!", style = rounded(36.sp, FontWeight.Black))
                Text("Solved in ${game.timeString}", style = rounded(20.sp, FontWeight.SemiBold, KryptoTheme.inkMuted))
                Text("Won $won · Best ${"%d:%02d".format(best / 60, best % 60)}", style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.inkMuted))
                Spacer(Modifier.height(8.dp))
                PrimaryButton("Next Puzzle", icon = Icons.AutoMirrored.Filled.ArrowForward, onClick = ::deal)
                TextButton(onClick = { showResult = false }) { Text("View board", style = rounded(14.sp, FontWeight.Bold, KryptoTheme.inkMuted)) }
            }
        }
    }
}
