package com.edwinma.krypto

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The shipped palette, same literals as `Remote.Palette.fallback` on iOS
 *  (and the `theme_palette` Remote Config default). */
object KryptoTheme {
    val background = Color(0xFFF8F6F1)
    val pill = Color(0xFFF0ECE2)
    val codeField = Color(0xFFD1D1D1)
    val codeText = Color(0xFF404040)
    val inkDark = Color(0xFF4A3B29)
    val inkMuted = Color(0xFF8C806B)
    val button = Color(0xFF5C4A30)
    val accent = Color(0xFFD9A640)
    /** Destructive actions (Delete account), the iOS `.red` role. */
    val danger = Color(0xFFD64545)
    val cardColors = listOf(
        Color(0xFFE8D6A3), // sand
        Color(0xFFC7D9B8), // sage
        Color(0xFFDEBF99), // tan
        Color(0xFFD4CFC4), // stone
        Color(0xFFE0C7BD), // clay
    )
    val shadow = Color.Black.copy(alpha = 0.07f)
}

/** iOS uses SF Rounded; Android's closest system face is the default sans at heavy weights. */
val Rounded = FontFamily.SansSerif

fun rounded(size: TextUnit, weight: FontWeight = FontWeight.Bold, color: Color = KryptoTheme.inkDark) =
    TextStyle(fontFamily = Rounded, fontSize = size, fontWeight = weight, color = color)

/** Round pill-backed icon button, as in every iOS top bar. */
@Composable
fun PillIconButton(icon: ImageVector, tint: Color = KryptoTheme.inkMuted, contentDescription: String?, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp).background(KryptoTheme.pill, CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, contentDescription, tint = tint, modifier = Modifier.size(20.dp)) }
}

/** Capsule label with an optional leading icon, e.g. the clock or streak. */
@Composable
fun PillLabel(text: String, icon: ImageVector? = null, tint: Color = KryptoTheme.inkMuted) {
    Row(
        Modifier.background(KryptoTheme.pill, CircleShape).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) Icon(icon, null, tint = tint, modifier = Modifier.size(16.dp))
        Text(text, style = rounded(15.sp, FontWeight.Bold, tint))
    }
}

/** Solid brown primary button (iOS `Theme.button`). */
@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Int = 56, icon: ImageVector? = null, onClick: () -> Unit) {
    Button(
        onClick = onClick, enabled = enabled, modifier = modifier.height(height.dp), shape = RoundedCornerShape(18.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = KryptoTheme.button, contentColor = Color.White,
            disabledContainerColor = KryptoTheme.button.copy(alpha = 0.4f), disabledContentColor = Color.White,
        ),
    ) {
        if (icon != null) { Icon(icon, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)) }
        Text(text, style = rounded(18.sp, FontWeight.Bold, Color.White))
    }
}

/** Soft pill secondary button (iOS `Theme.pill` background, ink text). */
@Composable
fun PillButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Int = 58, icon: ImageVector? = null, onClick: () -> Unit) {
    val ink = if (enabled) KryptoTheme.inkDark else KryptoTheme.inkMuted.copy(alpha = 0.5f)
    Button(
        onClick = onClick, enabled = enabled, modifier = modifier.height(height.dp), shape = RoundedCornerShape(18.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = KryptoTheme.pill, contentColor = ink,
            disabledContainerColor = KryptoTheme.pill, disabledContentColor = ink,
        ),
    ) {
        if (icon != null) { Icon(icon, null, Modifier.size(18.dp), tint = ink); Spacer(Modifier.width(8.dp)) }
        Text(text, style = rounded(18.sp, FontWeight.Bold, ink))
    }
}

/** White rounded card with the soft drop shadow used for mode cards and the target. */
@Composable
fun WhiteCard(modifier: Modifier = Modifier, radius: Int = 22, content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier
            .shadow(10.dp, RoundedCornerShape(radius.dp), ambientColor = KryptoTheme.shadow, spotColor = KryptoTheme.shadow)
            .background(Color.White, RoundedCornerShape(radius.dp)),
        content = content,
    )
}
