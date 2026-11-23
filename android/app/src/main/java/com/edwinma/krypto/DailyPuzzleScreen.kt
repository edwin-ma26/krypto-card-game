package com.edwinma.krypto

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch

private sealed interface Phase {
    data object Loading : Phase
    data class Error(val message: String) : Phase
    data class Ready(val puzzle: DailyPuzzleRepository.Puzzle, val completion: DailyPuzzleRepository.Completion?) : Phase
}

@Composable
fun DailyPuzzleScreen(solverName: String, signedIn: Boolean, onBack: () -> Unit, onProfile: () -> Unit, game: GameViewModel = viewModel()) {
    val context = LocalContext.current
    val repo = remember { DailyPuzzleRepository(context) }
    var phase by remember { mutableStateOf<Phase>(Phase.Loading) }
    var reloadKey by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(reloadKey) {
        phase = Phase.Loading
        phase = runCatching {
            val puzzle = repo.loadToday()
            Phase.Ready(puzzle, repo.existingCompletion(puzzle.dateKey))
        }.getOrElse { Phase.Error(it.message ?: "Couldn't load today's puzzle.") }
    }

    Box(Modifier.fillMaxSize()) {
        when (val p = phase) {
            Phase.Loading -> CircularProgressIndicator(Modifier.align(Alignment.Center), color = KryptoTheme.accent)
            is Phase.Error -> Column(Modifier.align(Alignment.Center).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(p.message, style = rounded(16.sp, FontWeight.Medium, KryptoTheme.inkMuted), textAlign = TextAlign.Center)
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    PillButton("Home", height = 52, onClick = onBack)
                    PrimaryButton("Retry", height = 52) { reloadKey++ }
                }
            }
            is Phase.Ready -> {
                val completion = p.completion
                if (completion != null && !game.isSolved) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) {
                        PillIconButton(Icons.Default.ChevronLeft, contentDescription = "Home", onClick = onBack)
                    }
                    CompletedState(completion, signedIn, Modifier.align(Alignment.Center))
                } else {
                    LaunchedEffect(p.puzzle.dateKey) {
                        game.onSolved = { seconds ->
                            PuzzleStatsRepository.recordSolved(p.puzzle.hand, p.puzzle.target, seconds, solverName)
                            scope.launch {
                                val c = repo.recordCompletion(p.puzzle.dateKey, seconds)
                                phase = Phase.Ready(p.puzzle, c)
                            }
                        }
                        game.startShared(p.puzzle.hand, p.puzzle.target)
                    }
                    GameBoard(
                        game,
                        topBar = {
                            PillIconButton(Icons.Default.ChevronLeft, contentDescription = "Home", onClick = onBack)
                            PillLabel(game.timeString, Icons.Default.Schedule)
                            if (signedIn) PillLabel("${completion?.streak ?: 0}", Icons.Default.LocalFireDepartment, tint = KryptoTheme.accent)
                            Spacer(Modifier.weight(1f))
                            Text("DAILY", style = rounded(12.sp, FontWeight.Black, KryptoTheme.accent).copy(letterSpacing = 1.sp),
                                modifier = Modifier.background(KryptoTheme.pill, CircleShape).padding(horizontal = 12.dp, vertical = 10.dp))
                            PillIconButton(Icons.Default.AccountCircle, contentDescription = "Profile", onClick = onProfile)
                        },
                        // No hints in the daily, same as iOS: everyone gets the same hand.
                        bottomRow = {
                            PillButton("Undo", Modifier.fillMaxWidth(), enabled = game.canUndo && !game.isSolved, icon = Icons.AutoMirrored.Filled.Undo, onClick = game::undo)
                        },
                    )
                    if (game.isSolved) {
                        ResultOverlay {
                            Text("🔥", fontSize = 56.sp)
                            Text(if (signedIn && completion != null) "${completion.streak}-Day Streak" else "Solved!", style = rounded(32.sp, FontWeight.Black))
                            Text("Solved in ${game.timeString}", style = rounded(13.sp, FontWeight.Medium, KryptoTheme.inkMuted))
                            if (!signedIn) Text("Sign in to keep your streak and race your friends.", style = rounded(13.sp, FontWeight.Medium, KryptoTheme.inkMuted), textAlign = TextAlign.Center)
                            Spacer(Modifier.height(8.dp))
                            PrimaryButton("Done", Modifier.fillMaxWidth(), height = 52, icon = Icons.Default.Check, onClick = onBack)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CompletedState(c: DailyPuzzleRepository.Completion, signedIn: Boolean, modifier: Modifier) {
    Column(modifier.padding(horizontal = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("🔥", fontSize = 56.sp)
        Text(if (signedIn) "${c.streak}-Day Streak" else "Solved today!", style = rounded(30.sp, FontWeight.Black))
        Text("You've solved today's puzzle. Come back tomorrow!", style = rounded(16.sp, FontWeight.Medium, KryptoTheme.inkMuted), textAlign = TextAlign.Center)
        if (signedIn && c.longestStreak > c.streak) Text("Best: ${c.longestStreak} days", style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.inkMuted))
        Text("Your time: %d:%02d".format(c.solveSeconds / 60, c.solveSeconds % 60), style = rounded(13.sp, FontWeight.SemiBold, KryptoTheme.inkMuted))
    }
}
