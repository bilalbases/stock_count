package com.example.stockcount

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/** Small hand-made icons, so we don't need the large extended icon library. */
object AppIcons {
    /** Barcode with scan corners. */
    val Barcode: ImageVector by lazy {
        ImageVector.Builder("Barcode", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                // corners
                moveTo(2f, 2f); horizontalLineTo(7f); verticalLineTo(4f); horizontalLineTo(4f); verticalLineTo(7f); horizontalLineTo(2f); close()
                moveTo(17f, 2f); horizontalLineTo(22f); verticalLineTo(7f); horizontalLineTo(20f); verticalLineTo(4f); horizontalLineTo(17f); close()
                moveTo(2f, 17f); horizontalLineTo(4f); verticalLineTo(20f); horizontalLineTo(7f); verticalLineTo(22f); horizontalLineTo(2f); close()
                moveTo(20f, 17f); horizontalLineTo(22f); verticalLineTo(22f); horizontalLineTo(17f); verticalLineTo(20f); horizontalLineTo(20f); close()
                // bars
                for ((x, w) in listOf(6f to 1.5f, 8.5f to 1f, 10.5f to 2f, 13.5f to 1f, 15.5f to 1.5f, 17.5f to 0.8f)) {
                    moveTo(x, 7f); horizontalLineTo(x + w); verticalLineTo(17f); horizontalLineTo(x); close()
                }
            }
        }.build()
    }

    /** Box / inventory. */
    val Inventory: ImageVector by lazy {
        ImageVector.Builder("Inventory", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(3f, 3f); horizontalLineTo(21f); verticalLineTo(8f); horizontalLineTo(3f); close()
                moveTo(4f, 9f); horizontalLineTo(20f); verticalLineTo(21f); horizontalLineTo(4f); close()
            }
            path(fill = SolidColor(Color.White)) {
                moveTo(9f, 11.5f); horizontalLineTo(15f); verticalLineTo(13.5f); horizontalLineTo(9f); close()
            }
        }.build()
    }

    /** Upload arrow into tray. */
    val Upload: ImageVector by lazy {
        ImageVector.Builder("Upload", 24.dp, 24.dp, 24f, 24f).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(12f, 3f); lineTo(18f, 9f); horizontalLineTo(14f); verticalLineTo(15f); horizontalLineTo(10f); verticalLineTo(9f); horizontalLineTo(6f); close()
                moveTo(4f, 17f); horizontalLineTo(20f); verticalLineTo(21f); horizontalLineTo(4f); close()
            }
        }.build()
    }
}
