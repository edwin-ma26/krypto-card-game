package com.edwinma.krypto

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun HomeScreen(onSolo: () -> Unit, onDaily: () -> Unit, onProfile: () -> Unit, onHowToPlay: () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(72.dp))
            Image(painterResource(R.drawable.krypto_logo), null, Modifier.size(72.dp).clip(RoundedCornerShape(18.dp)))
            Spacer(Modifier.height(10.dp))
            Text("Krypto!", style = rounded(40.sp, FontWeight.Black))
            Spacer(Modifier.height(6.dp))
            Text("Combine the cards to hit the target.", style = rounded(16.sp, FontWeight.Medium, KryptoTheme.inkMuted))
            Spacer(Modifier.height(22.dp))

            Column(Modifier.padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                ModeCard("Daily Puzzle", "One puzzle a day. Keep your streak alive.", Icons.Default.LocalFireDepartment, onClick = onDaily)
                ModeCard("Single Player", "Play solo on one device, at your own pace.", Icons.Default.Person, onClick = onSolo)
                ModeCard("Multiplayer", "Race a friend — on one phone, or across devices.", Icons.Default.Group, chip = "COMING SOON")
                ModeCard("Ranked", "Climb the leaderboard against real opponents.", Icons.Default.EmojiEvents, chip = "COMING SOON")
            }
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.height(22.dp))
            Row(Modifier.clickable(onClick = onHowToPlay).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.HelpOutline, null, tint = KryptoTheme.inkMuted, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("How to Play", style = rounded(13.sp, FontWeight.Bold, KryptoTheme.inkMuted))
            }
            Spacer(Modifier.height(12.dp))
        }
        Box(Modifier.align(Alignment.TopEnd).padding(top = 16.dp, end = 4.dp)) {
            PillIconButton(Icons.Default.AccountCircle, contentDescription = "Profile", onClick = onProfile)
        }
    }
}

@Composable
private fun ModeCard(title: String, subtitle: String, icon: ImageVector, chip: String? = null, onClick: (() -> Unit)? = null) {
    WhiteCard(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)) {
        Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Icon(icon, null, tint = KryptoTheme.accent, modifier = Modifier.width(44.dp).size(30.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(title, style = rounded(20.sp, FontWeight.Black))
                    if (chip != null) {
                        Text(chip, style = rounded(11.sp, FontWeight.Black, Color.White).copy(letterSpacing = 0.5.sp),
                            modifier = Modifier.background(KryptoTheme.accent, CircleShape).padding(horizontal = 8.dp, vertical = 3.dp))
                    }
                }
                Text(subtitle, style = rounded(13.sp, FontWeight.Medium, KryptoTheme.inkMuted), maxLines = 2)
            }
            Icon(Icons.Default.ChevronRight, null, tint = KryptoTheme.inkMuted.copy(alpha = 0.5f), modifier = Modifier.size(20.dp))
        }
    }
}
