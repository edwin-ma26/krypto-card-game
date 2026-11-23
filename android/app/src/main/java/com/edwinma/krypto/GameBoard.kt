package com.edwinma.krypto

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/** The iOS play surface (ContentView.puzzleColumn): top bar, target card,
 *  2-column card grid sized to the screen, hint line, operator tray, bottom row. */
@Composable
fun GameBoard(
    game: GameViewModel,
    topBar: @Composable RowScope.() -> Unit,
    aboveTarget: (@Composable () -> Unit)? = null,
    bottomRow: @Composable () -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
    // Same budget as iOS: everything but the three card rows is ~405pt.
    val cardHeight = ((maxHeight.value - 405) / 3f).coerceIn(66f, 300f).dp

    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp), content = topBar)
        Spacer(Modifier.weight(1f, fill = true).heightIn(min = 18.dp))
        aboveTarget?.invoke()
        TargetCard(game.target.toString())
        Spacer(Modifier.height(18.dp))
        CardGrid(game, cardHeight)
        Spacer(Modifier.weight(1f, fill = true).heightIn(min = 18.dp))
        game.hint?.let {
            Text(it, style = rounded(16.sp, FontWeight.SemiBold, KryptoTheme.inkMuted), textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp))
        }
        OperationRow(game)
        bottomRow()
        Spacer(Modifier.height(8.dp))
    }
    }
}

@Composable
fun TargetCard(value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("TARGET", style = rounded(15.sp, FontWeight.Bold, KryptoTheme.inkMuted).copy(letterSpacing = 1.5.sp))
        WhiteCard(radius = 24) {
            Text(value, style = rounded(56.sp, FontWeight.Black), modifier = Modifier.padding(horizontal = 36.dp, vertical = 8.dp))
        }
    }
}

@Composable
private fun CardGrid(game: GameViewModel, cardHeight: Dp) {
    val rows = game.cards.chunked(2)
    Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
        rows.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                row.forEach { card -> PlayingCard(card, game.selectedCardId == card.id, cardHeight, Modifier.weight(1f)) { game.tapCard(card) } }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
fun PlayingCard(card: Card, selected: Boolean, height: Dp, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val scale by animateFloatAsState(if (selected) 1.05f else 1f, spring(), label = "cardScale")
    val shape = RoundedCornerShape(26.dp)
    Box(
        modifier
            .height(height)
            .scale(scale)
            .shadow(8.dp, shape, ambientColor = KryptoTheme.shadow, spotColor = KryptoTheme.shadow)
            .background(KryptoTheme.cardColors[card.colorIndex % KryptoTheme.cardColors.size], shape)
            .border(3.dp, KryptoTheme.inkDark.copy(alpha = if (selected) 0.8f else 0f), shape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        val size = (height.value * if (card.value.isWhole) 0.43f else 0.28f).sp
        Text(card.value.toString(), style = rounded(size, FontWeight.Black), maxLines = 1, modifier = Modifier.padding(horizontal = 8.dp))
    }
}

@Composable
private fun OperationRow(game: GameViewModel) {
    Row(
        Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.6f), RoundedCornerShape(20.dp)).padding(6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Operation.entries.forEach { op ->
            val active = game.selectedOp == op
            Box(
                Modifier.weight(1f).height(60.dp)
                    .background(if (active) KryptoTheme.button else KryptoTheme.pill, RoundedCornerShape(16.dp))
                    .clickable { game.tapOperation(op) },
                contentAlignment = Alignment.Center,
            ) { Text(op.symbol, style = rounded(26.sp, FontWeight.Bold, if (active) Color.White else KryptoTheme.inkDark)) }
        }
    }
    Spacer(Modifier.height(12.dp))
}

/** Dimmed scrim with a cream result card, as in the iOS win / solved overlays. */
@Composable
fun ResultOverlay(content: @Composable ColumnScope.() -> Unit) {
    // A window-level dialog so the scrim covers the status and navigation bars too.
    Dialog(onDismissRequest = {}, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false, dismissOnBackPress = false, dismissOnClickOutside = false)) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.25f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(horizontal = 24.dp)
                .shadow(30.dp, RoundedCornerShape(32.dp), ambientColor = Color.Black.copy(alpha = 0.2f), spotColor = Color.Black.copy(alpha = 0.2f))
                .background(KryptoTheme.background, RoundedCornerShape(32.dp))
                .padding(horizontal = 28.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp), content = content,
        )
    }
    }
}
