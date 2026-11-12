package com.example.stockcount

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

val Brand = Color(0xFF2E358F)       // Alaswaq Alwatania blue
val BrandDark = Color(0xFF232970)
val Accent = Color(0xFF00A3A3)      // teal
val FooterGrey = Color(0xFF8A929E)  // soft grey for the credits line

private val Light = lightColorScheme(
    primary = Brand,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDFE0FF),
    onPrimaryContainer = Color(0xFF0F1450),
    secondary = Accent,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFC8F3F1),
    onSecondaryContainer = Color(0xFF00201F),
    background = Color(0xFFF4F6FA),
    surface = Color(0xFFF4F6FA),
    surfaceContainerLow = Color.White,
    surfaceContainer = Color.White,
    surfaceVariant = Color(0xFFE3E8F0),
    onSurfaceVariant = Color(0xFF5A6474),
    outline = Color(0xFFB4BCC8),
    outlineVariant = Color(0xFFDDE2EA),
)

private val Dark = darkColorScheme(
    primary = Color(0xFFBDC2FF),
    onPrimary = Color(0xFF1A1F6E),
    primaryContainer = Color(0xFF2E358F),
    onPrimaryContainer = Color(0xFFDFE0FF),
    secondary = Color(0xFF5ADBD8),
    onSecondary = Color(0xFF003736),
    secondaryContainer = Color(0xFF00504E),
    onSecondaryContainer = Color(0xFFC8F3F1),
    background = Color(0xFF10141A),
    surface = Color(0xFF10141A),
    surfaceContainerLow = Color(0xFF181D24),
    surfaceContainer = Color(0xFF1C2129),
)

/** App theme chosen in the menu: "system" (follow the phone), "light" or "dark". */
object ThemeMode {
    var mode by mutableStateOf("system")
    val label get() = when (mode) { "light" -> "Light"; "dark" -> "Dark"; else -> "Phone setting" }
    fun next() = when (mode) { "system" -> "light"; "light" -> "dark"; else -> "system" }
}

@Composable
fun StockTheme(content: @Composable () -> Unit) {
    val dark = when (ThemeMode.mode) { "light" -> false; "dark" -> true; else -> isSystemInDarkTheme() }
    MaterialTheme(
        colorScheme = if (dark) Dark else Light,
        shapes = Shapes(
            small = RoundedCornerShape(10.dp),
            medium = RoundedCornerShape(14.dp),
            large = RoundedCornerShape(20.dp),
        ),
        content = content
    )
}
